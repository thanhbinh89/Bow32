// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Formality only (make -C hw/ip/dphy_rx/fm equiv STEP=5, equiv.tcl): the receiver of step 5
// of docs/ip/mipi_rx_arch.md (bow_mipi_rx with the AFE interface, u_mipi) behind the ports
// and parameters of the receiver of step 4, so that the two can be compared point by point.
// The AFE ports map one to one onto the PHY I/O ports of step 4:
//
//   step 4 (PHY I/O)         step 5 (AFE)
//   byte_clk_i               afe_hs_byte_clk_i
//   rx_data_i, rx_valid_i    afe_hs_data_i, afe_hs_valid_i
//   lp_i, clk_lp_i           afe_lp_i, afe_clk_lp_i
//   byte_ce_o                afe_clk_gate_en_o
//   hs_en_o, clk_hs_en_o     afe_hsrx_en_o, afe_clk_hsrx_en_o  (term_en: the same flops)
//   phy_rdy_i, phy_status_i  afe_ready_i, afe_status_i
//   reinit_o                 afe_cal_start_o                   (the CMD.REINIT pulse)
//   dly_tap_i                afe_dly_q_i
//
// The step 4 outputs whose function moved into the AFE adapters or into des_rst have no
// counterpart here and are tied to 0; equiv.tcl does not compare them (the changes of step
// 5, listed there): byte_rst_o (the ISERDESE3 reset: the UltraScale+ adapter's from
// des_rst), burst_rst_en_o (~CTRL.DES_RST_DIS: inside des_rst), dly_tap_o / dly_load_o (the
// load requests: static codes with OWN, the loads in the adapters). The AFE outputs without
// a step 4 counterpart (des_rst, term_en, lprx_en, the codes and OWN, pd) stay open here.

module bow_mipi_rx_s4 import bow_bus_pkg::*; #(
  parameter int unsigned Lanes     = 2,
  parameter int unsigned PhyClkHz  = 200_000_000,
  parameter int unsigned CpuClkHz  = 0,
  parameter bit          HasPhy    = 1'b1,
  parameter int unsigned FifoDepth = 256,
  parameter bit          DlyVid    = 1'b0          // step 4: the Versal PHY (AfeKind 2)
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
  output logic [1:0]            m_axis_tuser_o,
  output logic                  m_axis_tlast_o,
  input  logic                  byte_clk_i,
  output logic                  byte_ce_o,
  output logic                  byte_rst_o,
  input  logic [1:0]            clk_lp_i,
  output logic                  clk_hs_en_o,
  input  logic [Lanes-1:0][1:0] lp_i,
  output logic [Lanes-1:0]      hs_en_o,
  input  logic [Lanes-1:0][7:0] rx_data_i,
  input  logic [Lanes-1:0]      rx_valid_i,
  input  logic                  phy_rdy_i,
  input  logic [7:0]            phy_status_i,
  output logic                  reinit_o,
  output logic                  burst_rst_en_o,
  output logic [Lanes-1:0][8:0] dly_tap_o,
  output logic [Lanes-1:0]      dly_load_o,
  input  logic [Lanes-1:0][8:0] dly_tap_i
);

  bow_mipi_rx #(
    .Lanes     (Lanes),
    .PhyClkHz  (PhyClkHz),
    .CpuClkHz  (CpuClkHz),
    .HasPhy    (HasPhy),
    .FifoDepth (FifoDepth),
    .AfeKind   (DlyVid ? 2 : 1),
    .ByteClkHz (PhyClkHz)                      // (step 7 of this tree: no default)
  ) u_mipi (
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
    .afe_hs_byte_clk_i (byte_clk_i),
    .afe_hs_data_i     (rx_data_i),
    .afe_hs_valid_i    (rx_valid_i),
    .afe_clk_gate_en_o (byte_ce_o),
    .afe_des_rst_o     (),
    .afe_clk_lp_i      (clk_lp_i),
    .afe_lp_i          (lp_i),
    .afe_clk_lprx_en_o (),
    .afe_lprx_en_o     (),
    .afe_clk_hsrx_en_o (clk_hs_en_o),
    .afe_hsrx_en_o     (hs_en_o),
    .afe_clk_term_en_o (),
    .afe_term_en_o     (),
    .afe_dly_code_o    (),
    .afe_dly_own_o     (),
    .afe_dly_q_i       (dly_tap_i),
    .afe_pd_o          (),
    .afe_ready_i       (phy_rdy_i),
    .afe_cal_start_o   (reinit_o),
    .afe_status_i      (phy_status_i)
  );

  assign byte_rst_o     = 1'b0;
  assign burst_rst_en_o = 1'b0;
  assign dly_tap_o      = '0;
  assign dly_load_o     = '0;

endmodule
