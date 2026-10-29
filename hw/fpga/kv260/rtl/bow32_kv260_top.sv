// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 on the AMD Kria KV260 Vision AI Starter Kit (K26 SOM).
//
// Clock/reset come from the Zynq UltraScale+ processing system (block design
// "bow32_ps", see tcl/ps_bd.tcl):
//   pl_clk0    100 MHz  -> BUFGCE_DIV /2 -> 50 MHz SoC clock
//   pl_resetn0          -> SoC power-on reset
// UART0 and six GPIO pads are on the PMOD connector J2 (constr/kv260.xdc):
//   PA0..PA3  J2 pins 2/4/6/8
//   PB0/PB1   J2 pins 5/7, UART1 TX/RX after reset (GPIOB.AF)
// Raspberry Pi camera connector J9 (control only, see docs/camera_kv260.md):
//   PA7       RPI_ENABLE (camera power/enable, 1 = on)
//   I2C0      PL I2C -> TCA9546A switch (0x74), channel 2 = camera
// The other GPIO pins have no pad on this board: they read back the level the
// chip drives (0 when not driven).
//
// This build has no MIPI CSI-2 receiver (see hw/fpga/kv260_cam): the camera
// input of the ISP is idle (use its test pattern generator), the ISP runs on
// the SoC clock and the AXI4-Lite window answers every access with a bus
// error after the bridge timeout.

module bow32_kv260_top #(
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
  output logic       fan_en_b    // SOM fan control, active low
);

  localparam int unsigned PlClkHz  = 100_000_000;
  localparam int unsigned SysClkHz = PlClkHz / 2;

  // ---------------------------------------------------------------------------
  // Processing system: clock and reset only
  // ---------------------------------------------------------------------------
  logic pl_clk0, pl_resetn0;

  bow32_ps_wrapper u_ps (
    .pl_clk0    (pl_clk0),
    .pl_resetn0 (pl_resetn0)
  );

  logic clk_sys;

  BUFGCE_DIV #(
    .BUFGCE_DIVIDE (2)
  ) u_clk_div (
    .I   (pl_clk0),
    .CE  (1'b1),
    .CLR (1'b0),
    .O   (clk_sys)
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
    .rst_ni       (pl_resetn0),
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
    // no camera receiver: ISP on the SoC clock, input idle, output sink
    .vid_clk_i    (clk_sys),
    .vid_rst_ni   (pl_resetn0),
    .cam_tvalid_i (1'b0),
    .cam_tready_o (),
    .cam_tdata_i  ('0),
    .cam_tuser_i  (1'b0),
    .cam_tlast_i  (1'b0),
    .isp_tvalid_o (),
    .isp_tready_i (1'b1),
    .isp_tdata_o  (),
    .isp_tuser_o  (),
    .isp_tlast_o  (),
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
  // GPIO pads
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

  // I2C: open drain, the pad only ever drives 0
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
  assign gpiob_i[7:2] = gpiob_oe[7:2] & gpiob_o[7:2];

  // Keep the SOM fan running at full speed (the PL owns this pin).
  assign fan_en_b = 1'b0;

endmodule
