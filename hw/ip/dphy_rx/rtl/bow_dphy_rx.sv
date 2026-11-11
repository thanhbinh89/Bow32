// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI D-PHY receiver, digital part: the D-PHY functions of the CSI-2
// receiver, split out of bow_csi2rx without changing them (step 1 of the
// migration plan in docs/ip/mipi_rx_arch.md, section 10). bow_csi2rx
// instantiates it (u_dphy_rx) between its PHY ports and its CSI-2 protocol
// layer; its ports and register map are unchanged.
//
//   clk_lp_i, lp_i --> bow_dphy_lp x (1 + Lanes) --> clk_hs_en_o, hs_en_o, byte_ce_o
//      (video domain)        | hs_active                  clk_tog (byte clock edges)
//   rx_data_i, rx_valid_i --> word flops --> bow_dphy_align x Lanes --> rx_*_hs_o (byte)
//                                  +--> raw_data_o, raw_valid_o (RAW capture of bow_csi2_capture)
//   dly_i, dly_req_i (CPU) --> tap loads (DlyVid 0: byte, 1: video domain) --> dly_tap_o, dly_load_o
//   dly_tap_i, byte clock meter, LP levels, HS / gate state, phy_rdy_i --> *_sys_o (CPU)
//
// Contents (all moved from bow_csi2rx unchanged; instance and register names
// kept, the FPGA constraints select them by name):
//   * the LP state machines (u_lp_clk, g_lp[l].u_lp) and their configuration
//     synchronisers (u_sync_vcfg: CTRL.CLK_FORCE, the lane enables,
//     PHY_CFG), the LP / HS / gate status towards the CPU (u_sync_vst) and
//     the phy_rdy_i synchroniser;
//   * clock lane activity: a byte clock flop toggling on every edge, seen from
//     the video domain (clk_tog: clock miss detection of the clock lane FSM);
//   * byte_rst_o, the ISERDES reset: asserted while the byte clock gate is
//     closed, released 2 byte clocks after the clock restarts (u_iserdes_rst);
//   * the rx_data / rx_valid word flops, the hs_active synchroniser into the
//     byte domain (u_sync_arm) and the aligners (g_align[l].u_align);
//   * the input delay tap loads (g_dly_byte / g_dly_vid) and the tap readback
//     synchroniser (u_sync_tap_out);
//   * the byte clock meter (meter_gray_q, u_sync_meter).
// The byte domain outputs per lane are the later PPI signals (RxActiveHS,
// RxValidHS, RxDataHS, RxSyncHS, ErrSotSyncHS, RxSkewCalHS); the RAW capture
// stays in bow_csi2_capture, which gets the registered PHY words.
//
// Clocks: clk_i (CPU), vid_clk_i (video: LP state machines, tap loads with
// DlyVid = 1), byte_clk_i (byte clock, runs only while byte_ce_o = 1 and the
// clock lane toggles). The resets come from bow_csi2rx, synchronised there
// (asynchronous assertion, synchronous release): vrst_ni (video), brst_ni
// (byte, hard), drst_ni (byte datapath: the aligners, also held while RX is
// off); rst_src_ni is their asynchronous source, for the ISERDES reset
// synchroniser. The PHY contract (rx_valid_i, phy_rdy_i, dly_*) is the one of
// bow_csi2rx (see there).

module bow_dphy_rx #(
  parameter int unsigned Lanes  = 2,         // data lanes: 1, 2 or 4
  parameter bit          DlyVid = 1'b0       // dly_* in the video domain (Versal XPHY)
) (
  input  logic                  clk_i,              // CPU clock
  input  logic                  rst_ni,             // CPU domain reset
  input  logic                  vid_clk_i,          // video clock
  input  logic                  vrst_ni,            // video domain reset (synchronised)
  input  logic                  byte_clk_i,         // byte clock (gated)
  input  logic                  brst_ni,            // byte domain hard reset (synchronised)
  input  logic                  drst_ni,            // byte datapath reset (synchronised)
  input  logic                  rst_src_ni,         // asynchronous source of the resets

  // CPU domain: configuration (quasi-static: changed only while PHY_EN = 0)
  input  logic [Lanes:0]        lane_en_i,          // [0] clock lane, [1 + l] data lane l
  input  logic                  clk_force_i,        // CTRL.CLK_FORCE
  input  logic [7:0]            settle_i,           // PHY_CFG.SETTLE
  input  logic [3:0]            lp_filter_i,        // PHY_CFG.LP_FILTER
  input  logic [7:0]            clk_settle_i,       // PHY_CFG.CLK_SETTLE
  input  logic [7:0]            clk_miss_i,         // PHY_CFG.CLK_MISS
  input  logic [Lanes-1:0][8:0] dly_i,              // DLYn taps
  input  logic [Lanes-1:0][1:0] dly_req_i,          // DLYn write counters (gray, DlyVid = 1)

  // CPU domain: status (synchronised)
  output logic [Lanes:0][1:0]   lp_sys_o,           // filtered LP {P, N}, same lane order
  output logic [Lanes:0]        hs_en_sys_o,        // HS receivers on
  output logic                  ce_sys_o,           // byte clock gate open
  output logic                  phy_rdy_sys_o,      // phy_rdy_i
  output logic [19:0]           meter_sys_o,        // byte clock cycle counter, gray
  output logic [Lanes-1:0][8:0] dly_sys_o,          // dly_tap_i (CNTVALUEOUT)

  // video domain: events of the LP state machines (one cycle pulses)
  output logic [Lanes:0]        ev_hs_o,            // HS entry, [0] clock lane, [1 + l] data lane l
  output logic [Lanes:0]        ev_lp_err_o,        // unexpected LP sequence / watchdog
  output logic                  ev_lp_loss_o,       // an HS entry refused at the LP level: LP
                                                    // error of an enabled data lane, or of
                                                    // the clock lane without CLK_FORCE

  // byte domain, per data lane
  output logic [Lanes-1:0]      rx_active_hs_o,     // hs_active of the lane FSM, synchronised
  output logic [Lanes-1:0]      rx_valid_hs_o,      // aligned byte
  output logic [Lanes-1:0][7:0] rx_data_hs_o,       // LSB = first bit on the wire
  output logic [Lanes-1:0]      rx_sync_hs_o,       // with the first byte after the sync byte
  output logic [Lanes-1:0]      err_sot_sync_hs_o,  // pulse: the burst ended without a sync
  output logic [Lanes-1:0]      rx_skew_cal_hs_o,   // pulse: deskew burst
  output logic [Lanes-1:0][7:0] raw_data_o,         // registered PHY words (RAW capture)
  output logic [Lanes-1:0]      raw_valid_o,        // registered rx_valid_i

  // PHY (bow_dphy_io_xusp, bow_dphy_io_versal): the PHY ports of bow_csi2rx
  output logic                  byte_ce_o,          // video domain flop (clock lane FSM)
  output logic                  byte_rst_o,         // ISERDES RST
  input  logic [1:0]            clk_lp_i,
  output logic                  clk_hs_en_o,        // video domain flop of the FSM, no extra stage
  input  logic [Lanes-1:0][1:0] lp_i,
  output logic [Lanes-1:0]      hs_en_o,            // video domain flops of the FSMs, no extra stage
  input  logic [Lanes-1:0][7:0] rx_data_i,          // registered once on byte_clk_i before use
  input  logic [Lanes-1:0]      rx_valid_i,         // byte domain: rx_data_i[l] is a new word
  input  logic                  phy_rdy_i,          // asynchronous: PHY ready
  output logic [Lanes-1:0][8:0] dly_tap_o,          // byte domain (DlyVid = 0) / video domain (1)
  output logic [Lanes-1:0]      dly_load_o,         // same domain as dly_tap_o
  input  logic [Lanes-1:0][8:0] dly_tap_i           // CNTVALUEOUT, same domain as dly_tap_o
);

  if ((Lanes != 1) && (Lanes != 2) && (Lanes != 4)) begin : g_bad_lanes
    $error("bow_dphy_rx: Lanes must be 1, 2 or 4, not %0d", Lanes);
  end

  // =========================================================================
  // Video domain: LP state machines
  // =========================================================================
  logic [Lanes:0]      lane_en, hs_en, hs_act, ev_hs, ev_lp_err;
  logic [Lanes:0][1:0] lp_st;
  logic                clk_force, clk_edge, byte_ce;
  logic [7:0]          settle, clk_settle, clk_miss;
  logic [3:0]          lp_filter;

  bow_sync_bus #(
    .Width (Lanes + 30)
  ) u_sync_vcfg (
    .clk_i  (vid_clk_i),
    .rst_ni (vrst_ni),
    .d_i    ({clk_force_i, lane_en_i, settle_i, lp_filter_i, clk_settle_i, clk_miss_i}),
    .q_o    ({clk_force, lane_en, settle, lp_filter, clk_settle, clk_miss})
  );

  bow_dphy_lp #(
    .ClockLane (1'b1)
  ) u_lp_clk (
    .clk_i       (vid_clk_i),
    .rst_ni      (vrst_ni),
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
      .rst_ni      (vrst_ni),
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
  assign ev_hs_o     = ev_hs;
  assign ev_lp_err_o = ev_lp_err;

  // HS entries refused at the LP level (LP error of an enabled data lane, or
  // of the clock lane when the byte clock is gated) lose a burst that the
  // packet layer never sees: bow_csi2rx marks it (lpl_*).
  assign ev_lp_loss_o = (|(ev_lp_err[Lanes:1] & lane_en[Lanes:1])) || (ev_lp_err[0] && !clk_force);

  // Clock lane activity: a byte clock flop toggling on every edge, seen from
  // the video domain (clock miss detection of the clock lane FSM). Every
  // byte clock edge counts, with or without a valid word: the byte clock
  // itself only runs while the clock lane toggles.
  logic clk_tog_q, clk_tog_s, clk_tog_last_q;

  always_ff @(posedge byte_clk_i or negedge brst_ni) begin
    if (!brst_ni) clk_tog_q <= 1'b0;
    else          clk_tog_q <= ~clk_tog_q;
  end

  bow_sync u_sync_tog (
    .clk_i  (vid_clk_i),
    .rst_ni (vrst_ni),
    .d_i    (clk_tog_q),
    .q_o    (clk_tog_s)
  );

  always_ff @(posedge vid_clk_i or negedge vrst_ni) begin
    if (!vrst_ni) clk_tog_last_q <= 1'b0;
    else          clk_tog_last_q <= clk_tog_s;
  end

  assign clk_edge = clk_tog_s ^ clk_tog_last_q;

  // ISERDES reset: asserted while the byte clock gate is closed, released 2
  // byte clocks after the clock restarts
  logic iserdes_rst_n;

  bow_rst_sync u_iserdes_rst (
    .clk_i  (byte_clk_i),
    .rst_ni (rst_src_ni & byte_ce),
    .rst_no (iserdes_rst_n)
  );

  assign byte_rst_o = ~iserdes_rst_n;

  // PHY status -> CPU
  bow_sync_bus #(
    .Width      (3 * Lanes + 4),
    .ResetValue ({{(Lanes + 2){1'b0}}, {(2 * Lanes + 2){1'b1}}})   // LP-11
  ) u_sync_vst (
    .clk_i,
    .rst_ni,
    .d_i ({byte_ce, hs_en, lp_st}),
    .q_o ({ce_sys_o, hs_en_sys_o, lp_sys_o})
  );

  bow_sync u_sync_phy_rdy (
    .clk_i,
    .rst_ni,
    .d_i (phy_rdy_i),
    .q_o (phy_rdy_sys_o)
  );

  // =========================================================================
  // Byte domain: word flops, sync search and byte alignment
  // =========================================================================
  logic [Lanes-1:0][7:0] rx_q;
  logic [Lanes-1:0]      rxv_q, arm;

  always_ff @(posedge byte_clk_i or negedge brst_ni) begin
    if (!brst_ni) begin
      rx_q  <= '0;
      rxv_q <= '0;
    end else begin
      rx_q  <= rx_data_i;
      rxv_q <= rx_valid_i;
    end
  end

  bow_sync_bus #(
    .Width (Lanes)
  ) u_sync_arm (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_ni),
    .d_i    (hs_act[Lanes:1]),
    .q_o    (arm)
  );

  for (genvar l = 0; l < Lanes; l++) begin : g_align
    bow_dphy_align u_align (
      .clk_i         (byte_clk_i),
      .rst_ni        (drst_ni),
      .arm_i         (arm[l]),
      .vld_i         (rxv_q[l]),
      .rx_i          (rx_q[l]),
      .valid_o       (rx_valid_hs_o[l]),
      .data_o        (rx_data_hs_o[l]),
      .sot_o         (rx_sync_hs_o[l]),
      .locked_o      (),
      .ev_sync_err_o (err_sot_sync_hs_o[l]),
      .ev_deskew_o   (rx_skew_cal_hs_o[l])
    );
  end

  assign rx_active_hs_o = arm;
  assign raw_data_o     = rx_q;
  assign raw_valid_o    = rxv_q;

  // =========================================================================
  // Input delay taps (DlyVid = 0: byte domain, IDELAYE3; 1: video domain, XPHY)
  // =========================================================================
  if (!DlyVid) begin : g_dly_byte
    // A tap is loaded (CNTVALUEIN + one cycle LOAD) when its synchronised
    // value was the same in two consecutive cycles and differs from the last
    // loaded one (the first value after a reset is always loaded). This only
    // happens while the byte clock runs, i.e. in the next burst.
    logic [Lanes-1:0][8:0] tap_s, tap_last_q, tap_ld_q;
    logic [Lanes-1:0]      tap_ld_v_q;

    bow_sync_bus #(
      .Width (9 * Lanes)
    ) u_sync_tap (
      .clk_i  (byte_clk_i),
      .rst_ni (brst_ni),
      .d_i    (dly_i),
      .q_o    (tap_s)
    );

    always_ff @(posedge byte_clk_i or negedge brst_ni) begin
      if (!brst_ni) begin
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

    logic unused_req;
    assign unused_req = ^dly_req_i;
  end else begin : g_dly_vid
    // Per lane: the 2 bit gray request counter of the CPU (+1 per DLYn
    // write) and the taps come through one synchroniser per bit. A change of
    // the counter starts a request; the tap bus, written in the same CPU
    // cycle as the counter, is taken 2 cycles after the last change was
    // seen (dly_tap_o), the one cycle load pulse follows one cycle later.
    // The next tap update of the lane waits until 16 cycles after the last
    // one; requests until then are merged (the newest tap is loaded).
    // During the first cycles after the reset the last seen counter value
    // follows the synchroniser: no load after a reset.
    logic [Lanes-1:0][8:0] vtap_s;
    logic [Lanes-1:0][1:0] req_s, req_last_q, req_last_d;
    logic [Lanes-1:0][1:0] settle_q, settle_d;
    logic [Lanes-1:0][3:0] gap_q, gap_d;
    logic [Lanes-1:0]      pend_q, pend_d, ld1_q, ld1_d;
    logic [Lanes-1:0][8:0] vtap_q, vtap_d;
    logic [2:0]            init_q;

    bow_sync_bus #(
      .Width (9 * Lanes)
    ) u_sync_tap (
      .clk_i  (vid_clk_i),
      .rst_ni (vrst_ni),
      .d_i    (dly_i),
      .q_o    (vtap_s)
    );

    bow_sync_bus #(
      .Width (2 * Lanes)
    ) u_sync_req (
      .clk_i  (vid_clk_i),
      .rst_ni (vrst_ni),
      .d_i    (dly_req_i),
      .q_o    (req_s)
    );

    always_comb begin
      req_last_d = req_last_q;
      settle_d   = settle_q;
      gap_d      = gap_q;
      pend_d     = pend_q;
      ld1_d      = '0;
      vtap_d     = vtap_q;
      for (int unsigned l = 0; l < Lanes; l++) begin
        if (gap_q[l] != 4'd0) gap_d[l] = gap_q[l] - 4'd1;
        if (init_q != 3'd7) begin
          req_last_d[l] = req_s[l];
        end else if (req_s[l] != req_last_q[l]) begin
          req_last_d[l] = req_s[l];
          pend_d[l]     = 1'b1;
          settle_d[l]   = 2'd2;
        end else if (settle_q[l] != 2'd0) begin
          settle_d[l] = settle_q[l] - 2'd1;
        end else if (pend_q[l] && (gap_q[l] == 4'd0)) begin
          vtap_d[l] = vtap_s[l];
          pend_d[l] = 1'b0;
          ld1_d[l]  = 1'b1;
          gap_d[l]  = 4'd15;
        end
      end
    end

    always_ff @(posedge vid_clk_i or negedge vrst_ni) begin
      if (!vrst_ni) begin
        init_q     <= '0;
        req_last_q <= '0;
        settle_q   <= '0;
        gap_q      <= '0;
        pend_q     <= '0;
        ld1_q      <= '0;
        vtap_q     <= '0;
        dly_load_o <= '0;
      end else begin
        if (init_q != 3'd7) init_q <= init_q + 3'd1;
        req_last_q <= req_last_d;
        settle_q   <= settle_d;
        gap_q      <= gap_d;
        pend_q     <= pend_d;
        ld1_q      <= ld1_d;
        vtap_q     <= vtap_d;
        dly_load_o <= ld1_q;
      end
    end

    assign dly_tap_o = vtap_q;
  end

  bow_sync_bus #(
    .Width (9 * Lanes)
  ) u_sync_tap_out (
    .clk_i,
    .rst_ni,
    .d_i (dly_tap_i),
    .q_o (dly_sys_o)
  );

  // =========================================================================
  // Byte domain: byte clock meter (free running gray counter)
  // =========================================================================
  logic [19:0] meter_q, meter_gray_q;

  always_ff @(posedge byte_clk_i or negedge brst_ni) begin
    if (!brst_ni) begin
      meter_q      <= '0;
      meter_gray_q <= '0;
    end else begin
      meter_q      <= meter_q + 20'd1;
      meter_gray_q <= meter_q ^ (meter_q >> 1);
    end
  end

  bow_sync_bus #(
    .Width (20)
  ) u_sync_meter (
    .clk_i,
    .rst_ni,
    .d_i (meter_gray_q),
    .q_o (meter_sys_o)
  );

  logic unused;
  assign unused = hs_act[0];

endmodule
