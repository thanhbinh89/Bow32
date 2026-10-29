// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 + camera on the AMD Kria KV260: Raspberry Pi camera v2 (IMX219) on
// connector J9 -> AMD MIPI CSI-2 RX Subsystem -> Bow32 ISP.
//
// The block design "bow32_cam" (tcl/cam_bd.tcl) holds the Xilinx IP:
//   Zynq UltraScale+ PS   pl_clk0 100 MHz, pl_resetn0
//   clk_wiz               200 MHz (D-PHY reference + video), 50 MHz (SoC)
//   proc_sys_reset x 2    resets of the two clock domains
//   MIPI CSI-2 RX         2 lanes, 912 Mbit/s per lane, RAW10, 1 pixel/clock
// Its wrapper bow32_cam_wrapper exports the clocks, the RAW10 AXI4-Stream
// (cam_axis_*) and the AXI4-Lite registers of the receiver (csi_axil_*),
// which Bow32 reaches through its AXI4-Lite window at 0x5000_0000.
//
// Everything else is the same as hw/fpga/kv260 (UART0, GPIO, camera enable
// on PA7, I2C0 to the camera, constr/kv260.xdc of that board directory).
// The MIPI CSI-2 receiver is a temporary vendor block: a Bow32 receiver is
// planned (docs/roadmap.md).

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

  // ---------------------------------------------------------------------------
  // Block design: PS, clocks, resets, MIPI CSI-2 RX
  // ---------------------------------------------------------------------------
  logic        clk_sys, clk_vid, rst_sys_n, rst_vid_n;

  // RAW10 stream: pixel in tdata[9:0] (1 pixel/clock), tuser[0] = start of
  // frame, tlast = end of line. tdest (virtual channel) is not used.
  logic [15:0] cam_tdata;
  logic [0:0]  cam_tuser;
  logic        cam_tvalid, cam_tready, cam_tlast;

  // AXI4-Lite registers of the CSI-2 RX subsystem (13 bit address)
  logic [15:0] axil_awaddr, axil_araddr;
  logic        axil_awvalid, axil_awready, axil_wvalid, axil_wready;
  logic [31:0] axil_wdata, axil_rdata;
  logic [3:0]  axil_wstrb;
  logic [1:0]  axil_bresp, axil_rresp;
  logic        axil_bvalid, axil_bready, axil_arvalid, axil_arready, axil_rvalid, axil_rready;

  bow32_cam_wrapper u_bd (
    .sys_clk                  (clk_sys),
    .sys_resetn               (rst_sys_n),
    .vid_clk                  (clk_vid),
    .vid_resetn               (rst_vid_n),

    .mipi_phy_if_raspi_clk_p  (mipi_phy_if_raspi_clk_p),
    .mipi_phy_if_raspi_clk_n  (mipi_phy_if_raspi_clk_n),
    .mipi_phy_if_raspi_data_p (mipi_phy_if_raspi_data_p),
    .mipi_phy_if_raspi_data_n (mipi_phy_if_raspi_data_n),

    .cam_axis_tdata           (cam_tdata),
    .cam_axis_tuser           (cam_tuser),
    .cam_axis_tlast           (cam_tlast),
    .cam_axis_tvalid          (cam_tvalid),
    .cam_axis_tready          (cam_tready),

    .csi_axil_awaddr          (axil_awaddr[12:0]),
    .csi_axil_awvalid         (axil_awvalid),
    .csi_axil_awready         (axil_awready),
    .csi_axil_wdata           (axil_wdata),
    .csi_axil_wstrb           (axil_wstrb),
    .csi_axil_wvalid          (axil_wvalid),
    .csi_axil_wready          (axil_wready),
    .csi_axil_bresp           (axil_bresp),
    .csi_axil_bvalid          (axil_bvalid),
    .csi_axil_bready          (axil_bready),
    .csi_axil_araddr          (axil_araddr[12:0]),
    .csi_axil_arvalid         (axil_arvalid),
    .csi_axil_arready         (axil_arready),
    .csi_axil_rdata           (axil_rdata),
    .csi_axil_rresp           (axil_rresp),
    .csi_axil_rvalid          (axil_rvalid),
    .csi_axil_rready          (axil_rready)
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
    .IbexRegFile   (ibex_pkg::RegFileFPGA)
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
    .cam_tvalid_i (cam_tvalid),
    .cam_tready_o (cam_tready),
    .cam_tdata_i  (cam_tdata[9:0]),
    .cam_tuser_i  (cam_tuser[0]),
    .cam_tlast_i  (cam_tlast),
    // no video output yet (a display path can be added here)
    .isp_tvalid_o (),
    .isp_tready_i (1'b1),
    .isp_tdata_o  (),
    .isp_tuser_o  (),
    .isp_tlast_o  (),
    .m_axil_awaddr_o  (axil_awaddr),
    .m_axil_awprot_o  (),
    .m_axil_awvalid_o (axil_awvalid),
    .m_axil_awready_i (axil_awready),
    .m_axil_wdata_o   (axil_wdata),
    .m_axil_wstrb_o   (axil_wstrb),
    .m_axil_wvalid_o  (axil_wvalid),
    .m_axil_wready_i  (axil_wready),
    .m_axil_bresp_i   (axil_bresp),
    .m_axil_bvalid_i  (axil_bvalid),
    .m_axil_bready_o  (axil_bready),
    .m_axil_araddr_o  (axil_araddr),
    .m_axil_arprot_o  (),
    .m_axil_arvalid_o (axil_arvalid),
    .m_axil_arready_i (axil_arready),
    .m_axil_rdata_i   (axil_rdata),
    .m_axil_rresp_i   (axil_rresp),
    .m_axil_rvalid_i  (axil_rvalid),
    .m_axil_rready_o  (axil_rready),
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
