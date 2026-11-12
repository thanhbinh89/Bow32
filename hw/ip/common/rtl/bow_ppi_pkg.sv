// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 PPI (PHY Protocol Interface): the receive side signals between the digital D-PHY
// (bow_dphy_rx) and the CSI-2 controller (bow_csi2rx), with the names of the public PPI in
// snake case, 8 bits per lane (docs/ip/mipi_rx_arch.md, section 5; this is v1.x since step 6
// of the migration plan, v1 in steps 2 to 5). Shared by both blocks, so it lives in common.f:
// the controller does not need the D-PHY's sources for its types.
//
//   ppi_hs_t      byte domain, one per data lane. Clock: RxByteClkHS (rx_byte_clk_hs), one
//                 byte clock for all lanes, stopped while the clock lane is not in HS.
//   ppi_lp_t      lp domain (the D-PHY's lp_clk), one per data lane.
//   ppi_lp_clk_t  lp domain, the clock lane.
// The controller drives Enable[l] / EnableClk (enable, enable_clk: plain bits from any
// domain, the D-PHY synchronises them). Bow32 deviations from the public PPI: section 5.3.
//
// v1.x (step 6):
//   * ErrControl, ErrControlClk, ErrEsc and ErrSyncEsc are 2 bit gray counters of the PHY's lp
//     clock (section 4.11): every error steps the counter (00 01 11 10 00 ...), at most one
//     step every 16 lp cycles (errors closer together are merged into one step; the D-PHY's
//     registers count them all), 0 after reset. The controller samples them in its own clock
//     (bow_ppi_err_rx) and takes every change as at least one error: its clock must be at
//     least lp_clk / 32 (bow_csi2rx: PpiLpClkHz, no default, checked at elaboration). v1
//     (steps 2 to 5): one cycle pulses on bit 0, bit 1 0, the controller on the lp clock.
//   * RxClkActiveHS is the byte clock gate (hs_active of the clock lane state machine): with
//     CLK_CONT (continuous clock) it is 1 whenever the clock lane is enabled, also in Stop
//     together with StopstateClk, so a stop sequence must not wait for it to fall in that
//     mode (section 5.3).
//   * RxSkewCalHS is a level from the recognition of a deskew burst until RxActiveHS falls
//     (v1: a one cycle pulse); the controller counts its rising edge. ErrSotSyncHS comes at
//     the end of the burst (v2: when the HS-zero ends).
//   * ULPS (CTRL.ULPS_EN of the D-PHY): UlpsActiveNot / UlpsActiveNotClk 0 from the ULPS
//     command until the lane is in Stop again, RxUlpsEsc 1 / RxUlpsClkNot 0 from the command
//     until the wake-up mark (LP-10).
//   * Functions that do not exist yet hold their idle values: ErrSotHS = 0 (v2), ErrSyncEsc
//     = 0 (no LPDT).
//   * Not in v1.x: PhyReady (the AFE ready: a register of the D-PHY), the escape mode data
//     and triggers (RxLPDTEsc, RxDataEsc, RxValidEsc, RxClkEsc, RxTriggerEsc: later).

package bow_ppi_pkg;

  // RxDataHS bits per lane (v1: 8; 16 is a v2 option, section 5)
  localparam int unsigned PpiW = 8;

  // Byte domain (RxByteClkHS), one per data lane
  typedef struct packed {
    logic            rx_active_hs;     // RxActiveHS: from the end of SETTLE (sync search)
                                       // until LP-11 was seen, + 2 byte clocks
    logic            rx_valid_hs;      // RxValidHS: rx_data_hs holds a byte; no backpressure,
                                       // gaps are possible inside a burst
    logic [PpiW-1:0] rx_data_hs;       // RxDataHS: aligned byte, bit 0 = first bit on the wire
    logic            rx_sync_hs;       // RxSyncHS: with the first byte after the sync byte
    logic            rx_skew_cal_hs;   // RxSkewCalHS: deskew burst recognised (v1.x: level until
                                       // RxActiveHS falls; v1: pulse)
    logic            err_sot_hs;       // ErrSotHS: sync with a 1 bit error accepted (v2; v1: 0)
    logic            err_sot_sync_hs;  // ErrSotSyncHS: pulse, the burst had no sync (v1: at
                                       // its end)
  } ppi_hs_t;

  // lp domain, one per data lane
  typedef struct packed {
    logic       stopstate;        // Stopstate: the lane is in Stop (LP-11)
    logic       ulps_active_not;  // UlpsActiveNot: active low, 0 = lane in ULPS (v1: 1)
    logic       rx_ulps_esc;      // RxUlpsEsc: ULPS command received, until wake-up (v1: 0)
    logic [1:0] err_control;      // ErrControl: wrong LP sequence, HS watchdog, CLK_LOST: gray
                                  // counter (v1: one cycle pulse on [0])
    logic [1:0] err_esc;          // ErrEsc: escape command other than ULPS, ESC_TMO: gray
                                  // counter (v1: 0)
    logic [1:0] err_sync_esc;     // ErrSyncEsc: LPDT not byte aligned (no LPDT: 0)
  } ppi_lp_t;

  // lp domain, the clock lane
  typedef struct packed {
    logic       stopstate;         // StopstateClk: the clock lane is in Stop (LP-11)
    logic       rx_clk_active_hs;  // RxClkActiveHS: the byte clock gate is open (clock lane in
                                   // HS; with CLK_CONT: whenever enabled, also in Stop)
    logic       ulps_active_not;   // UlpsActiveNotClk: active low (v1: 1)
    logic       rx_ulps_clk_not;   // RxUlpsClkNot: active low, clock lane ULPS (v1: 1)
    logic [1:0] err_control;       // ErrControlClk (Bow32): wrong LP sequence of the clock
                                   // lane: gray counter (v1: one cycle pulse on [0])
  } ppi_lp_clk_t;

endpackage
