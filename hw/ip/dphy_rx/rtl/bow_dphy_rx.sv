// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI D-PHY receiver, digital part (docs/ip/dphy_rx.md; docs/ip/mipi_rx_arch.md,
// section 4). Split out of the CSI-2 receiver in steps 1 and 2 of the migration plan
// (section 10); since step 4 it has its own registers (bow_dphy_rx_regs, the D-PHY window
// at 0xC00 of CSI2RX), its own resets and the RAW capture (bow_dphy_raw), and speaks only
// the PPI of bow_ppi_pkg with the CSI-2 controller (bow_csi2rx); since step 5 it speaks the
// AFE interface of section 3.2 with the analog part below it (an ASIC macro, or an FPGA
// adapter: bow_dphy_io_xusp, bow_dphy_io_versal); since step 6 it has the v1.x functions
// of section 4.12 (T_INIT, HS_TMO, ESC_TMO, HSRX_EARLY, CLK_MISS_OFF, CLK_TOG_DIV, ULPS,
// CLK_LOST, LATE_EOT, RxSkewCalHS as a level, the lp errors of the PPI as gray counters,
// the configuration through shadow registers and CMD.APPLY, the lp events to the bus as
// gray counters).
//
//   afe_clk_lp_i, afe_lp_i --> bow_dphy_lp x (1 + Lanes) --> afe_*hsrx_en_o, afe_*term_en_o,
//      (lp domain)               | hs_active                 afe_clk_gate_en_o, afe_des_rst_o
//                                | clk_tog (byte clock edges / 2^CLK_TOG_DIV)
//   afe_hs_data_i, afe_hs_valid_i --> word flops --> bow_dphy_align x Lanes --> ppi_hs_o
//                                          +--> bow_dphy_raw (RAW capture)    (byte domain)
//   LP state machines --> ppi_lp_o, ppi_lp_clk_o (lp domain: levels, gray error counters)
//   bus <--> bow_dphy_rx_regs (u_regs): CTRL / TIM0..2 (shadow, CMD.APPLY), CMD, AFE_CTRL,
//            AFE_STATUS, LANE_LP / LANE_HS / LANE_STOP, counters, BYTECLK, DLYn, RAW,
//            IRQ / ERR --> irq_o; AFE controls (afe_dly_code_o / afe_dly_own_o, afe_pd_o,
//            afe_lprx_en_o, afe_lane_pd_o, afe_cal_start_o)
//
// Contents (instance and register names of steps 1 and 2 kept: the FPGA constraints select
// them by name):
//   * the configuration of the lp domain (cfg_lp_q): CTRL and TIM0..2 of the register file
//     are shadow registers in the bus domain; CMD.APPLY toggles apply_req, which crosses
//     through one synchroniser (u_sync_apply), and the lp domain then copies the whole
//     shadow in one cycle (and once after its reset) and acknowledges (u_sync_apply_ack).
//     The software writes no shadow register while an APPLY is pending (CMD reads 1);
//   * the PPI enables (u_sync_vcfg, any domain, quasi-static);
//   * the LP state machines (u_lp_clk, g_lp[l].u_lp); CMD.REINIT (u_cdc_reinit) and the
//     AFE's ready rising (u_cdc_rdyup) make T_INIT due again, REINIT (and ready with
//     T_INIT != 0) also sends the lanes back to WaitStop;
//   * CLK_LOST (CTRL.CLK_LOST_EN): a data lane starts its sync search while the clock lane
//     is not in HS; LATE_EOT: the byte clock gate closed while RxActiveHS of a lane was
//     still high in the byte domain (arm_q, back to the lp domain through u_sync_eot): the
//     controller sees that burst end only when the byte clock runs again;
//   * the lp events towards the bus (HS entries and LP errors per lane, HS_TMO, escape
//     errors, ESC_TMO, CLK_LOST, LATE_EOT, ULPS entries and exits): a 4 bit gray counter per
//     kind (evc_gray_q, several lanes' events of one cycle added one step per cycle), read
//     by the register file through u_sync_evc, which adds the differences to its counters
//     (every event counted while lp_clk_i <= 12 x clk_i, BusClkHz);
//   * the LP / HS / gate / Stopstate / ULPS status towards the bus (u_sync_vst), the AFE's
//     ready, status and calibration result synchronisers;
//   * clock lane activity: a byte clock flop toggling every 2^CLK_TOG_DIV byte clock edges,
//     seen from the lp domain (clk_tog: clock miss detection of the clock lane state
//     machine; TIM1.CLK_TOG_DIV through u_sync_tdiv into the byte domain);
//   * the hs_data / hs_valid word flops, the hs_active synchroniser into the byte domain
//     (u_sync_arm) and the aligners (g_align[l].u_align);
//   * the delay readback synchroniser (u_sync_tap_out, AFE dly_q -> DLYn[24:16]);
//   * the byte clock meter (meter_gray_q, u_sync_meter);
//   * the RAW capture (u_raw, u_sync_raw_req, u_sync_raw_ack).
// What steps 1 to 4 had here for the FPGA PHY I/O went into the adapters in step 5
// (bow_dphy_dly_xusp, bow_dphy_dly_xphy): the input delay loads (both PHY kinds, the old
// DlyVid 0 / 1) and the ISERDES reset release on the byte clock; the D-PHY drives static
// delay codes and des_rst.
//
// PPI (bow_ppi_pkg, v1.x):
//   rx_byte_clk_hs_o  RxByteClkHS = afe_hs_byte_clk_i
//   ppi_hs_o[l]       RxActiveHS (hs_active of the lane, synchronised: arm), RxValidHS,
//                     RxDataHS, RxSyncHS, ErrSotSyncHS of the aligner; RxSkewCalHS: from the
//                     aligner's recognition of a deskew burst until RxActiveHS falls (a level,
//                     v1.x); ErrSotHS 0
//   ppi_lp_o[l]       Stopstate, UlpsActiveNot (low from the ULPS command until the wake-up
//                     mark), RxUlpsEsc (high from the command until LP-11 ends the wake-up);
//                     ErrControl (LP errors, HS_TMO and, with CTRL.CLK_LOST_EN, CLK_LOST of
//                     the lane) and ErrEsc (escape command other than ULPS, ESC_TMO): 2 bit
//                     gray counters (bow_ppi_err_tx), at most one step every 16 lp cycles,
//                     only while the lane's synchronised Enable is high; ErrSyncEsc 0
//   ppi_lp_clk_o      StopstateClk, RxClkActiveHS (the clock lane's hs_active: gate open),
//                     UlpsActiveNotClk, RxUlpsClkNot (as the data lanes' two), ErrControlClk:
//                     the clock lane's LP errors as a gray counter, none while CTRL.CLK_CONT
//                     (synchronised) = 1
//   enable_i[l], enable_clk_i  Enable[l], EnableClk (bus domain flops of the controller,
//                     synchronised here)
// The controller samples the gray counters in its own clock (bow_ppi_err_rx): its clock
// must be at least lp_clk / 32. The counters and ERR_STATUS / ERR_LANE of the registers
// count every error, unmasked.
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
//      afe_clk_hs_samp_i   optional, diagnostic: not used
//      afe_clk_act_i       optional for the FPGA adapters (none has it, AfeClkAct = 0), not
//                          used yet: the clock miss detection with it comes with step 10
//   B  afe_lp_i[l], afe_clk_lp_i       {P, N}, asynchronous: synchroniser + filter
//      afe_lprx_en_o, afe_clk_lprx_en_o  ~AFE_CTRL.PD, one bus clock flop for every lane
//   C  afe_hsrx_en_o, afe_clk_hsrx_en_o  lp flops of the state machines (hs_en_q): the HS
//                          receiver, from HS-Rqst with CTRL.HSRX_EARLY
//      afe_term_en_o, afe_clk_term_en_o  lp flops of the state machines (term_q): the
//                          termination; the clock lane's falls with the gate under
//                          CTRL.CLK_MISS_OFF (and the HS receiver with it)
//   D  afe_dly_code_o[l], afe_dly_own_o[l]  DLYn CODE and OWN: static levels from bus clock
//                          flops (u_regs; no load protocol here: the AFE applies a new code
//                          by itself, section 3.5); OWN falls with READY
//      afe_dly_q_i[l]      the delay in use, asynchronous: u_sync_tap_out -> DLYn[24:16]
//      afe_clk_dly_*       optional (clock lane delay, INFO[22] = 0): code 0, own 0, q unused
//      afe_mon_*           optional (monitor sampler, v3): en 0, code 0, data unused
//   E  afe_pd_o            AFE_CTRL.PD (bus clock flop, reset AfePdRst); never from Enable
//      afe_lane_pd_o, afe_clk_lane_pd_o  bus clock flops, one per lane: 1 from reset and
//                          while PD, 0 once a fresh READY was seen with PD = 0, i.e. READY 0
//                          since PD last rose, then 1 (not the stale READY of the synchroniser
//                          right after a short PD pulse); and 1 while the lane is in ULPS before
//                          its wake-up mark (state Ulps, synchronised)
//      afe_ready_i         asynchronous: AFE_STATUS.READY; OWN of every lane falls with it;
//                          its rise makes T_INIT due again
//      afe_cal_start_o     CMD.AFE_CAL, 32 bus clock cycles (CMD.REINIT up to step 5)
//      afe_cal_done_i, afe_cal_err_i  asynchronous: AFE_STATUS[1], [2]
//      afe_trim_o          0 (AFE_TRIM0/1 come with an AFE that defines the trim bits)
//      afe_status_i        asynchronous, quasi-static: AFE_STATUS[15:8]
//   F  afe_tst_mode_o, afe_tst_data_o, afe_atb_sel_o  test hooks: 0;
//      afe_hs_raw_i, afe_clk_hs_raw_i  not used (DFT and the loopback test come later)
//
// Clocks: clk_i (bus: registers, status synchronisers), lp_clk_i (LP state machines;
// bow_mipi_rx: vid_clk_i), afe_hs_byte_clk_i (the AFE's byte clock, runs only while
// afe_clk_gate_en_o = 1 and the clock lane toggles).
// Resets (section 4.11 of the spec), asynchronous assertion, synchronous release:
//   rst_ni                bus domain (registers, AFE controls, synchronisers towards the bus)
//   lrst_n (u_lrst)       lp domain, from rst_ni & lp_rst_ni: state machines, the applied
//                         configuration (reset values, then the shadow once), event counters
//   brst_n (u_brst)       byte domain, from rst_ni & lp_rst_ni, released by the first byte
//                         clocks: word flops, aligners (not reset while the controller's RX
//                         is off: a burst cut by a stop ends there as any burst), clock
//                         toggle, meter, RAW
// The lp domain is reset together with the bus domain (rst_ni resets both): a reset of the
// lp domain alone can add up to 15 counts to the counters of the registers and a change to
// the PPI error counters.
// At reset (section 3.6): afe_pd_o = AfePdRst, afe_lprx_en_o = ~AfePdRst, lane_pd 1, dly_own
// 0, codes 0, cal_start 0 (rst_ni: bus clock flops); hsrx / term 0, gate 0, des_rst 1 (the lp
// reset lrst_n, asserted with rst_ni).

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
  input  logic [7:0]                 afe_clk_hs_samp_i, // optional, not used
  input  logic                       afe_clk_act_i,     // optional, not used yet (step 10)
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
  output logic [Lanes-1:0]           afe_lane_pd_o,     // bus clock flops
  input  logic                       afe_ready_i,       // asynchronous
  output logic                       afe_cal_start_o,   // bus clock flop, 32 cycles
  input  logic                       afe_cal_done_i,    // asynchronous
  input  logic                       afe_cal_err_i,     // asynchronous
  output logic [TrimW-1:0]           afe_trim_o,        // 0
  input  logic [7:0]                 afe_status_i,      // asynchronous, quasi-static
  // F: test hooks (off)
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

  // The lp events reach the bus as 4 bit gray counters (one step per lp cycle at most) that
  // the register file reads every bus cycle: no event is lost while fewer than 16 steps
  // come between two reads, i.e. lp_clk_i <= 12 x clk_i with the synchronisers' skew (v1:
  // pulse synchronisers, lp_clk_i <= 16/3 x clk_i). The elaboration $fatal stops lint and
  // synthesis, the initial copy stops simulations whose build turns USERFATAL into a
  // warning (-Wno-fatal).
  if ((BusClkHz != 0) && (64'(LpClkHz) > 64'(BusClkHz) * 64'd12)) begin : g_bad_clk
    $fatal(1, "bow_dphy_rx: lp_clk_i %0d Hz > 12 x clk_i %0d Hz (the event counters lap)",
           LpClkHz, BusClkHz);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_dphy_rx: lp_clk_i %0d Hz > 12 x clk_i %0d Hz (the event counters lap)",
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
  // Configuration: the shadow of the register file (bus domain) and its copy in the lp
  // domain (CMD.APPLY)
  // =========================================================================
  typedef struct packed {
    logic        clk_cont;     // CTRL.CLK_CONT
    logic        des_rst_en;   // ~CTRL.DES_RST_DIS
    logic        ulps_en;      // CTRL.ULPS_EN
    logic        hsrx_early;   // CTRL.HSRX_EARLY
    logic        clk_lost_en;  // CTRL.CLK_LOST_EN
    logic        miss_off;     // CTRL.CLK_MISS_OFF
    logic [7:0]  settle;       // TIM0
    logic [3:0]  lp_filter;
    logic [7:0]  clk_settle;
    logic [7:0]  clk_miss;
    logic [23:0] hs_tmo;       // TIM1
    logic [3:0]  tog_div;
    logic [19:0] tinit;        // TIM2
    logic [11:0] esc_tmo;
  } cfg_t;

  // reset values (the registers' as well): v1 behaviour
  localparam cfg_t CfgReset = '{clk_cont: 1'b0, des_rst_en: 1'b1, ulps_en: 1'b0,
                                hsrx_early: 1'b0, clk_lost_en: 1'b0, miss_off: 1'b0,
                                settle: 8'd14, lp_filter: 4'd2, clk_settle: 8'd30,
                                clk_miss: 8'd8, hs_tmo: 24'h10_0000, tog_div: 4'd0,
                                tinit: 20'd0, esc_tmo: 12'd0};

  // the event counters towards the bus (see the header)
  localparam int unsigned EvcW   = 4;
  localparam int unsigned NumAgg = 7;     // HS_TMO, ESC, ESC_TMO, CLK_LOST, LATE_EOT, ULPS in, out
  localparam int unsigned AggTmo = 0, AggEsc = 1, AggEscTmo = 2, AggLost = 3, AggLate = 4,
                          AggUlps = 5, AggWake = 6;
  localparam int unsigned NumEvc = 2 * (Lanes + 1) + NumAgg;

  cfg_t                  cfg_sys;
  logic                  apply_req_sys, apply_ack_sys, reinit_sys, rdy_up_sys;
  logic [Lanes-1:0][8:0] dly_sys;
  logic                  lprx_en;
  logic [Lanes:0]        lane_pd;
  logic [3:0]            raw_req_sys, raw_ack, raw_ack_sys;
  logic                  raw_now_sys, raw_re;
  logic [5:0]            raw_addr;
  logic [8*Lanes-1:0]    raw_rdata;
  logic [NumEvc-1:0][EvcW-1:0] evc_sys;
  logic [Lanes:0][1:0]   lp_sys;
  logic [Lanes:0]        hs_en_sys, stop_sys, ulps_sys, ulps_act_sys;
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
    .AfePdRst    (AfePdRst),
    .EvcW        (EvcW),
    .NumAgg      (NumAgg)
  ) u_regs (
    .clk_i,
    .rst_ni,
    .bus_req_i,
    .bus_rsp_o,
    .irq_o,
    .clk_cont_o     (cfg_sys.clk_cont),
    .des_rst_en_o   (cfg_sys.des_rst_en),
    .ulps_en_o      (cfg_sys.ulps_en),
    .hsrx_early_o   (cfg_sys.hsrx_early),
    .clk_lost_en_o  (cfg_sys.clk_lost_en),
    .miss_off_o     (cfg_sys.miss_off),
    .settle_o       (cfg_sys.settle),
    .lp_filter_o    (cfg_sys.lp_filter),
    .clk_settle_o   (cfg_sys.clk_settle),
    .clk_miss_o     (cfg_sys.clk_miss),
    .hs_tmo_o       (cfg_sys.hs_tmo),
    .tog_div_o      (cfg_sys.tog_div),
    .tinit_o        (cfg_sys.tinit),
    .esc_tmo_o      (cfg_sys.esc_tmo),
    .apply_req_o    (apply_req_sys),
    .apply_ack_i    (apply_ack_sys),
    .reinit_o       (reinit_sys),
    .rdy_up_o       (rdy_up_sys),
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
    .evc_hs_i       (evc_sys[Lanes:0]),
    .evc_err_i      (evc_sys[2*Lanes+1 -: Lanes + 1]),
    .evc_agg_i      (evc_sys[NumEvc-1 -: NumAgg]),
    .lp_i           (lp_sys),
    .hs_en_i        (hs_en_sys),
    .ce_i           (ce_sys),
    .stop_i         (stop_sys),
    .ulps_i         (ulps_sys),
    .ulps_act_i     (ulps_act_sys),
    .ready_i        (phy_rdy_sys),
    .cal_done_i     (cal_done_sys),
    .cal_err_i      (cal_err_sys),
    .afe_status_i   (phy_status_sys),
    .meter_i        (meter_sys),
    .dly_q_i        (dly_sys)
  );

  // lp domain: the shadow is copied when the synchronised APPLY toggle changes, and once
  // after the lp reset (the configuration of the registers then, normally their reset
  // values); the copy is acknowledged by apply_seen_q. The shadow stays stable from the
  // APPLY until the acknowledge (the driver's rule, CMD.APPLY reads 1 meanwhile).
  cfg_t cfg_lp_q;
  logic apply_s, apply_seen_q, apply_first_q, apply_take;

  bow_sync u_sync_apply (
    .clk_i  (lp_clk_i),
    .rst_ni (lrst_n),
    .d_i    (apply_req_sys),
    .q_o    (apply_s)
  );

  assign apply_take = apply_first_q || (apply_s != apply_seen_q);

  always_ff @(posedge lp_clk_i or negedge lrst_n) begin
    if (!lrst_n) begin
      apply_seen_q  <= 1'b0;
      apply_first_q <= 1'b1;
      cfg_lp_q      <= CfgReset;
    end else begin
      apply_seen_q  <= apply_s;
      apply_first_q <= 1'b0;
      if (apply_take) cfg_lp_q <= cfg_sys;
    end
  end

  bow_sync u_sync_apply_ack (
    .clk_i,
    .rst_ni,
    .d_i (apply_seen_q),
    .q_o (apply_ack_sys)
  );

  // CMD.REINIT and the AFE's ready rising (bus domain pulses)
  logic reinit_lp, rdy_up_lp, tinit_set, force_wait;

  bow_cdc_pulse u_cdc_reinit (
    .src_clk_i   (clk_i),
    .src_rst_ni  (rst_ni),
    .src_pulse_i (reinit_sys),
    .dst_clk_i   (lp_clk_i),
    .dst_rst_ni  (lrst_n),
    .dst_pulse_o (reinit_lp)
  );

  bow_cdc_pulse u_cdc_rdyup (
    .src_clk_i   (clk_i),
    .src_rst_ni  (rst_ni),
    .src_pulse_i (rdy_up_sys),
    .dst_clk_i   (lp_clk_i),
    .dst_rst_ni  (lrst_n),
    .dst_pulse_o (rdy_up_lp)
  );

  assign tinit_set  = reinit_lp || rdy_up_lp;
  assign force_wait = reinit_lp || (rdy_up_lp && (cfg_lp_q.tinit != 20'd0));

  // =========================================================================
  // lp domain: LP state machines
  // =========================================================================
  logic [Lanes:0]      lane_en, hs_en, term_en, hs_act, ev_hs, ev_lp_err, stop;
  logic [Lanes:0]      ev_tmo, ev_esc, ev_esc_tmo, ev_ulps, ev_wake, ulps, ulps_act;
  logic [Lanes:0][1:0] lp_st;
  logic                clk_force, clk_edge, byte_ce, des_rst, des_rst_en;

  assign clk_force  = cfg_lp_q.clk_cont;
  assign des_rst_en = cfg_lp_q.des_rst_en;

  // the PPI enables in the bit order of step 1: [0] clock lane, [1 + l] data lane l
  bow_sync_bus #(
    .Width (Lanes + 1)
  ) u_sync_vcfg (
    .clk_i  (lp_clk_i),
    .rst_ni (lrst_n),
    .d_i    ({enable_i, enable_clk_i}),
    .q_o    (lane_en)
  );

  bow_dphy_lp #(
    .ClockLane (1'b1)
  ) u_lp_clk (
    .clk_i        (lp_clk_i),
    .rst_ni       (lrst_n),
    .en_i         (lane_en[0]),
    .force_hs_i   (clk_force),
    .settle_i     (cfg_lp_q.clk_settle),
    .filter_i     (cfg_lp_q.lp_filter),
    .miss_i       (cfg_lp_q.clk_miss),
    .clk_edge_i   (clk_edge),
    .des_rst_en_i (des_rst_en),
    .hsrx_early_i (cfg_lp_q.hsrx_early),
    .miss_off_i   (cfg_lp_q.miss_off),
    .ulps_en_i    (cfg_lp_q.ulps_en),
    .hs_tmo_i     (cfg_lp_q.hs_tmo),
    .esc_tmo_i    (cfg_lp_q.esc_tmo),
    .tinit_i      (cfg_lp_q.tinit),
    .tinit_set_i  (tinit_set),
    .force_wait_i (force_wait),
    .lp_i         (afe_clk_lp_i),
    .lp_o         (lp_st[0]),
    .hs_en_o      (hs_en[0]),
    .term_en_o    (term_en[0]),
    .hs_active_o  (hs_act[0]),
    .ce_o         (byte_ce),
    .des_rst_o    (des_rst),
    .ev_hs_o      (ev_hs[0]),
    .ev_err_o     (ev_lp_err[0]),
    .ev_tmo_o     (ev_tmo[0]),
    .ev_esc_o     (ev_esc[0]),
    .ev_esc_tmo_o (ev_esc_tmo[0]),
    .ev_ulps_o    (ev_ulps[0]),
    .ev_wake_o    (ev_wake[0]),
    .stop_o       (stop[0]),
    .ulps_o       (ulps[0]),
    .ulps_act_o   (ulps_act[0])
  );

  for (genvar l = 0; l < Lanes; l++) begin : g_lp
    bow_dphy_lp #(
      .ClockLane (1'b0)
    ) u_lp (
      .clk_i        (lp_clk_i),
      .rst_ni       (lrst_n),
      .en_i         (lane_en[1 + l]),
      .force_hs_i   (1'b0),
      .settle_i     (cfg_lp_q.settle),
      .filter_i     (cfg_lp_q.lp_filter),
      .miss_i       (8'd0),
      .clk_edge_i   (1'b0),
      .des_rst_en_i (1'b0),
      .hsrx_early_i (cfg_lp_q.hsrx_early),
      .miss_off_i   (1'b0),
      .ulps_en_i    (cfg_lp_q.ulps_en),
      .hs_tmo_i     (cfg_lp_q.hs_tmo),
      .esc_tmo_i    (cfg_lp_q.esc_tmo),
      .tinit_i      (cfg_lp_q.tinit),
      .tinit_set_i  (tinit_set),
      .force_wait_i (force_wait),
      .lp_i         (afe_lp_i[l]),
      .lp_o         (lp_st[1 + l]),
      .hs_en_o      (hs_en[1 + l]),
      .term_en_o    (term_en[1 + l]),
      .hs_active_o  (hs_act[1 + l]),
      .ce_o         (),
      .des_rst_o    (),
      .ev_hs_o      (ev_hs[1 + l]),
      .ev_err_o     (ev_lp_err[1 + l]),
      .ev_tmo_o     (ev_tmo[1 + l]),
      .ev_esc_o     (ev_esc[1 + l]),
      .ev_esc_tmo_o (ev_esc_tmo[1 + l]),
      .ev_ulps_o    (ev_ulps[1 + l]),
      .ev_wake_o    (ev_wake[1 + l]),
      .stop_o       (stop[1 + l]),
      .ulps_o       (ulps[1 + l]),
      .ulps_act_o   (ulps_act[1 + l])
    );
  end

  // AFE controls of the state machines: flops, no logic after them
  assign afe_clk_gate_en_o = byte_ce;
  assign afe_des_rst_o     = des_rst;
  assign afe_clk_hsrx_en_o = hs_en[0];
  assign afe_clk_term_en_o = term_en[0];
  assign afe_hsrx_en_o     = hs_en[Lanes:1];
  assign afe_term_en_o     = term_en[Lanes:1];

  // AFE controls of the register file (bus clock flops): lprx_en one flop for every lane,
  // lane_pd one per lane ([0] clock lane)
  assign afe_clk_lprx_en_o = lprx_en;
  assign afe_lprx_en_o     = {Lanes{lprx_en}};
  assign afe_clk_lane_pd_o = lane_pd[0];
  assign afe_lane_pd_o     = lane_pd[Lanes:1];

  // Optional AFE signals and test hooks, tied off: the clock lane delay (DLY_CLK,
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

  // CLK_LOST (CTRL.CLK_LOST_EN): a data lane starts its sync search (enters Hs) while the
  // clock lane is not in HS (gate closed; with CLK_CONT it is open while enabled)
  logic [Lanes-1:0] act_last_q, clk_lost;

  always_ff @(posedge lp_clk_i or negedge lrst_n) begin
    if (!lrst_n) act_last_q <= '0;
    else         act_last_q <= hs_act[Lanes:1];
  end

  for (genvar l = 0; l < Lanes; l++) begin : g_lost
    assign clk_lost[l] = cfg_lp_q.clk_lost_en && hs_act[1 + l] && !act_last_q[l] &&
                         !hs_act[0] && lane_en[1 + l];
  end

  // LATE_EOT: the gate closed (not by Enable or CMD.REINIT: the transmitter's clock stopped)
  // while RxActiveHS of a data lane was still high in the byte domain: arm_q (the value the
  // controller took at the last byte clock edge) back in the lp domain three cycles after
  // the close, once per burst end (late_done_q until arm_q is seen low again). The gate
  // closes after the clock stopped (clock miss, LP-11 backstop), so arm_q no longer changes
  // then.
  logic [Lanes-1:0] arm_q, arm_lp, late, late_done_q;
  logic             ce_last_q, force_q;
  logic [2:0]       close_q;

  bow_sync_bus #(
    .Width (Lanes)
  ) u_sync_eot (
    .clk_i  (lp_clk_i),
    .rst_ni (lrst_n),
    .d_i    (arm_q),
    .q_o    (arm_lp)
  );

  always_ff @(posedge lp_clk_i or negedge lrst_n) begin
    if (!lrst_n) begin
      ce_last_q   <= 1'b0;
      force_q     <= 1'b0;
      close_q     <= '0;
      late_done_q <= '0;
    end else begin
      ce_last_q   <= byte_ce;
      force_q     <= force_wait;
      close_q     <= {close_q[1:0], ce_last_q && !byte_ce && lane_en[0] && !force_q};
      late_done_q <= late | (late_done_q & arm_lp);
    end
  end

  assign late = {Lanes{close_q[2]}} & arm_lp & ~late_done_q & lane_en[Lanes:1];

  // PPI, lp domain: levels of the state machines; the errors as 2 bit gray counters
  // (bow_ppi_err_tx): ErrControl[l] (LP errors, HS_TMO, CLK_LOST) and ErrEsc[l] (escape
  // command, ESC_TMO) only while the lane's synchronised Enable is high, ErrControlClk
  // never while CTRL.CLK_CONT (the byte clock is not gated by the clock lane then)
  logic [Lanes-1:0][1:0] err_ctl_gray, err_esc_gray;
  logic [0:0][1:0]       err_clk_gray;

  bow_ppi_err_tx #(
    .N (Lanes)
  ) u_ppi_err_ctl (
    .clk_i  (lp_clk_i),
    .rst_ni (lrst_n),
    .ev_i   (ev_lp_err[Lanes:1] | clk_lost),
    .en_i   (lane_en[Lanes:1]),
    .gray_o (err_ctl_gray)
  );

  bow_ppi_err_tx #(
    .N (1)
  ) u_ppi_err_clk (
    .clk_i  (lp_clk_i),
    .rst_ni (lrst_n),
    .ev_i   (ev_lp_err[0]),
    .en_i   (!clk_force),
    .gray_o (err_clk_gray)
  );

  bow_ppi_err_tx #(
    .N (Lanes)
  ) u_ppi_err_esc (
    .clk_i  (lp_clk_i),
    .rst_ni (lrst_n),
    .ev_i   (ev_esc[Lanes:1] | ev_esc_tmo[Lanes:1]),
    .en_i   (lane_en[Lanes:1]),
    .gray_o (err_esc_gray)
  );

  for (genvar l = 0; l < Lanes; l++) begin : g_ppi_lp
    assign ppi_lp_o[l].stopstate       = stop[1 + l];
    assign ppi_lp_o[l].ulps_active_not = !ulps_act[1 + l];
    assign ppi_lp_o[l].rx_ulps_esc     = ulps[1 + l];
    assign ppi_lp_o[l].err_control     = err_ctl_gray[l];
    assign ppi_lp_o[l].err_esc         = err_esc_gray[l];
    assign ppi_lp_o[l].err_sync_esc    = 2'b00;
  end

  assign ppi_lp_clk_o.stopstate        = stop[0];
  assign ppi_lp_clk_o.rx_clk_active_hs = hs_act[0];
  assign ppi_lp_clk_o.ulps_active_not  = !ulps_act[0];
  assign ppi_lp_clk_o.rx_ulps_clk_not  = !ulps[0];
  assign ppi_lp_clk_o.err_control      = err_clk_gray[0];

  // LP events -> bus: a 4 bit gray counter per kind ([0] clock lane, [1 + l] data lane l):
  // HS entries and LP errors per lane state machine, and the kinds of several lanes, whose
  // events of one cycle are added and step the counter once per cycle (agg_pend_q)
  function automatic logic [EvcW-1:0] gray_inc(logic [EvcW-1:0] g);
    logic [EvcW-1:0] b;
    b[EvcW-1] = g[EvcW-1];
    for (int i = EvcW - 2; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
    b = b + 1'b1;
    return b ^ (b >> 1);
  endfunction

  function automatic logic [2:0] count1(logic [Lanes:0] v);
    logic [2:0] n;
    n = '0;
    for (int unsigned i = 0; i <= Lanes; i++) n = n + 3'(v[i]);
    return n;
  endfunction

  logic [NumAgg-1:0][Lanes:0] agg_ev;
  logic [NumAgg-1:0][3:0]     agg_pend_q;
  logic [NumAgg-1:0][4:0]     agg_sum;
  logic [NumAgg-1:0]          agg_step;
  logic [NumEvc-1:0][EvcW-1:0] evc_gray_q;
  logic [NumEvc-1:0]          evc_step;

  always_comb begin
    agg_ev            = '0;
    agg_ev[AggTmo]    = ev_tmo;
    agg_ev[AggEsc]    = ev_esc;
    agg_ev[AggEscTmo] = ev_esc_tmo;
    agg_ev[AggLost]   = {clk_lost, 1'b0};
    agg_ev[AggLate]   = {late, 1'b0};
    agg_ev[AggUlps]   = ev_ulps;
    agg_ev[AggWake]   = ev_wake;
    for (int unsigned k = 0; k < NumAgg; k++) begin
      agg_sum[k]  = 5'(agg_pend_q[k]) + 5'(count1(agg_ev[k]));
      agg_step[k] = (agg_sum[k] != 5'd0);
    end
    evc_step = {agg_step, ev_lp_err, ev_hs};
  end

  always_ff @(posedge lp_clk_i or negedge lrst_n) begin
    if (!lrst_n) begin
      agg_pend_q <= '0;
      evc_gray_q <= '0;
    end else begin
      for (int unsigned k = 0; k < NumAgg; k++) begin
        // (saturating: more than 15 events waiting cannot happen with LP sequences)
        agg_pend_q[k] <= !agg_step[k] ? 4'd0 : (agg_sum[k] > 5'd16) ? 4'd15 : 4'(agg_sum[k] - 5'd1);
      end
      for (int unsigned i = 0; i < NumEvc; i++) begin
        if (evc_step[i]) evc_gray_q[i] <= gray_inc(evc_gray_q[i]);
      end
    end
  end

  bow_sync_bus #(
    .Width (EvcW * NumEvc)
  ) u_sync_evc (
    .clk_i,
    .rst_ni,
    .d_i (evc_gray_q),
    .q_o (evc_sys)
  );

  // Clock lane activity: a byte clock flop toggling every 2^CLK_TOG_DIV byte clock edges
  // (TIM1, v1.x; 0: every edge, as in v1), seen from the lp domain (clock miss detection of
  // the clock lane FSM). The byte clock itself only runs while the clock lane toggles.
  logic        clk_tog_q, clk_tog_s, clk_tog_last_q;
  logic [3:0]  tog_div;
  logic [14:0] tog_cnt_q, tog_lim;

  bow_sync_bus #(
    .Width (4)
  ) u_sync_tdiv (
    .clk_i  (afe_hs_byte_clk_i),
    .rst_ni (brst_n),
    .d_i    (cfg_lp_q.tog_div),
    .q_o    (tog_div)
  );

  assign tog_lim = 15'((16'd1 << tog_div) - 16'd1);

  always_ff @(posedge afe_hs_byte_clk_i or negedge brst_n) begin
    if (!brst_n) begin
      clk_tog_q <= 1'b0;
      tog_cnt_q <= '0;
    end else if (tog_cnt_q >= tog_lim) begin
      clk_tog_q <= ~clk_tog_q;
      tog_cnt_q <= '0;
    end else begin
      tog_cnt_q <= tog_cnt_q + 15'd1;
    end
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

  // Status -> bus: the lane states as lp flops (Stopstate, ULPS: decodes of the state
  // registers) and the HS / gate / LP flops of the state machines
  logic [Lanes:0] stop_q, ulps_q, ulps_act_q;

  always_ff @(posedge lp_clk_i or negedge lrst_n) begin
    if (!lrst_n) begin
      stop_q     <= '0;
      ulps_q     <= '0;
      ulps_act_q <= '0;
    end else begin
      stop_q     <= stop;
      ulps_q     <= ulps;
      ulps_act_q <= ulps_act;
    end
  end

  bow_sync_bus #(
    .Width      (6 * Lanes + 7),
    .ResetValue ({{(4 * Lanes + 5){1'b0}}, {(2 * Lanes + 2){1'b1}}})   // LP-11
  ) u_sync_vst (
    .clk_i,
    .rst_ni,
    .d_i ({ulps_act_q, ulps_q, stop_q, byte_ce, hs_en, lp_st}),
    .q_o ({ulps_act_sys, ulps_sys, stop_sys, ce_sys, hs_en_sys, lp_sys})
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
  logic [Lanes-1:0]      rxv_q, arm, al_valid, al_sot, al_sync_err, al_deskew, dsk_lvl_q;

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

  // RxSkewCalHS (v1.x): a level from the aligner's deskew pulse until RxActiveHS falls
  // (dsk_lvl_q); arm_q: RxActiveHS one byte clock later, for LATE_EOT
  always_ff @(posedge afe_hs_byte_clk_i or negedge brst_n) begin
    if (!brst_n) begin
      dsk_lvl_q <= '0;
      arm_q     <= '0;
    end else begin
      dsk_lvl_q <= arm & (dsk_lvl_q | al_deskew);
      arm_q     <= arm;
    end
  end

  // PPI, byte domain
  assign rx_byte_clk_hs_o = afe_hs_byte_clk_i;

  for (genvar l = 0; l < Lanes; l++) begin : g_ppi_hs
    assign ppi_hs_o[l].rx_active_hs    = arm[l];
    assign ppi_hs_o[l].rx_valid_hs     = al_valid[l];
    assign ppi_hs_o[l].rx_data_hs      = al_data[l];
    assign ppi_hs_o[l].rx_sync_hs      = al_sot[l];
    assign ppi_hs_o[l].rx_skew_cal_hs  = al_deskew[l] | (dsk_lvl_q[l] & arm[l]);
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
