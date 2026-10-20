// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Single port synchronous RAM, 32 bit wide with byte enables.
//
// Written in the coding style that Vivado (and most FPGA tools) infer as
// block RAM: registered read data (read-first) and per-byte write enables.
// The memory is initialised either from a $readmemh file (one 32 bit word per
// line) or with InitValue for every word.

module bow_ram_1p #(
  parameter int unsigned Depth       = 1024,
  parameter              MemInitFile = "",
  parameter logic [31:0] InitValue   = '0
) (
  input  logic                     clk_i,
  input  logic                     req_i,
  input  logic                     we_i,
  input  logic [3:0]               be_i,
  input  logic [$clog2(Depth)-1:0] addr_i,
  input  logic [31:0]              wdata_i,
  output logic [31:0]              rdata_o
);

  logic [31:0] mem [Depth];

  initial begin
    for (int unsigned i = 0; i < Depth; i++) begin
      mem[i] = InitValue;
    end
    if (MemInitFile != "") begin
`ifndef SYNTHESIS
      $display("%m: loading %0s", MemInitFile);
`endif
      $readmemh(MemInitFile, mem);
    end
  end

  always_ff @(posedge clk_i) begin
    if (req_i) begin
      if (we_i) begin
        for (int unsigned b = 0; b < 4; b++) begin
          if (be_i[b]) begin
            mem[addr_i][b*8 +: 8] <= wdata_i[b*8 +: 8];
          end
        end
      end
      rdata_o <= mem[addr_i];
    end
  end

endmodule
