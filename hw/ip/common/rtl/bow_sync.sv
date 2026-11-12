// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Two flip-flop synchroniser for asynchronous single bit inputs (pins).
//
// Simulation only, `define BOW_SYNC_JITTER (the D-PHY bench hw/ip/dphy_rx/dv, not the other
// benches): an input that changed less than 0.5 ns before the clock edge (inside the window
// of a real flop's setup and hold time, and of the bus skew a constraint allows) resolves one
// cycle late at random, as a metastable flop may, so the bits of a bus of these synchronisers
// that change together can arrive one cycle apart (a bus that is not gray coded then shows
// values it never had).

module bow_sync #(
  parameter logic ResetValue = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic d_i,
  output logic q_o
);

`ifdef BOW_SYNC_JITTER
  timeunit 1ns;
  timeprecision 1ps;
`endif

  (* ASYNC_REG = "TRUE" *) logic [1:0] sync_q;

`ifndef BOW_SYNC_JITTER
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sync_q <= {2{ResetValue}};
    end else begin
      sync_q <= {sync_q[0], d_i};
    end
  end
`else
  logic    late_q;
  realtime t_chg = 0.0;

  always @(d_i) t_chg = $realtime;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sync_q <= {2{ResetValue}};
      late_q <= 1'b0;
    end else if ((d_i != sync_q[0]) && !late_q && ($realtime - t_chg < 0.5) &&
                 ($urandom_range(0, 1) == 1)) begin
      sync_q <= {sync_q[0], sync_q[0]};     // resolves one cycle late
      late_q <= 1'b1;
    end else begin
      sync_q <= {sync_q[0], d_i};
      late_q <= 1'b0;
    end
  end
`endif

  assign q_o = sync_q[1];

endmodule
