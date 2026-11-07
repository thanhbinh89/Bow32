// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Event + data across two clock domains by handshake: a request toggle goes
// to the destination, an acknowledge toggle comes back (2 flip-flop
// synchronisers each way).
//
// Unlike bow_cdc_pulse this works for any ratio of the two clocks and never
// loses or merges a transfer: the source offers one with src_valid_i, it is
// taken in a cycle where src_ready_o is high (the previous transfer has been
// acknowledged), and the data register holds it until the destination has
// it. The destination gets a one cycle dst_valid_o pulse; dst_data_o is
// valid with it and stays until the next pulse.
//
// One transfer per round trip (about 3 destination + 3 source cycles): events
// that come faster are merged by the user in the source domain while
// src_ready_o is low (sticky flags, the newest value of a register).
//
// Static timing: data_q only changes together with the request toggle, at
// least two destination clock cycles before the destination samples it, so
// it is a quasi-static bus like the configuration registers (no gray code,
// no bus skew constraint).
//
// Reset rule (as bow_fifo_async): src_rst_ni and dst_rst_ni must be asserted
// together, each released synchronously to its own clock. A side reset alone
// leaves the request and acknowledge toggles out of step.

module bow_cdc_hs #(
  parameter int unsigned Width = 8
) (
  input  logic             src_clk_i,
  input  logic             src_rst_ni,
  input  logic             src_valid_i,
  output logic             src_ready_o,
  input  logic [Width-1:0] src_data_i,

  input  logic             dst_clk_i,
  input  logic             dst_rst_ni,
  output logic             dst_valid_o,
  output logic [Width-1:0] dst_data_o
);

  logic ack_q;

  // ---------------------------------------------------------------- source
  logic                               req_q;
  logic [Width-1:0]                   data_q;
  (* ASYNC_REG = "TRUE" *) logic [1:0] ack_sync_q;

  assign src_ready_o = (req_q == ack_sync_q[1]);

  always_ff @(posedge src_clk_i or negedge src_rst_ni) begin
    if (!src_rst_ni) begin
      req_q      <= 1'b0;
      data_q     <= '0;
      ack_sync_q <= '0;
    end else begin
      ack_sync_q <= {ack_sync_q[0], ack_q};
      if (src_valid_i && src_ready_o) begin
        req_q  <= ~req_q;
        data_q <= src_data_i;
      end
    end
  end

  // ----------------------------------------------------------- destination
  (* ASYNC_REG = "TRUE" *) logic [1:0] req_sync_q;
  logic                               new_req;

  assign new_req = (req_sync_q[1] != ack_q);

  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) begin
    if (!dst_rst_ni) begin
      req_sync_q  <= '0;
      ack_q       <= 1'b0;
      dst_valid_o <= 1'b0;
      dst_data_o  <= '0;
    end else begin
      req_sync_q  <= {req_sync_q[0], req_q};
      ack_q       <= req_sync_q[1];
      dst_valid_o <= new_req;
      if (new_req) dst_data_o <= data_q;
    end
  end

endmodule
