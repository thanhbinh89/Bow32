// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI CSI-2 receiver (Bow32 wrapper): the digital D-PHY (bow_dphy_rx, u_dphy_rx) and
// the CSI-2 controller (bow_csi2rx, u_csi2rx), joined by the PPI of bow_ppi_pkg (steps 2 and 4
// of docs/ip/mipi_rx_arch.md, section 10). The register window (CSI2RX, 4 KiB) is split here:
// offsets 0x000..0xBFF go to the controller (bow_csi2rx_regs, docs/ip/csi2rx.md), 0xC00..0xFFF
// to the D-PHY (bow_dphy_rx_regs, docs/ip/dphy_rx.md); the D-PHY's interrupt is IRQ_STATUS[5]
// of the controller, whose irq_o is the receiver's. The D-PHY I/O (LP / HS receivers,
// deserialisers, input delays) is outside, e.g. hw/fpga/common/rtl/bow_dphy_io_xusp.sv on the
// KV260 or hw/fpga/common/rtl/bow_dphy_io_versal.sv (XPHY) on Versal.
//
//   PHY I/O ports --> bow_dphy_rx --PPI--> bow_csi2rx --> m_axis RAW10 (ISP)
//   (lp, rx_data,      LP state machines,     lane merge, packet, unpack, FIFO,
//    byte_clk ..)      aligners, tap loads,   LOG, registers 0x000..
//                      meter, RAW, registers 0xC00..
//
// PPI (bow_ppi_pkg, v1):
//   rx_byte_clk_hs  RxByteClkHS: byte_clk_i
//   ppi_hs[l]       byte domain: RxActiveHS, RxValidHS, RxDataHS, RxSyncHS, RxSkewCalHS,
//                   ErrSotHS (0), ErrSotSyncHS
//   ppi_lp[l]       lp domain: Stopstate, ErrControl (one cycle pulse on bit 0, masked by the
//                   lane's Enable), ULPS / escape idle
//   ppi_lp_clk      lp domain: StopstateClk, RxClkActiveHS, ErrControlClk (masked while
//                   CTRL.CLK_CONT of the D-PHY), ULPS idle
//   enable[l], enable_clk  Enable, EnableClk (controller -> D-PHY)
// The D-PHY's lp clock is vid_clk_i (FPGA: lp_clk = vid_clk): the v1 lp domain errors are
// pulses of the controller's own video clock. This connection is the guarantee;
// bow_csi2rx's PpiLpClkHz (= PhyClkHz here) only states it for its elaboration check.
//
// Clock domains:
//   clk_i       CPU: registers, counters, LOG/RAW read, status synchronisers
//   vid_clk_i   video: the D-PHY's lp clock (LP state machines, PHY control and, with
//               DlyVid = 1, the input delay control); the controller's LP error release,
//               lost burst request and pixel output
//   byte_clk_i  byte clock = HS clock / 4, runs only while byte_ce_o = 1 and the clock
//               lane toggles (non-continuous clock: HS bursts only)
// Resets: each block synchronises vid_rst_ni & rst_ni per domain on its own (the D-PHY:
// docs/ip/mipi_rx_arch.md section 4.11); the controller's datapath resets are also asserted
// while RX is off (CTRL.PHY_EN & RX_EN), the D-PHY's aligners are not. byte_rst_o
// (bow_dphy_rx): ISERDES reset, asserted while the byte clock gate is closed, released 2
// byte clocks after the clock restarts.
//
// PHY I/O contract (besides the ports of bow_dphy_io_xusp): see bow_dphy_rx (rx_valid_i,
// phy_rdy_i, phy_status_i, reinit_o, burst_rst_en_o, dly_*).
//
// The bus response: both register files grant at once and answer one cycle after the
// request, so the response comes from the one with rvalid (no state here).

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
  input  logic                  phy_rdy_i,        // asynchronous: PHY ready (AFE_STATUS.READY)
  input  logic [7:0]            phy_status_i,     // asynchronous: raw PHY status (AFE_STATUS[15:8])
  output logic                  reinit_o,         // CPU domain flop: PHY re-init (CMD.REINIT)
  output logic                  burst_rst_en_o,   // CPU domain flop: ~CTRL.DES_RST_DIS
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

  // ------------------------------------------------------- register window
  bus_req_t bus_req_c, bus_req_d;
  bus_rsp_t bus_rsp_c, bus_rsp_d;
  logic     dphy_sel, dphy_irq;

  assign dphy_sel = (bus_req_i.addr[11:10] == 2'b11);

  always_comb begin
    bus_req_c     = bus_req_i;
    bus_req_d     = bus_req_i;
    bus_req_c.req = bus_req_i.req & ~dphy_sel;
    bus_req_d.req = bus_req_i.req & dphy_sel;
  end

  always_comb begin
    bus_rsp_o        = bus_rsp_d.rvalid ? bus_rsp_d : bus_rsp_c;
    bus_rsp_o.gnt    = dphy_sel ? bus_rsp_d.gnt : bus_rsp_c.gnt;
    bus_rsp_o.rvalid = bus_rsp_c.rvalid | bus_rsp_d.rvalid;
  end

  bow_dphy_rx #(
    .Lanes    (Lanes),
    .DlyVid   (DlyVid),
    .LpClkHz  (PhyClkHz),                      // FPGA: lp_clk = vid_clk
    .BusClkHz (CpuClkHz)
  ) u_dphy_rx (
    .clk_i,
    .rst_ni,
    .lp_clk_i         (vid_clk_i),
    .lp_rst_ni        (vid_rst_ni),
    .byte_clk_i,
    .bus_req_i        (bus_req_d),
    .bus_rsp_o        (bus_rsp_d),
    .irq_o            (dphy_irq),
    .enable_i         (enable),
    .enable_clk_i     (enable_clk),
    .rx_byte_clk_hs_o (rx_byte_clk_hs),
    .ppi_hs_o         (ppi_hs),
    .ppi_lp_o         (ppi_lp),
    .ppi_lp_clk_o     (ppi_lp_clk),
    .byte_ce_o,
    .byte_rst_o,
    .clk_lp_i,
    .clk_hs_en_o,
    .lp_i,
    .hs_en_o,
    .rx_data_i,
    .rx_valid_i,
    .phy_rdy_i,
    .phy_status_i,
    .reinit_o,
    .burst_rst_en_o,
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
    .DphyWin    (1'b1),                        // the D-PHY's registers at 0xC00
    .PpiLpClkHz (PhyClkHz)                     // the D-PHY runs on vid_clk_i
  ) u_csi2rx (
    .clk_i,
    .rst_ni,
    .bus_req_i        (bus_req_c),
    .bus_rsp_o        (bus_rsp_c),
    .irq_o,
    .vid_clk_i,
    .vid_rst_ni,
    .m_axis_tvalid_o,
    .m_axis_tready_i,
    .m_axis_tdata_o,
    .m_axis_tuser_o,
    .m_axis_tlast_o,
    .rx_byte_clk_hs_i (rx_byte_clk_hs),
    .ppi_hs_i         (ppi_hs),
    .ppi_lp_i         (ppi_lp),
    .ppi_lp_clk_i     (ppi_lp_clk),
    .enable_o         (enable),
    .enable_clk_o     (enable_clk),
    .irq_i            (dphy_irq)
  );

endmodule
