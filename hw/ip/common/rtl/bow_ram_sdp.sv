// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Simple dual port RAM: one write port, one read port, independent clocks.
//
// Written in the style that Vivado infers as block RAM (or LUT RAM for small
// sizes). The read data is registered (one cycle latency) and only updated
// when re_i is high. Reading and writing the same address in the same cycle
// returns the old contents when both ports use the same clock; with
// different clocks the result is undefined (as for any dual clock RAM).

module bow_ram_sdp #(
  parameter int unsigned Width = 32,
  parameter int unsigned Depth = 1024
) (
  input  logic                     wclk_i,
  input  logic                     we_i,
  input  logic [$clog2(Depth)-1:0] waddr_i,
  input  logic [Width-1:0]         wdata_i,

  input  logic                     rclk_i,
  input  logic                     re_i,
  input  logic [$clog2(Depth)-1:0] raddr_i,
  output logic [Width-1:0]         rdata_o
);

  logic [Width-1:0] mem [Depth];

  initial begin
    for (int unsigned i = 0; i < Depth; i++) begin
      mem[i] = '0;
    end
  end

  always_ff @(posedge wclk_i) begin
    if (we_i) begin
      mem[waddr_i] <= wdata_i;
    end
  end

  always_ff @(posedge rclk_i) begin
    if (re_i) begin
      rdata_o <= mem[raddr_i];
    end
  end

endmodule
