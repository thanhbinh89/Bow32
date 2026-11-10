// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Test of the Versal DDR clock module bow_ddr_clk_versal (two MMCME5) with the
// unisim models (Vivado simulator, `make -C hw/fpga/common/dv test-vclk`).
// Parameters TIN (ClkInPeriodNs) / VcoMult / DdrDivide / SysDivide / DiffIn
// select the configuration (Makefile VCLK_CFGS: ddr200 = the Huins VP1902
// 200 MHz reference, VCO 200 * 16; ddr100 = 100 MHz, VCO 100 * 32; both
// 133.333 MHz DDR clocks with 768 fine phase steps per CK).
//
// The fine phase ports are driven directly (single steps) and through two
// bow_mmcm_ps steppers, as bow_ddr_dfi drives them (write: wps_*, read: ps_*;
// stepper reset = locked_ddr_o).
//
// Checks:
//  * PSEN before lock (one-cycle pulses on both ports while the outputs run
//    and LOCKED is low) is ignored: no PSDONE, no phase change;
//  * periods of ddr_clk, wclk, wclk90, rd_clk (T), clk_sys (TS), ddr_sys_clk
//    (4T) and clk_ibuf_o (TIN); clk_ibuf_o has the edges of the input pad;
//  * at write count 0 wclk has the rising edges of ddr_clk and wclk90 = wclk
//    + T/4 (static 90 deg), within 3 ps (the model rounds to 1 ps); rd_clk at
//    read count 0 is on the common grid of ddr_clk and the input clock (MMCM_B
//    may lock in any slot of it);
//  * every write or read step: wclk and wclk90 move by T / STEPS together
//    (still T/4 apart), rd_clk only on read steps; phases checked against a
//    mirror of the MMCME5 phase counters after every single step and every
//    stepper move, including a write sweep over a full period (STEPS steps
//    back to phase 0) and a read sweep of -STEPS;
//  * PSDONE (the model drives it 100 ps after its PSCLK edge; sampled in the
//    middle of each ddr_clk cycle, i.e. as a flop takes it at the next edge):
//    a flop takes it at the 12th or 13th ddr_clk rising edge after the one
//    that took PSEN, a one cycle pulse; while PSEN stays low the model repeats
//    it every 32 cycles, a new PSEN clears the repeat unless it is taken with
//    a repeat PSDONE (then the old 32-cycle cadence goes on): any other
//    PSDONE, or a missing repeat, is an error; PSEN never longer than one
//    cycle or while a step is pending;
//  * bow_mmcm_ps moves on both ports (several steps, both directions, through
//    zero) end with done and without err, now_o = target, one PSEN per step;
//    the moves are started at all 32 offsets to the PSDONE repeat, among them
//    the move whose first PSEN is taken together with a repeat PSDONE;
//  * clk_sys, ddr_clk and ddr_sys_clk never move: clk_sys rising edges on the
//    common grid of clk_sys and ddr_clk, ddr_clk keeps its phase to the input
//    clock, every ddr_sys_clk rising edge is a ddr_clk rising edge with four
//    ddr_clk rising edges per ddr_sys_clk period;
//  * every high / low phase of the clocks T/2 (TS/2, 2T for ddr_sys_clk) +- 40
//    ps while the phases move. The MMCME5 model turns a decrement from count
//    0 to -1 into a delay of T - STEP: one high or low phase of T/2 + T - STEP
//    on each clock of that port, tolerated exactly there (counted, printed);
//  * locked_sys_o / locked_ddr_o stay high while the phases move, and are
//    high only while the clocks run;
//  * rst_i returns both phases to 0 (locked_ddr_o low meanwhile);
//  * a loss of lock returns both phases to 0 (lock-loss reset of both MMCMs,
//    dut.lk_rst seen): the input clock stopped for 5 us (locked_ddr_o and
//    locked_sys_o fall); MMCM_B alone (its LOCKED net forced low: the reset
//    must cover MMCM_A, where the write phase lives) and MMCM_A alone
//    (locked_sys_o low): locked_ddr_o stays low while either LOCKED is low.
// The test prints "tb_bow_ddr_clk_versal: PASS" or "... FAIL (<n> errors)".

`timescale 1ns/1ps

module tb_bow_ddr_clk_versal #(
  parameter real TIN       = 5.0,    // input clock period (ClkInPeriodNs)
  parameter int  VcoMult   = 16,
  parameter int  DdrDivide = 24,
  parameter int  SysDivide = 64,
  parameter bit  DiffIn    = 1'b1
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

  localparam real VCO    = TIN / VcoMult;                    // VCO period (ns)
  localparam real T      = VCO * DdrDivide;                  // DDR clock period
  localparam real TS     = VCO * SysDivide;                  // clk_sys period
  localparam int  STEPS  = 32 * DdrDivide;                   // fine steps per T
  localparam real STEP   = T / STEPS;                        // VCO / 32
  localparam real GRID_S = VCO * gcd(DdrDivide, SysDivide);  // common edges of clk_sys / ddr_clk
  localparam real GRID_I = VCO * gcd(DdrDivide, VcoMult);    // common edges of input / ddr_clk
  localparam int  LIMIT  = 2 * STEPS;                        // bow_mmcm_ps Limit
  localparam real TOL    = 0.003;                            // phase tolerance
  localparam real PWTOL  = 0.040;                            // pulse width tolerance
  localparam real ART    = 1.5 * T - STEP;                   // model pulse at 0 -> -1

  // ---------------------------------------------------------------- clocks
  logic osc = 1'b0;
  logic osc_run = 1'b1;
  logic rst = 1'b0;
  always #(TIN / 2) if (osc_run) osc = ~osc;

  wire  clk_sys, ddr_clk, ddr_sys_clk, wclk, wclk90, rd_clk, clk_ibuf, locked_sys, locked_ddr;
  wire  ps_done, wps_done;

  // PS ports: the testbench (single steps) or the two steppers
  logic use_st = 1'b0;
  logic man_ps_en = 1'b0, man_ps_inc = 1'b0, man_wps_en = 1'b0, man_wps_inc = 1'b0;
  wire  st_ps_en, st_ps_inc, st_wps_en, st_wps_inc;
  wire  ps_en   = use_st ? st_ps_en   : man_ps_en;
  wire  ps_inc  = use_st ? st_ps_inc  : man_ps_inc;
  wire  wps_en  = use_st ? st_wps_en  : man_wps_en;
  wire  wps_inc = use_st ? st_wps_inc : man_wps_inc;

  bow_ddr_clk_versal #(
    .ClkInPeriodNs (TIN),
    .DiffIn        (DiffIn),
    .InDivide      (1),
    .VcoMult       (VcoMult),
    .SysDivide     (SysDivide),
    .DdrDivide     (DdrDivide)
  ) dut (
    .clk_pad_i    (osc),
    .clk_pad_n_i  (~osc),
    .rst_i        (rst),
    .clk_sys_o    (clk_sys),
    .ddr_clk_o    (ddr_clk),
    .ddr_sys_clk_o(ddr_sys_clk),
    .ddr_wclk_o   (wclk),
    .ddr_wclk90_o (wclk90),
    .ddr_rd_clk_o (rd_clk),
    .clk_ibuf_o   (clk_ibuf),
    .locked_sys_o (locked_sys),
    .locked_ddr_o (locked_ddr),
    .ps_en_i      (ps_en),
    .ps_inc_i     (ps_inc),
    .ps_done_o    (ps_done),
    .wps_en_i     (wps_en),
    .wps_inc_i    (wps_inc),
    .wps_done_o   (wps_done)
  );

  // ------------------------------------------------------------- steppers
  logic        go_r = 1'b0, go_w = 1'b0;
  logic [15:0] tgt_r = '0, tgt_w = '0;
  wire         busy_r, done_r, err_r, busy_w, done_w, err_w;
  wire  [15:0] now_r, now_w;

  bow_mmcm_ps #(.Limit (LIMIT), .Timeout (64)) u_ps_r (
    .clk_i     (ddr_clk),
    .rst_ni    (locked_ddr),
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
    .clk_i     (ddr_clk),
    .rst_ni    (locked_ddr),
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
  function automatic real gdist(real x, real p);   // distance of x to a multiple of p
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
  localparam int CK_DDR = 0, CK_W = 1, CK_W90 = 2, CK_RD = 3, CK_SYS = 4, CK_DSYS = 5,
                 CK_IBUF = 6, CK_OSC = 7;
  realtime e_t[8] = '{default: -1.0e6};
  int      e_cnt[8] = '{default: 0};
  always @(posedge ddr_clk)     begin e_t[CK_DDR]  = $realtime; e_cnt[CK_DDR]++;  end
  always @(posedge wclk)        begin e_t[CK_W]    = $realtime; e_cnt[CK_W]++;    end
  always @(posedge wclk90)      begin e_t[CK_W90]  = $realtime; e_cnt[CK_W90]++;  end
  always @(posedge rd_clk)      begin e_t[CK_RD]   = $realtime; e_cnt[CK_RD]++;   end
  always @(posedge clk_sys)     begin e_t[CK_SYS]  = $realtime; e_cnt[CK_SYS]++;  end
  always @(posedge ddr_sys_clk) begin e_t[CK_DSYS] = $realtime; e_cnt[CK_DSYS]++; end
  always @(posedge clk_ibuf)    begin e_t[CK_IBUF] = $realtime; e_cnt[CK_IBUF]++; end
  always @(posedge osc)         begin e_t[CK_OSC]  = $realtime; e_cnt[CK_OSC]++;  end

  // ---------------------------------------------------- PSEN / PSDONE monitor
  // Sampled in the middle of each ddr_clk cycle c (after rising edge c): PSEN
  // and PSDONE there are what the MMCM and a flop take at edge c + 1. Port 0 =
  // read (ps_*, MMCM_B), port 1 = write (wps_*, MMCM_A). pcnt mirrors the
  // phase counters of the MMCME5 model (increment wraps STEPS - 1 -> 0,
  // decrement wraps 1 - STEPS -> 0); by the contract of the module it returns
  // to 0 whenever locked_ddr_o falls.
  int  cyc = 0;                    // ddr_clk rising edges
  bit  locked_once = 1'b0;         // before the first lock any PSDONE is an error
  int  pcnt[2]    = '{0, 0};
  bit  pend[2]    = '{0, 0};       // PSEN taken, its PSDONE not seen yet
  bit  coinc[2]   = '{0, 0};       // ... and it was taken together with a repeat PSDONE
  bit  en_q[2]    = '{0, 0};
  int  s_en[2]    = '{0, 0};       // edge that took the pending PSEN
  int  cad[2]     = '{-1, -1};     // cycle of the next repeat PSDONE (-1: none)
  int  n_en[2]    = '{0, 0}, n_pre[2] = '{0, 0}, n_done[2] = '{0, 0}, n_rep[2] = '{0, 0};
  int  n_coinc[2] = '{0, 0}, n12[2] = '{0, 0}, n13[2] = '{0, 0}, last_rep[2] = '{0, 0};
  int  allow[3]   = '{0, 0, 0};    // tolerated model pulses: wclk, wclk90, rd_clk
  int  n_art      = 0, ps_err = 0;

  task automatic ps_fail(int p, string msg);
    ps_err++;
    if (ps_err < 20) $display("ERROR @%0t: %s port: %s", $time, (p != 0) ? "write" : "read", msg);
  endtask

  function automatic int ps_next(int c, bit inc);
    if (inc) return (c < STEPS - 1) ? c + 1 : 0;
    return (c > 1 - STEPS) ? c - 1 : 0;
  endfunction

  always @(posedge ddr_clk) begin
    bit en[2], inc[2], dn[2], lk;
    cyc++;
    #(T / 2);
    en[0]  = (ps_en === 1'b1);
    en[1]  = (wps_en === 1'b1);
    inc[0] = (ps_inc === 1'b1);
    inc[1] = (wps_inc === 1'b1);
    dn[0]  = (ps_done === 1'b1);
    dn[1]  = (wps_done === 1'b1);
    lk     = (locked_ddr === 1'b1);
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
          if (!inc[p] && pcnt[p] == 0) begin
            if (p != 0) begin
              allow[0]++;
              allow[1]++;
            end else begin
              allow[2]++;
            end
          end
          pcnt[p] = ps_next(pcnt[p], inc[p]);
        end
      end
      en_q[p] = en[p];
    end
  end

  // the phases return to 0 whenever locked_ddr_o falls (rst_i, lock-loss reset)
  bit rd0_ok = 1'b0;
  always @(negedge locked_ddr) begin
    pcnt    = '{0, 0};
    pend    = '{0, 0};
    coinc   = '{0, 0};
    cad     = '{-1, -1};
    rd0_ok  = 1'b0;
  end
  always @(posedge locked_ddr) locked_once = 1'b1;

  // stepper done / err (flop outputs, looked at just after each edge)
  bit st_done[2] = '{0, 0}, st_err[2] = '{0, 0};
  always @(posedge ddr_clk) begin
    #0.05;
    if (done_r === 1'b1) begin st_done[0] = 1'b1; st_err[0] = (err_r !== 1'b0); end
    if (done_w === 1'b1) begin st_done[1] = 1'b1; st_err[1] = (err_w !== 1'b0); end
  end

  // ------------------------------------------------------- clock monitors
  bit  mon_on = 1'b0;     // from lock to a deliberate reset / lock loss
  int  pw_err = 0, pw_chk = 0, sys_err = 0, sys_chk = 0, in_err = 0, in_chk = 0;
  int  dsys_err = 0, dsys_chk = 0, lock_err = 0;
  real pw_min = 100.0, pw_max = 0.0;
  real off_in0 = 0.0;     // ddr_clk after the input rising edge (mod GRID_I) at lock
  bit  off_in_ok = 1'b0;

  // Every high / low phase: nom +- PWTOL; on the shifted clocks (k = 0 wclk,
  // 1 wclk90, 2 rd_clk) one pulse of ART per 0 -> -1 decrement of their port.
  task automatic pw_check(string name, int k, realtime w, real nom);
    if (!mon_on) return;
    pw_chk++;
    if (w >= nom - PWTOL && w <= nom + PWTOL) begin
      if (nom == T / 2 && w < pw_min) pw_min = w;
      if (nom == T / 2 && w > pw_max) pw_max = w;
    end else if (k >= 0 && k <= 2 && allow[k] > 0 && w >= ART - PWTOL && w <= ART + PWTOL) begin
      allow[k]--;
      n_art++;
      $display("tb_bow_ddr_clk_versal: %s %0.4f ns phase at a 0 -> -1 step (MMCME5 model, tolerated)",
               name, w);
    end else begin
      pw_err++;
      if (pw_err < 10)
        $display("ERROR @%0t: %s high / low phase %0.4f ns (nominal %0.4f)", $time, name, w, nom);
    end
  endtask
  realtime c_ddr = 0, c_w = 0, c_w90 = 0, c_rd = 0, c_sys = 0, c_dsys = 0;
  always @(ddr_clk)     begin pw_check("ddr_clk", -1, $realtime - c_ddr, T / 2);   c_ddr  = $realtime; end
  always @(wclk)        begin pw_check("wclk", 0, $realtime - c_w, T / 2);         c_w    = $realtime; end
  always @(wclk90)      begin pw_check("wclk90", 1, $realtime - c_w90, T / 2);     c_w90  = $realtime; end
  always @(rd_clk)      begin pw_check("rd_clk", 2, $realtime - c_rd, T / 2);      c_rd   = $realtime; end
  always @(clk_sys)     begin pw_check("clk_sys", -1, $realtime - c_sys, TS / 2);  c_sys  = $realtime; end
  always @(ddr_sys_clk) begin pw_check("ddr_sys_clk", -1, $realtime - c_dsys, 2 * T); c_dsys = $realtime; end

  // clk_sys rising edges on the common grid of clk_sys and ddr_clk (neither
  // moves with the write phase)
  always @(posedge clk_sys) begin
    realtime ts;
    ts = $realtime;
    #0.001;
    if (mon_on) begin
      sys_chk++;
      if (gdist(ts - e_t[CK_DDR], GRID_S) > 0.0015) begin
        sys_err++;
        if (sys_err < 5)
          $display("ERROR @%0t: clk_sys edge %0.4f ns from the ddr_clk grid", $time,
                   modp(ts - e_t[CK_DDR], GRID_S));
      end
    end
  end

  // ddr_clk keeps its phase to the input clock (mod their common grid)
  always @(posedge ddr_clk) begin
    #0.001;
    if (mon_on && off_in_ok) begin
      in_chk++;
      if (!near(e_t[CK_DDR] - e_t[CK_OSC], off_in0, GRID_I, 0.0015)) begin
        in_err++;
        if (in_err < 5)
          $display("ERROR @%0t: ddr_clk %0.4f ns after the input edge (mod %0.4f), %0.4f at lock", $time,
                   modp(e_t[CK_DDR] - e_t[CK_OSC], GRID_I), GRID_I, off_in0);
      end
    end
  end

  // every ddr_sys_clk rising edge is a ddr_clk rising edge, four ddr_clk
  // rising edges per ddr_sys_clk period
  int dsys_c0 = 0;
  always @(posedge ddr_sys_clk) begin
    realtime ts;
    int n;
    ts = $realtime;
    #0.001;              // the ddr_clk edge of the same time step is counted
    n = e_cnt[CK_DDR] - dsys_c0;
    dsys_c0 = e_cnt[CK_DDR];
    if (mon_on) begin
      dsys_chk++;
      if (ts - e_t[CK_DDR] > 0.0015 || e_t[CK_DDR] - ts > 0.0015 || n != 4) begin
        dsys_err++;
        if (dsys_err < 5)
          $display("ERROR @%0t: ddr_sys_clk edge %0.4f ns after the last ddr_clk edge, %0d ddr_clk edges in its period",
                   $time, ts - e_t[CK_DDR], n);
      end
    end
  end

  // LOCKED stays high while the phases move
  always @(locked_sys or locked_ddr) begin
    if (mon_on && (locked_sys !== 1'b1 || locked_ddr !== 1'b1)) begin
      lock_err++;
      if (lock_err < 5)
        $display("ERROR @%0t: LOCKED dropped (sys %b, ddr %b)", $time, locked_sys, locked_ddr);
    end
  end

  // LOCKED only while the clocks run: every T/4, while locked_ddr_o is high
  // each DDR clock had a rising edge within 2T + 2 ns (2T: the model's 0 -> -1
  // pulse; the model drops LOCKED 1 ns after RST), clk_sys within TS + 2 ns,
  // ddr_sys_clk within 4T + 2 ns; locked_sys_o likewise for the MMCM_A clocks.
  // Not while the input clock is stopped (the model stops its outputs before
  // it drops LOCKED).
  bit run_mon = 1'b1;
  int run_err = 0, run_chk = 0;
  always begin
    #(T / 4);
    if (run_mon && locked_sys === 1'b1) begin
      run_chk++;
      if ($realtime - e_t[CK_DDR] > T + 2.0 || $realtime - e_t[CK_W] > 2 * T + 2.0 ||
          $realtime - e_t[CK_W90] > 2 * T + 2.0 || $realtime - e_t[CK_SYS] > TS + 2.0 ||
          $realtime - e_t[CK_DSYS] > 4 * T + 2.0 ||
          (locked_ddr === 1'b1 && $realtime - e_t[CK_RD] > 2 * T + 2.0)) begin
        run_err++;
        if (run_err < 5)
          $display("ERROR @%0t: LOCKED (sys %b, ddr %b) high, last rising edges ddr %0.3f wclk %0.3f %s",
                   $time, locked_sys, locked_ddr, $realtime - e_t[CK_DDR], $realtime - e_t[CK_W],
                   $sformatf("wclk90 %0.3f rd %0.3f sys %0.3f ddr_sys %0.3f ns ago",
                             $realtime - e_t[CK_W90], $realtime - e_t[CK_RD],
                             $realtime - e_t[CK_SYS], $realtime - e_t[CK_DSYS]));
      end
    end
  end

  // ------------------------------------------------------- measurements
  task automatic period_of(input int k, input int n, input real nom, input string name);
    int      c0;
    realtime t0;
    real     p;
    c0 = e_cnt[k];
    while (e_cnt[k] == c0) #0.25;
    t0 = e_t[k];
    c0 = e_cnt[k];
    while (e_cnt[k] < c0 + n) #0.25;
    p = (e_t[k] - t0) / n;
    $display("tb_bow_ddr_clk_versal: %s period %0.4f ns (expected %0.4f)", name, p, nom);
    if (p < nom - 0.001 || p > nom + 0.001) fail($sformatf("%s period %0.4f ns, expected %0.4f", name, p, nom));
  endtask

  // Phases after the ddr_clk rising edge, from the last rising edges half a
  // period after it, checked against the counter mirror. rd0 = rd_clk at read
  // count 0, re-learned after every reset (any slot of the input grid).
  real rd0 = 0.0;
  task automatic chk_phases(input string what);
    real w, w90, rd, ew;
    @(posedge ddr_clk);
    #(T / 2);
    w   = modp(e_t[CK_W] - e_t[CK_DDR], T);
    w90 = modp(e_t[CK_W90] - e_t[CK_DDR], T);
    rd  = modp(e_t[CK_RD] - e_t[CK_DDR], T);
    ew  = modp(pcnt[1] * STEP, T);
    $display("tb_bow_ddr_clk_versal: %s: wclk %0.4f ns (count %0d, expected %0.4f), wclk90 - wclk %0.4f, %s",
             what, w, pcnt[1], ew, modp(w90 - w, T),
             $sformatf("rd_clk %0.4f ns (count %0d) after ddr_clk", rd, pcnt[0]));
    if (!near(w, ew, T, TOL))
      fail($sformatf("%s: wclk %0.4f ns after ddr_clk, expected %0.4f (write count %0d)", what, w, ew, pcnt[1]));
    if (!near(w90, ew + T / 4, T, TOL))
      fail($sformatf("%s: wclk90 %0.4f ns after ddr_clk, expected wclk + T/4 = %0.4f", what, w90,
                     modp(ew + T / 4, T)));
    if (!rd0_ok) begin
      if (gdist(rd - pcnt[0] * STEP, GRID_I) > TOL)
        fail($sformatf("%s: rd_clk %0.4f ns after ddr_clk: read count %0d not on the input grid (%0.4f ns)",
                       what, rd, pcnt[0], GRID_I));
      rd0    = modp(rd - pcnt[0] * STEP, T);
      rd0_ok = 1'b1;
    end else if (!near(rd, rd0 + pcnt[0] * STEP, T, TOL)) begin
      fail($sformatf("%s: rd_clk %0.4f ns after ddr_clk, expected %0.4f (read count %0d)", what, rd,
                     modp(rd0 + pcnt[0] * STEP, T), pcnt[0]));
    end
    allow = '{0, 0, 0};
  endtask

  // ------------------------------------------------------------ stimulus
  // one step on port w (0 = read, 1 = write) through the PS ports directly:
  // PSEN for one ddr_clk cycle, then wait for its PSDONE (the monitor checks it)
  task automatic step(input bit w, input bit inc);
    int k;
    @(posedge ddr_clk);
    #0.1;
    if (w) begin
      man_wps_en  = 1'b1;
      man_wps_inc = inc;
    end else begin
      man_ps_en  = 1'b1;
      man_ps_inc = inc;
    end
    @(posedge ddr_clk);   // the MMCM takes PSEN here
    #0.1;
    man_wps_en = 1'b0;
    man_ps_en  = 1'b0;
    k = 0;
    while (pend[w] && k < 70) begin
      @(posedge ddr_clk);
      k++;
    end
    if (pend[w]) fail($sformatf("no PSDONE on port %0d", w));
    @(posedge ddr_clk);
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
    @(posedge ddr_clk);   // the stepper takes go_i here
    #0.1;
    go_w = 1'b0;
    go_r = 1'b0;
  endtask

  task automatic wait_move(input bit w, input int target, input int start, input int n0);
    int k;
    k = 0;
    while (!st_done[w] && k < 20 * iabs(target - start) + 40) begin
      @(posedge ddr_clk);
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
    @(posedge ddr_clk);
    #0.1;
    go(w, target);
    wait_move(w, target, start, n0);
  endtask

  // wait until the cycle counter reaches n (0.1 ns after edge n, or later in
  // cycle n)
  task automatic wait_cyc(input int n);
    while (cyc < n) begin
      @(posedge ddr_clk);
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
        @(posedge ddr_clk);
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
  // MMCM_B / MMCM_A forced low for 3 us (the MMCM keeps running until the
  // lock-loss reset restarts both; they relock under the force), 2: the input
  // clock stopped for 5 us (both lose lock; the synchroniser on the input
  // clock sees it when the clock is back). locked_ddr_o (and locked_sys_o for
  // MMCM_A) low meanwhile; the lock-loss reset must come and both phases be
  // back at 0 after the relock.
  task automatic lock_loss(input int which);
    string name;
    name = (which == 0) ? "MMCM_B lock loss" : (which == 1) ? "MMCM_A lock loss" : "input clock stop";
    use_st = 1'b1;
    move(1, 30);
    move(0, 20);
    chk_phases({"before the ", name});
    mon_on  = 1'b0;
    lk_seen = 1'b0;
    @(posedge ddr_clk);
    #0.1;
    case (which)
      0: force dut.locked_b = 1'b0;
      1: force dut.locked_a = 1'b0;
      default: begin
        run_mon = 1'b0;
        osc_run = 1'b0;
      end
    endcase
    repeat ((which == 2) ? 50 : 30) begin
      #100;
      if (locked_ddr !== 1'b0) fail($sformatf("locked_ddr_o high during the %s", name));
      if (which != 0 && locked_sys !== 1'b0) fail($sformatf("locked_sys_o high during the %s", name));
    end
    // xsim keeps a released variable at its forced value until its driver
    // changes: let it follow the MMCM's LOCKED first, then release it
    case (which)
      0: begin
        force dut.locked_b = dut.u_mmcm_b.LOCKED;
        #0.001;
        release dut.locked_b;
      end
      1: begin
        force dut.locked_a = dut.u_mmcm_a.LOCKED;
        #0.001;
        release dut.locked_a;
      end
      default: osc_run = 1'b1;
    endcase
    #0.001;
    if (dut.locked_a !== dut.u_mmcm_a.LOCKED || dut.locked_b !== dut.u_mmcm_b.LOCKED)
      fail("LOCKED nets do not follow the MMCMs after the release (test setup)");
    fork
      wait (lk_seen && locked_ddr === 1'b1);
      #300us;
    join_any
    disable fork;
    if (!lk_seen) fail($sformatf("no lock-loss reset after the %s", name));
    if (locked_ddr !== 1'b1) fail($sformatf("no relock after the %s", name));
    run_mon = 1'b1;
    repeat (20) @(posedge clk_sys);
    if ($signed(now_w) != 0 || $signed(now_r) != 0) fail("stepper now_o not 0 after the relock (test setup)");
    chk_phases({"after the ", name});
    mon_on = 1'b1;
  endtask

  // ---------------------------------------------------------------- main
  int k, n0;
  real p;

  initial begin
    $display("tb_bow_ddr_clk_versal: input %0.3f ns (DiffIn %0d), VCO x%0d, T %0.4f ns, %0d steps of %0.4f ps",
             TIN, DiffIn, VcoMult, T, STEPS, STEP * 1000.0);

    // ---- PSEN before lock: both ports, one-cycle pulses (increments) taken
    // at the 2nd and 4th ddr_clk rising edges, LOCKED still low at the 5th
    wait (ddr_clk === 1'b1);
    #0.1;
    for (k = 0; k < 2; k++) begin
      man_wps_en  = 1'b1;
      man_wps_inc = 1'b1;
      man_ps_en   = 1'b1;
      man_ps_inc  = 1'b1;
      @(posedge ddr_clk);   // taken here
      #0.1;
      man_wps_en = 1'b0;
      man_ps_en  = 1'b0;
      @(posedge ddr_clk);
      #0.1;
    end
    if (locked_ddr !== 1'b0 || locked_sys !== 1'b0)
      fail("locked before the PSEN-before-lock pulses were taken (test setup)");
    if (n_pre[0] != 2 || n_pre[1] != 2)
      fail($sformatf("%0d / %0d PSEN before lock (read / write), expected 2 (test setup)", n_pre[0], n_pre[1]));

    fork
      wait (locked_ddr === 1'b1);
      #50us;
    join_any
    disable fork;
    if (locked_ddr !== 1'b1) begin
      fail("no lock");
      $display("tb_bow_ddr_clk_versal: FAIL (%0d errors)", errors);
      $finish;
    end
    $display("tb_bow_ddr_clk_versal: locked at %0t, %0d ddr_clk rising edges before", $time,
             e_cnt[CK_DDR]);
    repeat (20) @(posedge clk_sys);
    if (n_done[0] + n_done[1] + n_rep[0] + n_rep[1] != 0 || n_en[0] + n_en[1] != 0)
      fail("PSDONE after the PSEN before lock");
    @(posedge ddr_clk);
    #0.001;
    off_in0   = modp(e_t[CK_DDR] - e_t[CK_OSC], GRID_I);
    off_in_ok = 1'b1;
    mon_on    = 1'b1;

    // ---- frequencies
    period_of(CK_DDR, 100, T, "ddr_clk");
    period_of(CK_W, 100, T, "wclk");
    period_of(CK_W90, 100, T, "wclk90");
    period_of(CK_RD, 100, T, "rd_clk");
    period_of(CK_SYS, 50, TS, "clk_sys");
    period_of(CK_DSYS, 50, 4 * T, "ddr_sys_clk");
    period_of(CK_IBUF, 100, TIN, "clk_ibuf");
    // clk_ibuf_o: the input pad through its IBUF(DS)
    for (k = 0; k < 20; k++) begin
      @(posedge osc);
      #0.001;
      if (e_t[CK_IBUF] != e_t[CK_OSC] || clk_ibuf !== osc)
        fail($sformatf("clk_ibuf_o rising edge %0.4f ns from the input", e_t[CK_IBUF] - e_t[CK_OSC]));
      @(negedge osc);
      #0.001;
      if (clk_ibuf !== osc) fail("clk_ibuf_o does not follow the input");
    end

    // ---- phases at lock (counts 0: the PSEN before lock did not step)
    chk_phases("at lock");

    // ---- single steps: write +1 (wclk / wclk90 move, rd_clk not, no read
    // PSDONE), read +1 (rd_clk only), 32-cycle repeats, back to 0
    step(1, 1);
    chk_phases("write +1");
    if (n_done[0] + n_rep[0] != 0) fail("read PSDONE on a write step");
    step(0, 1);
    chk_phases("read +1");
    repeat (110) @(posedge ddr_clk);
    $display("tb_bow_ddr_clk_versal: PSDONE repeats so far: read %0d, write %0d", n_rep[0], n_rep[1]);
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
    @(posedge ddr_clk);
    #0.1;
    go(1, LIMIT + 1);
    repeat (3) @(posedge ddr_clk);
    #0.1;
    if (!st_done[1] || !st_err[1] || n_en[1] != n0) fail("stepper: move beyond Limit not refused");
    move(1, 0);

    // ---- moves at all offsets to the PSDONE repeat
    $display("tb_bow_ddr_clk_versal: moves at all 32 offsets to the PSDONE repeat @%0t", $time);
    repeat_sweep(1);
    repeat_sweep(0);

    // ---- write phase over a full period (STEPS steps in 8 moves) and read
    // phase -STEPS (4 moves): wraps back to phase 0
    $display("tb_bow_ddr_clk_versal: write sweep of %0d steps @%0t", STEPS, $time);
    for (k = 1; k <= 8; k++) begin
      move(1, k * STEPS / 8);
      chk_phases($sformatf("write %0d steps", k * STEPS / 8));
    end
    $display("tb_bow_ddr_clk_versal: read sweep of -%0d steps @%0t", STEPS, $time);
    for (k = 1; k <= 4; k++) begin
      move(0, 1 - k * STEPS / 4);
      chk_phases($sformatf("read %0d steps", 1 - k * STEPS / 4));
    end

    // ---- rst_i returns both phases to 0
    move(1, STEPS + 40);
    move(0, 31 - STEPS);
    chk_phases("before rst_i");
    mon_on = 1'b0;
    @(posedge ddr_clk);
    #0.1;
    rst = 1'b1;
    #100;
    if (locked_ddr !== 1'b0 || locked_sys !== 1'b0) fail("LOCKED high during rst_i");
    rst = 1'b0;
    fork
      wait (locked_ddr === 1'b1);
      #50us;
    join_any
    disable fork;
    if (locked_ddr !== 1'b1) fail("no relock after rst_i");
    repeat (20) @(posedge clk_sys);
    chk_phases("after rst_i");
    mon_on = 1'b1;

    // ---- loss of lock: MMCM_B alone, MMCM_A alone, input clock stopped
    lock_loss(0);
    lock_loss(1);
    lock_loss(2);

    // ---- summary
    mon_on = 1'b0;
    $display("tb_bow_ddr_clk_versal: PSEN taken read %0d / write %0d, before lock %0d / %0d; PSDONE latency 12: %0d / %0d, 13: %0d / %0d",
             n_en[0], n_en[1], n_pre[0], n_pre[1], n12[0], n12[1], n13[0], n13[1]);
    $display("tb_bow_ddr_clk_versal: PSDONE repeats %0d / %0d, PSEN taken with a repeat PSDONE %0d / %0d, %0d PS errors",
             n_rep[0], n_rep[1], n_coinc[0], n_coinc[1], ps_err);
    $display("tb_bow_ddr_clk_versal: high / low phases: %0d checks (DDR clocks %0.4f .. %0.4f ns), %0d errors, %0d model pulses at 0 -> -1 tolerated",
             pw_chk, pw_min, pw_max, pw_err, n_art);
    $display("tb_bow_ddr_clk_versal: clk_sys grid %0d checks / %0d errors, ddr_clk to input %0d / %0d, ddr_sys_clk on ddr_clk %0d / %0d",
             sys_chk, sys_err, in_chk, in_err, dsys_chk, dsys_err);
    $display("tb_bow_ddr_clk_versal: LOCKED drops %0d; LOCKED only with running clocks: %0d checks, %0d errors",
             lock_err, run_chk, run_err);
    if (n_coinc[0] == 0 || n_coinc[1] == 0) fail("no PSEN taken with a repeat PSDONE (test setup)");
    if (n_rep[0] < 32 || n_rep[1] < 32) fail("too few PSDONE repeats (test setup)");
    if (dsys_chk < 1000 || sys_chk < 1000 || in_chk < 10000 || pw_chk < 50000 || run_chk < 10000)
      fail("too few clock checks (test setup)");
    errors += ps_err + pw_err + sys_err + in_err + dsys_err + lock_err + run_err;
    if (errors == 0) $display("tb_bow_ddr_clk_versal: PASS");
    else $display("tb_bow_ddr_clk_versal: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #5ms;
    $display("tb_bow_ddr_clk_versal: FAIL (timeout)");
    $finish;
  end
endmodule
