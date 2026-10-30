// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI CSI-2 receiver: D-PHY digital part (LP state machines, clock
// gating, sync detection and byte alignment) and CSI-2 protocol layer, with
// a RAW10 AXI4-Stream output (1 pixel/clock) for the ISP. The D-PHY I/O
// (LP / HS receivers, deserialisers, input delays) is outside, e.g.
// hw/fpga/common/rtl/bow_dphy_io_xusp.sv on the KV260.
//
//   lp pins ----------------------------> bow_dphy_lp x (1 + Lanes) --> hs_en, byte_ce
//                                               | hs_active
//   rx_data -> bow_dphy_align x Lanes -> bow_csi2_lane_merge -> bow_csi2_packet -> bow_csi2_unpack
//                                                                                       |
//   m_axis <- bow_csi2rx_out <-------------- bow_fifo_async (byte -> video clock) <-----+
//
// Clock domains:
//   clk_i       CPU: registers, counters, LOG/RAW read (bow_csi2rx_regs)
//   vid_clk_i   video: LP state machines, PHY control, pixel output
//   byte_clk_i  byte clock = HS clock / 4, runs only while byte_ce_o = 1 and
//               the clock lane toggles (non-continuous clock: HS bursts only)
// Resets (asynchronous assertion, synchronous release):
//   vrst_n      video hard reset (vid_rst_ni & rst_ni)
//   brst_n      byte hard reset: event toggles, command handshakes, LOG/RAW
//               capture, byte clock meter, IDELAY load, clock toggle
//   drst_n      byte datapath (aligners .. FIFO write side) and
//   vdrst_n     video datapath (FIFO read side, output): asserted while RX
//               is off (rx_on = CTRL.PHY_EN & RX_EN, a CPU flop), so a stop
//               drops partial packets, lines, the frame state and the FIFO.
//               drst_n is released by the first byte clocks of a burst.
//   byte_rst_o  ISERDES reset: asserted while the byte clock gate is closed,
//               released 2 byte clocks after the clock restarts.
// Clock domain crossings: configuration through one bow_sync per bit
// (quasi-static), events through one bow_cdc_pulse per kind, commands to
// the byte domain as gray request / ack counters, pixels through
// bow_fifo_async, gray coded byte clock meter. See bow_csi2rx_regs for the
// register map.

module bow_csi2rx import bow_bus_pkg::*; import bow_csi2rx_pkg::*; #(
  parameter int unsigned Lanes     = 2,            // physical data lanes: 1 or 2
  parameter int unsigned PhyClkHz  = 200_000_000,  // vid_clk_i frequency (INFO)
  parameter bit          HasPhy    = 1'b1,         // INFO.PHY: a D-PHY is connected
  parameter int unsigned FifoDepth = 256           // pixel FIFO entries (4 px each), power of 2
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  bus_req_t              bus_req_i,
  output bus_rsp_t              bus_rsp_o,
  output logic                  irq_o,
  input  logic                  vid_clk_i,
  input  logic                  vid_rst_ni,
  output logic                  m_axis_tvalid_o,
  input  logic                  m_axis_tready_i,
  output logic [9:0]            m_axis_tdata_o,
  output logic                  m_axis_tuser_o,   // start of frame (first pixel)
  output logic                  m_axis_tlast_o,   // end of line
  input  logic                  byte_clk_i,
  output logic                  byte_ce_o,        // video domain flop (clock lane FSM)
  output logic                  byte_rst_o,       // ISERDES RST
  input  logic [1:0]            clk_lp_i,
  output logic                  clk_hs_en_o,      // video domain flop of the FSM, no extra stage
  input  logic [Lanes-1:0][1:0] lp_i,
  output logic [Lanes-1:0]      hs_en_o,          // video domain flops of the FSMs, no extra stage
  input  logic [Lanes-1:0][7:0] rx_data_i,        // registered once on byte_clk_i before use
  output logic [Lanes-1:0][8:0] dly_tap_o,        // byte domain
  output logic [Lanes-1:0]      dly_load_o,       // byte domain
  input  logic [Lanes-1:0][8:0] dly_tap_i         // byte domain (CNTVALUEOUT)
);

  localparam int unsigned NumPktEv = $bits(csi2_pkt_ev_t);
  localparam int unsigned NumBEv   = NumPktEv + 1 + Lanes;   // packet, skew, sot per lane
  localparam int unsigned NumVEv   = 2 * (Lanes + 1);        // hs, lp_err per lane FSM

  // =========================================================================
  // Resets
  // =========================================================================
  logic rst_src_n, rx_on, byte_ce;
  logic vrst_n, brst_n, drst_n, vdrst_n, iserdes_rst_n;

  assign rst_src_n = vid_rst_ni & rst_ni;

  bow_rst_sync u_vrst (
    .clk_i  (vid_clk_i),
    .rst_ni (rst_src_n),
    .rst_no (vrst_n)
  );

  bow_rst_sync u_brst (
    .clk_i  (byte_clk_i),
    .rst_ni (rst_src_n),
    .rst_no (brst_n)
  );

  bow_rst_sync u_drst (
    .clk_i  (byte_clk_i),
    .rst_ni (rst_src_n & rx_on),
    .rst_no (drst_n)
  );

  bow_rst_sync u_vdrst (
    .clk_i  (vid_clk_i),
    .rst_ni (rst_src_n & rx_on),
    .rst_no (vdrst_n)
  );

  bow_rst_sync u_iserdes_rst (
    .clk_i  (byte_clk_i),
    .rst_ni (rst_src_n & byte_ce),
    .rst_no (iserdes_rst_n)
  );

  assign byte_rst_o = ~iserdes_rst_n;

  // =========================================================================
  // CPU domain: registers
  // =========================================================================
  csi2_cfg_t             cfg;
  csi2_ev_t              ev_sys;
  logic [Lanes:0]        lane_en_sys;
  logic [Lanes-1:0][8:0] dly_sys, dly_out_sys;
  logic [3:0]            log_req_sys, log_ack, log_ack_sys, raw_req_sys, raw_ack, raw_ack_sys;
  logic                  log_trig_sys, log_stop_sys, raw_now_sys;
  logic [5:0]            log_wptr, log_wptr_sys, ram_addr;
  logic                  log_re, raw_re;
  logic [29:0]           log_rdata;
  logic [8*Lanes-1:0]    raw_rdata;
  logic [15:0]           frame_lines, frame_num, line_wc;
  logic [31:0]           frame_sum;
  logic [5:0]            line_dt;
  logic [1:0]            line_vc;
  logic [Lanes:0][1:0]   lp_sys;
  logic [Lanes:0]        hs_en_sys;
  logic                  ce_sys, in_frame, in_frame_sys;
  logic [19:0]           meter_gray_q, meter_sys;

  bow_csi2rx_regs #(
    .Lanes     (Lanes),
    .PhyClkHz  (PhyClkHz),
    .HasPhy    (HasPhy),
    .FifoDepth (FifoDepth)
  ) u_regs (
    .clk_i,
    .rst_ni,
    .bus_req_i,
    .bus_rsp_o,
    .irq_o,
    .cfg_o         (cfg),
    .rx_on_o       (rx_on),
    .lane_en_o     (lane_en_sys),
    .dly_tap_o     (dly_sys),
    .log_req_o     (log_req_sys),
    .log_trig_fs_o (log_trig_sys),
    .log_stop_fe_o (log_stop_sys),
    .log_ack_i     (log_ack_sys),
    .log_wptr_i    (log_wptr_sys),
    .raw_req_o     (raw_req_sys),
    .raw_now_o     (raw_now_sys),
    .raw_ack_i     (raw_ack_sys),
    .log_re_o      (log_re),
    .raw_re_o      (raw_re),
    .ram_addr_o    (ram_addr),
    .log_rdata_i   (log_rdata),
    .raw_rdata_i   (raw_rdata),
    .ev_i          (ev_sys),
    .frame_lines_i (frame_lines),
    .frame_num_i   (frame_num),
    .frame_sum_i   (frame_sum),
    .line_wc_i     (line_wc),
    .line_dt_i     (line_dt),
    .line_vc_i     (line_vc),
    .lp_i          (lp_sys),
    .hs_en_i       (hs_en_sys),
    .ce_i          (ce_sys),
    .in_frame_i    (in_frame_sys),
    .meter_i       (meter_sys),
    .dly_tap_i     (dly_out_sys)
  );

  // =========================================================================
  // Video domain: LP state machines
  // =========================================================================
  logic [Lanes:0]      lane_en, hs_en, hs_act, ev_hs, ev_lp_err;
  logic [Lanes:0][1:0] lp_st;
  logic                clk_force, clk_edge;
  logic [7:0]          settle, clk_settle, clk_miss;
  logic [3:0]          lp_filter;

  bow_csi2_sync #(
    .Width (Lanes + 30)
  ) u_sync_vcfg (
    .clk_i  (vid_clk_i),
    .rst_ni (vrst_n),
    .d_i    ({cfg.clk_force, lane_en_sys, cfg.settle, cfg.lp_filter, cfg.clk_settle, cfg.clk_miss}),
    .q_o    ({clk_force, lane_en, settle, lp_filter, clk_settle, clk_miss})
  );

  bow_dphy_lp #(
    .ClockLane (1'b1)
  ) u_lp_clk (
    .clk_i       (vid_clk_i),
    .rst_ni      (vrst_n),
    .en_i        (lane_en[0]),
    .force_hs_i  (clk_force),
    .settle_i    (clk_settle),
    .filter_i    (lp_filter),
    .miss_i      (clk_miss),
    .clk_edge_i  (clk_edge),
    .lp_i        (clk_lp_i),
    .lp_o        (lp_st[0]),
    .hs_en_o     (hs_en[0]),
    .hs_active_o (hs_act[0]),
    .ce_o        (byte_ce),
    .ev_hs_o     (ev_hs[0]),
    .ev_err_o    (ev_lp_err[0])
  );

  for (genvar l = 0; l < Lanes; l++) begin : g_lp
    bow_dphy_lp #(
      .ClockLane (1'b0)
    ) u_lp (
      .clk_i       (vid_clk_i),
      .rst_ni      (vrst_n),
      .en_i        (lane_en[1 + l]),
      .force_hs_i  (1'b0),
      .settle_i    (settle),
      .filter_i    (lp_filter),
      .miss_i      (8'd0),
      .clk_edge_i  (1'b0),
      .lp_i        (lp_i[l]),
      .lp_o        (lp_st[1 + l]),
      .hs_en_o     (hs_en[1 + l]),
      .hs_active_o (hs_act[1 + l]),
      .ce_o        (),
      .ev_hs_o     (ev_hs[1 + l]),
      .ev_err_o    (ev_lp_err[1 + l])
    );
  end

  assign byte_ce_o   = byte_ce;
  assign clk_hs_en_o = hs_en[0];
  assign hs_en_o     = hs_en[Lanes:1];

  // Clock lane activity: a byte clock flop toggling on every edge, seen from
  // the video domain (clock miss detection of the clock lane FSM)
  logic clk_tog_q, clk_tog_s, clk_tog_last_q;

  always_ff @(posedge byte_clk_i or negedge brst_n) begin
    if (!brst_n) clk_tog_q <= 1'b0;
    else         clk_tog_q <= ~clk_tog_q;
  end

  bow_sync u_sync_tog (
    .clk_i  (vid_clk_i),
    .rst_ni (vrst_n),
    .d_i    (clk_tog_q),
    .q_o    (clk_tog_s)
  );

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) clk_tog_last_q <= 1'b0;
    else         clk_tog_last_q <= clk_tog_s;
  end

  assign clk_edge = clk_tog_s ^ clk_tog_last_q;

  // PHY status -> CPU
  bow_csi2_sync #(
    .Width      (3 * Lanes + 4),
    .ResetValue ({{(Lanes + 2){1'b0}}, {(2 * Lanes + 2){1'b1}}})   // LP-11
  ) u_sync_vst (
    .clk_i,
    .rst_ni,
    .d_i ({byte_ce, hs_en, lp_st}),
    .q_o ({ce_sys, hs_en_sys, lp_sys})
  );

  // LP events -> CPU. Each kind is released at most every 16 video cycles,
  // so the pulse synchronisers never merge two pulses (needs vid_clk_i <=
  // 5 x clk_i); real D-PHY sequences are much slower (T_LPX >= 50 ns per LP
  // state), only a glitching line can lose counts.
  logic [NumVEv-1:0] vev, vev_pend_q, vev_fire, vev_sys;
  logic [3:0]        vdiv_q;

  assign vev      = {ev_lp_err, ev_hs};
  assign vev_fire = (vdiv_q == 4'd0) ? vev_pend_q : '0;

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) begin
      vdiv_q     <= '0;
      vev_pend_q <= '0;
    end else begin
      vdiv_q     <= vdiv_q + 4'd1;
      vev_pend_q <= (vev_pend_q & ~vev_fire) | vev;
    end
  end

  for (genvar i = 0; i < NumVEv; i++) begin : g_cdc_vev
    bow_cdc_pulse u_cdc (
      .src_clk_i   (vid_clk_i),
      .src_rst_ni  (vrst_n),
      .src_pulse_i (vev_fire[i]),
      .dst_clk_i   (clk_i),
      .dst_rst_ni  (rst_ni),
      .dst_pulse_o (vev_sys[i])
    );
  end

  // =========================================================================
  // Byte domain: deserialised words -> packets -> pixel groups
  // =========================================================================
  logic [Lanes-1:0][7:0] rx_q;
  logic [Lanes-1:0]      arm;
  logic                  lanes2, vc_any;
  logic [1:0]            vc;
  logic [5:0]            dt;

  always_ff @(posedge byte_clk_i or negedge brst_n) begin
    if (!brst_n) rx_q <= '0;
    else         rx_q <= rx_data_i;
  end

  bow_csi2_sync #(
    .Width (10)
  ) u_sync_bcfg (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    ({cfg.lanes2, cfg.vc_any, cfg.vc, cfg.dt}),
    .q_o    ({lanes2, vc_any, vc, dt})
  );

  bow_csi2_sync #(
    .Width (Lanes)
  ) u_sync_arm (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (hs_act[Lanes:1]),
    .q_o    (arm)
  );

  logic [Lanes-1:0]      al_valid, al_sot, al_sync_err;
  logic [Lanes-1:0][7:0] al_data;

  for (genvar l = 0; l < Lanes; l++) begin : g_align
    bow_dphy_align u_align (
      .clk_i         (byte_clk_i),
      .rst_ni        (drst_n),
      .arm_i         (arm[l]),
      .rx_i          (rx_q[l]),
      .valid_o       (al_valid[l]),
      .data_o        (al_data[l]),
      .sot_o         (al_sot[l]),
      .locked_o      (),
      .ev_sync_err_o (al_sync_err[l])
    );
  end

  logic        lm_valid, lm_sop, lm_eob, lm_skew;
  logic [15:0] lm_data;
  logic [1:0]  lm_nbytes;

  bow_csi2_lane_merge #(
    .Lanes (Lanes)
  ) u_lane_merge (
    .clk_i     (byte_clk_i),
    .rst_ni    (drst_n),
    .lanes2_i  (lanes2),
    .arm_i     (arm),
    .valid_i   (al_valid),
    .data_i    (al_data),
    .sot_i     (al_sot),
    .valid_o   (lm_valid),
    .data_o    (lm_data),
    .nbytes_o  (lm_nbytes),
    .sop_o     (lm_sop),
    .eob_o     (lm_eob),
    .ev_skew_o (lm_skew)
  );

  csi2_pkt_ev_t pkt_ev;
  logic         px_sol, px_raw10, px_eol, px_ovf, fs, fe;
  logic [1:0]   px_valid;
  logic [15:0]  px_data;
  logic         log_we, log_fs, log_fe;
  logic [29:0]  log_entry;

  bow_csi2_packet u_packet (
    .clk_i         (byte_clk_i),
    .rst_ni        (drst_n),
    .vc_i          (vc),
    .vc_any_i      (vc_any),
    .dt_i          (dt),
    .valid_i       (lm_valid),
    .data_i        (lm_data),
    .nbytes_i      (lm_nbytes),
    .sop_i         (lm_sop),
    .eob_i         (lm_eob),
    .px_sol_o      (px_sol),
    .px_raw10_o    (px_raw10),
    .px_valid_o    (px_valid),
    .px_data_o     (px_data),
    .px_eol_o      (px_eol),
    .px_ovf_i      (px_ovf),
    .fs_o          (fs),
    .fe_o          (fe),
    .in_frame_o    (in_frame),
    .frame_lines_o (frame_lines),
    .frame_num_o   (frame_num),
    .line_wc_o     (line_wc),
    .line_dt_o     (line_dt),
    .line_vc_o     (line_vc),
    .log_we_o      (log_we),
    .log_entry_o   (log_entry),
    .log_fs_o      (log_fs),
    .log_fe_o      (log_fe),
    .ev_o          (pkt_ev)
  );

  logic              grp_push, fifo_full, fifo_empty, fifo_pop;
  logic [GroupW-1:0] grp_wdata, grp_rdata;

  bow_csi2_unpack u_unpack (
    .clk_i       (byte_clk_i),
    .rst_ni      (drst_n),
    .sol_i       (px_sol),
    .raw10_i     (px_raw10),
    .valid_i     (px_valid),
    .data_i      (px_data),
    .eol_i       (px_eol),
    .fs_i        (fs),
    .fe_i        (fe),
    .push_o      (grp_push),
    .group_o     (grp_wdata),
    .full_i      (fifo_full),
    .ovf_o       (px_ovf),
    .frame_sum_o (frame_sum)
  );

  bow_fifo_async #(
    .Width (GroupW),
    .Depth (FifoDepth)
  ) u_fifo (
    .wclk_i  (byte_clk_i),
    .wrst_ni (drst_n),
    .push_i  (grp_push),
    .wdata_i (grp_wdata),
    .full_o  (fifo_full),
    .rclk_i  (vid_clk_i),
    .rrst_ni (vdrst_n),
    .pop_i   (fifo_pop),
    .rdata_o (grp_rdata),
    .empty_o (fifo_empty)
  );

  bow_csi2rx_out u_out (
    .clk_i    (vid_clk_i),
    .rst_ni   (vdrst_n),
    .empty_i  (fifo_empty),
    .group_i  (grp_rdata),
    .pop_o    (fifo_pop),
    .tvalid_o (m_axis_tvalid_o),
    .tready_i (m_axis_tready_i),
    .tdata_o  (m_axis_tdata_o),
    .tuser_o  (m_axis_tuser_o),
    .tlast_o  (m_axis_tlast_o)
  );

  bow_sync u_sync_in_frame (
    .clk_i,
    .rst_ni,
    .d_i (in_frame),
    .q_o (in_frame_sys)
  );

  // Byte domain events -> CPU. Each kind comes at most once per packet or
  // burst; a new burst needs the LP-11 -> LP-01 -> LP-00 -> SETTLE sequence
  // of the lane FSMs (>= 370 ns with D-PHY timing), far more than the 3 CPU
  // cycles a pulse synchroniser needs. The data that goes with ev fe / line
  // is held in the packet layer and unpacker until the next event of the kind.
  logic [NumBEv-1:0] bev, bev_sys;

  assign bev = {al_sync_err, lm_skew, pkt_ev};

  for (genvar i = 0; i < NumBEv; i++) begin : g_cdc_bev
    bow_cdc_pulse u_cdc (
      .src_clk_i   (byte_clk_i),
      .src_rst_ni  (brst_n),
      .src_pulse_i (bev[i]),
      .dst_clk_i   (clk_i),
      .dst_rst_ni  (rst_ni),
      .dst_pulse_o (bev_sys[i])
    );
  end

  always_comb begin
    ev_sys                 = '0;
    ev_sys.pl              = bev_sys[NumPktEv-1:0];
    ev_sys.skew            = bev_sys[NumPktEv];
    ev_sys.sot[Lanes-1:0]  = bev_sys[NumBEv-1 -: Lanes];
    ev_sys.hs[Lanes:0]     = vev_sys[Lanes:0];
    ev_sys.lp_err[Lanes:0] = vev_sys[NumVEv-1 -: Lanes + 1];
  end

  // =========================================================================
  // Byte domain: IDELAY taps, byte clock meter, LOG / RAW capture
  // =========================================================================
  // A tap is loaded (CNTVALUEIN + one cycle LOAD) when its synchronised value
  // was the same in two consecutive cycles and differs from the last loaded
  // one (the first value after a reset is always loaded). This only happens
  // while the byte clock runs, i.e. in the next burst.
  logic [Lanes-1:0][8:0] tap_s, tap_last_q, tap_ld_q;
  logic [Lanes-1:0]      tap_ld_v_q;

  bow_csi2_sync #(
    .Width (9 * Lanes)
  ) u_sync_tap (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (dly_sys),
    .q_o    (tap_s)
  );

  always_ff @(posedge byte_clk_i or negedge brst_n) begin
    if (!brst_n) begin
      tap_last_q <= '0;
      tap_ld_q   <= '0;
      tap_ld_v_q <= '0;
      dly_tap_o  <= '0;
      dly_load_o <= '0;
    end else begin
      tap_last_q <= tap_s;
      dly_load_o <= '0;
      for (int unsigned l = 0; l < Lanes; l++) begin
        if ((tap_s[l] == tap_last_q[l]) && (!tap_ld_v_q[l] || (tap_s[l] != tap_ld_q[l]))) begin
          tap_ld_q[l]   <= tap_s[l];
          tap_ld_v_q[l] <= 1'b1;
          dly_tap_o[l]  <= tap_s[l];
          dly_load_o[l] <= 1'b1;
        end
      end
    end
  end

  bow_csi2_sync #(
    .Width (9 * Lanes)
  ) u_sync_tap_out (
    .clk_i,
    .rst_ni,
    .d_i (dly_tap_i),
    .q_o (dly_out_sys)
  );

  // Byte clock meter: free running gray counter
  logic [19:0] meter_q;

  always_ff @(posedge byte_clk_i or negedge brst_n) begin
    if (!brst_n) begin
      meter_q      <= '0;
      meter_gray_q <= '0;
    end else begin
      meter_q      <= meter_q + 20'd1;
      meter_gray_q <= meter_q ^ (meter_q >> 1);
    end
  end

  bow_csi2_sync #(
    .Width (20)
  ) u_sync_meter (
    .clk_i,
    .rst_ni,
    .d_i (meter_gray_q),
    .q_o (meter_sys)
  );

  // LOG / RAW capture: commands in (gray request counters + mode bits),
  // acknowledges (gray) and the LOG write pointer (quasi-static) out
  logic [3:0] log_req, raw_req;
  logic       log_trig, log_stop, raw_now;

  bow_csi2_sync #(
    .Width (4)
  ) u_sync_log_req (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (log_req_sys),
    .q_o    (log_req)
  );

  bow_csi2_sync #(
    .Width (4)
  ) u_sync_raw_req (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (raw_req_sys),
    .q_o    (raw_req)
  );

  bow_csi2_sync #(
    .Width (3)
  ) u_sync_mode (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    ({log_trig_sys, log_stop_sys, raw_now_sys}),
    .q_o    ({log_trig, log_stop, raw_now})
  );

  bow_csi2_capture #(
    .Lanes (Lanes)
  ) u_capture (
    .clk_i         (byte_clk_i),
    .rst_ni        (brst_n),
    .log_req_i     (log_req),
    .log_trig_fs_i (log_trig),
    .log_stop_fe_i (log_stop),
    .log_ack_o     (log_ack),
    .log_wptr_o    (log_wptr),
    .log_we_i      (log_we),
    .log_entry_i   (log_entry),
    .log_fs_i      (log_fs),
    .log_fe_i      (log_fe),
    .raw_req_i     (raw_req),
    .raw_now_i     (raw_now),
    .raw_ack_o     (raw_ack),
    .arm0_i        (arm[0]),
    .rx_i          (rx_q),
    .rclk_i        (clk_i),
    .log_re_i      (log_re),
    .raw_re_i      (raw_re),
    .raddr_i       (ram_addr),
    .log_rdata_o   (log_rdata),
    .raw_rdata_o   (raw_rdata)
  );

  bow_csi2_sync #(
    .Width (4)
  ) u_sync_log_ack (
    .clk_i,
    .rst_ni,
    .d_i (log_ack),
    .q_o (log_ack_sys)
  );

  bow_csi2_sync #(
    .Width (4)
  ) u_sync_raw_ack (
    .clk_i,
    .rst_ni,
    .d_i (raw_ack),
    .q_o (raw_ack_sys)
  );

  bow_csi2_sync #(
    .Width (6)
  ) u_sync_log_wptr (
    .clk_i,
    .rst_ni,
    .d_i (log_wptr),
    .q_o (log_wptr_sys)
  );

  logic unused;
  assign unused = ^{hs_act[0], cfg.phy_en, cfg.rx_en};

endmodule
