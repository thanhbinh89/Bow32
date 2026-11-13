// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// PPI lp domain error signals as 2 bit gray counters, PHY side (docs/ip/mipi_rx_arch.md,
// sections 4.9, 4.11 and 5.3; v1.x, step 6 of section 10): ErrControl[l], ErrControlClk,
// ErrEsc[l] of bow_dphy_rx, and the ErrControl pulses of a standard PHY in the flat-port
// wrapper bow_csi2rx_ppi_flat. The controller samples the counters in its own clock
// (bow_ppi_err_rx) and takes every change as at least one event, so nothing is lost on the
// crossing as long as a counter does not go round (4 steps) between two of its samples.
//
// One counter per signal (N of them), clock clk_i (the PHY's lp clock):
//   * ev_i[i] (one cycle pulses) counts only while en_i[i] = 1 (the lane's Enable: a
//     disabled lane reports nothing, and an event still waiting when it is disabled is
//     dropped); the D-PHY's own registers count every event, unmasked;
//   * a counter steps at most once every Hold cycles: an event while the counter rests
//     steps it at once (the cycle after the event pulse), events in the Hold - 1 cycles
//     after a step wait and step it once at the end of them (merged: the controller only
//     needs to know that there was at least one);
//   * gray_o[i]: the counter (a flop, gray coded: one bit changes per step), 0 after reset.
// With Hold = 16 a controller clock of at least clk_i / 32 never misses a step (bow_csi2rx
// checks the ratio of the two clocks at elaboration).

module bow_ppi_err_tx #(
  parameter int unsigned N    = 1,
  parameter int unsigned Hold = 16    // minimum cycles from one step of a counter to its next
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic [N-1:0]     ev_i,      // event pulses
  input  logic [N-1:0]     en_i,      // the signal's enable (Enable[l]); events count while 1
  output logic [N-1:0][1:0] gray_o    // 2 bit gray counters: 00 01 11 10 00 ...
);

  if ((Hold < 1) || (Hold > 64)) begin : g_bad_hold
    $error("bow_ppi_err_tx: Hold must be 1..64, not %0d", Hold);
  end

  localparam int unsigned HoldW = (Hold > 1) ? $clog2(Hold) : 1;

  logic [N-1:0]            pend_q, step;
  logic [N-1:0][HoldW-1:0] hold_q;
  logic [N-1:0][1:0]       gray_q;

  for (genvar i = 0; i < N; i++) begin : g_cnt
    assign step[i] = en_i[i] && (pend_q[i] || ev_i[i]) && (hold_q[i] == '0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        pend_q[i] <= 1'b0;
        hold_q[i] <= '0;
        gray_q[i] <= 2'b00;
      end else begin
        pend_q[i] <= en_i[i] && (pend_q[i] || ev_i[i]) && !step[i];
        if (step[i])                hold_q[i] <= HoldW'(Hold - 1);
        else if (hold_q[i] != '0)   hold_q[i] <= hold_q[i] - 1'b1;
        // gray increment of a 2 bit counter: 00 -> 01 -> 11 -> 10 -> 00
        if (step[i])                gray_q[i] <= {gray_q[i][0], ~gray_q[i][1]};
      end
    end
  end

  assign gray_o = gray_q;

endmodule
