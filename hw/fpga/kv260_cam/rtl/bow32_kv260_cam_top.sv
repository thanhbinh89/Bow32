// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 + camera on the AMD Kria KV260: Raspberry Pi camera v2 (IMX219) on
// connector J9 -> Bow32 MIPI CSI-2 receiver -> Bow32 ISP. No vendor CSI-2 or
// D-PHY IP: the pins go to bow_dphy_io_xusp, the UltraScale+ AFE adapter
// (IBUFDS_DPHY, IDELAYE3, ISERDESE3, BUFGCE_DIV and its fabric logic
// bow_dphy_dly_xusp), whose AFE ports (docs/ip/mipi_rx_arch.md section 3.2)
// connect one to one to the dphy_* ports of the SoC; the LP state machines, the
// byte alignment and the CSI-2 layer are in bow_mipi_rx inside the SoC
// (CSI2RX registers at 0x4000_8000, see docs/camera_kv260.md).
//
// The block design "bow32_cam" (tcl/cam_bd.tcl) holds the Xilinx IP:
//   Zynq UltraScale+ PS   pl_clk0 100 MHz, pl_resetn0
//   clk_wiz               200 MHz (video: ISP + D-PHY state machines), 50 MHz (SoC)
//   proc_sys_reset x 2    resets of the two clock domains
// The byte clock of the receiver (HS clock / 4, 114 MHz at 912 Mbit/s per
// lane) comes from the camera clock lane and only runs during HS bursts.
//
// Everything else is the same as hw/fpga/kv260 (UART0, GPIO, camera enable
// on PA7, I2C0 to the camera, constr/kv260.xdc of that board directory). The
// AXI4-Lite window has no device in this build: the bridge times out.

module bow32_kv260_cam_top #(
  parameter RomInitFile   = "",
  parameter FlashInitFile = ""
) (
  output logic       uart0_tx_o,
  input  logic       uart0_rx_i,
  inout  wire  [3:0] gpioa_io,   // PA0..PA3
  inout  wire  [1:0] gpiob_io,   // PB0/PB1
  inout  wire        cam_en_io,  // PA7 = RPI_ENABLE of the camera connector
  inout  wire        i2c_scl_io, // PL I2C (open drain)
  inout  wire        i2c_sda_io,
  output logic       fan_en_b,   // SOM fan control, active low

  // MIPI CSI-2 D-PHY, camera connector J9 (bank 66)
  input  wire        mipi_phy_if_raspi_clk_p,
  input  wire        mipi_phy_if_raspi_clk_n,
  input  wire  [1:0] mipi_phy_if_raspi_data_p,
  input  wire  [1:0] mipi_phy_if_raspi_data_n
);

  localparam int unsigned SysClkHz = 50_000_000;
  localparam int unsigned VidClkHz = 200_000_000;   // clk_out1 of tcl/cam_bd.tcl
  localparam int unsigned CsiLanes = 2;

  // ---------------------------------------------------------------------------
  // Block design: PS, clocks, resets
  // ---------------------------------------------------------------------------
  logic clk_sys, clk_vid, rst_sys_n, rst_vid_n;

  bow32_cam_wrapper u_bd (
    .sys_clk    (clk_sys),
    .sys_resetn (rst_sys_n),
    .vid_clk    (clk_vid),
    .vid_resetn (rst_vid_n)
  );

  // ---------------------------------------------------------------------------
  // D-PHY AFE adapter (constr/kv260_cam.xdc refers to the instance name)
  // ---------------------------------------------------------------------------
  logic                     dphy_hs_byte_clk, dphy_clk_gate_en, dphy_des_rst;
  logic                     dphy_clk_lprx_en, dphy_clk_hsrx_en, dphy_clk_term_en;
  logic                     dphy_pd, dphy_ready, dphy_cal_start;
  logic [7:0]               dphy_status;
  logic [1:0]               dphy_clk_lp;
  logic [CsiLanes-1:0][1:0] dphy_lp;
  logic [CsiLanes-1:0]      dphy_hs_valid, dphy_lprx_en, dphy_hsrx_en, dphy_term_en;
  logic [CsiLanes-1:0]      dphy_dly_own;
  logic [CsiLanes-1:0][7:0] dphy_hs_data;
  logic [CsiLanes-1:0][8:0] dphy_dly_code, dphy_dly_q;

  bow_dphy_io_xusp #(
    .Lanes (CsiLanes)
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

  // ---------------------------------------------------------------------------
  // SoC
  // ---------------------------------------------------------------------------
  logic [7:0] gpioa_i, gpioa_o, gpioa_oe;
  logic [7:0] gpiob_i, gpiob_o, gpiob_oe;
  logic       scl_i, scl_oe, sda_i, sda_oe;

  bow32_top #(
    .ClkFreqHz     (SysClkHz),
    .BootBaud      (115_200),
    .BootWaitMs    (300),
    .RomInitFile   (RomInitFile),
    .FlashInitFile (FlashInitFile),
    .IbexRegFile   (ibex_pkg::RegFileFPGA),
    .CsiLanes      (CsiLanes),
    .CsiPhy        (1'b1),
    .VidClkHz      (VidClkHz)
  ) u_soc (
    .clk_i        (clk_sys),
    .rst_ni       (rst_sys_n),
    .uart0_rx_i,
    .uart0_tx_o,
    .gpioa_i,
    .gpioa_o,
    .gpioa_oe_o   (gpioa_oe),
    .gpiob_i,
    .gpiob_o,
    .gpiob_oe_o   (gpiob_oe),
    .i2c0_scl_i   (scl_i),
    .i2c0_scl_oe_o(scl_oe),
    .i2c0_sda_i   (sda_i),
    .i2c0_sda_oe_o(sda_oe),
    .vid_clk_i    (clk_vid),
    .vid_rst_ni   (rst_vid_n),
    // no video output yet (a display path can be added here)
    .isp_tvalid_o (),
    .isp_tready_i (1'b1),
    .isp_tdata_o  (),
    .isp_tuser_o  (),
    .isp_tlast_o  (),
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
    .dphy_status_i      (dphy_status),
    // no AXI4-Lite device: the bridge times out
    .m_axil_awaddr_o  (),
    .m_axil_awprot_o  (),
    .m_axil_awvalid_o (),
    .m_axil_awready_i (1'b0),
    .m_axil_wdata_o   (),
    .m_axil_wstrb_o   (),
    .m_axil_wvalid_o  (),
    .m_axil_wready_i  (1'b0),
    .m_axil_bresp_i   (2'b00),
    .m_axil_bvalid_i  (1'b0),
    .m_axil_bready_o  (),
    .m_axil_araddr_o  (),
    .m_axil_arprot_o  (),
    .m_axil_arvalid_o (),
    .m_axil_arready_i (1'b0),
    .m_axil_rdata_i   ('0),
    .m_axil_rresp_i   (2'b00),
    .m_axil_rvalid_i  (1'b0),
    .m_axil_rready_o  (),
    // no DDR on this board (DdrEn = 0: stub)
    .ddr_sys_clk_i  (1'b0),
    .ddr_clk_i      (1'b0),
    .ddr_rst_ni     (1'b0),
    .ddr_rd_clk_i   (1'b0),
    .ddr_ps_en_o    (),
    .ddr_ps_inc_o   (),
    .ddr_ps_done_i  (1'b0),
    .ddr_wps_en_o   (),
    .ddr_wps_inc_o  (),
    .ddr_wps_done_i (1'b0),
    .ddr_io_o       (),
    .ddr_io_i       ('0),
    .ddr_dbg_i      ('0),
    // no HyperRAM on this board (HrEn = 0: stub)
    .hr_clk_i       (1'b0),
    .hr_rst_ni      (1'b0),
    .hr_rd_clk_i    (1'b0),
    .hr_ps_en_o     (),
    .hr_ps_inc_o    (),
    .hr_ps_done_i   (1'b0),
    .hr_wps_en_o    (),
    .hr_wps_inc_o   (),
    .hr_wps_done_i  (1'b0),
    .hr_io_o        (),
    .hr_io_i        ('0),
    .hr_rwds_pad_i  (1'b0),
    .hr_dbg_i       ('0),
    .sys_rst_no   (),
    .core_sleep_o ()
  );

  // ---------------------------------------------------------------------------
  // Pads (same as hw/fpga/kv260)
  // ---------------------------------------------------------------------------
  for (genvar i = 0; i < 4; i++) begin : g_pad_a
    IOBUF u_pad (
      .I  (gpioa_o[i]),
      .T  (~gpioa_oe[i]),
      .O  (gpioa_i[i]),
      .IO (gpioa_io[i])
    );
  end

  for (genvar i = 0; i < 2; i++) begin : g_pad_b
    IOBUF u_pad (
      .I  (gpiob_o[i]),
      .T  (~gpiob_oe[i]),
      .O  (gpiob_i[i]),
      .IO (gpiob_io[i])
    );
  end

  IOBUF u_pad_cam_en (
    .I  (gpioa_o[7]),
    .T  (~gpioa_oe[7]),
    .O  (gpioa_i[7]),
    .IO (cam_en_io)
  );

  assign gpioa_i[6:4] = gpioa_oe[6:4] & gpioa_o[6:4];
  assign gpiob_i[7:2] = gpiob_oe[7:2] & gpiob_o[7:2];

  IOBUF u_pad_scl (
    .I  (1'b0),
    .T  (~scl_oe),
    .O  (scl_i),
    .IO (i2c_scl_io)
  );

  IOBUF u_pad_sda (
    .I  (1'b0),
    .T  (~sda_oe),
    .O  (sda_i),
    .IO (i2c_sda_io)
  );

  assign fan_en_b = 1'b0;

endmodule
