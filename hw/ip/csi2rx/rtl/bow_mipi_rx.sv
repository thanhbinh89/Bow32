// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI CSI-2 receiver (Bow32 wrapper): the digital D-PHY (bow_dphy_rx, u_dphy_rx) and
// the CSI-2 controller (bow_csi2rx, u_csi2rx), joined by the PPI of bow_ppi_pkg and a
// temporary band (step 2 of docs/ip/mipi_rx_arch.md, section 10). Its ports and parameters
// are those of bow_csi2rx up to step 1, register map unchanged (CSI2RX, bow_csi2rx_regs in
// the controller). The D-PHY I/O (LP / HS receivers, deserialisers, input delays) is
// outside, e.g. hw/fpga/common/rtl/bow_dphy_io_xusp.sv on the KV260 or
// hw/fpga/common/rtl/bow_dphy_io_versal.sv (XPHY) on Versal.
//
//   PHY I/O ports --> bow_dphy_rx --PPI--> bow_csi2rx --> m_axis RAW10 (ISP)
//   (lp, rx_data,      LP state machines,     lane merge, packet, unpack, FIFO,
//    byte_clk ..)      aligners, tap loads,   LOG / RAW, registers (bus, irq)
//                      byte clock meter
//                           ^      |
//                           +------+  temporary band (configuration, status, events, resets,
//                                     raw words of the PHY part of the register file)
//
// PPI (bow_ppi_pkg, v1):
//   rx_byte_clk_hs  RxByteClkHS: byte_clk_i
//   ppi_hs[l]       byte domain: RxActiveHS, RxValidHS, RxDataHS, RxSyncHS, RxSkewCalHS,
//                   ErrSotHS (0), ErrSotSyncHS
//   ppi_lp[l]       lp domain: Stopstate, ErrControl (one cycle pulse on bit 0), ULPS / escape
//                   idle
//   ppi_lp_clk      lp domain: StopstateClk, RxClkActiveHS, ErrControlClk, ULPS idle
//   enable[l], enable_clk  Enable, EnableClk (controller -> D-PHY)
// The D-PHY's lp clock is vid_clk_i (FPGA: lp_clk = vid_clk): the v1 lp domain errors and the
// lp domain signals of the band (the lp reset, HS entry pulses, synchronised lane enables
// and CLK_FORCE) are signals of the controller's own video clock. This connection is the
// guarantee; bow_csi2rx's PpiLpClkHz (= PhyClkHz here) only states it for its elaboration
// check.
//
// Temporary band (band_*): the PHY part of the CSI2RX register file and the resets the two
// blocks share, until the D-PHY has its own registers and resets (step 4) and the AFE
// interface (step 5). bow_dphy_rx lists each signal with the step that removes it:
//   controller -> D-PHY  resets: lp domain (= vrst_n), byte hard, byte datapath (drst_n: the
//                        aligners, held while RX is off), their asynchronous source (ISERDES
//                        reset); CTRL.CLK_FORCE; PHY_CFG (SETTLE, LP_FILTER, CLK_SETTLE,
//                        CLK_MISS); DLYn taps and write counters
//   D-PHY -> controller  STATUS LP / HS / CE / PHY_RDY, the byte clock meter, the DLYn
//                        readback (CPU domain); the HS entry pulses, the lane enables and
//                        CLK_FORCE of the lp domain (lost burst marking); the registered PHY
//                        words for RAW (byte domain)
//
// Clock domains:
//   clk_i       CPU: registers, counters, LOG/RAW read, PHY status synchronisers
//   vid_clk_i   video: the D-PHY's lp clock (LP state machines, PHY control and, with
//               DlyVid = 1, the input delay control); the controller's LP event release,
//               lost burst request and pixel output
//   byte_clk_i  byte clock = HS clock / 4, runs only while byte_ce_o = 1 and the clock
//               lane toggles (non-continuous clock: HS bursts only)
// Resets (bow_csi2rx): vid_rst_ni & rst_ni, synchronised per domain; the datapath resets
// are also asserted while RX is off (CTRL.PHY_EN & RX_EN). byte_rst_o (bow_dphy_rx):
// ISERDES reset, asserted while the byte clock gate is closed, released 2 byte clocks
// after the clock restarts.
//
// PHY I/O contract (besides the ports of bow_dphy_io_xusp):
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

module bow_mipi_rx import bow_bus_pkg::*; import bow_ppi_pkg::*; #(
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

  // ---------------------------------------------------------------- PPI
  logic                rx_byte_clk_hs;
  ppi_hs_t [Lanes-1:0] ppi_hs;
  ppi_lp_t [Lanes-1:0] ppi_lp;
  ppi_lp_clk_t         ppi_lp_clk;
  logic [Lanes-1:0]    enable;
  logic                enable_clk;

  // ------------------------------------------------- temporary band (steps 4 and 5)
  // controller -> D-PHY
  logic                  band_lp_rst_n, band_brst_n, band_drst_n, band_rst_src_n;
  logic                  band_clk_force;
  logic [7:0]            band_settle, band_clk_settle, band_clk_miss;
  logic [3:0]            band_lp_filter;
  logic [Lanes-1:0][8:0] band_dly;
  logic [Lanes-1:0][1:0] band_dly_req;
  // D-PHY -> controller
  logic [Lanes:0][1:0]   band_lp_sys;
  logic [Lanes:0]        band_hs_en_sys, band_ev_hs;
  logic                  band_ce_sys, band_phy_rdy_sys, band_clk_force_lp;
  logic [19:0]           band_meter_sys;
  logic [Lanes-1:0][8:0] band_dly_sys;
  logic [Lanes-1:0]      band_lane_en_lp, band_raw_valid;
  logic [Lanes-1:0][7:0] band_raw_data;

  bow_dphy_rx #(
    .Lanes  (Lanes),
    .DlyVid (DlyVid)
  ) u_dphy_rx (
    .clk_i,
    .rst_ni,
    .lp_clk_i            (vid_clk_i),          // FPGA: lp_clk = vid_clk
    .byte_clk_i,
    .enable_i            (enable),
    .enable_clk_i        (enable_clk),
    .rx_byte_clk_hs_o    (rx_byte_clk_hs),
    .ppi_hs_o            (ppi_hs),
    .ppi_lp_o            (ppi_lp),
    .ppi_lp_clk_o        (ppi_lp_clk),
    .band_lp_rst_ni      (band_lp_rst_n),
    .band_brst_ni        (band_brst_n),
    .band_drst_ni        (band_drst_n),
    .band_rst_src_ni     (band_rst_src_n),
    .band_clk_force_i    (band_clk_force),
    .band_settle_i       (band_settle),
    .band_lp_filter_i    (band_lp_filter),
    .band_clk_settle_i   (band_clk_settle),
    .band_clk_miss_i     (band_clk_miss),
    .band_dly_i          (band_dly),
    .band_dly_req_i      (band_dly_req),
    .band_lp_sys_o       (band_lp_sys),
    .band_hs_en_sys_o    (band_hs_en_sys),
    .band_ce_sys_o       (band_ce_sys),
    .band_phy_rdy_sys_o  (band_phy_rdy_sys),
    .band_meter_sys_o    (band_meter_sys),
    .band_dly_sys_o      (band_dly_sys),
    .band_ev_hs_o        (band_ev_hs),
    .band_lane_en_lp_o   (band_lane_en_lp),
    .band_clk_force_lp_o (band_clk_force_lp),
    .band_raw_data_o     (band_raw_data),
    .band_raw_valid_o    (band_raw_valid),
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

  bow_csi2rx #(
    .Lanes      (Lanes),
    .PhyClkHz   (PhyClkHz),
    .CpuClkHz   (CpuClkHz),
    .HasPhy     (HasPhy),
    .FifoDepth  (FifoDepth),
    .DlyVid     (DlyVid),
    .PpiLpClkHz (PhyClkHz)                     // the D-PHY runs on vid_clk_i
  ) u_csi2rx (
    .clk_i,
    .rst_ni,
    .bus_req_i,
    .bus_rsp_o,
    .irq_o,
    .vid_clk_i,
    .vid_rst_ni,
    .m_axis_tvalid_o,
    .m_axis_tready_i,
    .m_axis_tdata_o,
    .m_axis_tuser_o,
    .m_axis_tlast_o,
    .rx_byte_clk_hs_i    (rx_byte_clk_hs),
    .ppi_hs_i            (ppi_hs),
    .ppi_lp_i            (ppi_lp),
    .ppi_lp_clk_i        (ppi_lp_clk),
    .enable_o            (enable),
    .enable_clk_o        (enable_clk),
    .band_lp_rst_no      (band_lp_rst_n),
    .band_brst_no        (band_brst_n),
    .band_drst_no        (band_drst_n),
    .band_rst_src_no     (band_rst_src_n),
    .band_clk_force_o    (band_clk_force),
    .band_settle_o       (band_settle),
    .band_lp_filter_o    (band_lp_filter),
    .band_clk_settle_o   (band_clk_settle),
    .band_clk_miss_o     (band_clk_miss),
    .band_dly_o          (band_dly),
    .band_dly_req_o      (band_dly_req),
    .band_lp_sys_i       (band_lp_sys),
    .band_hs_en_sys_i    (band_hs_en_sys),
    .band_ce_sys_i       (band_ce_sys),
    .band_phy_rdy_sys_i  (band_phy_rdy_sys),
    .band_meter_sys_i    (band_meter_sys),
    .band_dly_sys_i      (band_dly_sys),
    .band_ev_hs_i        (band_ev_hs),
    .band_lane_en_lp_i   (band_lane_en_lp),
    .band_clk_force_lp_i (band_clk_force_lp),
    .band_raw_data_i     (band_raw_data),
    .band_raw_valid_i    (band_raw_valid)
  );

endmodule
