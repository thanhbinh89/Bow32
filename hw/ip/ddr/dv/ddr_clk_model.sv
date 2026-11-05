// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Clock model of the DDR clocking of a board top (spec 4.5;
// hw/fpga/common/rtl/bow_ddr_clk_xusp.sv): ddr_clk (CK rate, phase 0) and
// sys_clk (LiteDRAM controller clock, CK / 4) of MMCM_A; wclk and wclk90
// (write clocks, one fine phase shift port for both: MMCM_A CLKOUT2 followed
// by MMCM_W); rd_clk (read capture, the fine phase shift port of MMCM_B).
// Runs in Verilator (--timing) and xsim.
//
//   * sys_clk_o rises with every fourth rising edge of ddr_clk_o (the first
//     one after a start) and falls with the rising edge two CK periods later.
//     Both are set by the same process in the same time step (no divider
//     flop, no continuous assignment between them), so flops of the two
//     domains sample each other's values from before the common edge, as the
//     synchronous paths of the hardware do. Connect both straight to the DUT
//     (a gate or assign on only one of them adds a delta delay: races).
//
//   * Every clock runs from its own loop with half period T/2 (TckPs / 2);
//     after en_i rises all clocks start T/8 later (wclk90 T/8 + T/4), so no
//     edge is ever at time 0. No delay is ever 0 or negative (edge times are
//     kept as exact reals and every wait is rounded to >= 1 ps).
//   * Fine phase shift (MMCME4_ADV): PSCLK = ddr_clk_o. ps_en_i (one cycle)
//     sampled high at a ddr_clk_o posedge moves rd_clk_o by one step of
//     T / PsSteps: the next high phase of rd_clk_o is lengthened (ps_inc_i = 1,
//     clock later) or shortened (ps_inc_i = 0). ps_done_o is high for one
//     ddr_clk cycle, PsDoneLat (12) cycles after the PSEN cycle. A PSEN while
//     a step is still running or before locked_o is ignored (counted in
//     ps_ignored / wps_ignored, with a warning when running). wps_*: the same
//     for wclk_o and wclk90_o (one step moves both).
//   * en_i = 0 stops all clocks low after the current period (sys_clk_o
//     with the last falling edge of ddr_clk_o) and drops locked_o; when en_i
//     rises again the MMCMs restart: phases back to 0, sys_clk_o rises with
//     the first ddr_clk_o edge, locked_o after LockCycles ddr_clk cycles.
//   * Status for the testbench: ps_phase / wps_phase (signed steps),
//     ps_steps / wps_steps (PSEN accepted), ps_ignored / wps_ignored.
//   * Test hook `freeze` (set hierarchically by a testbench): ddr_clk_o and
//     sys_clk_o stop low before the next sys_clk_o rising edge while locked_o
//     stays 1 (a DDR clock lost without a loss of lock); the other clocks run
//     on. Clear it after an MMCM restart (en_i low) for aligned clocks again.

`timescale 1ps / 1ps

// behavioural model: blocking assignments in edge processes are intended
/* verilator lint_off BLKSEQ */
module ddr_clk_model #(
  parameter int unsigned TckPs      = 7500,   // CK period
  parameter int unsigned PsSteps    = 504,    // fine steps per CK period (MMCME4: 56 * divide)
  parameter int unsigned LockCycles = 16,
  parameter int unsigned PsDoneLat  = 12
) (
  input  logic en_i,
  output logic ddr_clk_o,
  output logic sys_clk_o,     // CK / 4, rising edges on ddr_clk_o rising edges
  output logic wclk_o,
  output logic wclk90_o,
  output logic rd_clk_o,
  output logic locked_o,
  input  logic ps_en_i,
  input  logic ps_inc_i,
  output logic ps_done_o,
  input  logic wps_en_i,
  input  logic wps_inc_i,
  output logic wps_done_o
);

  localparam real T    = real'(TckPs);
  localparam real Step = real'(TckPs) / real'(PsSteps);

  // ------------------------------------------------------------- status
  int ps_phase = 0, wps_phase = 0;
  int ps_steps = 0, wps_steps = 0;
  int ps_ignored = 0, wps_ignored = 0;

  // phase adjustments waiting for the next high phase of each clock
  real adj_rd = 0.0, adj_w = 0.0, adj_w90 = 0.0;

  // every wait: until the absolute time t (ps), at least 1 ps (computed into a
  // variable: no function call inside a delay expression)

  // --------------------------------------------------------------- clocks
  bit freeze = 1'b0;

  initial begin : g_ddr_clk
    real         t, d;
    int unsigned n;                        // CK rising edges since the start
    ddr_clk_o = 1'b0;
    sys_clk_o = 1'b0;
    forever begin
      while (!en_i) @(posedge en_i);
      t = $realtime + T / 8.0;
      n = 0;
      while (en_i) begin
        if (freeze && n % 4 == 0) begin    // stopped low, locked_o unchanged
          while (freeze && en_i) @(freeze or en_i);
          if (!en_i) break;
          t = $realtime + T / 8.0;
        end
        d = t - $realtime;
        if (d < 1.0) d = 1.0;
        #(d);
        ddr_clk_o = 1'b1;                  // same time step, same process
        if (n % 4 == 0) sys_clk_o = 1'b1;
        if (n % 4 == 2) sys_clk_o = 1'b0;
        n++;
        t += T / 2.0;
        d = t - $realtime;
        if (d < 1.0) d = 1.0;
        #(d) ddr_clk_o = 1'b0;
        t += T / 2.0;
      end
      sys_clk_o = 1'b0;                    // stopped low (like ddr_clk_o)
    end
  end

  initial begin : g_rd_clk
    real t, d;
    rd_clk_o = 1'b0;
    forever begin
      while (!en_i) @(posedge en_i);
      t = $realtime + T / 8.0;
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
      t = $realtime + T / 8.0;
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

  initial begin : g_wclk90
    real t, d;
    wclk90_o = 1'b0;
    forever begin
      while (!en_i) @(posedge en_i);
      t = $realtime + T / 8.0 + T / 4.0;
      while (en_i) begin
        d = t - $realtime;
        if (d < 1.0) d = 1.0;
        #(d) wclk90_o = 1'b1;
        t += T / 2.0 + adj_w90;
        adj_w90 = 0.0;
        d = t - $realtime;
        if (d < 1.0) d = 1.0;
        #(d) wclk90_o = 1'b0;
        t += T / 2.0;
      end
    end
  end

  // ------------------------------------------------------- lock, restart
  int unsigned lock_cnt = 0;
  initial locked_o = 1'b0;
  always @(posedge ddr_clk_o or negedge en_i) begin
    if (!en_i) begin
      locked_o <= 1'b0;
      lock_cnt  = 0;
    end else if (!locked_o) begin
      lock_cnt++;
      if (lock_cnt >= LockCycles) locked_o <= 1'b1;
    end
  end

  always @(posedge en_i) begin           // MMCM restart: fine phases back to 0
    ps_phase  = 0;
    wps_phase = 0;
    adj_rd    = 0.0;
    adj_w     = 0.0;
    adj_w90   = 0.0;
  end

  // ---------------------------------------------------- phase shift ports
  int unsigned ps_cnt = 0, wps_cnt = 0;
  initial begin
    ps_done_o  = 1'b0;
    wps_done_o = 1'b0;
  end

  always @(posedge ddr_clk_o or negedge en_i) begin
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

  always @(posedge ddr_clk_o or negedge en_i) begin
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
          adj_w90   += wps_inc_i ? Step : -Step;
          wps_phase += wps_inc_i ? 1 : -1;
          wps_steps++;
          wps_cnt = PsDoneLat - 1;
        end
      end
    end
  end

endmodule
/* verilator lint_on BLKSEQ */
