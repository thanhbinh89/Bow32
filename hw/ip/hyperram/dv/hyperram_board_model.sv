// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Board model between the FPGA pins (bow_hyperram_io_sim /
// bow_hyperram_io_xilinx, split pins) and the HyperRAM balls (hyperram_model,
// split pins, "mem_" prefix): a direct board (LevelShift = 0) or the
// FMC+_DDR2_HyperRam card with TI TXV0108 direction-controlled level
// shifters (LevelShift = 1). Verilator (--timing) and xsim. Port directions
// are seen from the board: dq_i = what the FPGA drives, dq_o = the value at
// the FPGA pin; mem_dq_i = what the HyperRAM drives, mem_dq_o = the value at
// its ball.
//
// Direct board: every signal is delayed by TraceFpgaPs + TraceMemPs in both
//   directions; a pin shows its own driver, else the far driver after the
//   trace, else it keeps its last value.
// TXV0108 card (working spec 2; A side = HyperRAM 1.8 V, B side = FPGA):
//   * packages: U6 = CK_P, CK_N, CS#, RESET# (DIR tied low: always B -> A,
//     FPGA -> HyperRAM); U4 = DQ0..7 (DIR = ls_dir_dq_i); U8 = RWDS (DIR =
//     ls_dir_rwds_i). OE# (ls_oe_n_i) is common: OE# high isolates (both
//     ports inputs); DIR high = A -> B (HyperRAM -> FPGA), DIR low = B -> A.
//   * delays drawn per seed (Seed, or +hyperram_board_seed=<n>): per package
//     and direction a tpd in [TpdBaMinPs, TpdBaMaxPs] (B -> A) or [TpdAbMinPs,
//     TpdAbMaxPs] (A -> B), the packages of one direction within TpdSpreadPs
//     of each other (TpdSpreadPs >= max - min draws them independently),
//     plus a per channel and direction skew in +-SkewPs; per package an
//     enable and a disable time in [TenMinPs, TenMaxPs] for OE# / DIR changes
//     (break before make: the new output port turns on after max(enable,
//     disable) when the other port was on). Traces: FPGA pin <-> B port
//     TraceFpgaPs, A port <-> HyperRAM ball TraceMemPs (DIR / OE# reach the
//     shifters after TraceFpgaPs). The TXV0108 data sheet gives VCCA = VCCB =
//     1.8 V figures only; the card's B side runs at 1.5 V (VADJ).
//   * with the U6 A port off (OE# high, or before it is enabled) the
//     HyperRAM side CS# and RESET# are pulled high (10k pull-ups); CK_P / CK_N
//     and the undriven DQ / RWDS lines keep their last value (no new edges).
//   * mem_dq_drv_o / mem_rwds_drv_o: the host side drives the HyperRAM ball
//     (shifter A port on, or the FPGA after the trace on a direct board), for
//     the input checks of hyperram_model.
// Counters (integers, read them hierarchically; any count > 0 fails a test):
//   contention     a net with two drivers: the FPGA and the shifter B port on
//                  the FPGA side, the HyperRAM and the shifter A port on the
//                  HyperRAM side (direct board: FPGA and HyperRAM), counted
//                  per signal group (DQ, RWDS) each time it starts;
//                  contention_ps = total time
//   floats         a shifter B port that is the input of an enabled channel
//                  (OE# low, DIR = B -> A) while the FPGA does not drive it,
//                  for longer than FloatGracePs (one count per float period:
//                  IDLE_DRIVE off behind enabled shifters, or a turnaround
//                  window that is too long). A-side floats (DIR = A -> B and
//                  the HyperRAM not driving: the latency of every read, the
//                  RWDS turnaround of writes) are inherent to the card and
//                  only counted in floats_a (information).
// Every event is reported with $display when Verbose.

`timescale 1ps / 1ps

// behavioural model: blocking assignments in edge processes and lines that
// keep their last value (latches) are intended
/* verilator lint_off BLKSEQ */
/* verilator lint_off LATCH */
/* verilator lint_off SYNCASYNCNET */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off MULTIDRIVEN */
module hyperram_board_model #(
  parameter bit          LevelShift   = 1'b1,
  parameter int unsigned Seed         = 1,
  parameter int unsigned TraceFpgaPs  = 300,
  parameter int unsigned TraceMemPs   = 200,
  parameter int unsigned TpdAbMinPs   = 1200,    // A -> B (HyperRAM -> FPGA)
  parameter int unsigned TpdAbMaxPs   = 4800,
  parameter int unsigned TpdBaMinPs   = 1600,    // B -> A (FPGA -> HyperRAM)
  parameter int unsigned TpdBaMaxPs   = 4800,
  parameter int unsigned TpdSpreadPs  = 600,
  parameter int unsigned SkewPs       = 450,
  parameter int unsigned TenMinPs     = 1200,
  parameter int unsigned TenMaxPs     = 7000,
  parameter int unsigned FloatGracePs = 30000,
  parameter bit          Verbose      = 1'b1
) (
  // FPGA side
  input  logic       ck_p_i,
  input  logic       ck_n_i,
  input  logic       cs_n_i,
  input  logic       rst_n_i,
  input  logic [7:0] dq_i,
  input  logic       dq_oe_i,
  output logic [7:0] dq_o,
  input  logic       rwds_i,
  input  logic       rwds_oe_i,
  output logic       rwds_o,
  input  logic       ls_oe_n_i,
  input  logic       ls_dir_dq_i,
  input  logic       ls_dir_rwds_i,
  // HyperRAM side
  output logic       mem_ck_o,
  output logic       mem_ck_n_o,
  output logic       mem_cs_n_o,
  output logic       mem_rst_n_o,
  output logic [7:0] mem_dq_o,
  output logic       mem_dq_drv_o,
  input  logic [7:0] mem_dq_i,
  input  logic       mem_dq_oe_i,
  output logic       mem_rwds_o,
  output logic       mem_rwds_drv_o,
  input  logic       mem_rwds_i,
  input  logic       mem_rwds_oe_i
);

  // delays in this module's 1 ps whatever the parent's unit
  /* verilator no_inline_module */

  localparam int unsigned NPkg  = 3;     // U6 control, U4 DQ, U8 RWDS
  localparam int unsigned PkCtl = 0;
  localparam int unsigned PkDq  = 1;
  localparam int unsigned PkRw  = 2;
  localparam int unsigned NCtl  = 4;     // CK_P, CK_N, CS#, RESET#
  // trace delays (never 0: Verilator --timing), float grace
  localparam real         TTot  = (TraceFpgaPs + TraceMemPs > 0) ? real'(TraceFpgaPs + TraceMemPs) : 1.0;
  localparam real         TF    = (TraceFpgaPs > 0) ? real'(TraceFpgaPs) : 1.0;
  localparam real         TM    = (TraceMemPs > 0) ? real'(TraceMemPs) : 1.0;
  localparam real         TG    = (FloatGracePs > 0) ? real'(FloatGracePs) : 1.0;

  // ----------------------------------------------------------- counters
  // (the shifter values exist in both variants: one set of names for the tb)
  /* verilator lint_off UNUSEDSIGNAL */
  int  contention = 0, floats = 0, floats_a = 0;
  real contention_ps = 0.0;

  // ----------------------------------------------------------- delays
  real tpd_ba [NPkg];          // B -> A (FPGA -> HyperRAM)
  real tpd_ab [NPkg];          // A -> B (HyperRAM -> FPGA)
  real t_en   [NPkg];
  real t_dis  [NPkg];
  real sk_ctl [NCtl];
  real sk_dq  [8][2];          // [0] B -> A, [1] A -> B
  real sk_rw  [2];
  // the delays used by the channels (>= 1 ps; no function call in a delay)
  // (set at time 0, used from TraceFpgaPs / TraceMemPs on)
  real d_ctl  [NCtl];
  real d_dq   [8][2];
  real d_rw   [2];
  real d_en   [NPkg];          // enable, disable, break before make
  real d_dis  [NPkg];
  real d_bbm  [NPkg];
  /* verilator lint_on UNUSEDSIGNAL */

  // never wait 0 or less (Verilator --timing)
  function automatic real dly(real d);
    return (d < 1.0) ? 1.0 : d;
  endfunction

  // xorshift32: the same draws in every simulator
  int unsigned rng = 1;
  function automatic real urand(real lo, real hi);
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return lo + (hi - lo) * (real'(rng) / 4294967296.0);
  endfunction

  function automatic string pkg_name(int p);
    if (p == int'(PkCtl)) return "U6 CK/CS#/RESET#";
    if (p == int'(PkDq)) return "U4 DQ";
    return "U8 RWDS";
  endfunction

  initial begin
    int unsigned sd;
    real         ab_min, ab_max, ba_min, ba_max, span_ab, span_ba, base_ba, base_ab;
    sd = Seed;
    void'($value$plusargs("hyperram_board_seed=%d", sd));
    rng = sd ^ 32'h9E37_79B9;
    if (rng == 0) rng = 1;
    for (int k = 0; k < 8; k++) void'(urand(0.0, 1.0));
    ab_min  = real'(TpdAbMinPs);
    ab_max  = (TpdAbMaxPs > TpdAbMinPs) ? real'(TpdAbMaxPs) : ab_min;
    ba_min  = real'(TpdBaMinPs);
    ba_max  = (TpdBaMaxPs > TpdBaMinPs) ? real'(TpdBaMaxPs) : ba_min;
    span_ab = ab_max - ab_min;
    span_ba = ba_max - ba_min;
    if (real'(TpdSpreadPs) < span_ab) span_ab = real'(TpdSpreadPs);
    if (real'(TpdSpreadPs) < span_ba) span_ba = real'(TpdSpreadPs);
    base_ba = urand(ba_min, ba_max - span_ba);
    base_ab = urand(ab_min, ab_max - span_ab);
    for (int p = 0; p < int'(NPkg); p++) begin
      tpd_ba[p] = base_ba + urand(0.0, span_ba);
      tpd_ab[p] = base_ab + urand(0.0, span_ab);
      t_en[p]   = urand(real'(TenMinPs), real'(TenMaxPs));
      t_dis[p]  = urand(real'(TenMinPs), real'(TenMaxPs));
    end
    for (int k = 0; k < int'(NCtl); k++) sk_ctl[k] = urand(-real'(SkewPs), real'(SkewPs));
    for (int k = 0; k < 8; k++) begin
      sk_dq[k][0] = urand(-real'(SkewPs), real'(SkewPs));
      sk_dq[k][1] = urand(-real'(SkewPs), real'(SkewPs));
    end
    sk_rw[0] = urand(-real'(SkewPs), real'(SkewPs));
    sk_rw[1] = urand(-real'(SkewPs), real'(SkewPs));
    for (int k = 0; k < int'(NCtl); k++) d_ctl[k] = dly(tpd_ba[PkCtl] + sk_ctl[k]);
    for (int k = 0; k < 8; k++) begin
      d_dq[k][0] = dly(tpd_ba[PkDq] + sk_dq[k][0]);
      d_dq[k][1] = dly(tpd_ab[PkDq] + sk_dq[k][1]);
    end
    d_rw[0] = dly(tpd_ba[PkRw] + sk_rw[0]);
    d_rw[1] = dly(tpd_ab[PkRw] + sk_rw[1]);
    for (int p = 0; p < int'(NPkg); p++) begin
      d_en[p]  = dly(t_en[p]);
      d_dis[p] = dly(t_dis[p]);
      d_bbm[p] = dly((t_en[p] > t_dis[p]) ? t_en[p] : t_dis[p]);
    end
    if (Verbose) begin
      if (!LevelShift) begin
        $display("%m: direct board, trace %0d ps", TraceFpgaPs + TraceMemPs);
      end else begin
        $display("%m: TXV0108 card, seed %0d, traces FPGA %0d ps / HyperRAM %0d ps", sd,
                 TraceFpgaPs, TraceMemPs);
        for (int p = 0; p < int'(NPkg); p++) begin
          $display("%m:   %s: tpd B->A %0.0f ps, A->B %0.0f ps, enable %0.0f ps, disable %0.0f ps",
                   pkg_name(p), tpd_ba[p], tpd_ab[p], t_en[p], t_dis[p]);
        end
      end
    end
  end

  // one evaluation of every input copy at 2 ps: inputs that keep their time-0
  // value never trigger an @(change)
  logic kick = 1'b0;
  initial #2 kick = 1'b1;

  // ------------------------------------------------------------ events
  task automatic note(string what);
    if (Verbose) $display("%m: %0t ps: %s", $time, what);
  endtask

  // conditional text (string operands: no padding of the shorter literal)
  function automatic string pick(bit c, string a, string b);
    if (c) return a;
    return b;
  endfunction

  // =====================================================================
  if (!LevelShift) begin : g_direct
    // ------------------------------------------------- control channels
    logic [NCtl-1:0] f_ctl, m_ctl;
    assign f_ctl = {rst_n_i, cs_n_i, ck_n_i, ck_p_i};
    initial m_ctl = 4'b1110;               // RESET# 1, CS# 1, CK_N 1, CK_P 0
    for (genvar k = 0; k < NCtl; k++) begin : g_ctl
      always @(f_ctl[k] or kick) m_ctl[k] <= #(TTot) f_ctl[k];
    end
    assign {mem_rst_n_o, mem_cs_n_o, mem_ck_n_o, mem_ck_o} = m_ctl;

    // --------------------------------------------- bidirectional groups
    logic fd_dq_oe = 1'b0, md_dq_oe = 1'b0;    // far driver enables after the trace
    logic fd_rw_oe = 1'b0, md_rw_oe = 1'b0;
    always @(dq_oe_i or kick)       fd_dq_oe <= #(TTot) dq_oe_i;
    always @(mem_dq_oe_i or kick)   md_dq_oe <= #(TTot) mem_dq_oe_i;
    always @(rwds_oe_i or kick)     fd_rw_oe <= #(TTot) rwds_oe_i;
    always @(mem_rwds_oe_i or kick) md_rw_oe <= #(TTot) mem_rwds_oe_i;

    for (genvar c = 0; c < 8; c++) begin : g_dq
      logic fd_v = 1'b0, md_v = 1'b0, f_pin = 1'b0, m_pin = 1'b0;
      always @(dq_i[c] or kick)     fd_v <= #(TTot) dq_i[c];
      always @(mem_dq_i[c] or kick) md_v <= #(TTot) mem_dq_i[c];
      always @(dq_oe_i or dq_i[c] or md_dq_oe or md_v) begin
        if (dq_oe_i)       f_pin = dq_i[c];
        else if (md_dq_oe) f_pin = md_v;
      end
      always @(mem_dq_oe_i or mem_dq_i[c] or fd_dq_oe or fd_v) begin
        if (mem_dq_oe_i)   m_pin = mem_dq_i[c];
        else if (fd_dq_oe) m_pin = fd_v;
      end
      assign dq_o[c]     = f_pin;
      assign mem_dq_o[c] = m_pin;
    end

    if (1) begin : g_rw
      logic fd_v = 1'b0, md_v = 1'b0, f_pin = 1'b0, m_pin = 1'b0;
      always @(rwds_i or kick)     fd_v <= #(TTot) rwds_i;
      always @(mem_rwds_i or kick) md_v <= #(TTot) mem_rwds_i;
      always @(rwds_oe_i or rwds_i or md_rw_oe or md_v) begin
        if (rwds_oe_i)     f_pin = rwds_i;
        else if (md_rw_oe) f_pin = md_v;
      end
      always @(mem_rwds_oe_i or mem_rwds_i or fd_rw_oe or fd_v) begin
        if (mem_rwds_oe_i) m_pin = mem_rwds_i;
        else if (fd_rw_oe) m_pin = fd_v;
      end
      assign rwds_o     = f_pin;
      assign mem_rwds_o = m_pin;
    end

    assign mem_dq_drv_o   = fd_dq_oe;
    assign mem_rwds_drv_o = fd_rw_oe;

    // contention at either end of the line
    logic c_dq, c_rw;
    real  t0_dq = 0.0, t0_rw = 0.0;
    assign c_dq = (dq_oe_i && md_dq_oe) || (mem_dq_oe_i && fd_dq_oe);
    assign c_rw = (rwds_oe_i && md_rw_oe) || (mem_rwds_oe_i && fd_rw_oe);
    // (edge triggered: shared counters must not sit in combinational logic)
    always @(posedge c_dq) begin
      contention++;
      t0_dq = $realtime;
      note("contention on DQ (FPGA and HyperRAM drive)");
    end
    always @(negedge c_dq) contention_ps += $realtime - t0_dq;
    always @(posedge c_rw) begin
      contention++;
      t0_rw = $realtime;
      note("contention on RWDS (FPGA and HyperRAM drive)");
    end
    always @(negedge c_rw) contention_ps += $realtime - t0_rw;

    logic unused;
    assign unused = ^{ls_oe_n_i, ls_dir_dq_i, ls_dir_rwds_i};

  // =====================================================================
  end else begin : g_txv
    // control pins at the shifters
    logic oe_n_s = 1'b1, dir_dq_s = 1'b0, dir_rw_s = 1'b0;
    always @(ls_oe_n_i or kick)     oe_n_s   <= #(TF) ls_oe_n_i;
    always @(ls_dir_dq_i or kick)   dir_dq_s <= #(TF) ls_dir_dq_i;
    always @(ls_dir_rwds_i or kick) dir_rw_s <= #(TF) ls_dir_rwds_i;

    // port enables per package: a_en = A port drives (B -> A), b_en = B port drives
    logic [NPkg-1:0] a_en, b_en;
    for (genvar p = 0; p < NPkg; p++) begin : g_pkg
      logic want_a, want_b;
      logic a_on = 1'b0, b_on = 1'b0;
      assign a_en[p] = a_on;
      assign b_en[p] = b_on;
      if (p == PkCtl) begin : g_c
        assign want_a = !oe_n_s;
        assign want_b = 1'b0;
      end else if (p == PkDq) begin : g_d
        assign want_a = !oe_n_s && !dir_dq_s;
        assign want_b = !oe_n_s && dir_dq_s;
      end else begin : g_r
        assign want_a = !oe_n_s && !dir_rw_s;
        assign want_b = !oe_n_s && dir_rw_s;
      end
      // a request (change of want_*) schedules the port changes; a later
      // request makes the pending ones void (seq). Edge triggered blocks only.
      int unsigned seq = 0;
      int unsigned tok_a_on = 0, tok_a_off = 0, tok_b_on = 0, tok_b_off = 0;
      logic        ev_a_on = 1'b0, ev_a_off = 1'b0, ev_b_on = 1'b0, ev_b_off = 1'b0;
      logic        nx_a_on = 1'b0, nx_a_off = 1'b0, nx_b_on = 1'b0, nx_b_off = 1'b0;
      real         den = 1.0, ddis = 1.0, dbbm = 1.0;
      initial #1 begin
        den  = d_en[p];
        ddis = d_dis[p];
        dbbm = d_bbm[p];
      end
      always @(posedge want_a or negedge want_a or posedge want_b or negedge want_b) begin
        real don;
        seq++;
        if (!want_a && a_on) begin
          tok_a_off <= #(ddis) seq;
          nx_a_off   = !nx_a_off;
          ev_a_off  <= #(ddis) nx_a_off;
        end
        if (!want_b && b_on) begin
          tok_b_off <= #(ddis) seq;
          nx_b_off   = !nx_b_off;
          ev_b_off  <= #(ddis) nx_b_off;
        end
        if (want_a && !a_on) begin
          don       = b_on ? dbbm : den;
          tok_a_on <= #(don) seq;
          nx_a_on   = !nx_a_on;
          ev_a_on  <= #(don) nx_a_on;
        end
        if (want_b && !b_on) begin
          don       = a_on ? dbbm : den;
          tok_b_on <= #(don) seq;
          nx_b_on   = !nx_b_on;
          ev_b_on  <= #(don) nx_b_on;
        end
      end
      always @(posedge ev_a_on or negedge ev_a_on)   if (tok_a_on == seq)  a_on = 1'b1;
      always @(posedge ev_a_off or negedge ev_a_off) if (tok_a_off == seq) a_on = 1'b0;
      always @(posedge ev_b_on or negedge ev_b_on)   if (tok_b_on == seq)  b_on = 1'b1;
      always @(posedge ev_b_off or negedge ev_b_off) if (tok_b_off == seq) b_on = 1'b0;
    end

    // ------------------------------------------------- control channels
    logic [NCtl-1:0] f_ctl, m_ctl;
    assign f_ctl = {rst_n_i, cs_n_i, ck_n_i, ck_p_i};
    // HyperRAM side with the U6 A port off: CS# (2) / RESET# (3) pulled high,
    // CK_P / CK_N keep their level
    function automatic logic pulled(int k, logic cur);
      if (k == 2 || k == 3) return 1'b1;
      return cur;
    endfunction
    for (genvar k = 0; k < NCtl; k++) begin : g_ctl
      localparam logic Init = (k == 0) ? 1'b0 : 1'b1;   // CK_P low, CK_N / CS# / RESET# high
      logic b_v = Init, a_v = Init, a_pin = Init, m_v = Init;
      real  dch = 1.0;
      initial #1 dch = d_ctl[k];
      always @(f_ctl[k] or kick)    b_v <= #(TF) f_ctl[k];
      always @(b_v)                 a_v <= #(dch) b_v;
      always @(a_v or a_en[PkCtl])  a_pin = a_en[PkCtl] ? a_v : pulled(k, a_pin);
      always @(a_pin)               m_v <= #(TM) a_pin;
      assign m_ctl[k] = m_v;
    end
    assign {mem_rst_n_o, mem_cs_n_o, mem_ck_n_o, mem_ck_o} = m_ctl;

    // ------------------------------------------- driver enables at the ports
    logic            fb_dq_oe = 1'b0, ma_dq_oe = 1'b0, fb_rw_oe = 1'b0, ma_rw_oe = 1'b0;
    logic [NPkg-1:0] ad_en = '0, bd_en = '0;   // A port on, seen at the HyperRAM / B port on, at the FPGA
    always @(dq_oe_i or kick)       fb_dq_oe <= #(TF) dq_oe_i;
    always @(rwds_oe_i or kick)     fb_rw_oe <= #(TF) rwds_oe_i;
    always @(mem_dq_oe_i or kick)   ma_dq_oe <= #(TM) mem_dq_oe_i;
    always @(mem_rwds_oe_i or kick) ma_rw_oe <= #(TM) mem_rwds_oe_i;
    always @(a_en)                  ad_en    <= #(TM) a_en;
    always @(b_en)                  bd_en    <= #(TF) b_en;

    // -------------------------------------------------------- DQ channels
    for (genvar c = 0; c < 8; c++) begin : g_dq
      logic fb_v = 1'b0, b_pin = 1'b0, a_out = 1'b0, ma_v = 1'b0, a_pin = 1'b0, b_out = 1'b0;
      logic ad_v = 1'b0, bd_v = 1'b0, f_pin = 1'b0, m_pin = 1'b0;
      real  dba = 1.0, dab = 1.0;          // (plain variables: xsim takes no array element as a delay)
      initial #1 begin
        dba = d_dq[c][0];
        dab = d_dq[c][1];
      end
      always @(dq_i[c] or kick)     fb_v <= #(TF) dq_i[c];
      always @(mem_dq_i[c] or kick) ma_v <= #(TM) mem_dq_i[c];
      always @(fb_v or fb_dq_oe or b_out or b_en[PkDq]) begin
        if (fb_dq_oe)        b_pin = fb_v;
        else if (b_en[PkDq]) b_pin = b_out;
      end
      always @(b_pin) a_out <= #(dba) b_pin;
      always @(a_out or a_en[PkDq] or ma_v or ma_dq_oe) begin
        if (a_en[PkDq])    a_pin = a_out;
        else if (ma_dq_oe) a_pin = ma_v;
      end
      always @(a_pin) b_out <= #(dab) a_pin;
      always @(a_out) ad_v  <= #(TM) a_out;
      always @(b_out) bd_v  <= #(TF) b_out;
      always @(mem_dq_oe_i or mem_dq_i[c] or ad_en[PkDq] or ad_v) begin
        if (mem_dq_oe_i)      m_pin = mem_dq_i[c];
        else if (ad_en[PkDq]) m_pin = ad_v;
      end
      always @(dq_oe_i or dq_i[c] or bd_en[PkDq] or bd_v) begin
        if (dq_oe_i)          f_pin = dq_i[c];
        else if (bd_en[PkDq]) f_pin = bd_v;
      end
      assign dq_o[c]     = f_pin;
      assign mem_dq_o[c] = m_pin;
    end

    // ------------------------------------------------------- RWDS channel
    if (1) begin : g_rw
      logic fb_v = 1'b0, b_pin = 1'b0, a_out = 1'b0, ma_v = 1'b0, a_pin = 1'b0, b_out = 1'b0;
      logic ad_v = 1'b0, bd_v = 1'b0, f_pin = 1'b0, m_pin = 1'b0;
      real  dba = 1.0, dab = 1.0;
      initial #1 begin
        dba = d_rw[0];
        dab = d_rw[1];
      end
      always @(rwds_i or kick)     fb_v <= #(TF) rwds_i;
      always @(mem_rwds_i or kick) ma_v <= #(TM) mem_rwds_i;
      always @(fb_v or fb_rw_oe or b_out or b_en[PkRw]) begin
        if (fb_rw_oe)        b_pin = fb_v;
        else if (b_en[PkRw]) b_pin = b_out;
      end
      always @(b_pin) a_out <= #(dba) b_pin;
      always @(a_out or a_en[PkRw] or ma_v or ma_rw_oe) begin
        if (a_en[PkRw])    a_pin = a_out;
        else if (ma_rw_oe) a_pin = ma_v;
      end
      always @(a_pin) b_out <= #(dab) a_pin;
      always @(a_out) ad_v  <= #(TM) a_out;
      always @(b_out) bd_v  <= #(TF) b_out;
      always @(mem_rwds_oe_i or mem_rwds_i or ad_en[PkRw] or ad_v) begin
        if (mem_rwds_oe_i)    m_pin = mem_rwds_i;
        else if (ad_en[PkRw]) m_pin = ad_v;
      end
      always @(rwds_oe_i or rwds_i or bd_en[PkRw] or bd_v) begin
        if (rwds_oe_i)        f_pin = rwds_i;
        else if (bd_en[PkRw]) f_pin = bd_v;
      end
      assign rwds_o     = f_pin;
      assign mem_rwds_o = m_pin;
    end

    assign mem_dq_drv_o   = ad_en[PkDq];
    assign mem_rwds_drv_o = ad_en[PkRw];

    // -------------------------------------------------------- contention
    // (B side: FPGA and B port, A side: A port and HyperRAM)
    logic c_dq, c_rw;
    real  t0_dq = 0.0, t0_rw = 0.0;
    assign c_dq = (fb_dq_oe && b_en[PkDq]) || (a_en[PkDq] && ma_dq_oe);
    assign c_rw = (fb_rw_oe && b_en[PkRw]) || (a_en[PkRw] && ma_rw_oe);
    // (edge triggered: shared counters must not sit in combinational logic)
    always @(posedge c_dq) begin
      contention++;
      t0_dq = $realtime;
      note($sformatf("contention on DQ (FPGA %0d / B port %0d, A port %0d / HyperRAM %0d)",
                     fb_dq_oe, b_en[PkDq], a_en[PkDq], ma_dq_oe));
    end
    always @(negedge c_dq) contention_ps += $realtime - t0_dq;
    always @(posedge c_rw) begin
      contention++;
      t0_rw = $realtime;
      note($sformatf("contention on RWDS (FPGA %0d / B port %0d, A port %0d / HyperRAM %0d)",
                     fb_rw_oe, b_en[PkRw], a_en[PkRw], ma_rw_oe));
    end
    always @(negedge c_rw) contention_ps += $realtime - t0_rw;

    // ------------------------------------------------------------ floats
    // B input of an enabled B -> A channel not driven by the FPGA (floats), A
    // input of an enabled A -> B channel not driven by the HyperRAM
    // (floats_a); a float that still holds FloatGracePs after it started
    // counts once
    logic [3:0] fl;                         // DQ B, RWDS B, DQ A, RWDS A
    assign fl[0] = a_en[PkDq] && !fb_dq_oe;
    assign fl[1] = a_en[PkRw] && !fb_rw_oe;
    assign fl[2] = b_en[PkDq] && !ma_dq_oe;
    assign fl[3] = b_en[PkRw] && !ma_rw_oe;
    for (genvar i = 0; i < 4; i++) begin : g_fl
      logic        f;
      int unsigned fseq = 0, ftok = 0;
      logic        fev = 1'b0, fnx = 1'b0;
      assign f = fl[i];
      always @(posedge f or negedge f) begin
        fseq++;
        if (f) begin
          ftok <= #(TG) fseq;
          fnx   = !fnx;
          fev  <= #(TG) fnx;
        end
      end
      always @(posedge fev or negedge fev) begin
        if (ftok == fseq && f) begin
          if (i < 2) begin
            floats++;
            note($sformatf("%s: shifter B input floating for %0.0f ps (FPGA not driving, DIR = FPGA -> HyperRAM)",
                           pick(i == 0, "DQ", "RWDS"), TG));
          end else begin
            floats_a++;
          end
        end
      end
    end
  end

endmodule
/* verilator lint_on MULTIDRIVEN */
/* verilator lint_on UNOPTFLAT */
/* verilator lint_on SYNCASYNCNET */
/* verilator lint_on LATCH */
/* verilator lint_on BLKSEQ */
