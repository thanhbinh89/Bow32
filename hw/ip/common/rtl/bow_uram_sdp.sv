// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Simple dual port RAM, one clock, read latency 2, written in the style that
// Vivado maps onto UltraRAM (UltraScale+): the first read register is the
// URAM output register, the second its pipeline register. The read port reads
// every cycle (rdata_o = mem[raddr_i of two cycles before]); reading the
// address written in the same cycle returns the old contents.
//
// UltraRAM cannot be initialised: the contents after configuration are zero.
// Simulation starts with zeros as well.

module bow_uram_sdp #(
  parameter int unsigned Width = 64,
  parameter int unsigned Depth = 4096
) (
  input  logic                     clk_i,
  input  logic                     we_i,
  input  logic [$clog2(Depth)-1:0] waddr_i,
  input  logic [Width-1:0]         wdata_i,
  input  logic [$clog2(Depth)-1:0] raddr_i,
  output logic [Width-1:0]         rdata_o
);

  (* ram_style = "ultra" *) logic [Width-1:0] mem [Depth];
  logic [Width-1:0] q1, q2;

`ifndef SYNTHESIS
  initial begin
    for (int unsigned i = 0; i < Depth; i++) begin
      mem[i] = '0;
    end
  end
`endif

  always_ff @(posedge clk_i) begin
    if (we_i) begin
      mem[waddr_i] <= wdata_i;
    end
    q1 <= mem[raddr_i];
    q2 <= q1;
  end

  assign rdata_o = q2;

endmodule
