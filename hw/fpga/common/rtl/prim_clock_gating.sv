// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// FPGA implementation of the clock gate required by Ibex (see Ibex
// doc/02_user/integration.rst, "Primitives").
//
// Ibex gates its own clock while sleeping in WFI. On an FPGA the power saving
// is negligible, so by default the gate is a pass-through: the whole SoC then
// runs on one clock tree, which keeps timing closure simple. Define
// BOW32_FPGA_CLOCK_GATING to use a global clock buffer with enable (BUFGCE)
// instead.

module prim_clock_gating #(
  parameter bit NoFpgaGate    = 1'b0,
  parameter bit FpgaBufGlobal = 1'b1
) (
  input  logic clk_i,
  input  logic en_i,
  input  logic test_en_i,
  output logic clk_o
);

`ifdef BOW32_FPGA_CLOCK_GATING
  if (NoFpgaGate) begin : gen_no_gate
    assign clk_o = clk_i;
  end else begin : gen_gate
    BUFGCE #(
      .CE_TYPE ("SYNC")
    ) u_bufgce (
      .I  (clk_i),
      .CE (en_i | test_en_i),
      .O  (clk_o)
    );
  end
`else
  assign clk_o = clk_i;

  logic unused_en;
  assign unused_en = ^{en_i, test_en_i, NoFpgaGate, FpgaBufGlobal};
`endif

endmodule
