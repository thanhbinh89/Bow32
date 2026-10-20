// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Boot ROM: Bow32 bus device initialised from a $readmemh file at
// elaboration time (simulation) or bitstream generation time (FPGA).
// Writes are answered with a bus error.

module bow_rom import bow_bus_pkg::*; #(
  parameter int unsigned SizeBytes   = 8 * 1024,
  parameter              MemInitFile = ""
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  input  bus_req_t bus_req_i,
  output bus_rsp_t bus_rsp_o
);

  localparam int unsigned Depth     = SizeBytes / 4;
  localparam int unsigned AddrWidth = $clog2(Depth);

  logic        rvalid_q, err_q;
  logic [31:0] rdata;

  bow_ram_1p #(
    .Depth       (Depth),
    .MemInitFile (MemInitFile)
  ) u_rom (
    .clk_i,
    .req_i   (bus_req_i.req & ~bus_req_i.we),
    .we_i    (1'b0),
    .be_i    (4'b0),
    .addr_i  (bus_req_i.addr[AddrWidth+1:2]),
    .wdata_i ('0),
    .rdata_o (rdata)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      err_q    <= 1'b0;
    end else begin
      rvalid_q <= bus_req_i.req;
      err_q    <= bus_req_i.req & bus_req_i.we;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = err_q;
  assign bus_rsp_o.rdata  = rdata;

  logic unused_bus;
  assign unused_bus = ^{bus_req_i.addr[31:AddrWidth+2], bus_req_i.addr[1:0],
                        bus_req_i.be, bus_req_i.wdata};

endmodule
