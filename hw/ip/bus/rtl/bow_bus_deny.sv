// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bus firewall in front of one host: a request to the window
// (addr & DenyMask) == DenyBase never reaches the crossbar. It is granted
// at once and answered one cycle later with err = 1 and rdata = 0, as for
// an address without a device (docs/bus.md). Everything else passes through.
//
// Bow32 puts one in front of the DMA so that it cannot use the MKV block
// cipher (key registers, encryption / decryption on behalf of the CPU).

module bow_bus_deny import bow_bus_pkg::*; #(
  parameter logic [31:0] DenyBase = 32'h0,
  parameter logic [31:0] DenyMask = 32'hffff_ffff
) (
  input  logic     clk_i,
  input  logic     rst_ni,

  input  bus_req_t host_req_i,
  output bus_rsp_t host_rsp_o,

  output bus_req_t dev_req_o,
  input  bus_rsp_t dev_rsp_i
);

  logic deny, deny_q;
  assign deny = host_req_i.req && ((host_req_i.addr & DenyMask) == DenyBase);

  always_comb begin
    dev_req_o = host_req_i;
    if (deny) dev_req_o.req = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) deny_q <= 1'b0;
    else         deny_q <= deny;
  end

  // A denied request is granted here, so the crossbar has no response for
  // this host in the next cycle: the two never meet.
  always_comb begin
    host_rsp_o = dev_rsp_i;
    if (deny) host_rsp_o.gnt = 1'b1;
    if (deny_q) begin
      host_rsp_o.rvalid = 1'b1;
      host_rsp_o.err    = 1'b1;
      host_rsp_o.rdata  = '0;
    end
  end

endmodule
