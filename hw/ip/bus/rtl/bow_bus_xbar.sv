// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 bus crossbar: NumHosts x NumDevices, address decoded.
//
// * Every device port has its own round-robin arbiter, so different hosts can
//   access different devices in the same cycle.
// * A request that matches no device is granted immediately and answered with
//   err = 1 in the next cycle (bus error -> access fault exception in Ibex).
// * Relies on the fixed single cycle response latency of the Bow32 bus (see
//   bow_bus_pkg): the response is routed using the device selection
//   registered at the time of the grant.
//
// Device d is selected when (addr & DevMask[d]) == DevBase[d]. Generate the
// parameters from the memory map (bow32_memmap_pkg) to guarantee that regions
// don't overlap.
//
// With NumHosts = 1 the crossbar degenerates into a simple address decoder /
// demultiplexer (used for the peripheral bus).

module bow_bus_xbar import bow_bus_pkg::*; #(
  parameter int unsigned                 NumHosts   = 2,
  parameter int unsigned                 NumDevices = 1,
  parameter logic [NumDevices-1:0][31:0] DevBase    = '0,
  parameter logic [NumDevices-1:0][31:0] DevMask    = '0
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,

  input  bus_req_t [NumHosts-1:0]   host_req_i,
  output bus_rsp_t [NumHosts-1:0]   host_rsp_o,

  output bus_req_t [NumDevices-1:0] dev_req_o,
  input  bus_rsp_t [NumDevices-1:0] dev_rsp_i
);

  // ---------------------------------------------------------------------------
  // 1. Address decode (per host)
  // ---------------------------------------------------------------------------
  logic [NumHosts-1:0][NumDevices-1:0] host_dev_sel;  // one-hot or zero
  logic [NumHosts-1:0]                 host_dec_err;  // request hits no device

  for (genvar h = 0; h < NumHosts; h++) begin : g_decode
    for (genvar d = 0; d < NumDevices; d++) begin : g_dev
      assign host_dev_sel[h][d] = host_req_i[h].req &&
                                  ((host_req_i[h].addr & DevMask[d]) == DevBase[d]);
    end
    assign host_dec_err[h] = host_req_i[h].req && !(|host_dev_sel[h]);
  end

  // ---------------------------------------------------------------------------
  // 2. Arbitration and request multiplexing (per device)
  // ---------------------------------------------------------------------------
  logic [NumDevices-1:0][NumHosts-1:0] dev_host_req;
  logic [NumDevices-1:0][NumHosts-1:0] dev_host_gnt;  // arbiter winner, one-hot

  for (genvar d = 0; d < NumDevices; d++) begin : g_arb
    for (genvar h = 0; h < NumHosts; h++) begin : g_req
      assign dev_host_req[d][h] = host_dev_sel[h][d];
    end

    bow_rr_arbiter #(
      .N (NumHosts)
    ) u_arb (
      .clk_i,
      .rst_ni,
      .req_i (dev_host_req[d]),
      .ack_i (dev_rsp_i[d].gnt),
      .gnt_o (dev_host_gnt[d])
    );

    // One-hot AND-OR multiplexer of the winning request.
    always_comb begin
      dev_req_o[d] = BUS_REQ_DEFAULT;
      for (int unsigned h = 0; h < NumHosts; h++) begin
        if (dev_host_gnt[d][h]) begin
          dev_req_o[d] = host_req_i[h];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 3. Grant and response routing (per host)
  // ---------------------------------------------------------------------------
  logic [NumHosts-1:0]                 host_gnt;
  logic [NumHosts-1:0]                 rsp_pend_q;
  logic [NumHosts-1:0]                 rsp_dec_err_q;
  logic [NumHosts-1:0][NumDevices-1:0] rsp_dev_sel_q;

  for (genvar h = 0; h < NumHosts; h++) begin : g_host
    logic [NumDevices-1:0] dev_gnt;
    for (genvar d = 0; d < NumDevices; d++) begin : g_gnt
      assign dev_gnt[d] = dev_host_gnt[d][h] & dev_rsp_i[d].gnt;
    end
    assign host_gnt[h] = host_dec_err[h] | (|dev_gnt);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rsp_pend_q[h]    <= 1'b0;
        rsp_dec_err_q[h] <= 1'b0;
        rsp_dev_sel_q[h] <= '0;
      end else begin
        rsp_pend_q[h] <= host_req_i[h].req & host_gnt[h];
        if (host_req_i[h].req & host_gnt[h]) begin
          rsp_dec_err_q[h] <= host_dec_err[h];
          rsp_dev_sel_q[h] <= host_dev_sel[h];
        end
      end
    end

    always_comb begin
      host_rsp_o[h]        = BUS_RSP_DEFAULT;
      host_rsp_o[h].gnt    = host_gnt[h];
      host_rsp_o[h].rvalid = rsp_pend_q[h];
      host_rsp_o[h].err    = rsp_pend_q[h] & rsp_dec_err_q[h];
      for (int unsigned d = 0; d < NumDevices; d++) begin
        if (rsp_dev_sel_q[h][d]) begin
          host_rsp_o[h].rdata = dev_rsp_i[d].rdata;
          host_rsp_o[h].err   = host_rsp_o[h].err | (rsp_pend_q[h] & dev_rsp_i[d].err);
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Protocol checks (simulation only)
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  for (genvar h = 0; h < NumHosts; h++) begin : g_chk
    // A device must answer exactly one cycle after it granted a request.
    always @(posedge clk_i) begin
      if (rst_ni && rsp_pend_q[h] && !rsp_dec_err_q[h]) begin
        for (int unsigned d = 0; d < NumDevices; d++) begin
          if (rsp_dev_sel_q[h][d] && !dev_rsp_i[d].rvalid) begin
            $error("bow_bus_xbar: device %0d did not respond one cycle after gnt", d);
          end
        end
      end
    end
  end
`endif

endmodule
