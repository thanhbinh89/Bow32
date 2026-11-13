// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI CSI-2 receiver (Bow32 wrapper): the digital D-PHY (bow_dphy_rx, u_dphy_rx) and
// the CSI-2 controller (bow_csi2rx, u_csi2rx), joined by the PPI of bow_ppi_pkg (steps 2 and 4
// of docs/ip/mipi_rx_arch.md, section 10). The register window (CSI2RX, 4 KiB) is split here:
// offsets 0x000..0xBFF go to the controller (bow_csi2rx_regs, docs/ip/csi2rx.md), 0xC00..0xFFF
// to the D-PHY (bow_dphy_rx_regs, docs/ip/dphy_rx.md); the D-PHY's interrupt is IRQ_STATUS[5]
// of the controller, whose irq_o is the receiver's. Below the D-PHY is the AFE interface of
// section 3.2 (step 5): on the FPGAs an adapter of the vendor I/O primitives,
// hw/fpga/common/rtl/bow_dphy_io_xusp.sv (KV260) or bow_dphy_io_versal.sv (Versal XPHY).
//
//   AFE (afe_*)  --> bow_dphy_rx --PPI--> bow_csi2rx --> m_axis RAW10 (ISP)
//   (hs_data, lp,    LP state machines,   lane merge (byte clock) + its two clock FIFO,
//    hs_byte_clk ..) aligners, meter,     packet, unpack, FIFO, LOG (vid_clk_i: the
//                    RAW, registers 0xC00 controller's csi_clk, step 7), registers 0x000..
//
// PPI (bow_ppi_pkg, v1):
//   rx_byte_clk_hs  RxByteClkHS: afe_hs_byte_clk_i
//   ppi_hs[l]       byte domain: RxActiveHS, RxValidHS, RxDataHS, RxSyncHS, RxSkewCalHS,
//                   ErrSotHS (0), ErrSotSyncHS
//   ppi_lp[l]       lp domain: Stopstate, ErrControl (one cycle pulse on bit 0, masked by the
//                   lane's Enable), ULPS / escape idle
//   ppi_lp_clk      lp domain: StopstateClk, RxClkActiveHS, ErrControlClk (masked while
//                   CTRL.CLK_CONT of the D-PHY), ULPS idle
//   enable[l], enable_clk  Enable, EnableClk (controller -> D-PHY)
// The D-PHY's lp clock is vid_clk_i (FPGA: lp_clk = vid_clk), and so is the controller's own
// continuous clock csi_clk_i (step 7 of docs/ip/mipi_rx_arch.md: csi_clk = vid_clk on the
// FPGA): the v1 lp domain errors were pulses of that clock. This connection is the
// guarantee; bow_csi2rx's PpiLpClkHz (= PhyClkHz here) only states it for its elaboration
// check. ByteClkHz, the highest byte clock this receiver gets (the lane rate / 8), must not
// exceed vid_clk_i (bow_csi2rx's PpiByteClkHz check: the lane merge hands one word per byte
// clock to the controller's clock); its default, vid_clk_i itself, is also the limit of the
// D-PHY's clock lane check at CLK_TOG_DIV = 0 (byte clock < lp clock, section 4.3).
//
// AFE ports (afe_*): the signals of section 3.2 that the FPGA adapters have (bow_dphy_rx
// describes each one). The D-PHY's other AFE signals are tied off here: no FPGA adapter has
// clk_hs_samp in use, clk_act, a clock lane delay, the monitor sampler, cal_done / cal_err,
// lane_pd, trim or the test hooks (the ASIC wrapper of step 9 connects them to the macro).
//
// Clock domains:
//   clk_i              CPU: registers, counters, LOG/RAW read, status synchronisers, the AFE
//                      controls of the D-PHY's register file (delay codes, PD, cal_start)
//   vid_clk_i          video: the D-PHY's lp clock (LP state machines, gate, des_rst, HS
//                      receivers); the controller's clock csi_clk_i (step 7: everything after
//                      the lane merge's two clock FIFO, the PPI lp error samples, the pixel
//                      output)
//   afe_hs_byte_clk_i  byte clock = HS clock / 4, runs only while afe_clk_gate_en_o = 1 and
//                      the clock lane toggles (non-continuous clock: HS bursts only): the
//                      D-PHY's byte side and the controller's lane merge
// Resets: each block synchronises vid_rst_ni & rst_ni per domain on its own (the D-PHY:
// docs/ip/mipi_rx_arch.md section 4.11); the controller's datapath resets are also asserted
// while RX is off (CTRL.PHY_EN & RX_EN), the D-PHY's aligners are not. The AFE's receive path
// reset is des_rst (afe_des_rst_o): set while the byte clock gate is closed; an adapter that
// needs a synchronous release does it on its own clock (bow_dphy_dly_xusp: the ISERDESE3).
//
// The bus response: both register files grant at once and answer one cycle after the
// request, so the response comes from the one with rvalid (no state here).

module bow_mipi_rx import bow_bus_pkg::*; import bow_ppi_pkg::*; #(
  parameter int unsigned Lanes     = 2,            // physical data lanes: 1, 2 or 4
  parameter int unsigned PhyClkHz  = 200_000_000,  // vid_clk_i frequency (INFO)
  parameter int unsigned CpuClkHz  = 0,            // clk_i frequency (0: not checked)
  parameter bit          HasPhy    = 1'b1,         // INFO.PHY: a D-PHY is connected
  parameter int unsigned FifoDepth = 256,          // pixel FIFO entries (4 px each), power of 2
  parameter int unsigned AfeKind   = 1,            // the D-PHY's INFO[7:5]: 1 UltraScale+
                                                   // adapter (KV260), 2 Versal adapter (Huins)
  parameter int unsigned ByteClkHz = PhyClkHz      // highest byte clock (lane rate / 8), at
                                                   // most PhyClkHz (above)
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
  // AFE interface (docs/ip/mipi_rx_arch.md section 3.2; the FPGA adapters' set)
  input  logic                  afe_hs_byte_clk_i,  // byte clock, gated in the AFE
  input  logic [Lanes-1:0][7:0] afe_hs_data_i,      // byte domain, bit 0 = first bit
  input  logic [Lanes-1:0]      afe_hs_valid_i,     // byte domain: a new word
  output logic                  afe_clk_gate_en_o,  // video domain flop
  output logic                  afe_des_rst_o,      // video domain flop (~gate)
  input  logic [1:0]            afe_clk_lp_i,       // {P, N}, asynchronous
  input  logic [Lanes-1:0][1:0] afe_lp_i,           // {P, N}, asynchronous
  output logic                  afe_clk_lprx_en_o,  // CPU domain flop
  output logic [Lanes-1:0]      afe_lprx_en_o,      // CPU domain flop
  output logic                  afe_clk_hsrx_en_o,  // video domain flop
  output logic [Lanes-1:0]      afe_hsrx_en_o,      // video domain flops
  output logic                  afe_clk_term_en_o,  // video domain flop
  output logic [Lanes-1:0]      afe_term_en_o,      // video domain flops
  output logic [Lanes-1:0][8:0] afe_dly_code_o,     // CPU domain flops, static
  output logic [Lanes-1:0]      afe_dly_own_o,      // CPU domain flops
  input  logic [Lanes-1:0][8:0] afe_dly_q_i,        // asynchronous, quasi-static
  output logic                  afe_pd_o,           // CPU domain flop (AFE_CTRL.PD)
  input  logic                  afe_ready_i,        // asynchronous (AFE_STATUS.READY)
  output logic                  afe_cal_start_o,    // CPU domain flop (CMD.AFE_CAL pulse)
  input  logic [7:0]            afe_status_i        // asynchronous (AFE_STATUS[15:8])
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
    .AfeKind  (AfeKind),
    .LpClkHz  (PhyClkHz),                      // FPGA: lp_clk = vid_clk
    .BusClkHz (CpuClkHz)
  ) u_dphy_rx (
    .clk_i,
    .rst_ni,
    .lp_clk_i           (vid_clk_i),
    .lp_rst_ni          (vid_rst_ni),
    .bus_req_i          (bus_req_d),
    .bus_rsp_o          (bus_rsp_d),
    .irq_o              (dphy_irq),
    .enable_i           (enable),
    .enable_clk_i       (enable_clk),
    .rx_byte_clk_hs_o   (rx_byte_clk_hs),
    .ppi_hs_o           (ppi_hs),
    .ppi_lp_o           (ppi_lp),
    .ppi_lp_clk_o       (ppi_lp_clk),
    .afe_hs_byte_clk_i,
    .afe_hs_data_i,
    .afe_hs_valid_i,
    .afe_clk_gate_en_o,
    .afe_des_rst_o,
    .afe_clk_hs_samp_i  ('0),                  // none in use on the FPGA adapters
    .afe_clk_act_i      (1'b0),                // none on the FPGA adapters (step 10)
    .afe_clk_lp_i,
    .afe_lp_i,
    .afe_clk_lprx_en_o,
    .afe_lprx_en_o,
    .afe_clk_hsrx_en_o,
    .afe_hsrx_en_o,
    .afe_clk_term_en_o,
    .afe_term_en_o,
    .afe_dly_code_o,
    .afe_dly_own_o,
    .afe_dly_q_i,
    .afe_clk_dly_code_o (),                    // no clock lane delay
    .afe_clk_dly_own_o  (),
    .afe_clk_dly_q_i    ('0),
    .afe_mon_en_o       (),                    // no monitor sampler
    .afe_mon_code_o     (),
    .afe_mon_data_i     ('0),
    .afe_pd_o,
    .afe_clk_lane_pd_o  (),                    // not modelled by the FPGA adapters
    .afe_lane_pd_o      (),
    .afe_ready_i,
    .afe_cal_start_o,
    .afe_cal_done_i     (1'b0),                // no internal calibration result
    .afe_cal_err_i      (1'b0),
    .afe_trim_o         (),
    .afe_status_i,
    .afe_tst_mode_o     (),                    // no test hooks
    .afe_tst_data_o     (),
    .afe_clk_hs_raw_i   (1'b0),
    .afe_hs_raw_i       ('0),
    .afe_atb_sel_o      ()
  );

  bow_csi2rx #(
    .Lanes        (Lanes),
    .PhyClkHz     (PhyClkHz),
    .CpuClkHz     (CpuClkHz),
    .HasPhy       (HasPhy),
    .FifoDepth    (FifoDepth),
    .DphyWin      (1'b1),                      // the D-PHY's registers at 0xC00
    .PpiLpClkHz   (PhyClkHz),                  // the D-PHY runs on vid_clk_i
    .PpiByteClkHz (ByteClkHz)
  ) u_csi2rx (
    .clk_i,
    .rst_ni,
    .bus_req_i        (bus_req_c),
    .bus_rsp_o        (bus_rsp_c),
    .irq_o,
    .csi_clk_i        (vid_clk_i),             // the controller's clock (step 7)
    .csi_rst_ni       (vid_rst_ni),
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
