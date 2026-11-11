// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 PPI (PHY Protocol Interface): the receive side signals between the digital D-PHY
// (bow_dphy_rx) and the CSI-2 controller (bow_csi2rx), with the names of the public PPI in
// snake case, 8 bits per lane (docs/ip/mipi_rx_arch.md, section 5; this is v1, migration
// steps 2 to 5).
//
//   ppi_hs_t      byte domain, one per data lane. Clock: RxByteClkHS (rx_byte_clk_hs), one
//                 byte clock for all lanes, stopped while the clock lane is not in HS.
//   ppi_lp_t      lp domain (the D-PHY's lp_clk), one per data lane.
//   ppi_lp_clk_t  lp domain, the clock lane.
// The controller drives Enable[l] / EnableClk (enable, enable_clk: plain bits from any
// domain, the D-PHY synchronises them). Bow32 deviations from the public PPI: section 5.3.
//
// v1:
//   * ErrControl and ErrControlClk are 2 bits wide (v1.x: 2 bit gray counters of the lp
//     domain, section 4.11). In v1 they are one cycle pulses on bit 0, bit 1 is 0: valid only
//     for a controller that runs on the D-PHY's lp clock itself (FPGA: lp_clk = vid_clk,
//     bow_csi2rx checks it at elaboration).
//   * RxSkewCalHS is a one cycle pulse when the deskew burst is recognised (v1.x: a level
//     until the end of the burst); ErrSotSyncHS comes at the end of the burst (v2: when the
//     HS-zero ends).
//   * Functions that do not exist yet hold their idle values: ErrSotHS = 0 (v2),
//     UlpsActiveNot = UlpsActiveNotClk = RxUlpsClkNot = 1 (active low), RxUlpsEsc = 0,
//     ErrEsc = ErrSyncEsc = 0 (ULPS and escape: v1.x).
//   * Not in v1: PhyReady (the AFE ready in the lp domain: steps 4 and 5), the escape mode
//     data and triggers (RxLPDTEsc, RxDataEsc, RxValidEsc, RxClkEsc, RxTriggerEsc: later).

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
    logic            rx_skew_cal_hs;   // RxSkewCalHS: deskew burst recognised (v1: pulse)
    logic            err_sot_hs;       // ErrSotHS: sync with a 1 bit error accepted (v2; v1: 0)
    logic            err_sot_sync_hs;  // ErrSotSyncHS: pulse, the burst had no sync (v1: at
                                       // its end)
  } ppi_hs_t;

  // lp domain, one per data lane
  typedef struct packed {
    logic       stopstate;        // Stopstate: the lane is in Stop (LP-11)
    logic       ulps_active_not;  // UlpsActiveNot: active low, 0 = lane in ULPS (v1: 1)
    logic       rx_ulps_esc;      // RxUlpsEsc: ULPS command received (v1: 0)
    logic [1:0] err_control;      // ErrControl: wrong LP sequence or HS watchdog (v1: one
                                  // cycle pulse on [0])
    logic [1:0] err_esc;          // ErrEsc: unknown escape command (v1: 0)
    logic [1:0] err_sync_esc;     // ErrSyncEsc: LPDT not byte aligned (v1: 0)
  } ppi_lp_t;

  // lp domain, the clock lane
  typedef struct packed {
    logic       stopstate;         // StopstateClk: the clock lane is in Stop (LP-11)
    logic       rx_clk_active_hs;  // RxClkActiveHS: clock lane in HS with the byte clock gate
                                   // open (always while enabled with a continuous clock)
    logic       ulps_active_not;   // UlpsActiveNotClk: active low (v1: 1)
    logic       rx_ulps_clk_not;   // RxUlpsClkNot: active low, clock lane ULPS (v1: 1)
    logic [1:0] err_control;       // ErrControlClk (Bow32): wrong LP sequence of the clock
                                   // lane (v1: one cycle pulse on [0])
  } ppi_lp_clk_t;

endpackage
