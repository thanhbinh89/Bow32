// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI CSI-2 receiver: D-PHY digital part (bow_dphy_rx: LP state
// machines, clock gating, sync detection and byte alignment, input delay
// control, byte clock meter) and CSI-2 protocol layer, with a RAW10
// AXI4-Stream output (1 pixel/clock) for the ISP. The D-PHY I/O (LP / HS
// receivers, deserialisers, input delays) is outside, e.g.
// hw/fpga/common/rtl/bow_dphy_io_xusp.sv on the KV260 or
// hw/fpga/common/rtl/bow_dphy_io_versal.sv (XPHY) on Versal.
//
//   lp pins ------------> bow_dphy_rx (u_dphy_rx): bow_dphy_lp x (1 + Lanes) --> hs_en, byte_ce
//   rx_data, rx_valid ---> word flops -> bow_dphy_align x Lanes --+ aligned bytes per lane
//                                                                 |
//   bow_csi2_lane_merge <-----------------------------------------+
//     -> bow_csi2_packet -> bow_csi2_unpack -> bow_fifo_async (byte -> video clock)
//     -> bow_csi2rx_out -> m_axis
//
// Lanes = 1, 2 or 4 data lanes (CTRL.LANES / LANES4 select 1, 2 or 4 of
// them at run time): the byte domain takes 8 * Lanes bits per byte clock.
//
// m_axis_tuser_o[0] = first pixel of a frame (pixel 0 of its first line: a
// frame whose first line cannot be output is skipped, ERR_STATUS.SKIP),
// [1] = line error, with tlast: the line has a CRC or format error, was
// truncated or cut by a FIFO overflow, or an earlier line of the frame was
// lost (FIFO full, no pixel group, or its burst was lost: uncorrectable
// header, sync error, lane skew, a dropped packet cut short, packets after
// EXTRA, an HS entry refused at the LP level). Lines lost after the last
// output line of a frame cannot be flagged on the stream: FRAME_ERR (the
// error flags of each frame, latched at FE) holds them.
//
// Clock domains:
//   clk_i       CPU: registers, counters, LOG/RAW read (bow_csi2rx_regs)
//   vid_clk_i   video: LP state machines, PHY control and, with DlyVid = 1,
//               the input delay control (dly_*), all in bow_dphy_rx; here the
//               LP event release, the lost burst request (lpl_*) and the pixel
//               output
//   byte_clk_i  byte clock = HS clock / 4, runs only while byte_ce_o = 1 and
//               the clock lane toggles (non-continuous clock: HS bursts only)
// Resets (asynchronous assertion, synchronous release):
//   vrst_n      video hard reset (vid_rst_ni & rst_ni)
//   brst_n      byte hard reset: event toggles, command handshakes, LOG/RAW
//               capture; in bow_dphy_rx the byte clock meter, IDELAY load
//               (DlyVid = 0), clock toggle, rx_data / rx_valid registers
//   drst_n      byte datapath (aligners in bow_dphy_rx .. FIFO write side) and
//   vdrst_n     video datapath (FIFO read side, output): asserted while RX
//               is off (rx_on = CTRL.PHY_EN & RX_EN, a CPU flop), so a stop
//               drops partial packets, lines, the frame state and the FIFO.
//               drst_n is released by the first byte clocks of a burst.
//   byte_rst_o  ISERDES reset (bow_dphy_rx): asserted while the byte clock
//               gate is closed, released 2 byte clocks after the clock restarts.
// Clock domain crossings: configuration through one bow_sync per bit
// (quasi-static), events through one bow_cdc_pulse per kind, commands to
// the byte domain as gray request / ack counters, pixels through
// bow_fifo_async, gray coded byte clock meter, input delay load requests as
// 2 bit gray counters (DlyVid = 1). See bow_csi2rx_regs for the register
// map.
//
// PHY contract (besides the ports of bow_dphy_io_xusp):
//   rx_valid_i  byte domain, per lane: rx_data_i[l] is a new word. The
//               aligner of a lane only advances on valid words (a PHY with
//               FIFOs, e.g. the Versal XPHY, has no word in some cycles at
//               the start of a burst and hands out the words left over from
//               the previous burst first: they come before the HS-zero and
//               the sync byte, so they only fill the aligner history). A PHY
//               with a word in every cycle (bow_dphy_io_xusp) ties it to '1.
//   phy_rdy_i   asynchronous level, the PHY is ready (Versal: XPLL locked,
//               BISC done): STATUS.PHY_RDY. 1'b1 if the PHY has no such state.
//   dly_*       DlyVid = 0 (UltraScale+ IDELAYE3, CLK = byte clock): byte
//               domain; a tap is loaded (dly_tap_o + one cycle dly_load_o)
//               when its synchronised value was the same in two consecutive
//               cycles and differs from the last loaded one, the first value
//               after a reset is always loaded; only while the byte clock runs.
//               DlyVid = 1 (Versal XPHY, CTRL_CLK = vid_clk_i): video domain,
//               no load after a reset (the PHY keeps its BISC delay, readable
//               in DLYn[24:16]); every CPU write to DLYn gives exactly one
//               load of lane n with the written tap: dly_load_o[n] high for
//               one cycle, dly_tap_o[n] set the cycle before and held until
//               the next load, loads of a lane at least 16 cycles apart
//               (requests closer than that are merged into one load of the
//               newest tap). Works without a byte clock.
//
// xsim 2025.2 (hw/fpga/common/dv) mis-simulates "q[l] <= 0; if (c) q[l] <= 1;"
// in a loop of an always_ff and indices from constant functions: new
// per-lane state here is computed in always_comb and registered whole.

module bow_csi2rx import bow_bus_pkg::*; import bow_csi2rx_pkg::*; #(
  parameter int unsigned Lanes     = 2,            // physical data lanes: 1, 2 or 4
  parameter int unsigned PhyClkHz  = 200_000_000,  // vid_clk_i frequency (INFO)
  parameter int unsigned CpuClkHz  = 0,            // clk_i frequency (0: not checked)
  parameter bit          HasPhy    = 1'b1,         // INFO.PHY: a D-PHY is connected
  parameter int unsigned FifoDepth = 256,          // pixel FIFO entries (4 px each), power of 2
  parameter bit          DlyVid    = 1'b0          // dly_* in the video domain (Versal XPHY)
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
  output logic [1:0]            m_axis_tuser_o,   // [0] start of frame, [1] line error (tlast)
  output logic                  m_axis_tlast_o,   // end of line
  input  logic                  byte_clk_i,
  output logic                  byte_ce_o,        // video domain flop (clock lane FSM)
  output logic                  byte_rst_o,       // ISERDES RST
  input  logic [1:0]            clk_lp_i,
  output logic                  clk_hs_en_o,      // video domain flop of the FSM, no extra stage
  input  logic [Lanes-1:0][1:0] lp_i,
  output logic [Lanes-1:0]      hs_en_o,          // video domain flops of the FSMs, no extra stage
  input  logic [Lanes-1:0][7:0] rx_data_i,        // registered once on byte_clk_i before use
  input  logic [Lanes-1:0]      rx_valid_i,       // byte domain: rx_data_i[l] is a new word
  input  logic                  phy_rdy_i,        // asynchronous: PHY ready (STATUS.PHY_RDY)
  output logic [Lanes-1:0][8:0] dly_tap_o,        // byte domain (DlyVid = 0) / video domain (1)
  output logic [Lanes-1:0]      dly_load_o,       // same domain as dly_tap_o
  input  logic [Lanes-1:0][8:0] dly_tap_i         // CNTVALUEOUT, same domain as dly_tap_o
);

  if ((Lanes != 1) && (Lanes != 2) && (Lanes != 4)) begin : g_bad_lanes
    $error("bow_csi2rx: Lanes must be 1, 2 or 4, not %0d", Lanes);
  end

  localparam int unsigned NumPktEv = $bits(csi2_pkt_ev_t);
  localparam int unsigned NumBEv   = NumPktEv + 3 + Lanes;   // packet, skew, deskew, skip, sot per lane
  localparam int unsigned NumVEv   = 2 * (Lanes + 1);        // hs, lp_err per lane FSM

  // The LP event release below (one pulse per kind every 16 video cycles)
  // needs 3 CPU cycles per pulse: vid_clk_i <= 16/3 x clk_i. The elaboration
  // $fatal stops lint and synthesis, the initial copy stops simulations whose
  // build turns USERFATAL into a warning (-Wno-fatal).
  if ((CpuClkHz != 0) && (64'(PhyClkHz) * 64'd3 > 64'(CpuClkHz) * 64'd16)) begin : g_bad_clk
    $fatal(1, "bow_csi2rx: vid_clk_i %0d Hz > 16/3 x clk_i %0d Hz (LP event pulses merge)",
           PhyClkHz, CpuClkHz);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_csi2rx: vid_clk_i %0d Hz > 16/3 x clk_i %0d Hz (LP event pulses merge)",
                   PhyClkHz, CpuClkHz);
`endif
  end

  // =========================================================================
  // Resets
  // =========================================================================
  logic rst_src_n, rx_on;
  logic vrst_n, brst_n, drst_n, vdrst_n;

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

  // =========================================================================
  // CPU domain: registers
  // =========================================================================
  csi2_cfg_t             cfg;
  csi2_ev_t              ev_sys;
  logic [Lanes:0]        lane_en_sys;
  logic [Lanes-1:0][8:0] dly_sys, dly_out_sys;
  logic [Lanes-1:0][1:0] dly_req_sys;
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
  logic                  ce_sys, in_frame, in_frame_sys, phy_rdy_sys;
  logic [19:0]           meter_sys;

  bow_csi2rx_regs #(
    .Lanes     (Lanes),
    .PhyClkHz  (PhyClkHz),
    .HasPhy    (HasPhy),
    .FifoDepth (FifoDepth),
    .DlyVid    (DlyVid)
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
    .dly_req_o     (dly_req_sys),
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
    .phy_rdy_i     (phy_rdy_sys),
    .meter_i       (meter_sys),
    .dly_tap_i     (dly_out_sys)
  );

  // =========================================================================
  // D-PHY digital part: LP state machines, clock lane activity, ISERDES
  // reset, word flops, aligners, input delay taps, byte clock meter, PHY
  // status (bow_dphy_rx)
  // =========================================================================
  logic [Lanes:0]        ev_hs, ev_lp_err;
  logic                  lpl_ev;
  logic [Lanes-1:0][7:0] rx_q, al_data;
  logic [Lanes-1:0]      rxv_q, arm;
  logic [Lanes-1:0]      al_valid, al_sot, al_sync_err, al_deskew;

  bow_dphy_rx #(
    .Lanes  (Lanes),
    .DlyVid (DlyVid)
  ) u_dphy_rx (
    .clk_i,
    .rst_ni,
    .vid_clk_i,
    .vrst_ni           (vrst_n),
    .byte_clk_i,
    .brst_ni           (brst_n),
    .drst_ni           (drst_n),
    .rst_src_ni        (rst_src_n),
    .lane_en_i         (lane_en_sys),
    .clk_force_i       (cfg.clk_force),
    .settle_i          (cfg.settle),
    .lp_filter_i       (cfg.lp_filter),
    .clk_settle_i      (cfg.clk_settle),
    .clk_miss_i        (cfg.clk_miss),
    .dly_i             (dly_sys),
    .dly_req_i         (dly_req_sys),
    .lp_sys_o          (lp_sys),
    .hs_en_sys_o       (hs_en_sys),
    .ce_sys_o          (ce_sys),
    .phy_rdy_sys_o     (phy_rdy_sys),
    .meter_sys_o       (meter_sys),
    .dly_sys_o         (dly_out_sys),
    .ev_hs_o           (ev_hs),
    .ev_lp_err_o       (ev_lp_err),
    .ev_lp_loss_o      (lpl_ev),
    .rx_active_hs_o    (arm),
    .rx_valid_hs_o     (al_valid),
    .rx_data_hs_o      (al_data),
    .rx_sync_hs_o      (al_sot),
    .err_sot_sync_hs_o (al_sync_err),
    .rx_skew_cal_hs_o  (al_deskew),
    .raw_data_o        (rx_q),
    .raw_valid_o       (rxv_q),
    .byte_ce_o,
    .byte_rst_o,
    .clk_lp_i,
    .clk_hs_en_o,
    .lp_i,
    .hs_en_o,
    .rx_data_i,
    .rx_valid_i,
    .phy_rdy_i,
    .dly_tap_o,
    .dly_load_o,
    .dly_tap_i
  );

  // LP events -> CPU. Each kind is released at most every 16 video cycles,
  // so the pulse synchronisers never merge two pulses (needs vid_clk_i <=
  // 16/3 x clk_i, checked with CpuClkHz); real D-PHY sequences are much
  // slower (T_LPX >= 50 ns per LP state), only a glitching line can lose
  // counts.
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

  // HS entries refused at the LP level (lpl_ev: LP error of an enabled data
  // lane, or of the clock lane when the byte clock is gated) lose a burst
  // that the packet layer never sees. A request toggle tells the byte domain,
  // which counts it as a lost burst at the next packet start (drop of the
  // unpacker, only inside a frame). Requests while one is pending merge into
  // it.
  logic lpl_req_q, lpl_ack_s, lpl_ack_q, lpl_req_s, lpl_pend_q;

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n)                                   lpl_req_q <= 1'b0;
    else if (lpl_ev && (lpl_req_q == lpl_ack_s))   lpl_req_q <= ~lpl_req_q;
  end

  bow_sync u_sync_lpl_ack (
    .clk_i  (vid_clk_i),
    .rst_ni (vrst_n),
    .d_i    (lpl_ack_q),
    .q_o    (lpl_ack_s)
  );

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
  // Byte domain: aligned bytes -> packets -> pixel groups
  // =========================================================================
  logic                  lanes2, lanes4, vc_any;
  logic [1:0]            vc;
  logic [5:0]            dt;
  logic [7:0]            extra;

  bow_sync_bus #(
    .Width (19)
  ) u_sync_bcfg (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    ({cfg.lanes2, cfg.lanes4, cfg.vc_any, cfg.vc, cfg.dt, cfg.extra}),
    .q_o    ({lanes2, lanes4, vc_any, vc, dt, extra})
  );

  // LP level loss request (see above): acknowledged as soon as it is seen,
  // pending until the next packet start
  bow_sync u_sync_lpl_req (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (lpl_req_q),
    .q_o    (lpl_req_s)
  );

  always_ff @(posedge byte_clk_i or negedge brst_n) begin
    if (!brst_n) lpl_ack_q <= 1'b0;
    else         lpl_ack_q <= lpl_req_s;
  end

  logic                  lm_valid, lm_sop, lm_eob, lm_skew;
  logic [Lanes-1:0][7:0] lm_data;
  logic [2:0]            lm_nbytes;

  bow_csi2_lane_merge #(
    .Lanes (Lanes)
  ) u_lane_merge (
    .clk_i     (byte_clk_i),
    .rst_ni    (drst_n),
    .lanes2_i  (lanes2),
    .lanes4_i  (lanes4),
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

  csi2_pkt_ev_t          pkt_ev;
  logic                  px_sol, px_raw10, px_eol, px_err, px_ovf, fs, fe;
  logic [Lanes-1:0]      px_valid;
  logic [Lanes-1:0][7:0] px_data;
  logic                  log_we, log_fs, log_fe;
  logic [29:0]           log_entry;

  bow_csi2_packet #(
    .Bytes (Lanes)
  ) u_packet (
    .clk_i         (byte_clk_i),
    .rst_ni        (drst_n),
    .vc_i          (vc),
    .vc_any_i      (vc_any),
    .dt_i          (dt),
    .extra_i       (extra),
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
    .px_err_o      (px_err),
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

  logic              grp_push, fifo_full, fifo_afull, fifo_empty, fifo_pop, px_drop, px_skip;
  logic [GroupW-1:0] grp_wdata, grp_rdata;

  // HS entry refused at the LP level: pending until the next packet start
  always_ff @(posedge byte_clk_i or negedge drst_n) begin
    if (!drst_n)                      lpl_pend_q <= 1'b0;
    else if (lpl_req_s != lpl_ack_q)  lpl_pend_q <= 1'b1;
    else if (lm_sop)                  lpl_pend_q <= 1'b0;
  end

  // a burst of the frame was lost before the unpacker: the next line gets
  // tuser[1], or the frame is skipped if its first line has not started.
  // A truncation that did not end an accepted line (cut in the header, or a
  // dropped packet cut short) may have been a line with a corrupted header.
  assign px_drop = in_frame && (pkt_ev.ecc_err || pkt_ev.extra || lm_skew || (|al_sync_err) ||
                                (pkt_ev.trunc && !px_eol) || (lpl_pend_q && lm_sop));

  bow_csi2_unpack #(
    .Bytes (Lanes)
  ) u_unpack (
    .clk_i       (byte_clk_i),
    .rst_ni      (drst_n),
    .sol_i       (px_sol),
    .raw10_i     (px_raw10),
    .valid_i     (px_valid),
    .data_i      (px_data),
    .eol_i       (px_eol),
    .err_i       (px_err),
    .fs_i        (fs),
    .fe_i        (fe),
    .drop_i      (px_drop),
    .push_o      (grp_push),
    .group_o     (grp_wdata),
    .full_i      (fifo_full),
    .afull_i     (fifo_afull),
    .ovf_o       (px_ovf),
    .skip_o      (px_skip),
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
    .afull_o (fifo_afull),
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

  // deskew bursts are counted on lane 0 (the other lanes then deskew too,
  // or the burst is a skew or sync error)
  assign bev = {al_sync_err, px_skip, al_deskew[0], lm_skew, pkt_ev};

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
    ev_sys.deskew          = bev_sys[NumPktEv + 1];
    ev_sys.skip            = bev_sys[NumPktEv + 2];
    ev_sys.sot[Lanes-1:0]  = bev_sys[NumBEv-1 -: Lanes];
    ev_sys.hs[Lanes:0]     = vev_sys[Lanes:0];
    ev_sys.lp_err[Lanes:0] = vev_sys[NumVEv-1 -: Lanes + 1];
  end

  // =========================================================================
  // Byte domain: LOG / RAW capture
  // =========================================================================
  // Commands in (gray request counters + mode bits), acknowledges (gray) and
  // the LOG write pointer (quasi-static) out. RAW captures the registered PHY
  // words of bow_dphy_rx.
  logic [3:0] log_req, raw_req;
  logic       log_trig, log_stop, raw_now;

  bow_sync_bus #(
    .Width (4)
  ) u_sync_log_req (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (log_req_sys),
    .q_o    (log_req)
  );

  bow_sync_bus #(
    .Width (4)
  ) u_sync_raw_req (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (raw_req_sys),
    .q_o    (raw_req)
  );

  bow_sync_bus #(
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
    .rx_vld0_i     (rxv_q[0]),
    .rx_i          (rx_q),
    .rclk_i        (clk_i),
    .log_re_i      (log_re),
    .raw_re_i      (raw_re),
    .raddr_i       (ram_addr),
    .log_rdata_o   (log_rdata),
    .raw_rdata_o   (raw_rdata)
  );

  bow_sync_bus #(
    .Width (4)
  ) u_sync_log_ack (
    .clk_i,
    .rst_ni,
    .d_i (log_ack),
    .q_o (log_ack_sys)
  );

  bow_sync_bus #(
    .Width (4)
  ) u_sync_raw_ack (
    .clk_i,
    .rst_ni,
    .d_i (raw_ack),
    .q_o (raw_ack_sys)
  );

  bow_sync_bus #(
    .Width (6)
  ) u_sync_log_wptr (
    .clk_i,
    .rst_ni,
    .d_i (log_wptr),
    .q_o (log_wptr_sys)
  );

  logic unused;
  assign unused = ^{cfg.phy_en, cfg.rx_en, al_deskew, rxv_q};

endmodule
