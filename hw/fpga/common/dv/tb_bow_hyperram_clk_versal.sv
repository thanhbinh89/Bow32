// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Test of the Versal HyperRAM clock module bow_hyperram_clk_versal (two
// MMCME5) with the unisim models (Vivado simulator, `make -C
// hw/fpga/common/dv test-vclk`). Parameters TIN (ClkInPeriodNs) / VcoMult /
// HrDivide select the configuration (Makefile VCLK_CFGS: hr200 = the Huins
// VP1902 200 MHz reference, VCO 200 * 16; hr100 = 100 MHz, VCO 100 * 32; both
// 100 MHz HyperRAM clocks with 1024 fine phase steps per CK). The input clock
// drives clk_in_i directly (on the board: the IBUFDS output of
// bow_ddr_clk_versal).
//
// The fine phase ports are driven directly (single steps) and through two
// bow_mmcm_ps steppers, as bow_hyperram_ctrl drives them (write: wps_*, read:
// ps_*; stepper reset = locked_o).
//
// Checks:
//  * PSEN before lock (one-cycle pulses on both ports while hr_clk runs and
//    LOCKED is low) is ignored: no PSDONE, no phase change;
//  * periods of hr_clk, hr_wclk, hr_rd_clk (T);
//  * at write count 0 hr_wclk = hr_clk + T/4 (hr_clk at the static 270 deg,
//    hr_wclk at 0 deg of the same VCO), within 3 ps (the model rounds to 1
//    ps); hr_rd_clk at read count 0 is hr_clk + T/4 modulo the common grid of
//    hr_clk and the input clock (MMCM_R may lock in any slot of it);
//  * every write step moves hr_wclk by T / STEPS, every read step hr_rd_clk,
//    and nothing else; phases checked against a mirror of the MMCME5 phase
//    counters after every single step and every stepper move, including a
//    write sweep over a full period (STEPS steps back to phase 0) and a read
//    sweep of -STEPS;
//  * PSDONE (the model drives it 100 ps after its PSCLK edge; sampled in the
//    middle of each hr_clk cycle, i.e. as a flop takes it at the next edge):
//    a flop takes it at the 12th or 13th hr_clk rising edge after the one that
//    took PSEN, a one cycle pulse; while PSEN stays low the model repeats it
//    every 32 cycles, a new PSEN clears the repeat unless it is taken with a
//    repeat PSDONE (then the old 32-cycle cadence goes on): any other PSDONE,
//    or a missing repeat, is an error; PSEN never longer than one cycle or
//    while a step is pending;
//  * bow_mmcm_ps moves on both ports (several steps, both directions, through
//    zero) end with done and without err, now_o = target, one PSEN per step;
//    the moves are started at all 32 offsets to the PSDONE repeat, among them
//    the move whose first PSEN is taken together with a repeat PSDONE;
//  * hr_clk never moves: it keeps its phase to the input clock;
//  * every high / low phase T/2 +- 40 ps while the phases move. The MMCME5
//    model turns a decrement from count 0 to -1 into a delay of T - STEP: one
//    high or low phase of T/2 + T - STEP on the clock of that port, tolerated
//    exactly there (counted, printed);
//  * locked_o stays high while the phases move, and is high only while the
//    clocks run;
//  * rst_i returns both phases to 0 (locked_o low meanwhile);
//  * a loss of lock returns both phases to 0 (lock-loss reset of both MMCMs,
//    dut.lk_rst seen): the input clock stopped for 5 us (locked_o falls);
//    MMCM_R alone and MMCM_H alone (their LOCKED net forced low: the reset
//    must cover the other MMCM too): locked_o stays low while either LOCKED is
//    low.
// The test prints "tb_bow_hyperram_clk_versal: PASS" or "... FAIL (<n> errors)".

`timescale 1ns/1ps

module tb_bow_hyperram_clk_versal #(
  parameter real TIN      = 5.0,    // input clock period (ClkInPeriodNs)
  parameter int  VcoMult  = 16,
  parameter int  HrDivide = 32
);
  function automatic int gcd(int a, int b);
    int r;
    while (b != 0) begin
      r = a % b;
      a = b;
      b = r;
    end
    return a;
  endfunction

  localparam real VCO    = TIN / VcoMult;                   // VCO period (ns)
  localparam real T      = VCO * HrDivide;                  // HyperRAM clock period
  localparam int  STEPS  = 32 * HrDivide;                   // fine steps per T
  localparam real STEP   = T / STEPS;                       // VCO / 32
  localparam real GRID_I = VCO * gcd(HrDivide, VcoMult);    // common edges of input / hr_clk
  localparam int  LIMIT  = 2 * STEPS;                       // bow_mmcm_ps Limit
  localparam real TOL    = 0.003;                           // phase tolerance
  localparam real PWTOL  = 0.040;                           // pulse width tolerance
  localparam real ART    = 1.5 * T - STEP;                  // model pulse at 0 -> -1

  // ---------------------------------------------------------------- clocks
  logic osc = 1'b0;
  logic osc_run = 1'b1;
  logic rst = 1'b0;
  always #(TIN / 2) if (osc_run) osc = ~osc;

  wire  hr_clk, wclk, rd_clk, locked;
  wire  ps_done, wps_done;

  // PS ports: the testbench (single steps) or the two steppers
  logic use_st = 1'b0;
  logic man_ps_en = 1'b0, man_ps_inc = 1'b0, man_wps_en = 1'b0, man_wps_inc = 1'b0;
  wire  st_ps_en, st_ps_inc, st_wps_en, st_wps_inc;
  wire  ps_en   = use_st ? st_ps_en   : man_ps_en;
  wire  ps_inc  = use_st ? st_ps_inc  : man_ps_inc;
  wire  wps_en  = use_st ? st_wps_en  : man_wps_en;
  wire  wps_inc = use_st ? st_wps_inc : man_wps_inc;

  bow_hyperram_clk_versal #(
    .ClkInPeriodNs (TIN),
    .InDivide      (1),
    .VcoMult       (VcoMult),
    .HrDivide      (HrDivide)
  ) dut (
    .clk_in_i    (osc),
    .rst_i       (rst),
    .hr_clk_o    (hr_clk),
    .hr_wclk_o   (wclk),
    .hr_rd_clk_o (rd_clk),
    .locked_o    (locked),
    .ps_en_i     (ps_en),
    .ps_inc_i    (ps_inc),
    .ps_done_o   (ps_done),
    .wps_en_i    (wps_en),
    .wps_inc_i   (wps_inc),
    .wps_done_o  (wps_done)
  );

  // ------------------------------------------------------------- steppers
  logic        go_r = 1'b0, go_w = 1'b0;
  logic [15:0] tgt_r = '0, tgt_w = '0;
  wire         busy_r, done_r, err_r, busy_w, done_w, err_w;
  wire  [15:0] now_r, now_w;

  bow_mmcm_ps #(.Limit (LIMIT), .Timeout (64)) u_ps_r (
    .clk_i     (hr_clk),
    .rst_ni    (locked),
    .go_i      (go_r),
    .target_i  (tgt_r),
    .ref_i     (16'h0000),
    .busy_o    (busy_r),
    .done_o    (done_r),
    .err_o     (err_r),
    .now_o     (now_r),
    .ps_en_o   (st_ps_en),
    .ps_inc_o  (st_ps_inc),
    .ps_done_i (ps_done)
  );

  bow_mmcm_ps #(.Limit (LIMIT), .Timeout (64)) u_ps_w (
    .clk_i     (hr_clk),
    .rst_ni    (locked),
    .go_i      (go_w),
    .target_i  (tgt_w),
    .ref_i     (16'h0000),
    .busy_o    (busy_w),
    .done_o    (done_w),
    .err_o     (err_w),
    .now_o     (now_w),
    .ps_en_o   (st_wps_en),
    .ps_inc_o  (st_wps_inc),
    .ps_done_i (wps_done)
  );

  // ---------------------------------------------------------------- utils
  int errors = 0;
  task automatic fail(string msg);
    errors++;
    if (errors <= 40) $display("ERROR @%0t: %s", $time, msg);
  endtask

  function automatic real modp(real x, real p);   // x mod p in [0, p)
    real y;
    y = x - p * $floor(x / p);
    if (y >= p) y = y - p;
    if (y < 0.0) y = y + p;
    return y;
  endfunction
  function automatic real gdist(real x, real p);  // distance of x to a multiple of p
    real y;
    y = modp(x, p);
    return (y > p / 2) ? p - y : y;
  endfunction
  function automatic bit near(real x, real y, real p, real tol);   // x == y (mod p)
    return gdist(x - y, p) <= tol;
  endfunction
  function automatic int iabs(int x);
    return (x < 0) ? -x : x;
  endfunction

  // ---------------------------------------------------- rising edge times
  localparam int CK_HR = 0, CK_W = 1, CK_RD = 2, CK_OSC = 3;
  realtime e_t[4] = '{default: -1.0e6};
  int      e_cnt[4] = '{default: 0};
  always @(posedge hr_clk) begin e_t[CK_HR]  = $realtime; e_cnt[CK_HR]++;  end
  always @(posedge wclk)   begin e_t[CK_W]   = $realtime; e_cnt[CK_W]++;   end
  always @(posedge rd_clk) begin e_t[CK_RD]  = $realtime; e_cnt[CK_RD]++;  end
  always @(posedge osc)    begin e_t[CK_OSC] = $realtime; e_cnt[CK_OSC]++; end

  // ---------------------------------------------------- PSEN / PSDONE monitor
  // Sampled in the middle of each hr_clk cycle c (after rising edge c): PSEN
  // and PSDONE there are what the MMCM and a flop take at edge c + 1. Port 0 =
  // read (ps_*, MMCM_R), port 1 = write (wps_*, MMCM_H). pcnt mirrors the
  // phase counters of the MMCME5 model (increment wraps STEPS - 1 -> 0,
  // decrement wraps 1 - STEPS -> 0); by the contract of the module it returns
  // to 0 whenever locked_o falls.
  int  cyc = 0;                    // hr_clk rising edges
  bit  locked_once = 1'b0;         // before the first lock any PSDONE is an error
  int  pcnt[2]    = '{0, 0};
  bit  pend[2]    = '{0, 0};       // PSEN taken, its PSDONE not seen yet
  bit  coinc[2]   = '{0, 0};       // ... and it was taken together with a repeat PSDONE
  bit  en_q[2]    = '{0, 0};
  int  s_en[2]    = '{0, 0};       // edge that took the pending PSEN
  int  cad[2]     = '{-1, -1};     // cycle of the next repeat PSDONE (-1: none)
  int  n_en[2]    = '{0, 0}, n_pre[2] = '{0, 0}, n_done[2] = '{0, 0}, n_rep[2] = '{0, 0};
  int  n_coinc[2] = '{0, 0}, n12[2] = '{0, 0}, n13[2] = '{0, 0}, last_rep[2] = '{0, 0};
  int  allow[2]   = '{0, 0};       // tolerated model pulses: hr_rd_clk, hr_wclk
  int  n_art      = 0, ps_err = 0;

  task automatic ps_fail(int p, string msg);
    ps_err++;
    if (ps_err < 20) $display("ERROR @%0t: %s port: %s", $time, (p != 0) ? "write" : "read", msg);
  endtask

  function automatic int ps_next(int c, bit inc);
    if (inc) return (c < STEPS - 1) ? c + 1 : 0;
    return (c > 1 - STEPS) ? c - 1 : 0;
  endfunction

  always @(posedge hr_clk) begin
    bit en[2], inc[2], dn[2], lk;
    cyc++;
    #(T / 2);
    en[0]  = (ps_en === 1'b1);
    en[1]  = (wps_en === 1'b1);
    inc[0] = (ps_inc === 1'b1);
    inc[1] = (wps_inc === 1'b1);
    dn[0]  = (ps_done === 1'b1);
    dn[1]  = (wps_done === 1'b1);
    lk     = (locked === 1'b1);
    for (int p = 0; p < 2; p++) begin
      if (dn[p]) begin
        if (!locked_once) begin
          ps_fail(p, "PSDONE before the first lock (a PSEN before lock was taken)");
        end else if (pend[p]) begin
          // a flop takes this PSDONE at edge cyc + 1
          if (cyc + 1 - s_en[p] == 12) n12[p]++;
          else if (cyc + 1 - s_en[p] == 13) n13[p]++;
          else ps_fail(p, $sformatf("PSDONE %0d cycles after PSEN, expected 12..13", cyc + 1 - s_en[p]));
          pend[p] = 1'b0;
          n_done[p]++;
          if (!coinc[p]) cad[p] = cyc + 32;
        end else if (cad[p] >= 0 && cyc == cad[p]) begin
          n_rep[p]++;
          last_rep[p] = cyc;
          cad[p] = cyc + 32;
        end else if (lk) begin
          ps_fail(p, "PSDONE without PSEN, off the 32-cycle repeat");
        end
      end else if (cad[p] >= 0 && cyc == cad[p]) begin
        if (lk) ps_fail(p, "no PSDONE repeat 32 cycles after the previous PSDONE");
        cad[p] = -1;
      end
      if (en[p]) begin
        if (en_q[p]) ps_fail(p, "PSEN longer than one cycle (testbench / stepper)");
        if (!lk) begin
          n_pre[p]++;
        end else begin
          if (pend[p]) ps_fail(p, "PSEN while a step is pending (testbench / stepper)");
          coinc[p] = dn[p];
          if (dn[p]) n_coinc[p]++;
          else cad[p] = -1;          // a PSEN clears the repeat
          pend[p] = 1'b1;
          s_en[p] = cyc + 1;
          n_en[p]++;
          if (!inc[p] && pcnt[p] == 0) allow[p]++;
          pcnt[p] = ps_next(pcnt[p], inc[p]);
        end
      end
      en_q[p] = en[p];
    end
  end

  // the phases return to 0 whenever locked_o falls (rst_i, lock-loss reset)
  bit rd0_ok = 1'b0;
  always @(negedge locked) begin
    pcnt   = '{0, 0};
    pend   = '{0, 0};
    coinc  = '{0, 0};
    cad    = '{-1, -1};
    rd0_ok = 1'b0;
  end
  always @(posedge locked) locked_once = 1'b1;

  // stepper done / err (flop outputs, looked at just after each edge)
  bit st_done[2] = '{0, 0}, st_err[2] = '{0, 0};
  always @(posedge hr_clk) begin
    #0.05;
    if (done_r === 1'b1) begin st_done[0] = 1'b1; st_err[0] = (err_r !== 1'b0); end
    if (done_w === 1'b1) begin st_done[1] = 1'b1; st_err[1] = (err_w !== 1'b0); end
  end

  // ------------------------------------------------------- clock monitors
  bit  mon_on = 1'b0;     // from lock to a deliberate reset / lock loss
  int  pw_err = 0, pw_chk = 0, in_err = 0, in_chk = 0, lock_err = 0;
  real pw_min = 100.0, pw_max = 0.0;
  real off_in0 = 0.0;     // hr_clk after the input rising edge (mod GRID_I) at lock
  bit  off_in_ok = 1'b0;

  // Every high / low phase: T/2 +- PWTOL; on the shifted clocks (k = 0
  // hr_rd_clk, 1 hr_wclk) one pulse of ART per 0 -> -1 decrement of their port.
  task automatic pw_check(string name, int k, realtime w);
    if (!mon_on) return;
    pw_chk++;
    if (w >= T / 2 - PWTOL && w <= T / 2 + PWTOL) begin
      if (w < pw_min) pw_min = w;
      if (w > pw_max) pw_max = w;
    end else if (k >= 0 && allow[k] > 0 && w >= ART - PWTOL && w <= ART + PWTOL) begin
      allow[k]--;
      n_art++;
      $display("tb_bow_hyperram_clk_versal: %s %0.4f ns phase at a 0 -> -1 step (MMCME5 model, tolerated)",
               name, w);
    end else begin
      pw_err++;
      if (pw_err < 10) $display("ERROR @%0t: %s high / low phase %0.4f ns (nominal %0.4f)", $time, name, w, T / 2);
    end
  endtask
  realtime c_hr = 0, c_w = 0, c_rd = 0;
  always @(hr_clk) begin pw_check("hr_clk", -1, $realtime - c_hr);  c_hr = $realtime; end
  always @(wclk)   begin pw_check("hr_wclk", 1, $realtime - c_w);    c_w  = $realtime; end
  always @(rd_clk) begin pw_check("hr_rd_clk", 0, $realtime - c_rd); c_rd = $realtime; end

  // hr_clk keeps its phase to the input clock (mod their common grid)
  always @(posedge hr_clk) begin
    #0.001;
    if (mon_on && off_in_ok) begin
      in_chk++;
      if (!near(e_t[CK_HR] - e_t[CK_OSC], off_in0, GRID_I, 0.0015)) begin
        in_err++;
        if (in_err < 5)
          $display("ERROR @%0t: hr_clk %0.4f ns after the input edge (mod %0.4f), %0.4f at lock", $time,
                   modp(e_t[CK_HR] - e_t[CK_OSC], GRID_I), GRID_I, off_in0);
      end
    end
  end

  // locked_o stays high while the phases move
  always @(locked) begin
    if (mon_on && locked !== 1'b1) begin
      lock_err++;
      if (lock_err < 5) $display("ERROR @%0t: locked_o dropped", $time);
    end
  end

  // locked_o only while the clocks run: every T/4, while it is high hr_clk had
  // a rising edge within T + 2 ns, hr_wclk and hr_rd_clk within 2T + 2 ns (2T:
  // the model's 0 -> -1 pulse; the model drops LOCKED 1 ns after RST). Not
  // while the input clock is stopped (the model stops its outputs before it
  // drops LOCKED).
  bit run_mon = 1'b1;
  int run_err = 0, run_chk = 0;
  always begin
    #(T / 4);
    if (run_mon && locked === 1'b1) begin
      run_chk++;
      if ($realtime - e_t[CK_HR] > T + 2.0 || $realtime - e_t[CK_W] > 2 * T + 2.0 ||
          $realtime - e_t[CK_RD] > 2 * T + 2.0) begin
        run_err++;
        if (run_err < 5)
          $display("ERROR @%0t: locked_o high, last rising edges of hr_clk / hr_wclk / hr_rd_clk %0.3f / %0.3f / %0.3f ns ago",
                   $time, $realtime - e_t[CK_HR], $realtime - e_t[CK_W], $realtime - e_t[CK_RD]);
      end
    end
  end

  // ------------------------------------------------------- measurements
  task automatic period_of(input int k, input int n, input string name);
    int      c0;
    realtime t0;
    real     p;
    c0 = e_cnt[k];
    while (e_cnt[k] == c0) #0.25;
    t0 = e_t[k];
    c0 = e_cnt[k];
    while (e_cnt[k] < c0 + n) #0.25;
    p = (e_t[k] - t0) / n;
    $display("tb_bow_hyperram_clk_versal: %s period %0.4f ns (expected %0.4f)", name, p, T);
    if (p < T - 0.001 || p > T + 0.001) fail($sformatf("%s period %0.4f ns, expected %0.4f", name, p, T));
  endtask

  // Phases after the hr_clk rising edge, from the last rising edges half a
  // period after it, checked against the counter mirror. rd0 = hr_rd_clk at
  // read count 0, re-learned after every reset (any slot of the input grid).
  real rd0 = 0.0;
  task automatic chk_phases(input string what);
    real w, rd, ew;
    @(posedge hr_clk);
    #(T / 2);
    w  = modp(e_t[CK_W] - e_t[CK_HR], T);
    rd = modp(e_t[CK_RD] - e_t[CK_HR], T);
    ew = modp(T / 4 + pcnt[1] * STEP, T);
    $display("tb_bow_hyperram_clk_versal: %s: hr_wclk %0.4f ns (count %0d, expected %0.4f), %s",
             what, w, pcnt[1], ew, $sformatf("hr_rd_clk %0.4f ns (count %0d) after hr_clk", rd, pcnt[0]));
    if (!near(w, ew, T, TOL))
      fail($sformatf("%s: hr_wclk %0.4f ns after hr_clk, expected T/4 + %0d steps = %0.4f", what, w, pcnt[1], ew));
    if (!rd0_ok) begin
      if (gdist(rd - T / 4 - pcnt[0] * STEP, GRID_I) > TOL)
        fail($sformatf("%s: hr_rd_clk %0.4f ns after hr_clk: read count %0d not at T/4 on the input grid (%0.4f ns)",
                       what, rd, pcnt[0], GRID_I));
      rd0    = modp(rd - pcnt[0] * STEP, T);
      rd0_ok = 1'b1;
    end else if (!near(rd, rd0 + pcnt[0] * STEP, T, TOL)) begin
      fail($sformatf("%s: hr_rd_clk %0.4f ns after hr_clk, expected %0.4f (read count %0d)", what, rd,
                     modp(rd0 + pcnt[0] * STEP, T), pcnt[0]));
    end
    allow = '{0, 0};
  endtask

  // ------------------------------------------------------------ stimulus
  // one step on port w (0 = read, 1 = write) through the PS ports directly:
  // PSEN for one hr_clk cycle, then wait for its PSDONE (the monitor checks it)
  task automatic step(input bit w, input bit inc);
    int k;
    @(posedge hr_clk);
    #0.1;
    if (w) begin
      man_wps_en  = 1'b1;
      man_wps_inc = inc;
    end else begin
      man_ps_en  = 1'b1;
      man_ps_inc = inc;
    end
    @(posedge hr_clk);   // the MMCM takes PSEN here
    #0.1;
    man_wps_en = 1'b0;
    man_ps_en  = 1'b0;
    k = 0;
    while (pend[w] && k < 70) begin
      @(posedge hr_clk);
      k++;
    end
    if (pend[w]) fail($sformatf("no PSDONE on port %0d", w));
    @(posedge hr_clk);
  endtask

  // a stepper move of port w to target (go_i for one cycle, wait for done_o)
  task automatic go(input bit w, input int target);
    if (w) begin
      go_w  = 1'b1;
      tgt_w = 16'(target);
    end else begin
      go_r  = 1'b1;
      tgt_r = 16'(target);
    end
    st_done[w] = 1'b0;
    @(posedge hr_clk);   // the stepper takes go_i here
    #0.1;
    go_w = 1'b0;
    go_r = 1'b0;
  endtask

  task automatic wait_move(input bit w, input int target, input int start, input int n0);
    int k;
    k = 0;
    while (!st_done[w] && k < 20 * iabs(target - start) + 40) begin
      @(posedge hr_clk);
      k++;
    end
    #0.1;
    if (!st_done[w]) fail($sformatf("port %0d move %0d -> %0d: no done_o", w, start, target));
    else if (st_err[w]) fail($sformatf("port %0d move %0d -> %0d: err_o", w, start, target));
    if ($signed(w ? now_w : now_r) != target)
      fail($sformatf("port %0d move %0d -> %0d: now_o %0d", w, start, target, $signed(w ? now_w : now_r)));
    if (n_en[w] - n0 != iabs(target - start))
      fail($sformatf("port %0d move %0d -> %0d: %0d PSEN", w, start, target, n_en[w] - n0));
  endtask

  task automatic move(input bit w, input int target);
    int start, n0;
    start = $signed(w ? now_w : now_r);
    n0    = n_en[w];
    @(posedge hr_clk);
    #0.1;
    go(w, target);
    wait_move(w, target, start, n0);
  endtask

  // wait until the cycle counter reaches n (0.1 ns after edge n, or later in
  // cycle n)
  task automatic wait_cyc(input int n);
    while (cyc < n) begin
      @(posedge hr_clk);
      #0.1;
    end
  endtask

  // Moves of 2 steps (up / down) on port w started at all 32 offsets d to
  // the PSDONE repeat of that port: after a repeat PSDONE in cycle r (the
  // flops see it at edge r + 1), go_i is taken at edge r + 32 + d and the
  // first PSEN at edge r + 33 + d: d = 0 is the move whose first PSEN is taken
  // together with the next repeat PSDONE.
  task automatic repeat_sweep(input bit w);
    int d, r, k, n0, start, target, c0;
    c0 = n_coinc[w];
    for (d = 0; d < 32; d++) begin
      n0 = n_rep[w];
      k  = 0;
      while (n_rep[w] == n0 && k < 80) begin
        @(posedge hr_clk);
        k++;
      end
      if (n_rep[w] == n0) begin
        fail($sformatf("port %0d: no PSDONE repeat before the move at offset %0d", w, d));
        continue;
      end
      r      = last_rep[w];
      start  = $signed(w ? now_w : now_r);
      target = (d % 2 == 0) ? start + 2 : start - 2;
      n0     = n_en[w];
      wait_cyc(r + 31 + d);
      go(w, target);
      wait_move(w, target, start, n0);
      if (d == 0 && n_coinc[w] == c0)
        fail($sformatf("port %0d: the first PSEN of the offset 0 move was not taken with a repeat PSDONE (test setup)", w));
      chk_phases($sformatf("port %0d move %0d -> %0d at repeat offset %0d", w, start, target, d));
    end
  endtask

  // lock-loss reset seen (dut.lk_rst)
  bit lk_seen = 1'b0;
  always @(posedge dut.lk_rst) lk_seen = 1'b1;

  // Loss of lock with both phases moved: which = 0 / 1: the LOCKED net of
  // MMCM_R / MMCM_H forced low for 3 us (the MMCM keeps running until the
  // lock-loss reset restarts both; they relock under the force), 2: the input
  // clock stopped for 5 us (both lose lock; the synchroniser on the input
  // clock sees it when the clock is back). locked_o low meanwhile; the
  // lock-loss reset must come and both phases be back at 0 after the relock.
  task automatic lock_loss(input int which);
    string name;
    name = (which == 0) ? "MMCM_R lock loss" : (which == 1) ? "MMCM_H lock loss" : "input clock stop";
    use_st = 1'b1;
    move(1, 30);
    move(0, 20);
    chk_phases({"before the ", name});
    mon_on  = 1'b0;
    lk_seen = 1'b0;
    @(posedge hr_clk);
    #0.1;
    case (which)
      0: force dut.locked_r = 1'b0;
      1: force dut.locked_h = 1'b0;
      default: begin
        run_mon = 1'b0;
        osc_run = 1'b0;
      end
    endcase
    repeat ((which == 2) ? 50 : 30) begin
      #100;
      if (locked !== 1'b0) fail($sformatf("locked_o high during the %s", name));
    end
    // xsim keeps a released variable at its forced value until its driver
    // changes: let it follow the MMCM's LOCKED first, then release it
    case (which)
      0: begin
        force dut.locked_r = dut.u_mmcm_r.LOCKED;
        #0.001;
        release dut.locked_r;
      end
      1: begin
        force dut.locked_h = dut.u_mmcm_h.LOCKED;
        #0.001;
        release dut.locked_h;
      end
      default: osc_run = 1'b1;
    endcase
    #0.001;
    if (dut.locked_r !== dut.u_mmcm_r.LOCKED || dut.locked_h !== dut.u_mmcm_h.LOCKED)
      fail("LOCKED nets do not follow the MMCMs after the release (test setup)");
    fork
      wait (lk_seen && locked === 1'b1);
      #300us;
    join_any
    disable fork;
    if (!lk_seen) fail($sformatf("no lock-loss reset after the %s", name));
    if (locked !== 1'b1) fail($sformatf("no relock after the %s", name));
    run_mon = 1'b1;
    repeat (20) @(posedge hr_clk);
    if ($signed(now_w) != 0 || $signed(now_r) != 0) fail("stepper now_o not 0 after the relock (test setup)");
    chk_phases({"after the ", name});
    mon_on = 1'b1;
  endtask

  // ---------------------------------------------------------------- main
  int k, n0;

  initial begin
    $display("tb_bow_hyperram_clk_versal: input %0.3f ns, VCO x%0d, T %0.4f ns, %0d steps of %0.4f ps",
             TIN, VcoMult, T, STEPS, STEP * 1000.0);

    // ---- PSEN before lock: both ports, one-cycle pulses (increments) taken
    // at the 2nd and 4th hr_clk rising edges, LOCKED still low at the 5th
    wait (hr_clk === 1'b1);
    #0.1;
    for (k = 0; k < 2; k++) begin
      man_wps_en  = 1'b1;
      man_wps_inc = 1'b1;
      man_ps_en   = 1'b1;
      man_ps_inc  = 1'b1;
      @(posedge hr_clk);   // taken here
      #0.1;
      man_wps_en = 1'b0;
      man_ps_en  = 1'b0;
      @(posedge hr_clk);
      #0.1;
    end
    if (locked !== 1'b0) fail("locked before the PSEN-before-lock pulses were taken (test setup)");
    if (n_pre[0] != 2 || n_pre[1] != 2)
      fail($sformatf("%0d / %0d PSEN before lock (read / write), expected 2 (test setup)", n_pre[0], n_pre[1]));

    fork
      wait (locked === 1'b1);
      #50us;
    join_any
    disable fork;
    if (locked !== 1'b1) begin
      fail("no lock");
      $display("tb_bow_hyperram_clk_versal: FAIL (%0d errors)", errors);
      $finish;
    end
    $display("tb_bow_hyperram_clk_versal: locked at %0t, %0d hr_clk rising edges before", $time,
             e_cnt[CK_HR]);
    repeat (40) @(posedge hr_clk);
    if (n_done[0] + n_done[1] + n_rep[0] + n_rep[1] != 0 || n_en[0] + n_en[1] != 0)
      fail("PSDONE after the PSEN before lock");
    @(posedge hr_clk);
    #0.001;
    off_in0   = modp(e_t[CK_HR] - e_t[CK_OSC], GRID_I);
    off_in_ok = 1'b1;
    mon_on    = 1'b1;
    $display("tb_bow_hyperram_clk_versal: hr_clk %0.4f ns after the input rising edge (mod %0.4f)", off_in0,
             GRID_I);

    // ---- frequencies
    period_of(CK_HR, 100, "hr_clk");
    period_of(CK_W, 100, "hr_wclk");
    period_of(CK_RD, 100, "hr_rd_clk");

    // ---- phases at lock (counts 0: the PSEN before lock did not step)
    chk_phases("at lock");

    // ---- single steps: write +1 (hr_wclk moves, hr_rd_clk not, no read
    // PSDONE), read +1 (hr_rd_clk only), 32-cycle repeats, back to 0
    step(1, 1);
    chk_phases("write +1");
    if (n_done[0] + n_rep[0] != 0) fail("read PSDONE on a write step");
    step(0, 1);
    chk_phases("read +1");
    repeat (110) @(posedge hr_clk);
    $display("tb_bow_hyperram_clk_versal: PSDONE repeats so far: read %0d, write %0d", n_rep[0], n_rep[1]);
    if (n_rep[0] < 3 || n_rep[1] < 3) fail("fewer than 3 PSDONE repeats on a port after 110 cycles");
    step(1, 0);
    step(0, 0);
    chk_phases("single steps back to 0");

    // ---- bow_mmcm_ps moves: write +5, -7 (through 0), 0; read +9, -4, +1
    use_st = 1'b1;
    move(1, 5);
    chk_phases("stepper write 0 -> 5");
    move(1, -7);
    chk_phases("stepper write 5 -> -7");
    move(1, 0);
    chk_phases("stepper write -7 -> 0");
    move(0, 9);
    chk_phases("stepper read 0 -> 9");
    move(0, -4);
    chk_phases("stepper read 9 -> -4");
    move(0, 1);
    chk_phases("stepper read -4 -> 1");
    // a refused move (beyond Limit) and a move to the current phase: no PSEN
    n0 = n_en[1];
    @(posedge hr_clk);
    #0.1;
    go(1, LIMIT + 1);
    repeat (3) @(posedge hr_clk);
    #0.1;
    if (!st_done[1] || !st_err[1] || n_en[1] != n0) fail("stepper: move beyond Limit not refused");
    move(1, 0);

    // ---- moves at all offsets to the PSDONE repeat
    $display("tb_bow_hyperram_clk_versal: moves at all 32 offsets to the PSDONE repeat @%0t", $time);
    repeat_sweep(1);
    repeat_sweep(0);

    // ---- write phase over a full period (STEPS steps in 8 moves) and read
    // phase -STEPS (4 moves): wraps back to phase 0
    $display("tb_bow_hyperram_clk_versal: write sweep of %0d steps @%0t", STEPS, $time);
    for (k = 1; k <= 8; k++) begin
      move(1, k * STEPS / 8);
      chk_phases($sformatf("write %0d steps", k * STEPS / 8));
    end
    $display("tb_bow_hyperram_clk_versal: read sweep of -%0d steps @%0t", STEPS, $time);
    for (k = 1; k <= 4; k++) begin
      move(0, 1 - k * STEPS / 4);
      chk_phases($sformatf("read %0d steps", 1 - k * STEPS / 4));
    end

    // ---- rst_i returns both phases to 0
    move(1, STEPS + 40);
    move(0, 31 - STEPS);
    chk_phases("before rst_i");
    mon_on = 1'b0;
    @(posedge hr_clk);
    #0.1;
    rst = 1'b1;
    #100;
    if (locked !== 1'b0) fail("locked_o high during rst_i");
    rst = 1'b0;
    fork
      wait (locked === 1'b1);
      #50us;
    join_any
    disable fork;
    if (locked !== 1'b1) fail("no relock after rst_i");
    repeat (20) @(posedge hr_clk);
    chk_phases("after rst_i");
    mon_on = 1'b1;

    // ---- loss of lock: MMCM_R alone, MMCM_H alone, input clock stopped
    lock_loss(0);
    lock_loss(1);
    lock_loss(2);

    // ---- summary
    mon_on = 1'b0;
    $display("tb_bow_hyperram_clk_versal: PSEN taken read %0d / write %0d, before lock %0d / %0d; PSDONE latency 12: %0d / %0d, 13: %0d / %0d",
             n_en[0], n_en[1], n_pre[0], n_pre[1], n12[0], n12[1], n13[0], n13[1]);
    $display("tb_bow_hyperram_clk_versal: PSDONE repeats %0d / %0d, PSEN taken with a repeat PSDONE %0d / %0d, %0d PS errors",
             n_rep[0], n_rep[1], n_coinc[0], n_coinc[1], ps_err);
    $display("tb_bow_hyperram_clk_versal: high / low phases: %0d checks (%0.4f .. %0.4f ns), %0d errors, %0d model pulses at 0 -> -1 tolerated",
             pw_chk, pw_min, pw_max, pw_err, n_art);
    $display("tb_bow_hyperram_clk_versal: hr_clk to input %0d checks / %0d errors; locked_o drops %0d; %s %0d checks, %0d errors",
             in_chk, in_err, lock_err, "locked_o only with running clocks:", run_chk, run_err);
    if (n_coinc[0] == 0 || n_coinc[1] == 0) fail("no PSEN taken with a repeat PSDONE (test setup)");
    if (n_rep[0] < 32 || n_rep[1] < 32) fail("too few PSDONE repeats (test setup)");
    if (in_chk < 10000 || pw_chk < 50000 || run_chk < 10000) fail("too few clock checks (test setup)");
    errors += ps_err + pw_err + in_err + lock_err + run_err;
    if (errors == 0) $display("tb_bow_hyperram_clk_versal: PASS");
    else $display("tb_bow_hyperram_clk_versal: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #5ms;
    $display("tb_bow_hyperram_clk_versal: FAIL (timeout)");
    $finish;
  end
endmodule
