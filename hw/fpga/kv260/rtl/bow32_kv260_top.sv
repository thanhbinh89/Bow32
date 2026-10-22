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
// The other GPIO pins have no pad on this board: they read back the level the
// chip drives (0 when not driven).

module bow32_kv260_top #(
  parameter RomInitFile   = "",
  parameter FlashInitFile = ""
) (
  output logic       uart0_tx_o,
  input  logic       uart0_rx_i,
  inout  wire  [3:0] gpioa_io,   // PA0..PA3
  inout  wire  [1:0] gpiob_io,   // PB0/PB1
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

  assign gpioa_i[7:4] = gpioa_oe[7:4] & gpioa_o[7:4];
  assign gpiob_i[7:2] = gpiob_oe[7:2] & gpiob_o[7:2];

  // Keep the SOM fan running at full speed (the PL owns this pin).
  assign fan_en_b = 1'b0;

endmodule
