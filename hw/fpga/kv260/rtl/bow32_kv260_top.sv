// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 on the AMD Kria KV260 Vision AI Starter Kit (K26 SOM).
//
// Clock/reset come from the Zynq UltraScale+ processing system (block design
// "bow32_ps", see tcl/ps_bd.tcl):
//   pl_clk0    100 MHz  -> BUFGCE_DIV /2 -> 50 MHz SoC clock
//   pl_resetn0          -> SoC power-on reset
// The UARTs are on the PMOD connector J2 (constr/kv260.xdc).

module bow32_kv260_top #(
  parameter RomInitFile   = "",
  parameter FlashInitFile = ""
) (
  output logic uart0_tx_o,
  input  logic uart0_rx_i,
  output logic uart1_tx_o,
  input  logic uart1_rx_i,
  output logic fan_en_b      // SOM fan control, active low
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
    .uart1_rx_i,
    .uart1_tx_o,
    .sys_rst_no   (),
    .core_sleep_o ()
  );

  // Keep the SOM fan running at full speed (the PL owns this pin).
  assign fan_en_b = 1'b0;

endmodule
