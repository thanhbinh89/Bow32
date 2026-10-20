// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// On-chip SRAM: Bow32 bus device, zero wait states.

module bow_sram import bow_bus_pkg::*; #(
  parameter int unsigned SizeBytes   = 16 * 1024,
  parameter              MemInitFile = ""
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  input  bus_req_t bus_req_i,
  output bus_rsp_t bus_rsp_o
);

  localparam int unsigned Depth     = SizeBytes / 4;
  localparam int unsigned AddrWidth = $clog2(Depth);

  logic        rvalid_q;
  logic [31:0] rdata;

  bow_ram_1p #(
    .Depth       (Depth),
    .MemInitFile (MemInitFile)
  ) u_ram (
    .clk_i,
    .req_i   (bus_req_i.req),
    .we_i    (bus_req_i.we),
    .be_i    (bus_req_i.be),
    .addr_i  (bus_req_i.addr[AddrWidth+1:2]),
    .wdata_i (bus_req_i.wdata),
    .rdata_o (rdata)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
    end else begin
      rvalid_q <= bus_req_i.req;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = rdata;

  logic unused_addr;
  assign unused_addr = ^{bus_req_i.addr[31:AddrWidth+2], bus_req_i.addr[1:0]};

endmodule
