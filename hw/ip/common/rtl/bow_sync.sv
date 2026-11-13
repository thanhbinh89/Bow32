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
// values it never had). The time of the last change comes from an edge form of the input
// (Verilator 5.020 never wakes an always @(d_i) after time 0: a level form left the window
// closed for good). The bench's clocks must not be multiples of each other, or no edge ever
// falls inside the window. Every such change and every late resolution of the simulation is
// counted in bow_sync_jitter_pkg: a bench built with the define fails when no synchroniser
// resolved late (the model then tested nothing).

`ifdef BOW_SYNC_JITTER
package bow_sync_jitter_pkg;
  int unsigned n_window = 0;   // inputs that changed inside the window before a clock edge
  int unsigned n_late   = 0;   // ... and resolved one cycle late
endpackage
`endif

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
  realtime t_chg = -1.0;     // time of the last change of d_i (-1: none yet)

  always @(posedge d_i or negedge d_i) t_chg = $realtime;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sync_q <= {2{ResetValue}};
      late_q <= 1'b0;
    end else if ((d_i != sync_q[0]) && !late_q && (t_chg >= 0.0) && ($realtime - t_chg < 0.5)) begin
      bow_sync_jitter_pkg::n_window++;
      if ($urandom_range(0, 1) == 1) begin
        sync_q <= {sync_q[0], sync_q[0]};   // resolves one cycle late
        late_q <= 1'b1;
        bow_sync_jitter_pkg::n_late++;
      end else begin
        sync_q <= {sync_q[0], d_i};
        late_q <= 1'b0;
      end
    end else begin
      sync_q <= {sync_q[0], d_i};
      late_q <= 1'b0;
    end
  end
`endif

  assign q_o = sync_q[1];

endmodule
