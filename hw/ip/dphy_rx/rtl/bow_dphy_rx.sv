// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI D-PHY receiver, digital part (docs/ip/dphy_rx.md; docs/ip/mipi_rx_arch.md,
// section 4). Split out of the CSI-2 receiver in steps 1 and 2 of the migration plan
// (section 10); since step 4 it has its own registers (bow_dphy_rx_regs, the D-PHY window
// at 0xC00 of CSI2RX), its own resets and the RAW capture (bow_dphy_raw), and speaks only
// the PPI of bow_ppi_pkg with the CSI-2 controller (bow_csi2rx): the temporary band of
// steps 2 and 3 is gone.
//
//   clk_lp_i, lp_i --> bow_dphy_lp x (1 + Lanes) --> clk_hs_en_o, hs_en_o, byte_ce_o
//      (lp domain)        | hs_active                  clk_tog (byte clock edges)
//   rx_data_i, rx_valid_i --> word flops --> bow_dphy_align x Lanes --> ppi_hs_o (byte domain)
//                                  +--> bow_dphy_raw (RAW capture)
//   LP state machines --> ppi_lp_o, ppi_lp_clk_o (lp domain, masked ErrControl)
//   DLYn (bus) --> tap loads (DlyVid 0: byte, 1: lp domain) --> dly_tap_o, dly_load_o
//   bus <--> bow_dphy_rx_regs (u_regs): CTRL, CMD, TIM0, LANE_LP / LANE_HS, AFE_STATUS,
//            counters, BYTECLK, DLYn, RAW, IRQ / ERR --> irq_o, reinit_o, burst_rst_en_o
//
// Contents (instance and register names of steps 1 and 2 kept: the FPGA constraints select
// them by name):
//   * the LP state machines (u_lp_clk, g_lp[l].u_lp) and the synchroniser of their
//     configuration (u_sync_vcfg: the PPI enables, CTRL.CLK_CONT, TIM0), the LP / HS / gate
//     status towards the bus (u_sync_vst), the phy_rdy_i and phy_status_i synchronisers;
//   * the HS entries and LP errors of the state machines, released at most every 16 lp
//     cycles per kind and carried to the bus by one bow_cdc_pulse each (g_cdc_vev): the
//     counters CNT_BURSTn, CNT_CLK, CNT_LPERR, ERR_STATUS.CONTROL, ERR_LANE;
//   * clock lane activity: a byte clock flop toggling on every edge, seen from the lp
//     domain (clk_tog: clock miss detection of the clock lane state machine);
//   * byte_rst_o, the ISERDES reset: asserted while the byte clock gate is closed, released
//     2 byte clocks after the clock restarts (u_iserdes_rst; step 5: des_rst of the AFE);
//   * the rx_data / rx_valid word flops, the hs_active synchroniser into the byte domain
//     (u_sync_arm) and the aligners (g_align[l].u_align);
//   * the input delay tap loads (g_dly_byte / g_dly_vid) and the tap readback synchroniser
//     (u_sync_tap_out);
//   * the byte clock meter (meter_gray_q, u_sync_meter);
//   * the RAW capture (u_raw, u_sync_raw_req, u_sync_raw_ack).
//
// PPI (bow_ppi_pkg, v1):
//   rx_byte_clk_hs_o  RxByteClkHS = byte_clk_i
//   ppi_hs_o[l]       RxActiveHS (hs_active of the lane, synchronised: arm), RxValidHS,
//                     RxDataHS, RxSyncHS, ErrSotSyncHS, RxSkewCalHS of the aligner; ErrSotHS 0
//   ppi_lp_o[l]       Stopstate, ErrControl: the LP error pulse of the lane state machine on
//                     bit 0, masked by the lane's synchronised Enable; ULPS / escape idle
//   ppi_lp_clk_o      StopstateClk, RxClkActiveHS (the clock lane's hs_active: gate open),
//                     ErrControlClk: the clock lane's LP error pulse, masked while
//                     CTRL.CLK_CONT (synchronised) = 1; ULPS idle
//   enable_i[l], enable_clk_i  Enable[l], EnableClk (bus domain flops of the controller,
//                     synchronised here with the rest of the configuration)
// The ErrControl pulses are pulses of lp_clk_i: a v1 controller must run on it (FPGA: lp_clk
// = vid_clk, the connection in bow_mipi_rx; bow_csi2rx checks the frequency it is given as
// PpiLpClkHz). The masks are those the controller applied up to step 3 (the enables and
// CLK_FORCE of the band), in the same cycle: the lost burst marking is unchanged. The
// counters and ERR_STATUS / ERR_LANE of the registers count every error, unmasked.
//
// Clocks: clk_i (bus: registers, status synchronisers), lp_clk_i (LP state machines, tap
// loads with DlyVid = 1; bow_mipi_rx: vid_clk_i), byte_clk_i (byte clock of the PHY I/O, runs
// only while byte_ce_o = 1 and the clock lane toggles).
// Resets (section 4.11 of the spec), asynchronous assertion, synchronous release:
//   rst_ni                bus domain (registers, synchronisers towards the bus)
//   lrst_n (u_lrst)       lp domain, from rst_ni & lp_rst_ni: state machines, tap loads
//                         (DlyVid = 1), event release
//   brst_n (u_brst)       byte domain, from rst_ni & lp_rst_ni, released by the first byte
//                         clocks: word flops, aligners (not reset while the controller's RX
//                         is off: a burst cut by a stop ends there as any burst), clock
//                         toggle, meter, tap loads (DlyVid = 0), RAW
//   byte_rst_o            ISERDES RST (u_iserdes_rst, from rst_ni & lp_rst_ni & byte_ce)
//
// PHY I/O contract (bow_dphy_io_xusp, bow_dphy_io_versal):
//   rx_valid_i    byte domain, per lane: rx_data_i[l] is a new word. The aligner of a lane
//                 only advances on valid words (a PHY with FIFOs, e.g. the Versal XPHY, has
//                 no word in some cycles at the start of a burst and hands out the words left
//                 over from the previous burst first: they come before the HS-zero and the
//                 sync byte, so they only fill the aligner history). A PHY with a word in
//                 every cycle (bow_dphy_io_xusp) ties it to '1.
//   phy_rdy_i     asynchronous level, the PHY is ready (Versal: XPLL locked, BISC done):
//                 AFE_STATUS.READY; 1'b1 if the PHY has no such state.
//   phy_status_i  asynchronous, quasi-static raw status (Versal: {PHY_RDY all, DLY_RDY all,
//                 XPLL LOCKED_FB, LOCKED}): AFE_STATUS[15:8]; '0 if the PHY has none.
//   reinit_o      bus clock flop, CMD.REINIT: high for 32 bus cycles (Versal: the reinit_i
//                 knob, XPLL lock + BISC + VT tracking again); not used by bow_dphy_io_xusp.
//   burst_rst_en_o  bus clock flop, ~CTRL.DES_RST_DIS, 1 after reset (Versal: RX_RST of the
//                 data slices while the gate is closed); not used by bow_dphy_io_xusp.
//   dly_*         DlyVid = 0 (UltraScale+ IDELAYE3, CLK = byte clock): byte domain; a tap is
//                 loaded (dly_tap_o + one cycle dly_load_o) when its synchronised value was
//                 the same in two consecutive cycles and differs from the last loaded one,
//                 the first value after a reset is always loaded; only while the byte clock
//                 runs. DlyVid = 1 (Versal XPHY, CTRL_CLK = lp_clk_i): lp domain, no load
//                 after a reset (the PHY keeps its BISC delay, readable in DLYn[24:16]); every
//                 bus write to DLYn gives exactly one load of lane n with the written tap:
//                 dly_load_o[n] high for one cycle, dly_tap_o[n] set the cycle before and
//                 held until the next load, loads of a lane at least 16 cycles apart
//                 (requests closer than that are merged into one load of the newest tap).
//                 Works without a byte clock.

module bow_dphy_rx import bow_bus_pkg::*; import bow_ppi_pkg::*; #(
  parameter int unsigned Lanes       = 2,              // data lanes: 1, 2 or 4
  parameter bit          DlyVid      = 1'b0,           // dly_* in the lp clock domain (Versal XPHY)
  parameter int unsigned LpClkHz     = 200_000_000,    // lp_clk_i frequency (INFO[17:8])
  parameter int unsigned BusClkHz    = 0,              // clk_i frequency (0: not checked)
  parameter int unsigned AfeKind     = DlyVid ? 2 : 1, // INFO[7:5]: 1 UltraScale+, 2 Versal
  parameter int unsigned AfeSettleNs = DlyVid ? 120 : 107,   // INFO2: SETTLE target (ns, UI)
  parameter int unsigned AfeSettleUi = DlyVid ? 0 : 24,
  parameter int unsigned AfeTrailB   = DlyVid ? 8 : 0  // INFO2: trail bytes per lane of the AFE
) (
  input  logic                  clk_i,               // bus clock
  input  logic                  rst_ni,              // bus domain reset
  input  logic                  lp_clk_i,            // lp clock (bow_mipi_rx: video clock)
  input  logic                  lp_rst_ni,           // lp domain reset source (asynchronous)
  input  logic                  byte_clk_i,          // byte clock of the PHY I/O (gated)

  // registers (D-PHY window: bow_mipi_rx passes offsets 0xC00..0xFFF of CSI2RX)
  input  bus_req_t              bus_req_i,
  output bus_rsp_t              bus_rsp_o,
  output logic                  irq_o,               // |(IRQ_STATUS & IRQ_EN), bus clock domain

  // PPI (bow_ppi_pkg)
  input  logic [Lanes-1:0]      enable_i,            // Enable[l], any domain
  input  logic                  enable_clk_i,        // EnableClk, any domain
  output logic                  rx_byte_clk_hs_o,    // RxByteClkHS
  output ppi_hs_t [Lanes-1:0]   ppi_hs_o,            // byte domain
  output ppi_lp_t [Lanes-1:0]   ppi_lp_o,            // lp domain
  output ppi_lp_clk_t           ppi_lp_clk_o,        // lp domain

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
  input  logic [7:0]            phy_status_i,        // asynchronous: raw PHY status
  output logic                  reinit_o,            // bus clock flop: PHY re-init (CMD.REINIT)
  output logic                  burst_rst_en_o,      // bus clock flop: ~CTRL.DES_RST_DIS
  output logic [Lanes-1:0][8:0] dly_tap_o,           // byte domain (DlyVid = 0) / lp domain (1)
  output logic [Lanes-1:0]      dly_load_o,          // same domain as dly_tap_o
  input  logic [Lanes-1:0][8:0] dly_tap_i            // CNTVALUEOUT, same domain as dly_tap_o
);

  if ((Lanes != 1) && (Lanes != 2) && (Lanes != 4)) begin : g_bad_lanes
    $error("bow_dphy_rx: Lanes must be 1, 2 or 4, not %0d", Lanes);
  end

  // The LP event release below (one pulse per kind every 16 lp cycles) needs 3 bus cycles
  // per pulse: lp_clk_i <= 16/3 x clk_i. The elaboration $fatal stops lint and synthesis,
  // the initial copy stops simulations whose build turns USERFATAL into a warning
  // (-Wno-fatal).
  if ((BusClkHz != 0) && (64'(LpClkHz) * 64'd3 > 64'(BusClkHz) * 64'd16)) begin : g_bad_clk
    $fatal(1, "bow_dphy_rx: lp_clk_i %0d Hz > 16/3 x clk_i %0d Hz (LP event pulses merge)",
           LpClkHz, BusClkHz);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_dphy_rx: lp_clk_i %0d Hz > 16/3 x clk_i %0d Hz (LP event pulses merge)",
                   LpClkHz, BusClkHz);
`endif
  end

  // =========================================================================
  // Resets of the D-PHY itself (section 4.11 of the spec)
  // =========================================================================
  logic rst_src_n, lrst_n, brst_n;

  assign rst_src_n = rst_ni & lp_rst_ni;

  bow_rst_sync u_lrst (
    .clk_i  (lp_clk_i),
    .rst_ni (rst_src_n),
    .rst_no (lrst_n)
  );

  bow_rst_sync u_brst (
    .clk_i  (byte_clk_i),
    .rst_ni (rst_src_n),
    .rst_no (brst_n)
  );

  // =========================================================================
  // Bus domain: registers
  // =========================================================================
  logic                  cfg_clk_cont;
  logic [7:0]            cfg_settle, cfg_clk_settle, cfg_clk_miss;
  logic [3:0]            cfg_lp_filter;
  logic [Lanes-1:0][8:0] dly_code_sys, dly_sys;
  logic [Lanes-1:0][1:0] dly_req_sys;
  logic [3:0]            raw_req_sys, raw_ack, raw_ack_sys;
  logic                  raw_now_sys, raw_re;
  logic [5:0]            raw_addr;
  logic [8*Lanes-1:0]    raw_rdata;
  logic [Lanes:0]        ev_hs_sys, ev_err_sys;
  logic [Lanes:0][1:0]   lp_sys;
  logic [Lanes:0]        hs_en_sys;
  logic                  ce_sys, phy_rdy_sys;
  logic [7:0]            phy_status_sys;
  logic [19:0]           meter_sys;

  bow_dphy_rx_regs #(
    .Lanes       (Lanes),
    .LpClkHz     (LpClkHz),
    .AfeKind     (AfeKind),
    .AfeSettleNs (AfeSettleNs),
    .AfeSettleUi (AfeSettleUi),
    .AfeTrailB   (AfeTrailB)
  ) u_regs (
    .clk_i,
    .rst_ni,
    .bus_req_i,
    .bus_rsp_o,
    .irq_o,
    .clk_cont_o     (cfg_clk_cont),
    .burst_rst_en_o,
    .reinit_o,
    .settle_o       (cfg_settle),
    .lp_filter_o    (cfg_lp_filter),
    .clk_settle_o   (cfg_clk_settle),
    .clk_miss_o     (cfg_clk_miss),
    .dly_code_o     (dly_code_sys),
    .dly_req_o      (dly_req_sys),
    .raw_req_o      (raw_req_sys),
    .raw_now_o      (raw_now_sys),
    .raw_ack_i      (raw_ack_sys),
    .raw_re_o       (raw_re),
    .raw_addr_o     (raw_addr),
    .raw_rdata_i    (raw_rdata),
    .ev_hs_i        (ev_hs_sys),
    .ev_err_i       (ev_err_sys),
    .lp_i           (lp_sys),
    .hs_en_i        (hs_en_sys),
    .ce_i           (ce_sys),
    .ready_i        (phy_rdy_sys),
    .afe_status_i   (phy_status_sys),
    .meter_i        (meter_sys),
    .dly_q_i        (dly_sys)
  );

  // =========================================================================
  // lp domain: LP state machines
  // =========================================================================
  logic [Lanes:0]      lane_en, hs_en, hs_act, ev_hs, ev_lp_err, stop;
  logic [Lanes:0][1:0] lp_st;
  logic                clk_force, clk_edge, byte_ce;
  logic [7:0]          settle, clk_settle, clk_miss;
  logic [3:0]          lp_filter;

  // the PPI enables in the bit order of step 1: [0] clock lane, [1 + l] data lane l;
  // CTRL.CLK_CONT (clk_force: the clock lane state machine's continuous clock) and TIM0
  bow_sync_bus #(
    .Width (Lanes + 30)
  ) u_sync_vcfg (
    .clk_i  (lp_clk_i),
    .rst_ni (lrst_n),
    .d_i    ({cfg_clk_cont, enable_i, enable_clk_i, cfg_settle, cfg_lp_filter, cfg_clk_settle,
              cfg_clk_miss}),
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

  // PPI, lp domain: the LP errors of the state machines (one cycle pulses), ErrControl of a
  // data lane masked by its synchronised Enable, ErrControlClk while CTRL.CLK_CONT (the
  // byte clock is not gated by the clock lane then); ULPS and escape idle (v1)
  for (genvar l = 0; l < Lanes; l++) begin : g_ppi_lp
    assign ppi_lp_o[l].stopstate       = stop[1 + l];
    assign ppi_lp_o[l].ulps_active_not = 1'b1;
    assign ppi_lp_o[l].rx_ulps_esc     = 1'b0;
    assign ppi_lp_o[l].err_control     = {1'b0, ev_lp_err[1 + l] & lane_en[1 + l]};
    assign ppi_lp_o[l].err_esc         = 2'b00;
    assign ppi_lp_o[l].err_sync_esc    = 2'b00;
  end

  assign ppi_lp_clk_o.stopstate        = stop[0];
  assign ppi_lp_clk_o.rx_clk_active_hs = hs_act[0];
  assign ppi_lp_clk_o.ulps_active_not  = 1'b1;
  assign ppi_lp_clk_o.rx_ulps_clk_not  = 1'b1;
  assign ppi_lp_clk_o.err_control      = {1'b0, ev_lp_err[0] & ~clk_force};

  // LP events -> bus (HS entries, LP errors; [0] clock lane, [1 + l] data lane l), for the
  // counters and ERR_STATUS / ERR_LANE (every error, unmasked). Each kind is released at
  // most every 16 lp cycles, so the pulse synchronisers never merge two pulses (needs
  // lp_clk_i <= 16/3 x clk_i, checked with BusClkHz); real D-PHY sequences are much slower
  // (T_LPX >= 50 ns per LP state), only a glitching line can lose counts.
  localparam int unsigned NumVEv = 2 * (Lanes + 1);

  logic [NumVEv-1:0] vev, vev_pend_q, vev_fire, vev_sys;
  logic [3:0]        vdiv_q;

  assign vev      = {ev_lp_err, ev_hs};
  assign vev_fire = (vdiv_q == 4'd0) ? vev_pend_q : '0;

  always_ff @(posedge lp_clk_i or negedge lrst_n) begin
    if (!lrst_n) begin
      vdiv_q     <= '0;
      vev_pend_q <= '0;
    end else begin
      vdiv_q     <= vdiv_q + 4'd1;
      vev_pend_q <= (vev_pend_q & ~vev_fire) | vev;
    end
  end

  for (genvar i = 0; i < NumVEv; i++) begin : g_cdc_vev
    bow_cdc_pulse u_cdc (
      .src_clk_i   (lp_clk_i),
      .src_rst_ni  (lrst_n),
      .src_pulse_i (vev_fire[i]),
      .dst_clk_i   (clk_i),
      .dst_rst_ni  (rst_ni),
      .dst_pulse_o (vev_sys[i])
    );
  end

  assign ev_hs_sys  = vev_sys[Lanes:0];
  assign ev_err_sys = vev_sys[NumVEv-1 -: Lanes + 1];

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
    .rst_ni (rst_src_n & byte_ce),
    .rst_no (iserdes_rst_n)
  );

  assign byte_rst_o = ~iserdes_rst_n;

  // PHY status -> bus
  bow_sync_bus #(
    .Width      (3 * Lanes + 4),
    .ResetValue ({{(Lanes + 2){1'b0}}, {(2 * Lanes + 2){1'b1}}})   // LP-11
  ) u_sync_vst (
    .clk_i,
    .rst_ni,
    .d_i ({byte_ce, hs_en, lp_st}),
    .q_o ({ce_sys, hs_en_sys, lp_sys})
  );

  bow_sync u_sync_phy_rdy (
    .clk_i,
    .rst_ni,
    .d_i (phy_rdy_i),
    .q_o (phy_rdy_sys)
  );

  bow_sync_bus #(
    .Width (8)
  ) u_sync_phy_st (
    .clk_i,
    .rst_ni,
    .d_i (phy_status_i),
    .q_o (phy_status_sys)
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
      .rst_ni        (brst_n),
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

  // =========================================================================
  // Byte domain: RAW capture of the registered PHY words, from the rising arm of lane 0.
  // Commands as a gray request counter (bus -> byte) and an ack (byte -> bus); the RAM is
  // read on the bus clock.
  // =========================================================================
  logic [3:0] raw_req;
  logic       raw_now;

  bow_sync_bus #(
    .Width (4)
  ) u_sync_raw_req (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (raw_req_sys),
    .q_o    (raw_req)
  );

  bow_sync u_sync_raw_now (
    .clk_i  (byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (raw_now_sys),
    .q_o    (raw_now)
  );

  bow_dphy_raw #(
    .Lanes (Lanes)
  ) u_raw (
    .clk_i       (byte_clk_i),
    .rst_ni      (brst_n),
    .raw_req_i   (raw_req),
    .raw_now_i   (raw_now),
    .raw_ack_o   (raw_ack),
    .arm0_i      (arm[0]),
    .rx_vld0_i   (rxv_q[0]),
    .rx_i        (rx_q),
    .rclk_i      (clk_i),
    .raw_re_i    (raw_re),
    .raddr_i     (raw_addr),
    .raw_rdata_o (raw_rdata)
  );

  bow_sync_bus #(
    .Width (4)
  ) u_sync_raw_ack (
    .clk_i,
    .rst_ni,
    .d_i (raw_ack),
    .q_o (raw_ack_sys)
  );

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
      .d_i    (dly_code_sys),
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
    assign unused_req = ^dly_req_sys;
  end else begin : g_dly_vid
    // Per lane: the 2 bit gray request counter of the bus side (+1 per DLYn
    // write) and the taps come through one synchroniser per bit. A change of
    // the counter starts a request; the tap bus, written in the same bus
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
      .d_i    (dly_code_sys),
      .q_o    (vtap_s)
    );

    bow_sync_bus #(
      .Width (2 * Lanes)
    ) u_sync_req (
      .clk_i  (lp_clk_i),
      .rst_ni (lrst_n),
      .d_i    (dly_req_sys),
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
    .q_o (dly_sys)
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
    .q_o (meter_sys)
  );

endmodule
