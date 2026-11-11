// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// A bus of independent bow_sync synchronisers. The bits are not sampled
// together, so only for data that is quasi-static (changes while the
// receiver does not use it) or gray coded (one bit changes at a time, with
// a bus skew constraint on the path).
//
// Cell names: bit i is g_bit[i].u_sync, its first flop g_bit[i].u_sync/
// sync_q_reg[0]. FPGA constraints (set_bus_skew) and the reviewed CDC lists
// select the destination flops by these names.

module bow_sync_bus #(
  parameter int unsigned      Width      = 1,
  parameter logic [Width-1:0] ResetValue = '0
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic [Width-1:0] d_i,
  output logic [Width-1:0] q_o
);

  for (genvar i = 0; i < Width; i++) begin : g_bit
    bow_sync #(
      .ResetValue (ResetValue[i])
    ) u_sync (
      .clk_i,
      .rst_ni,
      .d_i (d_i[i]),
      .q_o (q_o[i])
    );
  end

endmodule
