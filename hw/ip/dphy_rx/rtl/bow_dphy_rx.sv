// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI D-PHY receiver, digital part (docs/ip/dphy_rx.md; docs/ip/mipi_rx_arch.md,
// section 4). Split out of the CSI-2 receiver in steps 1 and 2 of the migration plan
// (section 10); since step 4 it has its own registers (bow_dphy_rx_regs, the D-PHY window
// at 0xC00 of CSI2RX), its own resets and the RAW capture (bow_dphy_raw), and speaks only
// the PPI of bow_ppi_pkg with the CSI-2 controller (bow_csi2rx); since step 5 it speaks the
// AFE interface of section 3.2 with the analog part below it (an ASIC macro, or an FPGA
// adapter: bow_dphy_io_xusp, bow_dphy_io_versal).
//
//   afe_clk_lp_i, afe_lp_i --> bow_dphy_lp x (1 + Lanes) --> afe_*hsrx_en_o, afe_*term_en_o,
//      (lp domain)               | hs_active                 afe_clk_gate_en_o, afe_des_rst_o
//                                | clk_tog (byte clock edges)
//   afe_hs_data_i, afe_hs_valid_i --> word flops --> bow_dphy_align x Lanes --> ppi_hs_o
//                                          +--> bow_dphy_raw (RAW capture)    (byte domain)
//   LP state machines --> ppi_lp_o, ppi_lp_clk_o (lp domain, masked ErrControl)
//   bus <--> bow_dphy_rx_regs (u_regs): CTRL, CMD, AFE_CTRL, AFE_STATUS, TIM0, LANE_LP /
//            LANE_HS, counters, BYTECLK, DLYn, RAW, IRQ / ERR --> irq_o; AFE controls
//            (afe_dly_code_o / afe_dly_own_o, afe_pd_o, afe_lprx_en_o, afe_lane_pd_o,
//            afe_cal_start_o)
//
// Contents (instance and register names of steps 1 and 2 kept: the FPGA constraints select
// them by name):
//   * the LP state machines (u_lp_clk, g_lp[l].u_lp) and the synchroniser of their
//     configuration (u_sync_vcfg: the PPI enables, CTRL.CLK_CONT, TIM0 and, since step 5,
//     ~CTRL.DES_RST_DIS), the LP / HS / gate status towards the bus (u_sync_vst), the AFE's
//     ready, status and calibration result synchronisers;
//   * the HS entries and LP errors of the state machines, released at most every 16 lp
//     cycles per kind and carried to the bus by one bow_cdc_pulse each (g_cdc_vev): the
//     counters CNT_BURSTn, CNT_CLK, CNT_LPERR, ERR_STATUS.CONTROL, ERR_LANE;
//   * clock lane activity: a byte clock flop toggling on every edge, seen from the lp
//     domain (clk_tog: clock miss detection of the clock lane state machine);
//   * the hs_data / hs_valid word flops, the hs_active synchroniser into the byte domain
//     (u_sync_arm) and the aligners (g_align[l].u_align);
//   * the delay readback synchroniser (u_sync_tap_out, AFE dly_q -> DLYn[24:16]);
//   * the byte clock meter (meter_gray_q, u_sync_meter);
//   * the RAW capture (u_raw, u_sync_raw_req, u_sync_raw_ack).
// What steps 1 to 4 had here for the FPGA PHY I/O went into the adapters in step 5
// (bow_dphy_dly_xusp, bow_dphy_dly_xphy): the input delay loads (both PHY kinds, the old
// DlyVid 0 / 1) and the ISERDES
// reset release on the byte clock; the D-PHY drives static delay codes and des_rst.
//
// PPI (bow_ppi_pkg, v1):
//   rx_byte_clk_hs_o  RxByteClkHS = afe_hs_byte_clk_i
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
// AFE interface (docs/ip/mipi_rx_arch.md, section 3.2; ports afe_<name>_i / _o, [l] = data
// lane l, afe_clk_* = the clock lane). Every control towards the AFE comes straight from a
// flop (the AFE takes them as asynchronous); every AFE output but the byte domain group is
// synchronised here.
//   A  afe_hs_byte_clk_i   byte clock (DesW = 8), gated in the AFE by afe_clk_gate_en_o
//      afe_hs_data_i[l], afe_hs_valid_i[l]  byte domain, registered once before use; valid:
//                          a new word (an AFE with FIFOs, e.g. the Versal adapter; else '1).
//                          The aligner of a lane only advances on valid words.
//      afe_clk_gate_en_o   lp flop: the clock lane state machine's gate (ce_q)
//      afe_des_rst_o       lp flop: ~afe_clk_gate_en_o, set and released at the same lp edge
//                          as the gate closes and opens (bow_dphy_lp); 0 while
//                          CTRL.DES_RST_DIS = 1 (a test bit). Clears the AFE's data path
//                          only, never its byte clock divider.
//      afe_clk_hs_samp_i   optional, diagnostic: not used in v1
//      afe_clk_act_i       optional for the FPGA adapters (none has it, AfeClkAct = 0), not
//                          used in v1: the clock miss detection with it comes with step 10
//   B  afe_lp_i[l], afe_clk_lp_i       {P, N}, asynchronous: synchroniser + filter
//      afe_lprx_en_o, afe_clk_lprx_en_o  ~AFE_CTRL.PD, one bus clock flop for every lane
//   C  afe_hsrx_en_o, afe_clk_hsrx_en_o  lp flops of the state machines (hs_en_q);
//      afe_term_en_o, afe_clk_term_en_o  v1: the same flops (separate ports; HSRX_EARLY and
//                          CLK_MISS_OFF, which make them differ, come with step 6)
//   D  afe_dly_code_o[l], afe_dly_own_o[l]  DLYn CODE and OWN: static levels from bus clock
//                          flops (u_regs; no load protocol here: the AFE applies a new code
//                          by itself, section 3.5); OWN falls with READY
//      afe_dly_q_i[l]      the delay in use, asynchronous: u_sync_tap_out -> DLYn[24:16]
//      afe_clk_dly_*       optional (clock lane delay, INFO[22] = 0): code 0, own 0, q unused
//      afe_mon_*           optional (monitor sampler, v3): en 0, code 0, data unused
//   E  afe_pd_o            AFE_CTRL.PD (bus clock flop, reset AfePdRst); never from Enable
//      afe_lane_pd_o, afe_clk_lane_pd_o  one bus clock flop: 1 from reset and while PD, 0 once
//                          READY was seen with PD = 0 (v1: no LANE_EN, no ULPS)
//      afe_ready_i         asynchronous: AFE_STATUS.READY; OWN of every lane falls with it
//      afe_cal_start_o     CMD.REINIT, 32 bus clock cycles (v1; CMD.AFE_CAL from step 6)
//      afe_cal_done_i, afe_cal_err_i  asynchronous: AFE_STATUS[1], [2]
//      afe_trim_o          v1: 0 (AFE_TRIM0/1 come with an AFE that defines the trim bits)
//      afe_status_i        asynchronous, quasi-static: AFE_STATUS[15:8]
//   F  afe_tst_mode_o, afe_tst_data_o, afe_atb_sel_o  test hooks, v1: 0;
//      afe_hs_raw_i, afe_clk_hs_raw_i  not used (DFT and the loopback test come later)
//
// Clocks: clk_i (bus: registers, status synchronisers), lp_clk_i (LP state machines;
// bow_mipi_rx: vid_clk_i), afe_hs_byte_clk_i (the AFE's byte clock, runs only while
// afe_clk_gate_en_o = 1 and the clock lane toggles).
// Resets (section 4.11 of the spec), asynchronous assertion, synchronous release:
//   rst_ni                bus domain (registers, AFE controls, synchronisers towards the bus)
//   lrst_n (u_lrst)       lp domain, from rst_ni & lp_rst_ni: state machines, event release
//   brst_n (u_brst)       byte domain, from rst_ni & lp_rst_ni, released by the first byte
//                         clocks: word flops, aligners (not reset while the controller's RX
//                         is off: a burst cut by a stop ends there as any burst), clock
//                         toggle, meter, RAW
// At reset (section 3.6): afe_pd_o = AfePdRst, afe_lprx_en_o = ~AfePdRst, hsrx / term 0,
// gate 0, des_rst 1, dly_own 0, lane_pd 1.

module bow_dphy_rx import bow_bus_pkg::*; import bow_ppi_pkg::*; #(
  parameter int unsigned Lanes       = 2,              // data lanes: 1, 2 or 4
  parameter int unsigned AfeKind     = 1,              // INFO[7:5]: 0 ASIC macro, 1 UltraScale+
                                                       //   adapter, 2 Versal adapter, 3 model
  parameter int unsigned LpClkHz     = 200_000_000,    // lp_clk_i frequency (INFO[17:8])
  parameter int unsigned BusClkHz    = 0,              // clk_i frequency (0: not checked)
  parameter int unsigned AfeSettleNs = (AfeKind == 2) ? 120 : 107,   // INFO2: SETTLE target
  parameter int unsigned AfeSettleUi = (AfeKind == 2) ? 0 : 24,      //   (ns, UI)
  parameter int unsigned AfeTrailB   = (AfeKind == 2) ? 8 : 0,       // INFO2: AFE trail bytes
  parameter bit          AfePdRst    = 1'b0,           // AFE_CTRL.PD after reset (ASIC: 1)
  parameter int unsigned TrimW       = 64,             // AFE trim bits, 1..64
  localparam int unsigned DlyW       = 9               // delay code bits (INFO[21:18])
) (
  input  logic                       clk_i,             // bus clock
  input  logic                       rst_ni,            // bus domain reset
  input  logic                       lp_clk_i,          // lp clock (bow_mipi_rx: video clock)
  input  logic                       lp_rst_ni,         // lp domain reset source (asynchronous)

  // registers (D-PHY window: bow_mipi_rx passes offsets 0xC00..0xFFF of CSI2RX)
  input  bus_req_t                   bus_req_i,
  output bus_rsp_t                   bus_rsp_o,
  output logic                       irq_o,             // |(IRQ_STATUS & IRQ_EN), bus clock

  // PPI (bow_ppi_pkg)
  input  logic [Lanes-1:0]           enable_i,          // Enable[l], any domain
  input  logic                       enable_clk_i,      // EnableClk, any domain
  output logic                       rx_byte_clk_hs_o,  // RxByteClkHS
  output ppi_hs_t [Lanes-1:0]        ppi_hs_o,          // byte domain
  output ppi_lp_t [Lanes-1:0]        ppi_lp_o,          // lp domain
  output ppi_lp_clk_t                ppi_lp_clk_o,      // lp domain

  // AFE interface (docs/ip/mipi_rx_arch.md, section 3.2; see above)
  // A: HS data and byte clock
  input  logic                       afe_hs_byte_clk_i,
  input  logic [Lanes-1:0][7:0]      afe_hs_data_i,     // byte domain
  input  logic [Lanes-1:0]           afe_hs_valid_i,    // byte domain
  output logic                       afe_clk_gate_en_o, // lp flop
  output logic                       afe_des_rst_o,     // lp flop
  input  logic [7:0]                 afe_clk_hs_samp_i, // optional, not used in v1
  input  logic                       afe_clk_act_i,     // optional, not used in v1 (step 10)
  // B: LP
  input  logic [1:0]                 afe_clk_lp_i,      // asynchronous
  input  logic [Lanes-1:0][1:0]      afe_lp_i,          // asynchronous
  output logic                       afe_clk_lprx_en_o, // bus clock flop
  output logic [Lanes-1:0]           afe_lprx_en_o,     // bus clock flop
  // C: HS receivers and termination
  output logic                       afe_clk_hsrx_en_o, // lp flop
  output logic [Lanes-1:0]           afe_hsrx_en_o,     // lp flops
  output logic                       afe_clk_term_en_o, // lp flop
  output logic [Lanes-1:0]           afe_term_en_o,     // lp flops
  // D: delays
  output logic [Lanes-1:0][DlyW-1:0] afe_dly_code_o,    // bus clock flops, static
  output logic [Lanes-1:0]           afe_dly_own_o,     // bus clock flops
  input  logic [Lanes-1:0][DlyW-1:0] afe_dly_q_i,       // asynchronous, quasi-static
  output logic [DlyW-1:0]            afe_clk_dly_code_o,  // optional: 0
  output logic                       afe_clk_dly_own_o,   // optional: 0
  input  logic [DlyW-1:0]            afe_clk_dly_q_i,     // optional, not used
  output logic [Lanes-1:0]           afe_mon_en_o,        // optional (v3): 0
  output logic [Lanes-1:0][DlyW-1:0] afe_mon_code_o,      // optional (v3): 0
  input  logic [Lanes-1:0][7:0]      afe_mon_data_i,      // optional (v3), not used
  // E: power, internal calibration, status
  output logic                       afe_pd_o,          // bus clock flop
  output logic                       afe_clk_lane_pd_o, // bus clock flop
  output logic [Lanes-1:0]           afe_lane_pd_o,     // bus clock flop
  input  logic                       afe_ready_i,       // asynchronous
  output logic                       afe_cal_start_o,   // bus clock flop, 32 cycles
  input  logic                       afe_cal_done_i,    // asynchronous
  input  logic                       afe_cal_err_i,     // asynchronous
  output logic [TrimW-1:0]           afe_trim_o,        // v1: 0
  input  logic [7:0]                 afe_status_i,      // asynchronous, quasi-static
  // F: test hooks (v1: off)
  output logic [2:0]                 afe_tst_mode_o,
  output logic [Lanes-1:0][7:0]      afe_tst_data_o,
  input  logic                       afe_clk_hs_raw_i,
  input  logic [Lanes-1:0]           afe_hs_raw_i,
  output logic [7:0]                 afe_atb_sel_o
);

  if ((Lanes != 1) && (Lanes != 2) && (Lanes != 4)) begin : g_bad_lanes
    $error("bow_dphy_rx: Lanes must be 1, 2 or 4, not %0d", Lanes);
  end
  if ((TrimW < 1) || (TrimW > 64)) begin : g_bad_trim
    $error("bow_dphy_rx: TrimW must be 1..64, not %0d", TrimW);
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
    .clk_i  (afe_hs_byte_clk_i),
    .rst_ni (rst_src_n),
    .rst_no (brst_n)
  );

  // =========================================================================
  // Bus domain: registers
  // =========================================================================
  logic                  cfg_clk_cont, cfg_des_rst_en;
  logic [7:0]            cfg_settle, cfg_clk_settle, cfg_clk_miss;
  logic [3:0]            cfg_lp_filter;
  logic [Lanes-1:0][8:0] dly_sys;
  logic                  lprx_en, lane_pd;
  logic [3:0]            raw_req_sys, raw_ack, raw_ack_sys;
  logic                  raw_now_sys, raw_re;
  logic [5:0]            raw_addr;
  logic [8*Lanes-1:0]    raw_rdata;
  logic [Lanes:0]        ev_hs_sys, ev_err_sys;
  logic [Lanes:0][1:0]   lp_sys;
  logic [Lanes:0]        hs_en_sys;
  logic                  ce_sys, phy_rdy_sys, cal_done_sys, cal_err_sys;
  logic [7:0]            phy_status_sys;
  logic [19:0]           meter_sys;

  bow_dphy_rx_regs #(
    .Lanes       (Lanes),
    .LpClkHz     (LpClkHz),
    .AfeKind     (AfeKind),
    .AfeSettleNs (AfeSettleNs),
    .AfeSettleUi (AfeSettleUi),
    .AfeTrailB   (AfeTrailB),
    .AfePdRst    (AfePdRst)
  ) u_regs (
    .clk_i,
    .rst_ni,
    .bus_req_i,
    .bus_rsp_o,
    .irq_o,
    .clk_cont_o     (cfg_clk_cont),
    .des_rst_en_o   (cfg_des_rst_en),
    .settle_o       (cfg_settle),
    .lp_filter_o    (cfg_lp_filter),
    .clk_settle_o   (cfg_clk_settle),
    .clk_miss_o     (cfg_clk_miss),
    .cal_start_o    (afe_cal_start_o),
    .pd_o           (afe_pd_o),
    .lprx_en_o      (lprx_en),
    .lane_pd_o      (lane_pd),
    .dly_code_o     (afe_dly_code_o),
    .dly_own_o      (afe_dly_own_o),
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
    .cal_done_i     (cal_done_sys),
    .cal_err_i      (cal_err_sys),
    .afe_status_i   (phy_status_sys),
    .meter_i        (meter_sys),
    .dly_q_i        (dly_sys)
  );

  // =========================================================================
  // lp domain: LP state machines
  // =========================================================================
  logic [Lanes:0]      lane_en, hs_en, hs_act, ev_hs, ev_lp_err, stop;
  logic [Lanes:0][1:0] lp_st;
  logic                clk_force, clk_edge, byte_ce, des_rst_en, des_rst;
  logic [7:0]          settle, clk_settle, clk_miss;
  logic [3:0]          lp_filter;

  // the PPI enables in the bit order of step 1: [0] clock lane, [1 + l] data lane l;
  // CTRL.CLK_CONT (clk_force: the clock lane state machine's continuous clock), TIM0 and,
  // above them (step 5), ~CTRL.DES_RST_DIS (reset 1, as its register: des_rst stays set
  // through and after a reset)
  bow_sync_bus #(
    .Width      (Lanes + 31),
    .ResetValue ({1'b1, {(Lanes + 30){1'b0}}})
  ) u_sync_vcfg (
    .clk_i  (lp_clk_i),
    .rst_ni (lrst_n),
    .d_i    ({cfg_des_rst_en, cfg_clk_cont, enable_i, enable_clk_i, cfg_settle, cfg_lp_filter,
              cfg_clk_settle, cfg_clk_miss}),
    .q_o    ({des_rst_en, clk_force, lane_en, settle, lp_filter, clk_settle, clk_miss})
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
    .des_rst_en_i (des_rst_en),
    .lp_i        (afe_clk_lp_i),
    .lp_o        (lp_st[0]),
    .hs_en_o     (hs_en[0]),
    .hs_active_o (hs_act[0]),
    .ce_o        (byte_ce),
    .des_rst_o   (des_rst),
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
      .des_rst_en_i (1'b0),
      .lp_i        (afe_lp_i[l]),
      .lp_o        (lp_st[1 + l]),
      .hs_en_o     (hs_en[1 + l]),
      .hs_active_o (hs_act[1 + l]),
      .ce_o        (),
      .des_rst_o   (),
      .ev_hs_o     (ev_hs[1 + l]),
      .ev_err_o    (ev_lp_err[1 + l]),
      .stop_o      (stop[1 + l])
    );
  end

  // AFE controls of the state machines: flops, no logic after them. v1: the HS receiver and
  // the termination of a lane switch together (one flop drives both ports; HSRX_EARLY and
  // CLK_MISS_OFF of step 6 separate them).
  assign afe_clk_gate_en_o = byte_ce;
  assign afe_des_rst_o     = des_rst;
  assign afe_clk_hsrx_en_o = hs_en[0];
  assign afe_clk_term_en_o = hs_en[0];
  assign afe_hsrx_en_o     = hs_en[Lanes:1];
  assign afe_term_en_o     = hs_en[Lanes:1];

  // AFE controls of the register file (bus clock flops): one flop for every lane in v1
  assign afe_clk_lprx_en_o = lprx_en;
  assign afe_lprx_en_o     = {Lanes{lprx_en}};
  assign afe_clk_lane_pd_o = lane_pd;
  assign afe_lane_pd_o     = {Lanes{lane_pd}};

  // Optional AFE signals and test hooks, tied off in v1: the clock lane delay (DLY_CLK,
  // INFO[22] = 0), the monitor sampler (v3), the trim bits (AFE_TRIM0/1, with an AFE that
  // defines them), the loopback / DC test modes and the analog test bus
  assign afe_clk_dly_code_o = '0;
  assign afe_clk_dly_own_o  = 1'b0;
  assign afe_mon_en_o       = '0;
  assign afe_mon_code_o     = '0;
  assign afe_trim_o         = '0;
  assign afe_tst_mode_o     = '0;
  assign afe_tst_data_o     = '0;
  assign afe_atb_sel_o      = '0;

  logic unused_afe;
  assign unused_afe = ^{afe_clk_hs_samp_i, afe_clk_act_i, afe_clk_dly_q_i, afe_mon_data_i,
                        afe_clk_hs_raw_i, afe_hs_raw_i};

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

  always_ff @(posedge afe_hs_byte_clk_i or negedge brst_n) begin
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

  // AFE status -> bus
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
    .d_i (afe_ready_i),
    .q_o (phy_rdy_sys)
  );

  bow_sync_bus #(
    .Width (8)
  ) u_sync_phy_st (
    .clk_i,
    .rst_ni,
    .d_i (afe_status_i),
    .q_o (phy_status_sys)
  );

  bow_sync_bus #(
    .Width (2)
  ) u_sync_cal (
    .clk_i,
    .rst_ni,
    .d_i ({afe_cal_err_i, afe_cal_done_i}),
    .q_o ({cal_err_sys, cal_done_sys})
  );

  // =========================================================================
  // Byte domain: word flops, sync search and byte alignment
  // =========================================================================
  logic [Lanes-1:0][7:0] rx_q, al_data;
  logic [Lanes-1:0]      rxv_q, arm, al_valid, al_sot, al_sync_err, al_deskew;

  always_ff @(posedge afe_hs_byte_clk_i or negedge brst_n) begin
    if (!brst_n) begin
      rx_q  <= '0;
      rxv_q <= '0;
    end else begin
      rx_q  <= afe_hs_data_i;
      rxv_q <= afe_hs_valid_i;
    end
  end

  bow_sync_bus #(
    .Width (Lanes)
  ) u_sync_arm (
    .clk_i  (afe_hs_byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (hs_act[Lanes:1]),
    .q_o    (arm)
  );

  for (genvar l = 0; l < Lanes; l++) begin : g_align
    bow_dphy_align u_align (
      .clk_i         (afe_hs_byte_clk_i),
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
  assign rx_byte_clk_hs_o = afe_hs_byte_clk_i;

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
    .clk_i  (afe_hs_byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (raw_req_sys),
    .q_o    (raw_req)
  );

  bow_sync u_sync_raw_now (
    .clk_i  (afe_hs_byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (raw_now_sys),
    .q_o    (raw_now)
  );

  bow_dphy_raw #(
    .Lanes (Lanes)
  ) u_raw (
    .clk_i       (afe_hs_byte_clk_i),
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
  // AFE delays: the codes and OWN are static levels of the register file (afe_dly_code_o,
  // afe_dly_own_o); the delay in use comes back bit by bit (quasi-static: software reads it
  // until two reads agree)
  // =========================================================================
  bow_sync_bus #(
    .Width (9 * Lanes)
  ) u_sync_tap_out (
    .clk_i,
    .rst_ni,
    .d_i (afe_dly_q_i),
    .q_o (dly_sys)
  );

  // =========================================================================
  // Byte domain: byte clock meter (free running gray counter)
  // =========================================================================
  logic [19:0] meter_q, meter_gray_q;

  always_ff @(posedge afe_hs_byte_clk_i or negedge brst_n) begin
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
