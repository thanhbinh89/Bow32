// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Pulse synchroniser between two clock domains (toggle + 3 flip-flops).
//
// Every single cycle pulse on src_pulse_i produces one single cycle pulse on
// dst_pulse_o, 2-3 destination clock cycles later. Pulses must be at least
// three destination clock cycles apart, otherwise they merge.
//
// Typical use: "start" commands from the CPU domain into a video domain and
// "done" events back. Multi-bit data that goes with the event must be held
// stable by the sender until the receiver has taken it (quasi-static data).

module bow_cdc_pulse (
  input  logic src_clk_i,
  input  logic src_rst_ni,
  input  logic src_pulse_i,

  input  logic dst_clk_i,
  input  logic dst_rst_ni,
  output logic dst_pulse_o
);

  logic src_toggle_q;

  always_ff @(posedge src_clk_i or negedge src_rst_ni) begin
    if (!src_rst_ni) begin
      src_toggle_q <= 1'b0;
    end else if (src_pulse_i) begin
      src_toggle_q <= ~src_toggle_q;
    end
  end

  (* ASYNC_REG = "TRUE" *) logic [1:0] sync_q;
  logic                               last_q;

  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) begin
    if (!dst_rst_ni) begin
      sync_q <= '0;
      last_q <= 1'b0;
    end else begin
      sync_q <= {sync_q[0], src_toggle_q};
      last_q <= sync_q[1];
    end
  end

  assign dst_pulse_o = sync_q[1] ^ last_q;

endmodule
