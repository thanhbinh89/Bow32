// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Video RAM: large Bow32 bus device, zero wait states (like bow_sram), for
// DMA buffers (the H.264 stream). 64 bit words with 8 byte enables, written
// in the style that Vivado maps onto UltraRAM (UltraScale+, 4K x 72 bit per
// block: 1 MiB = 32 blocks); a 32 bit bus access selects one half.
// UltraRAM is not initialised by the bitstream: zero after configuration,
// kept over a reset of the SoC.

module bow_vram import bow_bus_pkg::*; #(
  parameter int unsigned SizeBytes = 1024 * 1024
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  input  bus_req_t bus_req_i,
  output bus_rsp_t bus_rsp_o
);

  localparam int unsigned Depth = SizeBytes / 8;
  localparam int unsigned AW    = $clog2(Depth);

  (* ram_style = "ultra" *) logic [63:0] mem [Depth];

`ifndef SYNTHESIS
  initial begin
    for (int unsigned i = 0; i < Depth; i++) begin
      mem[i] = '0;
    end
  end
`endif

  logic [AW-1:0] addr;
  logic          half, half_q, rvalid_q;
  logic [7:0]    we8;
  logic [63:0]   wdata64, q;

  assign addr    = bus_req_i.addr[AW+2:3];
  assign half    = bus_req_i.addr[2];
  assign we8     = (bus_req_i.req && bus_req_i.we) ? (half ? {bus_req_i.be, 4'b0} : {4'b0, bus_req_i.be})
                                                   : 8'h00;
  assign wdata64 = {bus_req_i.wdata, bus_req_i.wdata};

  always_ff @(posedge clk_i) begin
    for (int unsigned b = 0; b < 8; b++) begin
      if (we8[b]) mem[addr][8 * b +: 8] <= wdata64[8 * b +: 8];
    end
    if (bus_req_i.req && !bus_req_i.we) q <= mem[addr];   // UltraRAM: no change on a write
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      half_q   <= 1'b0;
    end else begin
      rvalid_q <= bus_req_i.req;
      if (bus_req_i.req) half_q <= half;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = half_q ? q[63:32] : q[31:0];

  logic unused_addr;
  assign unused_addr = ^{bus_req_i.addr[31:AW+3], bus_req_i.addr[1:0]};

endmodule
