// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Clock model of the HyperRAM clocking of a board top (working spec 3, the
// MMCMs of the board top): hr_clk (controller clock at the CK rate, phase 0;
// also PSCLK of both fine phase shift ports), wclk (write clock: hr_clk + T/4
// at write phase 0, fine phase shift port wps_*; the pad wrapper clocks the
// DQ / RWDS output ODDRs with ~wclk, i.e. they sample at hr_clk + 3T/4) and
// rd_clk (read capture clock, its own fine phase shift port ps_*, any start
// phase). Runs in Verilator (--timing) and xsim.
//
//   * Every clock runs from its own loop with half period T/2 (TckPs / 2).
//     After en_i rises, hr_clk_o starts T/8 later (no edge is ever at time
//     0), wclk_o T/8 + T/4 later, rd_clk_o T/8 + P0 later. P0, the read clock
//     start phase, is drawn once per run uniformly in [0, T)
//     (+hyperram_clk_seed=<n>, default 1; +hyperram_rd_phase_ps=<n> sets it):
//     a testbench has to calibrate the read capture phase as the hardware
//     does. No delay is ever 0 or negative (edge times are kept as exact
//     reals, every wait is rounded to >= 1 ps).
//   * Fine phase shift (MMCME4_ADV): PSCLK = hr_clk_o. ps_en_i (one cycle)
//     sampled high at an hr_clk_o posedge moves rd_clk_o by one step of
//     T / PsSteps: the next high phase of rd_clk_o is lengthened (ps_inc_i =
//     1, clock later) or shortened (ps_inc_i = 0). ps_done_o is high for one
//     hr_clk cycle, PsDoneLat (12) cycles after the PSEN cycle. A PSEN while
//     a step is still running or before locked_o is ignored (counted in
//     ps_ignored, with a warning when running). wps_*: the same for wclk_o
//     (wps_ignored).
//   * en_i = 0 stops all clocks low after the current period and drops
//     locked_o; when en_i rises again the MMCMs restart: the write phase back
//     to 0, rd_clk_o back to its start phase P0, locked_o after LockCycles
//     hr_clk cycles.
//   * Status for the testbench: ps_phase / wps_phase (signed steps since the
//     last start), ps_steps / wps_steps (PSEN accepted), ps_ignored /
//     wps_ignored, rd_start_ps (P0); rd_phase_ps() / w_phase_ps() = the
//     current phase of rd_clk_o / wclk_o after hr_clk_o in [0, T).
//   * Test hook `freeze` (set hierarchically by a testbench): hr_clk_o stops
//     low before its next rising edge while locked_o stays 1 (the controller
//     clock lost without a loss of lock); wclk_o and rd_clk_o run on. Clear
//     it after an MMCM restart (en_i low) for aligned clocks again.
//   * Not inlined (no_inline_module): Verilator before 5.022 (Ubuntu 24.04
//     and the CI have 5.020) gives the delays of an inlined module the time
//     unit of the module it is inlined into (verilator/verilator#4806), while
//     $realtime keeps this module's 1 ps. Every hr_clk rising edge checks its
//     time against the computed one (fatal error when a delay is scaled
//     wrongly).

`timescale 1ps / 1ps

// behavioural model: blocking assignments in edge processes are intended
/* verilator lint_off BLKSEQ */
module hyperram_clk_model #(
  parameter int unsigned TckPs      = 10000,  // CK period (hr_clk, wclk, rd_clk)
  parameter int unsigned PsSteps    = 672,    // fine steps per CK period (MMCME4: 56 * divide)
  parameter int unsigned LockCycles = 16,
  parameter int unsigned PsDoneLat  = 12
) (
  input  logic en_i,
  output logic hr_clk_o,
  output logic wclk_o,
  output logic rd_clk_o,
  output logic locked_o,
  input  logic ps_en_i,
  input  logic ps_inc_i,
  output logic ps_done_o,
  input  logic wps_en_i,
  input  logic wps_inc_i,
  output logic wps_done_o
);

  // delays in this module's 1 ps whatever the parent's unit (see the header)
  /* verilator no_inline_module */

  localparam real T    = real'(TckPs);
  localparam real Step = real'(TckPs) / real'(PsSteps);

  // ------------------------------------------------------------- status
  int  ps_phase = 0, wps_phase = 0;
  int  ps_steps = 0, wps_steps = 0;
  int  ps_ignored = 0, wps_ignored = 0;
  real rd_start_ps = 0.0;

  // phase adjustments waiting for the next high phase of each clock
  real adj_rd = 0.0, adj_w = 0.0;

  function automatic real wrap_t(real p);
    real r;
    r = p;
    while (r < 0.0) r += T;
    while (r >= T) r -= T;
    return r;
  endfunction

  // current phase of rd_clk_o / wclk_o after hr_clk_o, in [0, T)
  function automatic real rd_phase_ps();
    return wrap_t(rd_start_ps + real'(ps_phase) * Step);
  endfunction

  function automatic real w_phase_ps();
    return wrap_t(T / 4.0 + real'(wps_phase) * Step);
  endfunction

  // every wait: until the absolute time t (ps), at least 1 ps (computed into a
  // variable: no function call inside a delay expression)

  // --------------------------------------------------------------- clocks
  bit freeze = 1'b0;

  initial begin : g_hr_clk
    real t, d, now;
    hr_clk_o = 1'b0;
    forever begin
      while (!en_i) @(posedge en_i);
      t = $realtime + T / 8.0;
      while (en_i) begin
        if (freeze) begin                  // stopped low, locked_o unchanged
          while (freeze && en_i) @(freeze or en_i);
          if (!en_i) break;
          t = $realtime + T / 8.0;
        end
        d = t - $realtime;
        if (d < 1.0) d = 1.0;
        #(d);
        now = $realtime;                   // the wait ends within 1 ps of t
        if (now > t + 1.0 || now < t - 1.0) begin
          $fatal(1, "%m: hr_clk edge at %0.1f ps instead of %0.1f ps: delays scaled wrongly (header)",
                 now, t);
        end
        hr_clk_o = 1'b1;
        t += T / 2.0;
        d = t - $realtime;
        if (d < 1.0) d = 1.0;
        #(d) hr_clk_o = 1'b0;
        t += T / 2.0;
      end
    end
  end

  initial begin : g_rd_clk
    real         t, d;
    int unsigned sd, rng;
    int          fixed;
    rd_clk_o = 1'b0;
    // start phase P0 (xorshift32: the same draw in every simulator)
    sd = 1;
    void'($value$plusargs("hyperram_clk_seed=%d", sd));
    rng = sd ^ 32'h2545_F491;
    if (rng == 0) rng = 1;
    for (int k = 0; k < 9; k++) begin
      rng ^= rng << 13;
      rng ^= rng >> 17;
      rng ^= rng << 5;
    end
    rd_start_ps = T * (real'(rng) / 4294967296.0);
    if ($value$plusargs("hyperram_rd_phase_ps=%d", fixed)) rd_start_ps = wrap_t(real'(fixed));
    forever begin
      while (!en_i) @(posedge en_i);
      t = $realtime + T / 8.0 + rd_start_ps;
      while (en_i) begin
        d = t - $realtime;
        if (d < 1.0) d = 1.0;
        #(d) rd_clk_o = 1'b1;
        t += T / 2.0 + adj_rd;
        adj_rd = 0.0;
        d = t - $realtime;
        if (d < 1.0) d = 1.0;
        #(d) rd_clk_o = 1'b0;
        t += T / 2.0;
      end
    end
  end

  initial begin : g_wclk
    real t, d;
    wclk_o = 1'b0;
    forever begin
      while (!en_i) @(posedge en_i);
      t = $realtime + T / 8.0 + T / 4.0;
      while (en_i) begin
        d = t - $realtime;
        if (d < 1.0) d = 1.0;
        #(d) wclk_o = 1'b1;
        t += T / 2.0 + adj_w;
        adj_w = 0.0;
        d = t - $realtime;
        if (d < 1.0) d = 1.0;
        #(d) wclk_o = 1'b0;
        t += T / 2.0;
      end
    end
  end

  // ------------------------------------------------------- lock, restart
  int unsigned lock_cnt = 0;
  initial locked_o = 1'b0;
  always @(posedge hr_clk_o or negedge en_i) begin
    if (!en_i) begin
      locked_o <= 1'b0;
      lock_cnt  = 0;
    end else if (!locked_o) begin
      lock_cnt++;
      if (lock_cnt >= LockCycles) locked_o <= 1'b1;
    end
  end

  always @(posedge en_i) begin           // MMCM restart: fine phases back to the start
    ps_phase  = 0;
    wps_phase = 0;
    adj_rd    = 0.0;
    adj_w     = 0.0;
  end

  // ---------------------------------------------------- phase shift ports
  int unsigned ps_cnt = 0, wps_cnt = 0;
  initial begin
    ps_done_o  = 1'b0;
    wps_done_o = 1'b0;
  end

  always @(posedge hr_clk_o or negedge en_i) begin
    if (!en_i) begin
      ps_cnt    = 0;
      ps_done_o <= 1'b0;
    end else begin
      ps_done_o <= 1'b0;
      if (ps_cnt != 0) begin
        ps_cnt--;
        if (ps_cnt == 0) ps_done_o <= 1'b1;
        if (ps_en_i) begin
          ps_ignored++;
          $warning("%m: PSEN while a read phase step is running (ignored)");
        end
      end else if (ps_en_i) begin
        if (!locked_o) begin
          ps_ignored++;
        end else begin
          adj_rd   += ps_inc_i ? Step : -Step;
          ps_phase += ps_inc_i ? 1 : -1;
          ps_steps++;
          ps_cnt = PsDoneLat - 1;
        end
      end
    end
  end

  always @(posedge hr_clk_o or negedge en_i) begin
    if (!en_i) begin
      wps_cnt    = 0;
      wps_done_o <= 1'b0;
    end else begin
      wps_done_o <= 1'b0;
      if (wps_cnt != 0) begin
        wps_cnt--;
        if (wps_cnt == 0) wps_done_o <= 1'b1;
        if (wps_en_i) begin
          wps_ignored++;
          $warning("%m: PSEN while a write phase step is running (ignored)");
        end
      end else if (wps_en_i) begin
        if (!locked_o) begin
          wps_ignored++;
        end else begin
          adj_w     += wps_inc_i ? Step : -Step;
          wps_phase += wps_inc_i ? 1 : -1;
          wps_steps++;
          wps_cnt = PsDoneLat - 1;
        end
      end
    end
  end

endmodule
/* verilator lint_on BLKSEQ */
