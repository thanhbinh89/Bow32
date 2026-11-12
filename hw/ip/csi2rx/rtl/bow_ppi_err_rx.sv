// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// PPI lp domain error signals as 2 bit gray counters, controller side
// (docs/ip/mipi_rx_arch.md, sections 4.11 and 5.3; v1.x, step 6 of section 10): the counters
// of the PHY's lp clock (bow_ppi_err_tx: ErrControl[l], ErrControlClk) sampled in the
// controller's clock clk_i through one synchroniser per bit (u_sync_err), compared with the
// sample before. ev_o[i] is a one cycle pulse whenever counter i changed: at least one event
// of the PHY. steps_o[i] is the number of steps between the two samples (1..3; a gray value
// read in the middle of a step is the old or the new one), for tests.
//
// Nothing is lost while a counter makes fewer than 4 steps between two samples: the PHY steps
// a counter at most once every 16 lp cycles, so the controller's clock must be at least
// lp_clk / 32 (bow_csi2rx checks it at elaboration). Different clocks need the gray buses
// within one lp clock period of skew (set_bus_skew on an FPGA, the SDC of an ASIC); with
// the same clock (Bow32's FPGA builds: lp_clk = vid_clk) the synchronisers are plain flops.

module bow_ppi_err_rx #(
  parameter int unsigned N = 1
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic [N-1:0][1:0] gray_i,   // the PHY's counters (asynchronous)
  output logic [N-1:0]      ev_o,     // pulse: the counter changed
  output logic [N-1:0][1:0] steps_o   // its steps since the sample before (0 without ev_o)
);

  logic [N-1:0][1:0] gray_s, last_q;

  bow_sync_bus #(
    .Width (2 * N)
  ) u_sync_err (
    .clk_i,
    .rst_ni,
    .d_i (gray_i),
    .q_o (gray_s)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) last_q <= '0;
    else         last_q <= gray_s;
  end

  // gray -> binary of a 2 bit counter: {g1, g1 ^ g0}
  function automatic logic [1:0] bin2(logic [1:0] g);
    return {g[1], g[1] ^ g[0]};
  endfunction

  always_comb begin
    for (int unsigned i = 0; i < N; i++) begin
      ev_o[i]    = (gray_s[i] != last_q[i]);
      steps_o[i] = bin2(gray_s[i]) - bin2(last_q[i]);
    end
  end

endmodule
