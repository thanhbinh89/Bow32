// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Out-of-context check of the receiver part of the KV260 camera build (make -C
// hw/fpga/kv260_cam rx-ooc, ooc/rx_ooc.tcl; decision D1 of docs/ip/mipi_rx_arch.md: no KV260
// bitstream during the migration steps). The CSI-2 receiver (bow_mipi_rx) at u_soc/u_csi2rx
// and the UltraScale+ AFE adapter (bow_dphy_io_xusp) at u_dphy, connected as in
// bow32_kv260_cam_top and on its MIPI pins, so that the receiver constraints of
// constr/kv260_cam.xdc select the same cells. The bus is driven by an LFSR (random accesses
// over the receiver window) and every output is folded into one pin, so that nothing is
// optimised away; clk_sys / clk_vid are pins here (the PS and the MMCM of the block design
// in the board build). Not a design to load.

// u_soc: the receiver under the instance names of bow32_top (u_soc/u_csi2rx)
module bow32_kv260_rx_ooc_soc import bow_bus_pkg::*; #(
  parameter int unsigned Lanes     = 2,
  parameter int unsigned FifoDepth = 256
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
  input  logic                  dphy_hs_byte_clk_i,
  input  logic [Lanes-1:0][7:0] dphy_hs_data_i,
  input  logic [Lanes-1:0]      dphy_hs_valid_i,
  output logic                  dphy_clk_gate_en_o,
  output logic                  dphy_des_rst_o,
  input  logic [1:0]            dphy_clk_lp_i,
  input  logic [Lanes-1:0][1:0] dphy_lp_i,
  output logic                  dphy_clk_lprx_en_o,
  output logic [Lanes-1:0]      dphy_lprx_en_o,
  output logic                  dphy_clk_hsrx_en_o,
  output logic [Lanes-1:0]      dphy_hsrx_en_o,
  output logic                  dphy_clk_term_en_o,
  output logic [Lanes-1:0]      dphy_term_en_o,
  output logic [Lanes-1:0][8:0] dphy_dly_code_o,
  output logic [Lanes-1:0]      dphy_dly_own_o,
  input  logic [Lanes-1:0][8:0] dphy_dly_q_i,
  output logic                  dphy_pd_o,
  input  logic                  dphy_ready_i,
  output logic                  dphy_cal_start_o,
  input  logic [7:0]            dphy_status_i
);

  bow_mipi_rx #(
    .Lanes     (Lanes),
    .PhyClkHz  (200_000_000),
    .CpuClkHz  (50_000_000),
    .HasPhy    (1'b1),
    .FifoDepth (FifoDepth),
    .AfeKind   (1)
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
    .afe_hs_byte_clk_i (dphy_hs_byte_clk_i),
    .afe_hs_data_i     (dphy_hs_data_i),
    .afe_hs_valid_i    (dphy_hs_valid_i),
    .afe_clk_gate_en_o (dphy_clk_gate_en_o),
    .afe_des_rst_o     (dphy_des_rst_o),
    .afe_clk_lp_i      (dphy_clk_lp_i),
    .afe_lp_i          (dphy_lp_i),
    .afe_clk_lprx_en_o (dphy_clk_lprx_en_o),
    .afe_lprx_en_o     (dphy_lprx_en_o),
    .afe_clk_hsrx_en_o (dphy_clk_hsrx_en_o),
    .afe_hsrx_en_o     (dphy_hsrx_en_o),
    .afe_clk_term_en_o (dphy_clk_term_en_o),
    .afe_term_en_o     (dphy_term_en_o),
    .afe_dly_code_o    (dphy_dly_code_o),
    .afe_dly_own_o     (dphy_dly_own_o),
    .afe_dly_q_i       (dphy_dly_q_i),
    .afe_pd_o          (dphy_pd_o),
    .afe_ready_i       (dphy_ready_i),
    .afe_cal_start_o   (dphy_cal_start_o),
    .afe_status_i      (dphy_status_i)
  );

endmodule

module bow32_kv260_rx_ooc_top import bow_bus_pkg::*; (
  input  logic       clk_sys,
  input  logic       clk_vid,
  input  logic       rst_n_pin,
  input  wire        mipi_phy_if_raspi_clk_p,
  input  wire        mipi_phy_if_raspi_clk_n,
  input  wire  [1:0] mipi_phy_if_raspi_data_p,
  input  wire  [1:0] mipi_phy_if_raspi_data_n,
  output logic       led
);

  localparam int unsigned Lanes = 2;

  logic rst_n, vid_rst_n;

  bow_rst_sync u_rst (
    .clk_i  (clk_sys),
    .rst_ni (rst_n_pin),
    .rst_no (rst_n)
  );

  bow_rst_sync u_vrst (
    .clk_i  (clk_vid),
    .rst_ni (rst_n_pin),
    .rst_no (vid_rst_n)
  );

  // random bus accesses in the receiver window (0x4000_8000, 4 KiB)
  logic [31:0] lfsr_q;
  bus_req_t    req;
  bus_rsp_t    rsp;

  always_ff @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) lfsr_q <= 32'h1;
    else        lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
  end

  assign req.req   = lfsr_q[0];
  assign req.we    = lfsr_q[1];
  assign req.be    = lfsr_q[5:2];
  assign req.addr  = {20'h40008, lfsr_q[15:6], 2'b00};
  assign req.wdata = {lfsr_q[15:0], lfsr_q[31:16]};

  logic vid_ready_q;
  always_ff @(posedge clk_vid) vid_ready_q <= ~vid_ready_q;

  logic                  dphy_hs_byte_clk, dphy_clk_gate_en, dphy_des_rst;
  logic [Lanes-1:0][7:0] dphy_hs_data;
  logic [Lanes-1:0]      dphy_hs_valid;
  logic [1:0]            dphy_clk_lp;
  logic [Lanes-1:0][1:0] dphy_lp;
  logic                  dphy_clk_lprx_en, dphy_clk_hsrx_en, dphy_clk_term_en;
  logic [Lanes-1:0]      dphy_lprx_en, dphy_hsrx_en, dphy_term_en, dphy_dly_own;
  logic [Lanes-1:0][8:0] dphy_dly_code, dphy_dly_q;
  logic                  dphy_pd, dphy_ready, dphy_cal_start;
  logic [7:0]            dphy_status;
  logic                  irq, tvalid, tlast;
  logic [9:0]            tdata;
  logic [1:0]            tuser;

  // D-PHY AFE adapter: the instance name constr/kv260_cam.xdc refers to
  bow_dphy_io_xusp #(
    .Lanes (Lanes)
  ) u_dphy (
    .clk_p         (mipi_phy_if_raspi_clk_p),
    .clk_n         (mipi_phy_if_raspi_clk_n),
    .data_p        (mipi_phy_if_raspi_data_p),
    .data_n        (mipi_phy_if_raspi_data_n),
    .hs_byte_clk_o (dphy_hs_byte_clk),
    .hs_data_o     (dphy_hs_data),
    .hs_valid_o    (dphy_hs_valid),
    .clk_gate_en_i (dphy_clk_gate_en),
    .des_rst_i     (dphy_des_rst),
    .clk_lp_o      (dphy_clk_lp),
    .lp_o          (dphy_lp),
    .clk_lprx_en_i (dphy_clk_lprx_en),
    .lprx_en_i     (dphy_lprx_en),
    .clk_hsrx_en_i (dphy_clk_hsrx_en),
    .hsrx_en_i     (dphy_hsrx_en),
    .clk_term_en_i (dphy_clk_term_en),
    .term_en_i     (dphy_term_en),
    .dly_code_i    (dphy_dly_code),
    .dly_own_i     (dphy_dly_own),
    .dly_q_o       (dphy_dly_q),
    .pd_i          (dphy_pd),
    .ready_o       (dphy_ready),
    .cal_start_i   (dphy_cal_start),
    .status_o      (dphy_status)
  );

  bow32_kv260_rx_ooc_soc #(
    .Lanes     (Lanes),
    .FifoDepth (256)
  ) u_soc (
    .clk_i              (clk_sys),
    .rst_ni             (rst_n),
    .bus_req_i          (req),
    .bus_rsp_o          (rsp),
    .irq_o              (irq),
    .vid_clk_i          (clk_vid),
    .vid_rst_ni         (vid_rst_n),
    .m_axis_tvalid_o    (tvalid),
    .m_axis_tready_i    (vid_ready_q),
    .m_axis_tdata_o     (tdata),
    .m_axis_tuser_o     (tuser),
    .m_axis_tlast_o     (tlast),
    .dphy_hs_byte_clk_i (dphy_hs_byte_clk),
    .dphy_hs_data_i     (dphy_hs_data),
    .dphy_hs_valid_i    (dphy_hs_valid),
    .dphy_clk_gate_en_o (dphy_clk_gate_en),
    .dphy_des_rst_o     (dphy_des_rst),
    .dphy_clk_lp_i      (dphy_clk_lp),
    .dphy_lp_i          (dphy_lp),
    .dphy_clk_lprx_en_o (dphy_clk_lprx_en),
    .dphy_lprx_en_o     (dphy_lprx_en),
    .dphy_clk_hsrx_en_o (dphy_clk_hsrx_en),
    .dphy_hsrx_en_o     (dphy_hsrx_en),
    .dphy_clk_term_en_o (dphy_clk_term_en),
    .dphy_term_en_o     (dphy_term_en),
    .dphy_dly_code_o    (dphy_dly_code),
    .dphy_dly_own_o     (dphy_dly_own),
    .dphy_dly_q_i       (dphy_dly_q),
    .dphy_pd_o          (dphy_pd),
    .dphy_ready_i       (dphy_ready),
    .dphy_cal_start_o   (dphy_cal_start),
    .dphy_status_i      (dphy_status)
  );

  // every output folded into one pin (registered per clock domain)
  logic sys_fold_q, vid_fold_q;
  always_ff @(posedge clk_sys) sys_fold_q <= ^{rsp, irq};
  always_ff @(posedge clk_vid) vid_fold_q <= ^{tvalid, tdata, tuser, tlast};
  assign led = sys_fold_q ^ vid_fold_q;

endmodule
