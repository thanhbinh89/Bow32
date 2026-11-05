// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Test of the DDR clock module bow_ddr_clk_xusp (three MMCME4_ADV) with the
// unisim models (Vivado simulator, `make -C hw/fpga/common/dv test-ddr-clk`).
// 100 MHz oscillator; parameters T / STEPS / VcoMult / DdrDivide / SysDivide
// select the configuration (Makefile: 133.33 MHz with 504 steps, 125 MHz with
// 448 steps).
//
// Checks:
//  * PSEN before lock is ignored (no PSDONE); locked_ddr_o comes up;
//  * periods of ddr_clk, wclk, wclk90, rd_clk (T), clk_sys (20 ns) and the
//    controller clock ddr_sys_clk (4T);
//  * at lock: wclk on the ddr_clk edges, wclk90 = ddr_clk + T/4;
//  * one step on each port: PSDONE 12 ddr_clk cycles after PSEN, a one cycle
//    pulse; step size T / STEPS; a write step moves wclk and wclk90 together
//    and not rd_clk, a read step moves rd_clk only;
//  * a full period sweep of the write phase (phase grows by T / STEPS per
//    step and wraps after STEPS), 60 decrements, read phase below 0;
//  * clk_sys and ddr_clk never move (clk_sys edges stay on the common grid of
//    the two periods); every high / low phase of the DDR clocks is T/2 +-
//    40 ps while stepping (no glitches);
//  * every rising edge of ddr_sys_clk is a rising edge of ddr_clk, with four
//    ddr_clk rising edges per ddr_sys_clk period, from lock to the reset
//    (while both phases step) and again after the relock; high / low phases
//    of ddr_sys_clk 2T +- 40 ps;
//  * locked_sys_o / locked_ddr_o stay high from lock to the reset;
//  * rst_i returns both phases to 0;
//  * a loss of lock (the oscillator stopped for 5 us) resets all three MMCMs
//    (lock-loss reset): after the relock both phases are back at 0;
//  * so does MMCM_W alone losing lock (its RST forced for 1 us): the reset
//    must cover MMCM_A too, where the write phase lives.
// The test prints "tb_bow_ddr_clk_xusp: PASS" or "... FAIL (<n> errors)".

`timescale 1ns/1ps

module tb_bow_ddr_clk_xusp #(
  parameter real T         = 7.5,    // DDR clock period
  parameter int  STEPS     = 504,    // 56 * DdrDivide
  parameter real VcoMult   = 12.0,
  parameter int  DdrDivide = 9,
  parameter int  SysDivide = 24
);
  logic osc = 1'b0;
  logic rst = 1'b0;
  wire  clk_sys, ddr_clk, ddr_sys_clk, wclk, wclk90, rd_clk, locked_sys, locked_ddr;
  logic ps_en = 0, ps_inc = 0, wps_en = 0, wps_inc = 0;
  wire  ps_done, wps_done;

  localparam real TIN = 10.0;
  localparam real TS  = 20.0;
  localparam real STEP = T / STEPS;   // 14.881 ps at 133.33 MHz
  localparam real GRID = (T == 8.0) ? 4.0 : 2.5;   // gcd of the clk_sys and DDR periods

  logic osc_run = 1'b1;
  bit   lk_seen = 1'b0;            // a lock-loss reset pulse was seen
  always @(posedge dut.lk_rst) lk_seen = 1'b1;
  always #(TIN / 2) if (osc_run) osc = ~osc;

  bow_ddr_clk_xusp #(
    .VcoMult   (VcoMult),
    .DdrDivide (DdrDivide),
    .SysDivide (SysDivide)
  ) dut (
    .clk_pad_i    (osc),
    .rst_i        (rst),
    .clk_sys_o    (clk_sys),
    .ddr_clk_o    (ddr_clk),
    .ddr_sys_clk_o(ddr_sys_clk),
    .ddr_wclk_o   (wclk),
    .ddr_wclk90_o (wclk90),
    .ddr_rd_clk_o (rd_clk),
    .locked_sys_o (locked_sys),
    .locked_ddr_o (locked_ddr),
    .ps_en_i      (ps_en),
    .ps_inc_i     (ps_inc),
    .ps_done_o    (ps_done),
    .wps_en_i     (wps_en),
    .wps_inc_i    (wps_inc),
    .wps_done_o   (wps_done)
  );

  int errors = 0;
  task automatic fail(string msg);
    errors++;
    $display("ERROR @%0t: %s", $time, msg);
  endtask

  // -------------------------------------------------------------- edge times
  realtime t_ddr = 0, t_wclk = 0, t_w90 = 0, t_rd = 0, t_sys = 0;
  realtime t_ddr_f = 0, t_wclk_f = 0, t_w90_f = 0, t_rd_f = 0, t_sys_f = 0;
  always @(posedge ddr_clk) t_ddr  = $realtime;
  always @(posedge wclk)    t_wclk = $realtime;
  always @(posedge wclk90)  t_w90  = $realtime;
  always @(posedge rd_clk)  t_rd   = $realtime;
  always @(posedge clk_sys) t_sys  = $realtime;

  // Pulse width monitor (after lock): every high and low phase of the DDR
  // clocks must be T/2 +- 40 ps (a fine step changes one phase by 14.9 ps),
  // clk_sys TS/2 +- 40 ps.
  bit mon_on = 0;
  int pw_err = 0;
  real pw_min = 100.0, pw_max = 0.0;
  task automatic pw_check(string name, realtime w, real nom);
    if (mon_on) begin
      if (w < pw_min && nom == T / 2) pw_min = w;
      if (w > pw_max && nom == T / 2) pw_max = w;
      if (w < nom - 0.040 || w > nom + 0.040) begin
        pw_err++;
        if (pw_err < 10)
          $display("ERROR @%0t: %s pulse width %0.4f ns (nominal %0.4f)", $time, name, w, nom);
      end
    end
  endtask
  realtime e_ddr = 0, e_wclk = 0, e_w90 = 0, e_rd = 0, e_sys = 0, e_dsys = 0;
  always @(ddr_clk) begin pw_check("ddr_clk", $realtime - e_ddr, T / 2);  e_ddr  = $realtime; end
  always @(ddr_sys_clk) begin pw_check("ddr_sys_clk", $realtime - e_dsys, 2 * T); e_dsys = $realtime; end
  always @(wclk)    begin pw_check("wclk",    $realtime - e_wclk, T / 2); e_wclk = $realtime; end
  always @(wclk90)  begin pw_check("wclk90",  $realtime - e_w90, T / 2);  e_w90  = $realtime; end
  always @(rd_clk)  begin pw_check("rd_clk",  $realtime - e_rd, T / 2);   e_rd   = $realtime; end
  always @(clk_sys) begin pw_check("clk_sys", $realtime - e_sys, TS / 2); e_sys  = $realtime; end

  // clk_sys (MMCM_A, never shifted) must keep its rising edges on the 2.5 ns
  // grid of ddr_clk (20 ns and 7.5 ns share edges every 60 ns): any write
  // phase step that moved clk_sys or ddr_clk breaks this.
  int sys_err = 0, sys_chk = 0;
  always @(posedge clk_sys) begin
    realtime ts, dd;
    ts = $realtime;
    #0.001;
    if (mon_on) begin
      dd = ts - t_ddr;
      while (dd >= GRID - 0.0015) dd -= GRID;
      sys_chk++;
      if (dd > 0.0015 || dd < -0.0015) begin
        sys_err++;
        if (sys_err < 5) $display("ERROR @%0t: clk_sys edge %0.4f ns off the ddr_clk grid", $time, dd);
      end
    end
  end

  // ddr_sys_clk (MMCM_A CLKOUT3, CK / 4) is the LiteDRAM controller clock:
  // each rising edge must be a ddr_clk rising edge (the DFI adapter counts the
  // four ddr_clk cycles of a controller cycle from it, and STA times the
  // paths between the two clocks as synchronous). ddr_edges counts the
  // ddr_clk rising edges since the previous ddr_sys_clk rising edge; checked
  // while sys_mon_on (from lock to the reset, and after the relock).
  bit sys_mon_on = 0;
  int dsys_err = 0, dsys_chk = 0, ddr_edges = 0;
  always @(posedge ddr_clk) ddr_edges++;
  always @(posedge ddr_sys_clk) begin
    realtime ts;
    int n;
    ts = $realtime;
    #0.001;              // the ddr_clk edge of the same time step is counted
    n = ddr_edges;
    ddr_edges = 0;
    if (sys_mon_on) begin
      dsys_chk++;
      if (ts - t_ddr > 0.0015 || t_ddr - ts > 0.0015 || n != 4) begin
        dsys_err++;
        if (dsys_err < 5)
          $display("ERROR @%0t: ddr_sys_clk edge %0.4f ns after the last ddr_clk edge, %0d ddr_clk edges in its period",
                   $time, ts - t_ddr, n);
      end
    end
  end

  // LOCKED must stay high while the phases move: locked_sys_o releases the
  // SoC reset, locked_ddr_o the DDR controller's link reset (MMCM_W follows
  // the steps of its input clock).
  int lock_err = 0;
  always @(locked_sys or locked_ddr) begin
    if (mon_on && (locked_sys !== 1'b1 || locked_ddr !== 1'b1)) begin
      lock_err++;
      if (lock_err < 5)
        $display("ERROR @%0t: LOCKED dropped after lock (sys %b, ddr %b)", $time, locked_sys, locked_ddr);
    end
  end

  // Phase of clock x relative to ddr_clk in [0, T): wait for a ddr_clk rising
  // edge, then the next rising edge of x.
  task automatic phase_of(input int sel, output real ph);
    realtime t0;
    @(posedge ddr_clk);
    t0 = $realtime;
    unique case (sel)
      0: @(posedge wclk);
      1: @(posedge wclk90);
      2: @(posedge rd_clk);
      default: @(posedge clk_sys);
    endcase
    ph = $realtime - t0;
    if (ph >= T - 0.0005) ph = ph - T;
  endtask

  // Period of a clock averaged over n rising edges.
  task automatic period_of(input int sel, input int n, output real p);
    realtime t0;
    unique case (sel)
      0: @(posedge ddr_clk);
      1: @(posedge wclk);
      2: @(posedge wclk90);
      3: @(posedge rd_clk);
      5: @(posedge ddr_sys_clk);
      default: @(posedge clk_sys);
    endcase
    t0 = $realtime;
    repeat (n) begin
      unique case (sel)
        0: @(posedge ddr_clk);
        1: @(posedge wclk);
        2: @(posedge wclk90);
        3: @(posedge rd_clk);
        5: @(posedge ddr_sys_clk);
        default: @(posedge clk_sys);
      endcase
    end
    p = ($realtime - t0) / n;
  endtask

  // One PS step on port w (0 = read ps_*, 1 = write wps_*), returns the number
  // of ddr_clk cycles from the enable edge to the cycle in which done is seen.
  task automatic step(input bit w, input bit inc, output int lat);
    @(posedge ddr_clk);
    #0.1;
    if (w) begin wps_en = 1; wps_inc = inc; end
    else   begin ps_en = 1;  ps_inc = inc;  end
    @(posedge ddr_clk);   // the MMCM samples PSEN here
    #0.1;
    wps_en = 0; ps_en = 0;
    lat = 0;
    while (1) begin
      @(posedge ddr_clk);
      lat++;
      if ((w ? wps_done : ps_done) === 1'b1) break;
      if (lat > 64) begin
        fail($sformatf("no PSDONE on port %0d", w));
        break;
      end
    end
    // check that done is a single cycle pulse
    @(posedge ddr_clk);
    if ((w ? wps_done : ps_done) !== 1'b0) fail("PSDONE longer than one cycle");
  endtask

  function automatic real wrapd(real d);   // wrap a phase difference into (-T/2, T/2]
    while (d > T / 2) d -= T;
    while (d <= -T / 2) d += T;
    return d;
  endfunction

  real p, ph_w0, ph_w90_0, ph_rd0, ph, ph2, ph_s0, d;
  int  lat, k, dones;

  initial begin
    $display("tb_bow_ddr_clk_xusp: start");
    // PSEN before lock: must be ignored (no PSDONE)
    #50;
    dones = 0;
    fork
      begin
        repeat (3) begin
          #(T);
          wps_en = 1; ps_en = 1;
          #(T);
          wps_en = 0; ps_en = 0;
        end
      end
      begin
        repeat (60) begin
          #(T / 3);
          if (ps_done === 1'b1 || wps_done === 1'b1) dones++;
        end
      end
    join
    if (locked_sys) fail("locked before the PSEN-before-lock test finished (test setup)");

    wait (locked_ddr === 1'b1);
    $display("tb_bow_ddr_clk_xusp: locked at %0t", $time);
    if (dones != 0) fail("PSDONE after PSEN before lock");
    repeat (20) @(posedge clk_sys);
    mon_on = 1;
    sys_mon_on = 1;

    // ---- frequencies
    period_of(0, 200, p);
    if (p < T - 0.001 || p > T + 0.001) fail($sformatf("ddr_clk period %0.4f", p));
    period_of(1, 200, p);
    if (p < T - 0.001 || p > T + 0.001) fail($sformatf("wclk period %0.4f", p));
    period_of(2, 200, p);
    if (p < T - 0.001 || p > T + 0.001) fail($sformatf("wclk90 period %0.4f", p));
    period_of(3, 200, p);
    if (p < T - 0.001 || p > T + 0.001) fail($sformatf("rd_clk period %0.4f", p));
    period_of(4, 100, p);
    if (p < TS - 0.001 || p > TS + 0.001) fail($sformatf("clk_sys period %0.4f", p));
    period_of(5, 50, p);
    if (p < 4 * T - 0.001 || p > 4 * T + 0.001) fail($sformatf("ddr_sys_clk period %0.4f", p));

    // ---- phases at reset
    phase_of(0, ph_w0);
    phase_of(1, ph_w90_0);
    phase_of(2, ph_rd0);
    $display("tb_bow_ddr_clk_xusp: phase at lock: wclk %0.4f  wclk90 %0.4f  rd_clk %0.4f ns",
             ph_w0, ph_w90_0, ph_rd0);
    if (ph_w0 > 0.001 && ph_w0 < T - 0.001) fail("wclk not aligned with ddr_clk at phase 0");
    // the unisim model rounds the VCO period to 1 ps (833 ps): 2.25 * 833 = 1874
    if (ph_w90_0 < T / 4 - 0.003 || ph_w90_0 > T / 4 + 0.003) fail("wclk90 not ddr_clk + T/4");

    // ---- one write-phase step: PSDONE latency and size
    step(1, 1, lat);
    $display("tb_bow_ddr_clk_xusp: write PS done after %0d ddr_clk cycles", lat);
    if (lat != 12) fail($sformatf("PSDONE latency %0d, expected 12", lat));
    repeat (4) @(posedge ddr_clk);
    phase_of(0, ph);
    d = wrapd(ph - ph_w0);
    if (d < STEP - 0.002 || d > STEP + 0.002)
      fail($sformatf("wclk step %0.4f ns, expected %0.4f", d, STEP));
    phase_of(1, ph2);
    if (wrapd(ph2 - ph_w90_0 - d) > 0.002 || wrapd(ph2 - ph_w90_0 - d) < -0.002)
      fail("wclk90 did not move with wclk");
    phase_of(2, ph);
    if (wrapd(ph - ph_rd0) > 0.001 || wrapd(ph - ph_rd0) < -0.001)
      fail("rd_clk moved on a write PS step");

    // ---- one read-phase step
    step(0, 1, lat);
    if (lat != 12) fail($sformatf("read PSDONE latency %0d, expected 12", lat));
    repeat (4) @(posedge ddr_clk);
    phase_of(2, ph);
    d = wrapd(ph - ph_rd0);
    $display("tb_bow_ddr_clk_xusp: read step %0.4f ns", d);
    if (d < STEP - 0.002 || d > STEP + 0.002)
      fail($sformatf("rd_clk step %0.4f ns, expected %0.4f", d, STEP));
    phase_of(0, ph);
    if (wrapd(ph - ph_w0 - STEP) > 0.002 || wrapd(ph - ph_w0 - STEP) < -0.002)
      fail("wclk moved on a read PS step");

    // ---- sweep the write phase over a full period (+503 more steps): the
    // phase must grow by STEP per step and wrap after 504 steps.
    for (k = 2; k <= STEPS; k++) begin
      step(1, 1, lat);
      if (lat != 12) fail($sformatf("PSDONE latency %0d at step %0d", lat, k));
      if (k % 56 == 0 || k == STEPS || k == 57 || k == 55) begin
        repeat (3) @(posedge ddr_clk);
        phase_of(0, ph);
        d = wrapd(ph - ph_w0 - k * STEP);
        $display("tb_bow_ddr_clk_xusp: write phase after %0d steps: %0.4f ns (expected %0.4f, error %0.4f)",
                 k, ph, k * STEP - $floor(k * STEP / T) * T, d);
        if (d > 0.003 || d < -0.003)
          fail($sformatf("write phase error %0.4f ns after %0d steps", d, k));
      end
    end
    // ---- decrement 60 steps
    for (k = 0; k < 60; k++) step(1, 0, lat);
    repeat (3) @(posedge ddr_clk);
    phase_of(0, ph);
    d = wrapd(ph - ph_w0 - (STEPS - 60) * STEP);
    $display("tb_bow_ddr_clk_xusp: write phase after -60 steps: %0.4f ns (error %0.4f)", ph, d);
    if (d > 0.003 || d < -0.003) fail("write phase wrong after decrements");

    // ---- read port decrement below zero (from +1 to -10)
    for (k = 0; k < 11; k++) step(0, 0, lat);
    repeat (3) @(posedge ddr_clk);
    phase_of(2, ph);
    d = wrapd(ph - ph_rd0 + 10 * STEP);
    $display("tb_bow_ddr_clk_xusp: read phase at -10 steps: %0.4f ns (error %0.4f)", ph, d);
    if (d > 0.003 || d < -0.003) fail("read phase wrong after decrements below 0");

    // ---- reset returns both phases to 0
    mon_on = 0;
    sys_mon_on = 0;
    k = dsys_chk;
    rst = 1;
    #100;
    rst = 0;
    wait (locked_ddr === 1'b1);
    repeat (20) @(posedge clk_sys);
    sys_mon_on = 1;
    phase_of(0, ph);
    if (ph > 0.001 && ph < T - 0.001) fail("wclk not back at phase 0 after reset");
    phase_of(1, ph);
    if (ph < T / 4 - 0.003 || ph > T / 4 + 0.003) fail("wclk90 not at +T/4 after reset");
    // ddr_sys_clk aligned to ddr_clk again after the relock
    repeat (50) @(posedge ddr_sys_clk);
    #0.01;
    if (dsys_chk - k < 50) fail($sformatf("%0d ddr_sys_clk checks after the relock", dsys_chk - k));
    if (k < 1000) fail($sformatf("only %0d ddr_sys_clk checks before the reset", k));

    // ---- a loss of lock returns both phases to 0 (lock-loss reset)
    sys_mon_on = 0;
    for (k = 0; k < 30; k++) step(1, 1, lat);
    for (k = 0; k < 20; k++) step(0, 1, lat);
    repeat (3) @(posedge ddr_clk);
    phase_of(0, ph);
    if (wrapd(ph - ph_w0 - 30 * STEP) > 0.003 || wrapd(ph - ph_w0 - 30 * STEP) < -0.003)
      fail("write phase not at +30 steps before the lock loss");
    osc_run = 0;
    #5us;
    if (locked_ddr !== 1'b0) fail("LOCKED still high with the oscillator stopped (test setup)");
    osc_run = 1;
    fork
      begin
        wait (dut.lk_rst === 1'b1);
        $display("tb_bow_ddr_clk_xusp: lock-loss reset at %0t", $time);
      end
      begin
        #200us;
        fail("no lock-loss reset");
      end
    join_any
    disable fork;
    wait (locked_ddr === 1'b1);
    repeat (20) @(posedge clk_sys);
    phase_of(0, ph);
    if (ph > 0.001 && ph < T - 0.001) fail($sformatf("wclk at %0.4f ns after the lock loss, not 0", ph));
    phase_of(1, ph);
    if (ph < T / 4 - 0.003 || ph > T / 4 + 0.003) fail("wclk90 not at +T/4 after the lock loss");
    phase_of(2, ph);
    if (wrapd(ph - ph_rd0) > 0.003 || wrapd(ph - ph_rd0) < -0.003)
      fail($sformatf("rd_clk %0.4f ns from its phase at lock after the lock loss", wrapd(ph - ph_rd0)));

    // ---- MMCM_W alone loses lock: all three are reset, both phases back at 0
    for (k = 0; k < 30; k++) step(1, 1, lat);
    for (k = 0; k < 20; k++) step(0, 1, lat);
    repeat (3) @(posedge ddr_clk);
    phase_of(0, ph);
    if (wrapd(ph - ph_w0 - 30 * STEP) > 0.003 || wrapd(ph - ph_w0 - 30 * STEP) < -0.003)
      fail("write phase not at +30 steps before the MMCM_W lock loss");
    lk_seen = 1'b0;
    force dut.rst_w = 1'b1;
    #1us;
    release dut.rst_w;
    fork
      wait (lk_seen && locked_ddr === 1'b1);
      #300us;
    join_any
    disable fork;
    if (!lk_seen) fail("no lock-loss reset after an MMCM_W lock loss");
    if (locked_ddr !== 1'b1) fail("no relock after the MMCM_W lock loss");
    repeat (20) @(posedge clk_sys);
    phase_of(0, ph);
    if (ph > 0.001 && ph < T - 0.001) fail($sformatf("wclk at %0.4f ns after the MMCM_W lock loss, not 0", ph));
    phase_of(2, ph);
    if (wrapd(ph - ph_rd0) > 0.003 || wrapd(ph - ph_rd0) < -0.003)
      fail($sformatf("rd_clk %0.4f ns from its phase at lock after the MMCM_W lock loss", wrapd(ph - ph_rd0)));
    $display("tb_bow_ddr_clk_xusp: MMCM_W lock loss: lock-loss reset, phases back at 0");

    $display("tb_bow_ddr_clk_xusp: pulse widths of the DDR clocks while stepping: %0.4f .. %0.4f ns, %0d errors",
             pw_min, pw_max, pw_err);
    $display("tb_bow_ddr_clk_xusp: clk_sys grid checks %0d, errors %0d; LOCKED drops %0d", sys_chk,
             sys_err, lock_err);
    $display("tb_bow_ddr_clk_xusp: ddr_sys_clk on ddr_clk edges: %0d checks, %0d errors", dsys_chk,
             dsys_err);
    errors += pw_err + sys_err + lock_err + dsys_err;
    if (errors == 0) $display("tb_bow_ddr_clk_xusp: PASS");
    else $display("tb_bow_ddr_clk_xusp: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #5ms;
    $display("tb_bow_ddr_clk_xusp: FAIL (timeout)");
    $finish;
  end
endmodule
