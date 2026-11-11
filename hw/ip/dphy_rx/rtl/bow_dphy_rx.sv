// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI D-PHY receiver, digital part, split out of the CSI-2 receiver without
// changing its function (docs/ip/mipi_rx_arch.md, section 10: step 1 moved it out of
// bow_csi2rx, step 2 put it next to the controller in bow_mipi_rx). Towards the CSI-2
// controller it speaks the PPI of bow_ppi_pkg, plus a temporary band of configuration,
// status, events, resets and raw words that the controller's register file still holds
// (listed below; it goes away in steps 4 and 5).
//
//   clk_lp_i, lp_i --> bow_dphy_lp x (1 + Lanes) --> clk_hs_en_o, hs_en_o, byte_ce_o
//      (lp domain)        | hs_active                  clk_tog (byte clock edges)
//   rx_data_i, rx_valid_i --> word flops --> bow_dphy_align x Lanes --> ppi_hs_o (byte domain)
//                                  +--> band_raw_* (RAW capture of the controller)
//   LP state machines --> ppi_lp_o, ppi_lp_clk_o (lp domain)
//   band_dly_* (CPU) --> tap loads (DlyVid 0: byte, 1: lp domain) --> dly_tap_o, dly_load_o
//   dly_tap_i, byte clock meter, LP levels, HS / gate state, phy_rdy_i --> band_*_sys_o (CPU)
//
// Contents (moved from bow_csi2rx in step 1; instance and register names kept, the FPGA
// constraints select them by name):
//   * the LP state machines (u_lp_clk, g_lp[l].u_lp) and the synchroniser of their
//     configuration (u_sync_vcfg: the PPI enables, CLK_FORCE, PHY_CFG), the LP / HS / gate
//     status towards the CPU (u_sync_vst) and the phy_rdy_i synchroniser;
//   * clock lane activity: a byte clock flop toggling on every edge, seen from the lp
//     domain (clk_tog: clock miss detection of the clock lane state machine);
//   * byte_rst_o, the ISERDES reset: asserted while the byte clock gate is closed, released
//     2 byte clocks after the clock restarts (u_iserdes_rst);
//   * the rx_data / rx_valid word flops, the hs_active synchroniser into the byte domain
//     (u_sync_arm) and the aligners (g_align[l].u_align);
//   * the input delay tap loads (g_dly_byte / g_dly_vid) and the tap readback synchroniser
//     (u_sync_tap_out);
//   * the byte clock meter (meter_gray_q, u_sync_meter).
//
// PPI (bow_ppi_pkg, v1):
//   rx_byte_clk_hs_o  RxByteClkHS = byte_clk_i
//   ppi_hs_o[l]       RxActiveHS (hs_active of the lane, synchronised: arm), RxValidHS,
//                     RxDataHS, RxSyncHS, ErrSotSyncHS, RxSkewCalHS of the aligner; ErrSotHS 0
//   ppi_lp_o[l]       Stopstate, ErrControl (LP error pulse of the lane state machine, on
//                     bit 0); ULPS / escape signals idle
//   ppi_lp_clk_o      StopstateClk, RxClkActiveHS (the clock lane's hs_active: gate open),
//                     ErrControlClk (LP error pulse of the clock lane); ULPS idle
//   enable_i[l], enable_clk_i  Enable[l], EnableClk (CPU domain flops of the controller,
//                     synchronised here with the rest of the configuration)
// The ErrControl pulses are not gated: the controller marks the lost bursts (lane enables,
// CLK_FORCE). They are pulses of lp_clk_i, which the controller must run on (FPGA: lp_clk =
// vid_clk, checked by bow_csi2rx).
//
// Temporary band (band_*, bow_mipi_rx; docs/ip/mipi_rx_arch.md section 10, step 2), with the
// step that removes each part:
//   in   band_lp_rst_ni, band_brst_ni, band_drst_ni   the controller's synchronised resets
//                     (lp_clk_i = vid_clk_i, byte hard, byte datapath = aligners, also held
//                     while RX is off): step 4 (resets of the D-PHY itself, section 4.11)
//   in   band_rst_src_ni  their asynchronous source, for the ISERDES reset: step 5 (des_rst
//                     of the AFE interface)
//   in   band_clk_force_i, band_settle_i, band_lp_filter_i, band_clk_settle_i,
//        band_clk_miss_i  CTRL.CLK_FORCE, PHY_CFG (CPU domain, quasi-static): step 4
//                     (D-PHY CTRL.CLK_CONT, TIM0)
//   in   band_dly_i, band_dly_req_i  DLYn taps and write counters (CPU domain): step 4
//                     (D-PHY DLYn), the load protocol moves to the AFE adapter in step 5
//   out  band_lp_sys_o, band_hs_en_sys_o, band_ce_sys_o, band_phy_rdy_sys_o, band_meter_sys_o,
//        band_dly_sys_o  STATUS, BYTECLK and DLYn readback (CPU domain): step 4 (D-PHY
//                     LANE_LP, LANE_HS, AFE_STATUS, BYTECLK, DLYn)
//   out  band_ev_hs_o  HS entry pulses (lp domain) for CNT_BURST*, CNT_MISC[15:0]: step 4
//                     (D-PHY CNT_BURSTn, CNT_CLK)
//   out  band_lane_en_lp_o, band_clk_force_lp_o  the lane enables and CLK_FORCE of
//                     u_sync_vcfg (lp domain) for the controller's lost burst marking: step 4
//                     (CLK_FORCE becomes the D-PHY's CTRL.CLK_CONT; section 10, step 2 notes)
//   out  band_raw_data_o, band_raw_valid_o  registered PHY words for RAW (byte domain):
//                     step 4 (RAW in the D-PHY, bow_dphy_raw)
//
// Clocks: clk_i (CPU: status synchronisers), lp_clk_i (LP state machines, tap loads with
// DlyVid = 1; bow_mipi_rx: vid_clk_i), byte_clk_i (byte clock of the PHY I/O, runs only
// while byte_ce_o = 1 and the clock lane toggles). The PHY I/O contract (rx_valid_i,
// phy_rdy_i, dly_*) is described in bow_mipi_rx.

module bow_dphy_rx import bow_ppi_pkg::*; #(
  parameter int unsigned Lanes  = 2,         // data lanes: 1, 2 or 4
  parameter bit          DlyVid = 1'b0       // dly_* in the lp clock domain (Versal XPHY)
) (
  input  logic                  clk_i,               // CPU clock
  input  logic                  rst_ni,              // CPU domain reset
  input  logic                  lp_clk_i,            // lp clock (bow_mipi_rx: video clock)
  input  logic                  byte_clk_i,          // byte clock of the PHY I/O (gated)

  // PPI (bow_ppi_pkg)
  input  logic [Lanes-1:0]      enable_i,            // Enable[l], any domain
  input  logic                  enable_clk_i,        // EnableClk, any domain
  output logic                  rx_byte_clk_hs_o,    // RxByteClkHS
  output ppi_hs_t [Lanes-1:0]   ppi_hs_o,            // byte domain
  output ppi_lp_t [Lanes-1:0]   ppi_lp_o,            // lp domain
  output ppi_lp_clk_t           ppi_lp_clk_o,        // lp domain

  // Temporary band (see above): resets and configuration from the controller
  input  logic                  band_lp_rst_ni,      // lp domain reset (synchronised)
  input  logic                  band_brst_ni,        // byte domain hard reset (synchronised)
  input  logic                  band_drst_ni,        // byte datapath reset (synchronised)
  input  logic                  band_rst_src_ni,     // asynchronous source of the resets
  input  logic                  band_clk_force_i,    // CTRL.CLK_FORCE (CPU domain, quasi-static:
  input  logic [7:0]            band_settle_i,       // PHY_CFG.SETTLE      changed only while
  input  logic [3:0]            band_lp_filter_i,    // PHY_CFG.LP_FILTER   PHY_EN = 0)
  input  logic [7:0]            band_clk_settle_i,   // PHY_CFG.CLK_SETTLE
  input  logic [7:0]            band_clk_miss_i,     // PHY_CFG.CLK_MISS
  input  logic [Lanes-1:0][8:0] band_dly_i,          // DLYn taps (CPU domain)
  input  logic [Lanes-1:0][1:0] band_dly_req_i,      // DLYn write counters (gray, DlyVid = 1)

  // Temporary band: status, events and raw words to the controller
  output logic [Lanes:0][1:0]   band_lp_sys_o,       // filtered LP {P, N}, [0] clock lane, [1 + l]
                                                     // data lane l (CPU domain)
  output logic [Lanes:0]        band_hs_en_sys_o,    // HS receivers on, same order (CPU)
  output logic                  band_ce_sys_o,       // byte clock gate open (CPU)
  output logic                  band_phy_rdy_sys_o,  // phy_rdy_i (CPU)
  output logic [19:0]           band_meter_sys_o,    // byte clock cycle counter, gray (CPU)
  output logic [Lanes-1:0][8:0] band_dly_sys_o,      // dly_tap_i, CNTVALUEOUT (CPU)
  output logic [Lanes:0]        band_ev_hs_o,        // HS entry pulses, same order (lp domain)
  output logic [Lanes-1:0]      band_lane_en_lp_o,   // data lane enables (lp domain)
  output logic                  band_clk_force_lp_o, // CLK_FORCE (lp domain)
  output logic [Lanes-1:0][7:0] band_raw_data_o,     // registered PHY words (byte domain)
  output logic [Lanes-1:0]      band_raw_valid_o,    // registered rx_valid_i (byte domain)

  // PHY I/O (bow_dphy_io_xusp, bow_dphy_io_versal): the PHY ports of bow_mipi_rx
  output logic                  byte_ce_o,           // lp domain flop (clock lane FSM)
  output logic                  byte_rst_o,          // ISERDES RST
  input  logic [1:0]            clk_lp_i,
  output logic                  clk_hs_en_o,         // lp domain flop of the FSM, no extra stage
  input  logic [Lanes-1:0][1:0] lp_i,
  output logic [Lanes-1:0]      hs_en_o,             // lp domain flops of the FSMs, no extra stage
  input  logic [Lanes-1:0][7:0] rx_data_i,           // registered once on byte_clk_i before use
  input  logic [Lanes-1:0]      rx_valid_i,          // byte domain: rx_data_i[l] is a new word
  input  logic                  phy_rdy_i,           // asynchronous: PHY ready
  output logic [Lanes-1:0][8:0] dly_tap_o,           // byte domain (DlyVid = 0) / lp domain (1)
  output logic [Lanes-1:0]      dly_load_o,          // same domain as dly_tap_o
  input  logic [Lanes-1:0][8:0] dly_tap_i            // CNTVALUEOUT, same domain as dly_tap_o
);

  if ((Lanes != 1) && (Lanes != 2) && (Lanes != 4)) begin : g_bad_lanes
    $error("bow_dphy_rx: Lanes must be 1, 2 or 4, not %0d", Lanes);
  end

  // Resets of the band (step 4: synchronisers of the D-PHY itself)
  logic lrst_n, brst_n, drst_n;

  assign lrst_n = band_lp_rst_ni;
  assign brst_n = band_brst_ni;
  assign drst_n = band_drst_ni;

  // =========================================================================
  // lp domain: LP state machines
  // =========================================================================
  logic [Lanes:0]      lane_en, hs_en, hs_act, ev_hs, ev_lp_err, stop;
  logic [Lanes:0][1:0] lp_st;
  logic                clk_force, clk_edge, byte_ce;
  logic [7:0]          settle, clk_settle, clk_miss;
  logic [3:0]          lp_filter;

  // the PPI enables in the bit order of step 1: [0] clock lane, [1 + l] data lane l
  bow_sync_bus #(
    .Width (Lanes + 30)
  ) u_sync_vcfg (
    .clk_i  (lp_clk_i),
    .rst_ni (lrst_n),
    .d_i    ({band_clk_force_i, enable_i, enable_clk_i, band_settle_i, band_lp_filter_i,
              band_clk_settle_i, band_clk_miss_i}),
    .q_o    ({clk_force, lane_en, settle, lp_filter, clk_settle, clk_miss})
  );

  bow_dphy_lp #(
    .ClockLane (1'b1)
  ) u_lp_clk (
    .clk_i       (lp_clk_i),
    .rst_ni      (lrst_n),
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
    .ev_err_o    (ev_lp_err[0]),
    .stop_o      (stop[0])
  );

  for (genvar l = 0; l < Lanes; l++) begin : g_lp
    bow_dphy_lp #(
      .ClockLane (1'b0)
    ) u_lp (
      .clk_i       (lp_clk_i),
      .rst_ni      (lrst_n),
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
      .ev_err_o    (ev_lp_err[1 + l]),
      .stop_o      (stop[1 + l])
    );
  end

  assign byte_ce_o   = byte_ce;
  assign clk_hs_en_o = hs_en[0];
  assign hs_en_o     = hs_en[Lanes:1];

  // PPI, lp domain: the LP errors as they come from the state machines (one cycle pulses,
  // not gated); ULPS and escape idle (v1)
  for (genvar l = 0; l < Lanes; l++) begin : g_ppi_lp
    assign ppi_lp_o[l].stopstate       = stop[1 + l];
    assign ppi_lp_o[l].ulps_active_not = 1'b1;
    assign ppi_lp_o[l].rx_ulps_esc     = 1'b0;
    assign ppi_lp_o[l].err_control     = {1'b0, ev_lp_err[1 + l]};
    assign ppi_lp_o[l].err_esc         = 2'b00;
    assign ppi_lp_o[l].err_sync_esc    = 2'b00;
  end

  assign ppi_lp_clk_o.stopstate        = stop[0];
  assign ppi_lp_clk_o.rx_clk_active_hs = hs_act[0];
  assign ppi_lp_clk_o.ulps_active_not  = 1'b1;
  assign ppi_lp_clk_o.rx_ulps_clk_not  = 1'b1;
  assign ppi_lp_clk_o.err_control      = {1'b0, ev_lp_err[0]};

  // Band: HS entries for the controller's counters, the synchronised lane enables and
  // CLK_FORCE for its lost burst marking
  assign band_ev_hs_o        = ev_hs;
  assign band_lane_en_lp_o   = lane_en[Lanes:1];
  assign band_clk_force_lp_o = clk_force;

  // Clock lane activity: a byte clock flop toggling on every edge, seen from
  // the lp domain (clock miss detection of the clock lane FSM). Every
  // byte clock edge counts, with or without a valid word: the byte clock
  // itself only runs while the clock lane toggles.
  logic clk_tog_q, clk_tog_s, clk_tog_last_q;

  always_ff @(posedge byte_clk_i or negedge brst_n) begin
    if (!brst_n) clk_tog_q <= 1'b0;
    else         clk_tog_q <= ~clk_tog_q;
  end

  bow_sync u_sync_tog (
    .clk_i  (lp_clk_i),
    .rst_ni (lrst_n),
    .d_i    (clk_tog_q),
    .q_o    (clk_tog_s)
  );

  always_ff @(posedge lp_clk_i or negedge lrst_n) begin
    if (!lrst_n) clk_tog_last_q <= 1'b0;
    else         clk_tog_last_q <= clk_tog_s;
  end

  assign clk_edge = clk_tog_s ^ clk_tog_last_q;

  // ISERDES reset: asserted while the byte clock gate is closed, released 2
  // byte clocks after the clock restarts
  logic iserdes_rst_n;

  bow_rst_sync u_iserdes_rst (
    .clk_i  (byte_clk_i),
    .rst_ni (band_rst_src_ni & byte_ce),
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
    .q_o ({band_ce_sys_o, band_hs_en_sys_o, band_lp_sys_o})
  );

  bow_sync u_sync_phy_rdy (
    .clk_i,
    .rst_ni,
    .d_i (phy_rdy_i),
    .q_o (band_phy_rdy_sys_o)
  );

  // =========================================================================
  // Byte domain: word flops, sync search and byte alignment
  // =========================================================================
  logic [Lanes-1:0][7:0] rx_q, al_data;
  logic [Lanes-1:0]      rxv_q, arm, al_valid, al_sot, al_sync_err, al_deskew;

  always_ff @(posedge byte_clk_i or negedge brst_n) begin
    if (!brst_n) begin
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
    .rst_ni (brst_n),
    .d_i    (hs_act[Lanes:1]),
    .q_o    (arm)
  );

  for (genvar l = 0; l < Lanes; l++) begin : g_align
    bow_dphy_align u_align (
      .clk_i         (byte_clk_i),
      .rst_ni        (drst_n),
      .arm_i         (arm[l]),
      .vld_i         (rxv_q[l]),
      .rx_i          (rx_q[l]),
      .valid_o       (al_valid[l]),
      .data_o        (al_data[l]),
      .sot_o         (al_sot[l]),
      .locked_o      (),
      .ev_sync_err_o (al_sync_err[l]),
      .ev_deskew_o   (al_deskew[l])
    );
  end

  // PPI, byte domain
  assign rx_byte_clk_hs_o = byte_clk_i;

  for (genvar l = 0; l < Lanes; l++) begin : g_ppi_hs
    assign ppi_hs_o[l].rx_active_hs    = arm[l];
    assign ppi_hs_o[l].rx_valid_hs     = al_valid[l];
    assign ppi_hs_o[l].rx_data_hs      = al_data[l];
    assign ppi_hs_o[l].rx_sync_hs      = al_sot[l];
    assign ppi_hs_o[l].rx_skew_cal_hs  = al_deskew[l];
    assign ppi_hs_o[l].err_sot_hs      = 1'b0;
    assign ppi_hs_o[l].err_sot_sync_hs = al_sync_err[l];
  end

  assign band_raw_data_o  = rx_q;
  assign band_raw_valid_o = rxv_q;

  // =========================================================================
  // Input delay taps (DlyVid = 0: byte domain, IDELAYE3; 1: lp domain, XPHY)
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
      .rst_ni (brst_n),
      .d_i    (band_dly_i),
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

    logic unused_req;
    assign unused_req = ^band_dly_req_i;
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
      .clk_i  (lp_clk_i),
      .rst_ni (lrst_n),
      .d_i    (band_dly_i),
      .q_o    (vtap_s)
    );

    bow_sync_bus #(
      .Width (2 * Lanes)
    ) u_sync_req (
      .clk_i  (lp_clk_i),
      .rst_ni (lrst_n),
      .d_i    (band_dly_req_i),
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

    always_ff @(posedge lp_clk_i or negedge lrst_n) begin
      if (!lrst_n) begin
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
    .q_o (band_dly_sys_o)
  );

  // =========================================================================
  // Byte domain: byte clock meter (free running gray counter)
  // =========================================================================
  logic [19:0] meter_q, meter_gray_q;

  always_ff @(posedge byte_clk_i or negedge brst_n) begin
    if (!brst_n) begin
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
    .q_o (band_meter_sys_o)
  );

endmodule
