// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 + camera on the AMD Kria KV260: Raspberry Pi camera v2 (IMX219) on
// connector J9 -> Bow32 MIPI CSI-2 receiver -> Bow32 ISP. No vendor CSI-2 or
// D-PHY IP: the pins go to bow_dphy_io_xusp (UltraScale+ I/O primitives:
// IBUFDS_DPHY, IDELAYE3, ISERDESE3, BUFGCE_DIV), the LP state machines, the
// byte alignment and the CSI-2 layer are in bow_csi2rx inside the SoC
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
  // D-PHY receive I/O (constr/kv260_cam.xdc refers to the instance name)
  // ---------------------------------------------------------------------------
  logic                     dphy_byte_clk, dphy_byte_ce, dphy_byte_rst, dphy_clk_hs_en;
  logic [1:0]               dphy_clk_lp;
  logic [CsiLanes-1:0][1:0] dphy_lp;
  logic [CsiLanes-1:0]      dphy_hs_en, dphy_dly_load;
  logic [CsiLanes-1:0][7:0] dphy_rx_data;
  logic [CsiLanes-1:0][8:0] dphy_dly_tap, dphy_dly_tap_out;

  bow_dphy_io_xusp #(
    .Lanes (CsiLanes)
  ) u_dphy (
    .clk_p       (mipi_phy_if_raspi_clk_p),
    .clk_n       (mipi_phy_if_raspi_clk_n),
    .data_p      (mipi_phy_if_raspi_data_p),
    .data_n      (mipi_phy_if_raspi_data_n),
    .byte_clk_o  (dphy_byte_clk),
    .byte_ce_i   (dphy_byte_ce),
    .byte_rst_i  (dphy_byte_rst),
    .clk_lp_o    (dphy_clk_lp),
    .clk_hs_en_i (dphy_clk_hs_en),
    .lp_o        (dphy_lp),
    .hs_en_i     (dphy_hs_en),
    .rx_data_o   (dphy_rx_data),
    .dly_tap_i   (dphy_dly_tap),
    .dly_load_i  (dphy_dly_load),
    .dly_tap_o   (dphy_dly_tap_out)
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
    .dphy_byte_clk_i  (dphy_byte_clk),
    .dphy_byte_ce_o   (dphy_byte_ce),
    .dphy_byte_rst_o  (dphy_byte_rst),
    .dphy_clk_lp_i    (dphy_clk_lp),
    .dphy_clk_hs_en_o (dphy_clk_hs_en),
    .dphy_lp_i        (dphy_lp),
    .dphy_hs_en_o     (dphy_hs_en),
    .dphy_rx_data_i   (dphy_rx_data),
    .dphy_dly_tap_o   (dphy_dly_tap),
    .dphy_dly_load_o  (dphy_dly_load),
    .dphy_dly_tap_i   (dphy_dly_tap_out),
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
