// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Behavioural model of an Infineon S80KS2562 (256 Mb HyperRAM 2.0, x8,
// 1.8 V, data sheet 002-31337 Rev. *C) at its balls, for the Verilator
// (--timing) and xsim testbenches of the Bow32 HyperRAM IP. It is the
// reference the controller is verified against: everything below comes from
// the data sheet, nothing from the RTL.
//
// Pins (split, like the board model's "mem_" side): ck_i / ck_n_i / cs_n_i /
// rst_n_i = the levels at the balls; dq_i / rwds_i = the values at the balls
// (they include the model's own drive), dq_drv_i / rwds_drv_i = the host side
// drives that ball (level shifter A port on, or the FPGA on a direct board);
// dq_o / dq_oe_o, rwds_o / rwds_oe_o = what the model drives. CK is taken
// single ended (CR1[6] = 1, the default; CK# is not used).
//
// Bus protocol (CK cycle k = 1.. from the first CK rising edge after CS#
// falls, r_k / f_k its rising / falling edge; e = edge index, r1 = 0):
//   * CA[47:40] at r1 .. CA[7:0] at f3: [47] R/W# (1 read), [46] AS (1
//     register space), [45] burst type (1 linear, 0 wrapped), word address =
//     {CA[44:16], CA[2:0]}, CA[15:3] reserved (must be 0).
//   * latency: CR0[7:4] = 1110 3, 1111 4, 0000 5, 0001 6, 0010 7 clocks (L);
//     2x latency when RWDS is high during CA: always with fixed latency
//     (CR0[3] = 1, the default), with variable latency (CR0[3] = 0) when a
//     refresh collides (drawn per transaction, +hyperram_refresh_pct=<0..100>,
//     default 20). The first data word of a memory read, register read or
//     memory write is in cycle D = L + 3 (1x) or 2L + 3 (2x): byte A at r_D,
//     byte B at f_D, word n in cycle D + n. A register write has zero latency:
//     its word is in cycle 4.
//   * memory: linear bursts run on across the end of the array (MemBytes) to
//     word 0; wrapped bursts (CA[45] = 0) wrap in an aligned group of 16 /
//     32 / 64 / 128 bytes (CR0[1:0] = 10 / 11 / 01 / 00); with CR0[2] = 0
//     (hybrid) the first group wraps once, then the burst continues linearly
//     from the start of the next group. Byte A / B = the first / second byte
//     of the word on the bus; the model stores them as they come (peek()
//     returns {A, B}).
//   * registers (big endian, byte A = [15:8]): ID0 (word address 0, read
//     only, Id0), ID1 (1, Id1), CR0 (0x800, default 0x8F2F), CR1 (0x801,
//     default 0xFFC0 | RefreshInterval). Writes: CA[45] = 1, one word, zero
//     latency, the host does not drive RWDS; reserved fields must be written
//     with their defaults (they keep them); CR1[1:0] is read only. Reads: one
//     word, with latency like a memory read; more words read back as random
//     bytes ("indeterminate") and count an error.
// Output timing (drawn once per run from the data sheet ranges, Seed or
// +hyperram_mem_seed=<n>; tCKD and tCKDS of one device track each other):
//   * RWDS driven tDSV (0.5..5 ns) after CS# falls with the latency level;
//     memory write: released tDSZ after f3 (the host's turn); register write:
//     released after f3 or kept low until CS# rises (drawn per run: the data
//     sheet allows both); read: driven low tCKDSR (1..5.5 ns) after f3 when it
//     was high, then high with byte A / low with byte B tCKDS after the CK
//     edges (1..5 ns).
//   * read DQ: driven from r_(D-1) + tDQLZ (0..1 ns) with random bytes, byte A
//     / B valid tCKD after r / f (|tCKD - tCKDS| <= 0.4 ns: tDSS), random
//     between tCKDI (>= tCKDS - 0.4 ns, tDSH) and tCKD of every edge.
//   * DQ released tOZ (tCKD..5 ns), RWDS tDSZ (tCKDS..5 ns) after CS# rises:
//     the last byte / strobe edge, output tCKD / tCKDS after the last CK
//     falling edge, is on the bus before the output turns off
//     (+hyperram_oz_free: 1..5 ns each, independent, see below).
// Power states:
//   * power-up: no transaction in the first TvcsNs (tVCS; from the RESET#
//     rising edge when RESET# is low at time 0).
//   * deep power down: CR0[15] = 0 written; data lost at once; a CS# low pulse
//     of 200..3000 ns (tCSDPD, not before tDPDIN) exits, then tEXTDPD
//     (TextDpdNs) before the next transaction; registers back to their
//     defaults (POR state).
//   * hybrid sleep: CR1[5] = 1 written; a CS# low pulse of 60..3000 ns
//     (tCSHS, not before tHSIN) exits, then tEXTHS (TextHsNs); data and
//     registers kept, CR1[5] back to 0; with partial array refresh (CR1[4:2]
//     != 0) the words outside the refreshed part are lost.
//   * RESET# low (tRP >= 200 ns): a transaction in flight is aborted, the
//     outputs are released, registers default, DPD / HS left, data lost
//     (ResetLosesData = 1: the data sheet says the host must assume so);
//     the next CS# fall >= 200 ns after RESET# rises (tRH) and >= 400 ns
//     after it fell (tRPH).
//   A transaction the device cannot take (not ready, RESET# low) is ignored:
//   no output, nothing written, an error counted.
// Checks (one counter each, all also summed in `errors`; any count > 0 fails
// a test; each is reported with $display when Verbose, the first MaxShow of
// a class):
//   err_tcshi    CS# high < 6 ns (tCSHI)
//   err_trwr     previous CS# rise to f2 < 35 ns (tRWR)
//   err_tcss     CS# fall to the first CK rising edge < 4 ns, or a CK rising
//                edge < 4 ns after CS# rose (tCSS)
//   err_tcsh     CS# rose with CK high (tCSH: after the last falling edge)
//   err_ckcs     CS# fell with CK high (a transaction starts with CK low)
//   err_tcsm     CS# low longer than tCSM (4 us when RefreshInterval = 01, else
//                1 us); not for DPD / HS exit pulses
//   err_tck      a CK period < 5 ns while CS# is low
//   err_tckhp    a CK high phase outside 0.45..0.55 of the period (a low phase
//                longer than 0.55 / 0.45 of the high phase is an active clock
//                stop, allowed: CK low)
//   err_latf     CK faster than the latency allows (3: 85, 4: 104, 5: 133,
//                6: 166, 7: 200 MHz; 1 % tolerance), at the first data edge
//   err_tis / err_tih   DQ (CA, register / memory write data) or RWDS (write
//                mask) not stable from 0.5 ns before to 0.5 ns after the CK
//                edge that captures it (tIS / tIH)
//   err_drv      DQ / RWDS not driven by the host at a capturing edge
//   err_pre      memory write: RWDS not driven low by the host at f_(D-1)
//                (mask preamble, tDMV >= 0), or released before r_D
//   err_cont_dq / err_cont_rwds   host and HyperRAM drive DQ / RWDS at once
//   err_regwr_rwds   the host drives RWDS during a register write (after CA)
//   err_ca       CA[15:3] != 0, CS# high before the 6 CA edges
//   err_reg      register access: unknown address, ID write, CA[45] = 0 in a
//                write, write not exactly one word, read longer than one word,
//                reserved bits / latency code written
//   err_range    memory word address >= MemBytes / 2 (the model wraps it)
//   err_pwr      transaction during tVCS / tEXTDPD / tEXTHS, CS# low before
//                tDPDIN / tHSIN, exit pulse width, CK toggling during an exit
//                pulse
//   err_rst      tRP, CS# low while RESET# is low, tRH / tRPH
// Information: n_txn, n_mem_rd, n_mem_wr, n_reg_rd, n_reg_wr, n_words_rd,
// n_words_wr, n_lat2x, n_refresh (2x of variable latency), n_ck_stop,
// n_ignored, n_dpd, n_hs, n_rst, info_uninit (words read that were never
// fully written: they read as uninit_word()); cr0 / cr1, pstate (0 active, 1
// deep power down, 2 hybrid sleep), lat2x (latency of the last transaction).
// Write phase sweep hook: wr_relax (a variable, set hierarchically, see its
// declaration): capture violations count in n_relaxed instead of errors, a
// command captured with a violation is ignored, a write word captured with
// one is stored inverted (the DDR models' wr_relax_i, for the same purpose).
// Abort hook: ca_abort_ok (also a variable): a command-address phase cut by
// CS# counts in n_ca_aborted instead of an ECa error (channel reset tests).
// Testbench API (hierarchical calls): peek(waddr) = {byte A, byte B} (an
// unwritten word reads uninit_word(waddr) = {8'hDE, waddr[7:0]}), poke(waddr,
// v), peek_byte / poke_byte(baddr) with the bus byte address (2n = byte A,
// 2n + 1 = byte B), written_mask(waddr) = {A, B} written since the last data
// loss, was_written(waddr), ready() = a transaction may start now.
// Log: one line per transaction (TxnLog or +hyperram_txn_log=<file>):
// "<CS# fall ps> <MR|MW|RR|RW> <LIN|WRAP> <word address> L<n> <1x|2x>
// <words> : <words, A B in hex; -- = masked byte>".
//
// Data sheet ambiguities and the choices made here:
//   * hybrid sleep enter / exit: section 8.3 and table 15 say CR1[5] = 0
//     enters, CS# low sets it to 1; table 12 and section 6.3.2 say 1 enters,
//     back to 0 at the exit. The model follows table 12.
//   * register write RWDS after CA: "may continue to drive RWDS LOW or may take
//     RWDS to HIGH-Z": drawn per run (regwr_keep).
//   * reserved register bits written with other values: "undefined" - an
//     error, the bits keep their default; reserved latency codes: an error,
//     the latency stays 7 clocks (valid at any frequency).
//   * tDQLZ has no maximum: the model drives DQ at most 1 ns after r_(D-1).
//   * the RWDS preamble: valid low at f_(D-1) (tDMV >= 0) with no setup / hold
//     of its own; the mask itself has tIS / tIH like DQ.
//   * hardware reset: "memory array data is considered as invalid": data
//     dropped (ResetLosesData = 0 keeps it).
//   * partial array refresh: applied at the hybrid sleep exit only.
//   * the "CK frequency for the latency" table is stricter than tACC / L (35
//     ns); the table is checked.
//   * the "tCSS" after the last CK edge (figure 30) is checked as: no CK rising
//     edge within 4 ns after CS# rises.
//   * tOZ / tDSZ have no minimum. A host may raise CS# right after the last CK
//     falling edge (tCSH >= 0) while the last byte only appears tCKD (up to
//     5 ns) after that edge; figures 30 / 32 draw the last byte valid until CS#
//     + tOZ. The model turns DQ / RWDS off no earlier than tCKD / tCKDS after
//     CS# rises (the line then keeps its level: the board model holds
//     undriven lines). +hyperram_oz_free draws them in 1..5 ns independently:
//     a transition still in flight at CS# + tOZ is cut and the line keeps the
//     invalid level - a stress for controllers that need the last byte
//     after raising CS#.
//
// Not inlined (no_inline_module): Verilator before 5.022 gives the delays of
// an inlined module the time unit of its parent (hyperram_clk_model header).

`timescale 1ps / 1ps

// behavioural model: blocking assignments in edge processes and shared
// counters written by several processes are intended
/* verilator lint_off BLKSEQ */
/* verilator lint_off MULTIDRIVEN */
module hyperram_model #(
  parameter int unsigned MemBytes        = 32 << 20,
  parameter logic [15:0] Id0             = 16'h0E86,
  parameter logic [15:0] Id1             = 16'h0001,
  parameter logic [1:0]  RefreshInterval = 2'b10,    // CR1[1:0]: 01 = 4 us, 10 = 1 us tCSM
  parameter int unsigned TvcsNs          = 150000,
  parameter int unsigned Seed            = 1,
  parameter bit          Verbose         = 1'b1,
  // beyond the data sheet minimum set (defaults = the S80KS2562)
  parameter bit          ResetLosesData  = 1'b1,
  parameter int unsigned TextDpdNs       = 150000,   // tEXTDPD
  parameter int unsigned TextHsNs        = 100000,   // tEXTHS
  parameter int unsigned TdpdinNs        = 3000,     // tDPDIN
  parameter int unsigned ThsinNs         = 3000,     // tHSIN
  parameter int unsigned MaxShow         = 10,       // messages per error class
  parameter string       TxnLog          = ""
) (
  input  logic       ck_i,
  input  logic       ck_n_i,
  input  logic       cs_n_i,
  input  logic       rst_n_i,
  input  logic [7:0] dq_i,
  input  logic       dq_drv_i,
  output logic [7:0] dq_o,
  output logic       dq_oe_o,
  input  logic       rwds_i,
  input  logic       rwds_drv_i,
  output logic       rwds_o,
  output logic       rwds_oe_o
);

  // delays in this module's 1 ps whatever the parent's unit
  /* verilator no_inline_module */

  // ------------------------------------------------------------ constants
  localparam int unsigned Words  = MemBytes / 2;
  localparam longint      Big    = 64'd1 << 50;
  // data sheet timing (ps)
  localparam longint TCshi     = 6_000;
  localparam longint TRwr      = 35_000;
  localparam longint TCss      = 4_000;
  localparam longint TIs       = 500;
  localparam longint TIh       = 500;
  localparam longint TCkMin    = 5_000;
  localparam longint TCsm      = (RefreshInterval == 2'b01) ? 4_000_000 : 1_000_000;
  localparam longint TRp       = 200_000;
  localparam longint TRh       = 200_000;
  localparam longint TRph      = 400_000;
  localparam longint TCsDpdMin = 200_000;
  localparam longint TCsDpdMax = 3_000_000;
  localparam longint TCsHsMin  = 60_000;
  localparam longint TCsHsMax  = 3_000_000;
  localparam longint TVcs      = longint'(TvcsNs) * 1000;
  localparam longint TExtDpd   = longint'(TextDpdNs) * 1000;
  localparam longint TExtHs    = longint'(TextHsNs) * 1000;
  localparam longint TDpdIn    = longint'(TdpdinNs) * 1000;
  localparam longint THsIn     = longint'(ThsinNs) * 1000;

  localparam logic [15:0] Cr0Def = 16'h8F2F;
  localparam logic [15:0] Cr1Def = {14'h3FF0, RefreshInterval};   // 0xFFC0 | RefreshInterval

  // ======================================================== error classes
  typedef enum int {
    ETcshi, ETrwr, ETcss, ETcsh, ECkcs, ETcsm, ETck, ETckhp, ELatf, ETis, ETih, EDrv, EPre,
    EContDq, EContRw, ERegwrRwds, ECa, EReg, ERange, EPwr, ERst, ENum
  } ecls_e;

  int errors = 0;
  int err_cnt [ENum];
  initial for (int i = 0; i < int'(ENum); i++) err_cnt[i] = 0;

  // named counters for the testbench
  /* verilator lint_off UNUSEDSIGNAL */
  int err_tcshi, err_trwr, err_tcss, err_tcsh, err_ckcs, err_tcsm, err_tck, err_tckhp, err_latf;
  int err_tis, err_tih, err_drv, err_pre, err_cont_dq, err_cont_rwds, err_regwr_rwds, err_ca;
  int err_reg, err_range, err_pwr, err_rst;
  assign err_tcshi      = err_cnt[ETcshi];
  assign err_trwr       = err_cnt[ETrwr];
  assign err_tcss       = err_cnt[ETcss];
  assign err_tcsh       = err_cnt[ETcsh];
  assign err_ckcs       = err_cnt[ECkcs];
  assign err_tcsm       = err_cnt[ETcsm];
  assign err_tck        = err_cnt[ETck];
  assign err_tckhp      = err_cnt[ETckhp];
  assign err_latf       = err_cnt[ELatf];
  assign err_tis        = err_cnt[ETis];
  assign err_tih        = err_cnt[ETih];
  assign err_drv        = err_cnt[EDrv];
  assign err_pre        = err_cnt[EPre];
  assign err_cont_dq    = err_cnt[EContDq];
  assign err_cont_rwds  = err_cnt[EContRw];
  assign err_regwr_rwds = err_cnt[ERegwrRwds];
  assign err_ca         = err_cnt[ECa];
  assign err_reg        = err_cnt[EReg];
  assign err_range      = err_cnt[ERange];
  assign err_pwr        = err_cnt[EPwr];
  assign err_rst        = err_cnt[ERst];
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic string cls_name(ecls_e c);
    unique case (c)
      ETcshi:     return "tCSHI";
      ETrwr:      return "tRWR";
      ETcss:      return "tCSS";
      ETcsh:      return "tCSH";
      ECkcs:      return "CK at CS# fall";
      ETcsm:      return "tCSM";
      ETck:       return "tCK";
      ETckhp:     return "tCKHP";
      ELatf:      return "latency vs CK";
      ETis:       return "tIS";
      ETih:       return "tIH";
      EDrv:       return "not driven";
      EPre:       return "mask preamble";
      EContDq:    return "DQ contention";
      EContRw:    return "RWDS contention";
      ERegwrRwds: return "RWDS in register write";
      ECa:        return "CA";
      EReg:       return "register";
      ERange:     return "address range";
      EPwr:       return "power state";
      ERst:       return "reset";
      default:    return "?";
    endcase
  endfunction

  function automatic void error(ecls_e c, string msg);
    err_cnt[c]++;
    errors++;
    if (Verbose && err_cnt[c] <= int'(MaxShow)) begin
      $display("%m: %0t ps: ERROR [%s] %s%s", $time, cls_name(c), msg,
               pick(err_cnt[c] == int'(MaxShow), " (further errors of this class not shown)", ""));
    end
  endfunction

  function automatic void note(string msg);
    if (Verbose) $display("%m: %0t ps: %s", $time, msg);
  endfunction

  // conditional text (string operands: no padding of the shorter literal)
  function automatic string pick(bit c, string a, string b);
    if (c) return a;
    return b;
  endfunction

  // ===================================================== information
  int n_txn = 0, n_mem_rd = 0, n_mem_wr = 0, n_reg_rd = 0, n_reg_wr = 0;
  int n_words_rd = 0, n_words_wr = 0, n_lat2x = 0, n_refresh = 0, n_ck_stop = 0, n_ignored = 0;
  int n_dpd = 0, n_hs = 0, n_rst = 0, info_uninit = 0;

  // ============================================================== random
  // xorshift32: the same draws in every simulator
  int unsigned rng = 1;
  function automatic int unsigned rnd();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic longint urange(longint lo, longint hi);
    int unsigned r;
    if (hi <= lo) return lo;
    r = rnd() % 32'(hi - lo + 1);
    return lo + longint'(r);
  endfunction
  function automatic logic [7:0] rnd8();
    return 8'(rnd() >> 7);
  endfunction
  function automatic longint lmax(longint a, longint b);
    return (a > b) ? a : b;
  endfunction
  function automatic longint lmin(longint a, longint b);
    return (a < b) ? a : b;
  endfunction

  // output timing of this device (ps), drawn at time 0
  longint tdsv, tckds, tckd, tckdi, tckdsr, tdqlz, tdsz, toz;
  bit     regwr_keep;
  int     refresh_pct = 20;

  int fd_log = 0;

  initial begin
    int unsigned sd;
    string       fn;
    sd = Seed;
    void'($value$plusargs("hyperram_mem_seed=%d", sd));
    rng = sd ^ 32'h5BD1_E995;
    if (rng == 0) rng = 1;
    for (int k = 0; k < 8; k++) void'(rnd());
    tdsv       = urange(500, 5000);
    tckds      = urange(1000, 4600);
    tckd       = urange(lmax(1000, tckds - 400), lmin(5000, tckds + 400));
    tckdi      = urange(lmax(1, tckds - 400), lmin(tckd, 4200));
    tckdsr     = urange(1000, 5500);
    tdqlz      = urange(1, 1000);
    // the output stage turns off no earlier than its data path settles (the
    // last byte stays on the bus until CS# + tOZ, data sheet figures 30 / 32;
    // note 70: DQ and RWDS delays track); +hyperram_oz_free: tOZ / tDSZ in
    // 1 .. 5 ns whatever tCKD / tCKDS (the last byte may be cut, stress)
    if ($test$plusargs("hyperram_oz_free")) begin
      tdsz = urange(1000, 5000);
      toz  = urange(1000, 5000);
    end else begin
      tdsz = urange(tckds, 5000);
      toz  = urange(tckd, 5000);
    end
    regwr_keep = (rnd() & 32'd1) != 0;
    void'($value$plusargs("hyperram_refresh_pct=%d", refresh_pct));
    if (refresh_pct < 0) refresh_pct = 0;
    if (refresh_pct > 100) refresh_pct = 100;
    fn = TxnLog;
    void'($value$plusargs("hyperram_txn_log=%s", fn));
    if (fn != "") begin
      fd_log = $fopen(fn, "w");
      if (fd_log == 0) $fatal(1, "%m: cannot open %s", fn);
    end
    if (Verbose) begin
      $display("%m: S80KS2562 model, %0d MiB, seed %0d: tDSV %0d tCKDS %0d tCKD %0d tCKDI %0d tCKDSR %0d tDQLZ %0d tDSZ %0d tOZ %0d ps, register write RWDS %s, refresh collisions %0d %%, tCSM %0d ns",
               MemBytes >> 20, sd, tdsv, tckds, tckd, tckdi, tckdsr, tdqlz, tdsz, toz,
               pick(regwr_keep, "kept low", "released"), refresh_pct, TCsm / 1000);
    end
  end

  final begin
    if (fd_log != 0) $fclose(fd_log);
  end

  // ============================================================= storage
  // sparse: word address -> {byte A, byte B}; wvalid: bytes written {A, B}
  logic [15:0] mem    [int unsigned];
  logic [1:0]  wvalid [int unsigned];

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [15:0] uninit_word(int unsigned waddr);   // (waddr[7:0] only)
    return {8'hDE, 8'(waddr)};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [15:0] peek(int unsigned waddr);
    return (mem.exists(waddr) != 0) ? mem[waddr] : uninit_word(waddr);
  endfunction

  function automatic void poke(int unsigned waddr, logic [15:0] v);
    mem[waddr]    = v;
    wvalid[waddr] = 2'b11;
  endfunction

  function automatic logic [1:0] written_mask(int unsigned waddr);
    return (wvalid.exists(waddr) != 0) ? wvalid[waddr] : 2'b00;
  endfunction

  function automatic bit was_written(int unsigned waddr);
    return written_mask(waddr) != 2'b00;
  endfunction

  function automatic logic [7:0] peek_byte(int unsigned baddr);
    logic [15:0] w;
    w = peek(baddr >> 1);
    return baddr[0] ? w[7:0] : w[15:8];
  endfunction

  function automatic void poke_byte(int unsigned baddr, logic [7:0] v);
    logic [15:0] w;
    logic [1:0]  m;
    w = peek(baddr >> 1);
    m = written_mask(baddr >> 1);
    if (baddr[0]) begin
      w[7:0] = v;
      m[0]   = 1'b1;
    end else begin
      w[15:8] = v;
      m[1]    = 1'b1;
    end
    mem[baddr >> 1]    = w;
    wvalid[baddr >> 1] = m;
  endfunction

  function automatic void mem_clear(string why);
    if (mem.num() != 0) note($sformatf("%0d memory words lost (%s)", mem.num(), why));
    mem.delete();
    wvalid.delete();
  endfunction

  // one word of a memory write (mask bit 1 = byte not written)
  function automatic void mem_write(int unsigned w, logic [7:0] a, logic [7:0] b, logic ma, logic mb);
    logic [15:0] v;
    logic [1:0]  m;
    if (ma && mb) return;
    v = peek(w);
    m = written_mask(w);
    if (!ma) begin
      v[15:8] = a;
      m[1]    = 1'b1;
    end
    if (!mb) begin
      v[7:0] = b;
      m[0]   = 1'b1;
    end
    mem[w]    = v;
    wvalid[w] = m;
  endfunction

  // ============================================================ registers
  logic [15:0] cr0 = Cr0Def, cr1 = Cr1Def;

  function automatic void regs_default();
    cr0 = Cr0Def;
    cr1 = Cr1Def;
  endfunction

  // register of a word address: 0 ID0, 1 ID1, 2 CR0, 3 CR1, -1 none
  function automatic int reg_sel(logic [31:0] w);
    if (w == 32'h0000_0000) return 0;
    if (w == 32'h0000_0001) return 1;
    if (w == 32'h0000_0800) return 2;
    if (w == 32'h0000_0801) return 3;
    return -1;
  endfunction

  function automatic logic [15:0] reg_value(int sel);
    unique case (sel)
      0:       return Id0;
      1:       return Id1;
      2:       return cr0;
      default: return cr1;
    endcase
  endfunction

  function automatic bit lat_code_ok(logic [3:0] code);
    return code inside {4'b1110, 4'b1111, 4'b0000, 4'b0001, 4'b0010};
  endfunction

  // initial latency in clocks of a CR0[7:4] code (reserved codes: 7)
  function automatic int lat_clocks(logic [3:0] code);
    unique case (code)
      4'b1110: return 3;
      4'b1111: return 4;
      4'b0000: return 5;
      4'b0001: return 6;
      default: return 7;
    endcase
  endfunction

  // shortest CK period for a latency (ps): 85 / 104 / 133 / 166 / 200 MHz
  function automatic longint lat_tck_min(int l);
    unique case (l)
      3:       return 11_765;
      4:       return 9_615;
      5:       return 7_519;
      6:       return 6_024;
      default: return 5_000;
    endcase
  endfunction

  // ============================================================ power
  logic   cs_q = 1'b1, ck_q = 1'b0, rst_q = 1'b1;   // CS# / CK / RESET# levels (X: high, low, high)
  typedef enum int {PwrActive = 0, PwrDpd = 1, PwrHs = 2} pwr_e;
  pwr_e   pstate      = PwrActive;
  longint t_sleep     = 0;            // DPD / HS entered (CS# rise of the register write)
  longint t_ready     = TVcs;         // no transaction before
  string  ready_why   = "tVCS (power-up)";
  bit     ready_rst   = 1'b0;         // t_ready set by a reset rule (else power state)
  bit     vcs_wait_rst = 1'b0;        // RESET# low at power-up: tVCS from its rising edge

  function automatic void set_ready(longint t, string why, bit is_rst);
    if (t > t_ready) begin
      t_ready   = t;
      ready_why = why;
      ready_rst = is_rst;
    end
  endfunction

  function automatic bit ready();
    return rst_q && pstate == PwrActive && $time >= t_ready && !vcs_wait_rst;
  endfunction

  // partial array refresh (CR1[4:2]): words outside the refreshed part lost
  function automatic void par_invalidate();
    longint      lo, hi;
    int unsigned gone [$];
    unique case (cr1[4:2])
      3'b000:  return;
      3'b001:  begin lo = 0;                         hi = longint'(Words) / 2;      end
      3'b010:  begin lo = 0;                         hi = longint'(Words) / 4;      end
      3'b011:  begin lo = 0;                         hi = longint'(Words) / 8;      end
      3'b100:  begin lo = 0;                         hi = 0;                        end
      3'b101:  begin lo = longint'(Words) / 2;       hi = longint'(Words);          end
      3'b110:  begin lo = longint'(Words) * 3 / 4;   hi = longint'(Words);          end
      default: begin lo = longint'(Words) * 7 / 8;   hi = longint'(Words);          end
    endcase
    foreach (mem[w]) if (longint'(w) < lo || longint'(w) >= hi) gone.push_back(w);
    foreach (gone[i]) begin
      mem.delete(gone[i]);
      wvalid.delete(gone[i]);
    end
    if (gone.size() != 0) note($sformatf("partial array refresh CR1[4:2] = %b: %0d words lost in hybrid sleep",
                                         cr1[4:2], gone.size()));
  endfunction

  // =========================================================== outputs
  // Timed output actions in one queue (time order, then order of push):
  // every process that pushes actions issues one delayed NBA wake-up per
  // action (a literal NBA in an always block: Verilator turns NBAs of tasks
  // into blocking assignments); the apply process takes every due action.
  // An action belongs to a transaction (tag = txn_id at its CS# fall): a
  // drive applies only for the current transaction before its release; a
  // release (CS# rise + tOZ / tDSZ, the RWDS turnaround of a write, RESET#)
  // drops the later actions of its transaction and turns the output off
  // unless a newer transaction drives it already.
  typedef enum int {ADq, ADqRel, ARw, ARwRel} akind_e;
  typedef struct {
    longint      t;
    akind_e      kind;
    logic [7:0]  v;
    int unsigned tag;
  } act_t;

  act_t        pend [$];
  longint      wk_q [$];             // delays of the actions pushed by the running process
  int unsigned wake = 0, wseq = 0;
  int unsigned txn_id = 0;
  int unsigned dq_rel = 0, rw_rel = 0, dq_own = 0, rw_own = 0;

  function automatic void push(longint d, akind_e kind, logic [7:0] v);
    act_t a;
    int   i;
    if (d < 1) d = 1;
    a.t    = $time + d;
    a.kind = kind;
    a.v    = v;
    a.tag  = txn_id;
    i = pend.size();
    while (i > 0 && pend[i - 1].t > a.t) i--;
    pend.insert(i, a);
    wk_q.push_back(d);
  endfunction

  // (a literal NBA per pushed action, at the end of every pushing process)
`define HYPERRAM_MODEL_WAKE \
    for (int wi = 0; wi < wk_q.size(); wi++) begin \
      wd = wk_q[wi]; \
      wseq++; \
      wake <= #(wd) wseq; \
    end \
    wk_q.delete();

  initial begin
    dq_o      = '0;
    dq_oe_o   = 1'b0;
    rwds_o    = 1'b0;
    rwds_oe_o = 1'b0;
  end

  always @(wake) begin
    while (pend.size() != 0 && pend[0].t <= $time) begin
      act_t a;
      a = pend.pop_front();
      unique case (a.kind)
        ADq: begin
          if (a.tag == txn_id && a.tag > dq_rel) begin
            dq_o    = a.v;
            dq_oe_o = 1'b1;
            dq_own  = a.tag;
          end
        end
        ADqRel: begin
          if (a.tag > dq_rel) dq_rel = a.tag;
          if (dq_own <= a.tag) dq_oe_o = 1'b0;
        end
        ARw: begin
          if (a.tag == txn_id && a.tag > rw_rel) begin
            rwds_o    = a.v[0];
            rwds_oe_o = 1'b1;
            rw_own    = a.tag;
          end
        end
        default: begin
          if (a.tag > rw_rel) rw_rel = a.tag;
          if (rw_own <= a.tag) rwds_oe_o = 1'b0;
        end
      endcase
    end
  end

  // ========================================================= transaction
  typedef enum int {KMemRd, KMemWr, KRegRd, KRegWr} kind_e;

  bit          txn = 1'b0;            // CS# low, the device takes part
  bit          ignored = 1'b0;        // CS# low, transaction refused (error counted)
  bit          pulse = 1'b0;          // CS# low: DPD / HS exit pulse
  bit          pulse_ck = 1'b0;
  longint      t_cs_fall = -Big, t_cs_rise = -Big, t_rst_fall = -Big;
  int          k = 0;                 // CK cycle (rising edges since CS# fell)
  int          n_edges = 0;           // CK edges of the transaction
  logic [47:0] ca = '0;
  bit          dec = 1'b0;            // CA decoded (f3 seen)
  kind_e       kind = KMemRd;
  bit          lat2x = 1'b0;
  int          lat = 7;
  int          dcyc = 0;              // first data cycle D
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] cr0_t = Cr0Def;        // CR0 at the start of the transaction (latency, wrap)
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] waddr_ca = '0;         // word address of the CA
  int unsigned waddr_s = 0;           // start word address in the array
  int          rsel = -1;             // register of a register access
  int          nw = 0;                // words transferred
  logic [15:0] rd_word = '0;
  logic [7:0]  wr_a = '0;
  logic        wr_ma = 1'b0;
  logic [7:0]  reg_a = '0;
  logic [15:0] reg_word = '0;
  bit          reg_ok = 1'b0;
  bit          rep_tck = 1'b0, rep_tckhp = 1'b0, rep_regrd = 1'b0, rep_regwr = 1'b0, rep_rwds = 1'b0;
  bit          pre_watch = 1'b0;
  longint      t_rp = -Big, t_fp = -Big, p_ref = 0;
  string       log_s = "";

  // ------------------------------------------------- write phase sweep hook
  // wr_relax (set hierarchically by a testbench while the controller moves
  // DQ / RWDS out of the tIS / tIH window on purpose: the write phase scan of
  // bow_hr_calibrate_write, which shifts the CA bytes too): a setup / hold /
  // not-driven violation of a DQ or RWDS capture, or a missing mask
  // preamble, counts in n_relaxed instead of an error class, and the device
  // stays harmless but visibly wrong: a transaction whose CA was captured with
  // a violation is garbled (ignored: no read data, nothing written, a register
  // write not applied; RWDS answers the CA phase and is released after f3 as
  // in a write, so that no host turnaround runs into it), a write word
  // captured with a violation is stored inverted (both bytes, whatever the
  // mask).
  bit          wr_relax = 1'b0;
  int          n_relaxed = 0;
  // ca_abort_ok (set hierarchically by a testbench that cuts transactions on
  // purpose, e.g. a channel reset of the controller in the middle of a read):
  // CS# rising before the 6 command-address edges counts in n_ca_aborted
  // instead of an ECa error (the device ignores the transaction either way)
  bit          ca_abort_ok = 1'b0;
  int          n_ca_aborted = 0;
  bit          garbled = 1'b0;        // relax: this transaction's CA was captured with a violation
  bit          garble_rel = 1'b0;     // relax: RWDS of the garbled transaction released
  bit          word_bad = 1'b0;       // relax: the write word being assembled had a violation
  int unsigned last_w = 0;            // relax: word address of the last stored write word
  bit          last_w_ok = 1'b0;

  // ------------------------------------------------- setup / hold tracking
  longint t_dq_chg = -Big, t_dq_on = -Big, t_dq_cap = -Big;
  longint t_rw_chg = -Big, t_rw_on = -Big, t_rw_cap = -Big;
  bit     dq_hold_rep = 1'b0, rw_hold_rep = 1'b0;
  string  dq_cap_what = "", rw_cap_what = "";
  bit     dq_cap_ca = 1'b0, dq_cap_b = 1'b0, rw_cap_b = 1'b0;   // kind of the last capture edge

  // a capture violation: an error, or (wr_relax) a garbled CA / bad write word
  function automatic void cap_viol(ecls_e c, string msg, bit is_ca, bit after_b);
    if (!wr_relax) begin
      error(c, msg);
    end else begin
      n_relaxed++;
      if (is_ca) begin
        garbled = 1'b1;
      end else if (after_b && last_w_ok) begin
        mem[last_w]    = ~peek(last_w);     // that word is stored already: inverted now
        wvalid[last_w] = 2'b11;
      end else begin
        word_bad = 1'b1;                    // inverted when the word is stored
      end
    end
  endfunction

  // DQ captured at this edge: driven, stable for tIS (hold checked on change)
  function automatic void cap_dq(longint now, string what, bit is_ca, bit is_b);
    longint s;
    s = now - lmax(t_dq_chg, t_dq_on);
    if (!dq_drv_i) begin
      cap_viol(EDrv, $sformatf("DQ not driven by the host at the CK edge capturing %s", what), is_ca, 1'b0);
    end else if (s < TIs) begin
      cap_viol(ETis, $sformatf("tIS: DQ changed %0d ps before the CK edge capturing %s", s, what), is_ca, 1'b0);
    end
    t_dq_cap    = now;
    dq_hold_rep = 1'b0;
    dq_cap_what = what;
    dq_cap_ca   = is_ca;
    dq_cap_b    = is_b;
  endfunction

  function automatic void cap_rw(longint now, string what, bit is_b);
    longint s;
    s = now - lmax(t_rw_chg, t_rw_on);
    if (!rwds_drv_i) begin
      cap_viol(EDrv, $sformatf("RWDS not driven by the host at the CK edge capturing %s", what), 1'b0, 1'b0);
    end else if (s < TIs) begin
      cap_viol(ETis, $sformatf("tIS: RWDS changed %0d ps before the CK edge capturing %s", s, what), 1'b0, 1'b0);
    end
    t_rw_cap    = now;
    rw_hold_rep = 1'b0;
    rw_cap_what = what;
    rw_cap_b    = is_b;
  endfunction

  always @(dq_i) begin
    if ($time - t_dq_cap < TIh && !dq_hold_rep) begin
      dq_hold_rep = 1'b1;
      cap_viol(ETih, $sformatf("tIH: DQ changed %0d ps after the CK edge capturing %s", $time - t_dq_cap,
                               dq_cap_what), dq_cap_ca, dq_cap_b);
    end
    t_dq_chg = $time;
  end
  always @(posedge dq_drv_i) t_dq_on = $time;
  always @(negedge dq_drv_i) begin
    if ($time - t_dq_cap < TIh && !dq_hold_rep) begin
      dq_hold_rep = 1'b1;
      cap_viol(ETih, $sformatf("tIH: DQ released %0d ps after the CK edge capturing %s", $time - t_dq_cap,
                               dq_cap_what), dq_cap_ca, dq_cap_b);
    end
  end

  always @(rwds_i) begin
    if ($time - t_rw_cap < TIh && !rw_hold_rep) begin
      rw_hold_rep = 1'b1;
      cap_viol(ETih, $sformatf("tIH: RWDS changed %0d ps after the CK edge capturing %s", $time - t_rw_cap,
                               rw_cap_what), 1'b0, rw_cap_b);
    end
    t_rw_chg = $time;
  end
  always @(posedge rwds_drv_i) begin
    t_rw_on = $time;
    if (txn && dec && kind == KRegWr) regwr_rwds();
  end
  always @(negedge rwds_drv_i) begin
    if ($time - t_rw_cap < TIh && !rw_hold_rep) begin
      rw_hold_rep = 1'b1;
      cap_viol(ETih, $sformatf("tIH: RWDS released %0d ps after the CK edge capturing %s", $time - t_rw_cap,
                               rw_cap_what), 1'b0, rw_cap_b);
    end
    if (txn && pre_watch) begin
      pre_watch = 1'b0;
      if (wr_relax) n_relaxed++;
      else error(EPre, "the host released RWDS between the mask preamble (f_(D-1)) and the first data edge");
    end
  end

  function automatic void regwr_rwds();
    if (!rep_rwds) begin
      rep_rwds = 1'b1;
      error(ERegwrRwds, "the host drives RWDS during a register write");
    end
  endfunction

  // ------------------------------------------------------------ contention
  logic c_dq, c_rw;
  assign c_dq = dq_drv_i && dq_oe_o;
  assign c_rw = rwds_drv_i && rwds_oe_o;
  always @(posedge c_dq) error(EContDq, "DQ driven by the host and by the HyperRAM");
  always @(posedge c_rw) error(EContRw, "RWDS driven by the host and by the HyperRAM");

  // ------------------------------------------------------- burst address
  // word n of the burst (wrap configuration of CR0 at the transaction start)
  function automatic int unsigned burst_addr(int n);
    int unsigned g, base, off;
    if (kind == KRegRd || ca[45]) return int'((longint'(waddr_s) + longint'(n)) % longint'(Words));
    unique case (cr0_t[1:0])
      2'b00:   g = 64;          // 128 bytes
      2'b01:   g = 32;          // 64 bytes
      2'b10:   g = 8;           // 16 bytes
      default: g = 16;          // 32 bytes
    endcase
    base = waddr_s & ~(g - 1);
    off  = waddr_s - base;
    if (cr0_t[2] || n < int'(g)) return base + ((off + n) % g);      // legacy wrap / first group
    return int'((longint'(base) + longint'(g) + longint'(n) - longint'(g)) % longint'(Words));   // hybrid: linear
  endfunction

  // read data word n
  function automatic logic [15:0] fetch(int n);
    int unsigned w;
    logic [7:0]  ra, rb;
    if (kind == KRegRd) begin
      if (n == 0 && rsel >= 0) return reg_value(rsel);
      if (n != 0 && !rep_regrd) begin
        rep_regrd = 1'b1;
        error(EReg, "register read longer than one word: the data is indeterminate (random bytes)");
      end
      ra = rnd8();
      rb = rnd8();
      return {ra, rb};
    end
    w = burst_addr(n);
    if (written_mask(w) != 2'b11) info_uninit++;
    return peek(w);
  endfunction

  function automatic void lat_freq_check();
    if (p_ref > 0 && p_ref * 100 < lat_tck_min(lat) * 99) begin
      error(ELatf, $sformatf("CK period %0d ps is too short for an initial latency of %0d clocks (>= %0d ps)",
                             p_ref, lat, lat_tck_min(lat)));
    end
  endfunction

  // ============================================================ CS# edges
  task automatic cs_fall();
    longint now, rdraw;
    string  msg;
    now = $time;
    txn_id++;
    t_cs_fall = now;
    if (t_cs_rise > -Big && now - t_cs_rise < TCshi) begin
      error(ETcshi, $sformatf("tCSHI: CS# high for %0d ps (< 6 ns)", now - t_cs_rise));
    end
    if (!rst_q) begin
      error(ERst, "CS# low while RESET# is low (tRPH): ignored");
      ignored = 1'b1;
      n_ignored++;
      return;
    end
    if (pstate != PwrActive) begin
      pulse    = 1'b1;
      pulse_ck = 1'b0;
      if (now - t_sleep < ((pstate == PwrDpd) ? TDpdIn : THsIn)) begin
        error(EPwr, $sformatf("CS# low %0d ns after entering %s (< %s = %0d ns)", (now - t_sleep) / 1000,
                              pick(pstate == PwrDpd, "deep power down", "hybrid sleep"),
                              pick(pstate == PwrDpd, "tDPDIN", "tHSIN"),
                              ((pstate == PwrDpd) ? TDpdIn : THsIn) / 1000));
      end
      return;
    end
    if (now < t_ready || vcs_wait_rst) begin
      msg = $sformatf("transaction %0d ns before the end of %s: ignored", (t_ready - now + 999) / 1000,
                      ready_why);
      if (ready_rst) error(ERst, msg);
      else           error(EPwr, msg);
      ignored = 1'b1;
      n_ignored++;
      return;
    end
    if (ck_q) error(ECkcs, "transaction started with CK high");
    txn       = 1'b1;
    k         = 0;
    n_edges   = 0;
    ca        = '0;
    dec       = 1'b0;
    nw        = 0;
    reg_ok    = 1'b0;
    rep_tck   = 1'b0;
    rep_tckhp = 1'b0;
    rep_regrd = 1'b0;
    rep_regwr = 1'b0;
    rep_rwds  = 1'b0;
    pre_watch = 1'b0;
    garbled    = 1'b0;
    garble_rel = 1'b0;
    word_bad   = 1'b0;
    last_w_ok  = 1'b0;
    t_rp      = -Big;
    t_fp      = -Big;
    p_ref     = 0;
    log_s     = "";
    cr0_t     = cr0;
    // (one draw per transaction in a plain statement, used or not: the same
    // sequence in every simulator - Verilator 5.022 evaluated a draw in the
    // untaken branch of an if / else of two assignments)
    rdraw     = urange(0, 99);
    lat2x     = cr0[3] || rdraw < longint'(refresh_pct);
    if (lat2x) n_lat2x++;
    if (lat2x && !cr0[3]) n_refresh++;
    push(tdsv, ARw, {7'd0, lat2x});
  endtask

  // a DPD / HS exit pulse ends
  function automatic void pulse_end(longint now);
    longint w;
    w = now - t_cs_fall;
    if (pstate == PwrDpd) begin
      if (w < TCsDpdMin || w > TCsDpdMax) begin
        error(EPwr, $sformatf("tCSDPD: deep power down exit pulse %0d ns (200 .. 3000 ns)", w / 1000));
      end
      regs_default();
      pstate = PwrActive;
      set_ready(now + TExtDpd, "tEXTDPD (deep power down exit)", 1'b0);
      note($sformatf("deep power down exit (CS# pulse %0d ns), ready in %0d us", w / 1000, TExtDpd / 1000000));
    end else begin
      if (w < TCsHsMin || w > TCsHsMax) begin
        error(EPwr, $sformatf("tCSHS: hybrid sleep exit pulse %0d ns (60 .. 3000 ns)", w / 1000));
      end
      cr1[5] = 1'b0;
      par_invalidate();
      pstate = PwrActive;
      set_ready(now + TExtHs, "tEXTHS (hybrid sleep exit)", 1'b0);
      note($sformatf("hybrid sleep exit (CS# pulse %0d ns), ready in %0d us", w / 1000, TExtHs / 1000000));
    end
  endfunction

  function automatic void reg_write(int sel, logic [15:0] v, longint now);
    unique case (sel)
      2: begin
        if (v[11:8] != 4'hF) error(EReg, $sformatf("CR0 written %04h: reserved CR0[11:8] must be 1111", v));
        if (!lat_code_ok(v[7:4])) begin
          error(EReg, $sformatf("CR0 written %04h: reserved latency code %b (the model keeps 7 clocks)", v, v[7:4]));
        end
        cr0 = {v[15:12], 4'hF, v[7:0]};
        if (!v[15]) begin
          pstate  = PwrDpd;
          t_sleep = now;
          n_dpd++;
          note($sformatf("CR0 = %04h: deep power down", cr0));
          mem_clear("deep power down");
        end
      end
      3: begin
        if (v[15:7] != 9'h1FF) error(EReg, $sformatf("CR1 written %04h: reserved CR1[15:7] must be all 1", v));
        cr1 = {9'h1FF, v[6:2], RefreshInterval};
        if (!v[6]) note("CR1[6] = 0: differential clock (the model uses CK only)");
        if (v[5]) begin
          pstate  = PwrHs;
          t_sleep = now;
          n_hs++;
          note($sformatf("CR1 = %04h: hybrid sleep", cr1));
        end
      end
      0, 1: error(EReg, $sformatf("write %04h to the read-only ID%0d register", v, sel));
      default: error(EReg, $sformatf("register write %04h to the unknown word address %08h", v, waddr_ca));
    endcase
  endfunction

  task automatic cs_rise();
    longint now;
    string  ty;
    now = $time;
    if (pulse) begin
      pulse_end(now);
      pulse     = 1'b0;
      t_cs_rise = now;
      return;
    end
    if (ignored || !txn) begin
      ignored   = 1'b0;
      t_cs_rise = now;
      return;
    end
    txn = 1'b0;
    if (ck_q) error(ETcsh, "tCSH: CS# rose with CK high (after the last CK falling edge, with CK low)");
    if (k >= 1 && t_fp > t_rp && p_ref > 0) hp_check(t_fp - t_rp, p_ref);
    if (now - t_cs_fall > TCsm) begin
      error(ETcsm, $sformatf("tCSM: CS# low for %0d ns (> %0d ns)", (now - t_cs_fall) / 1000, TCsm / 1000));
    end
    if (!dec) begin
      if (ca_abort_ok) n_ca_aborted++;
      else error(ECa, $sformatf("CS# rose after %0d of the 6 command-address edges", n_edges));
    end else if (garbled) begin
      note("relax: a transaction with a violated command-address capture was ignored");
    end else begin
      n_txn++;
      unique case (kind)
        KMemRd: begin
          n_mem_rd++;
          n_words_rd += nw;
          ty = "MR";
        end
        KMemWr: begin
          n_mem_wr++;
          n_words_wr += nw;
          ty = "MW";
        end
        KRegRd: begin
          n_reg_rd++;
          ty = "RR";
        end
        default: begin
          n_reg_wr++;
          ty = "RW";
          if (reg_ok) reg_write(rsel, reg_word, now);
          else error(EReg, "register write ended before its data word was complete (nothing written)");
        end
      endcase
      if (fd_log != 0) begin
        $fdisplay(fd_log, "%0d %s %s %08h L%0d %s %0d :%s", t_cs_fall, ty, pick(ca[45], "LIN", "WRAP"),
                  waddr_ca, lat, pick(lat2x, "2x", "1x"), nw, log_s);
      end
    end
    push(toz, ADqRel, 8'd0);
    push(tdsz, ARwRel, 8'd0);
    t_cs_rise = now;
  endtask

  logic [31:0] unused_ck_n;
  assign unused_ck_n = {31'd0, ck_n_i};

  always @(cs_n_i) begin
    logic   cs;
    longint wd;
    cs = (cs_n_i === 1'b0) ? 1'b0 : 1'b1;
    if (cs != cs_q) begin
      cs_q = cs;
      if ($time > 0) begin
        if (!cs) cs_fall();
        else cs_rise();
      end
    end
    `HYPERRAM_MODEL_WAKE
  end

  // ============================================================ RESET#
  always @(rst_n_i) begin
    logic   r;
    longint wd, now;
    r   = (rst_n_i === 1'b0) ? 1'b0 : 1'b1;
    now = $time;
    if (r != rst_q) begin
      rst_q = r;
      if (now == 0) begin
        if (!r) vcs_wait_rst = 1'b1;
      end else if (!r) begin
        t_rst_fall = now;
        if (txn) note("RESET# low during a transaction: aborted");
        txn       = 1'b0;
        dec       = 1'b0;
        pulse     = 1'b0;
        ignored   = 1'b0;
        pre_watch = 1'b0;
        push(1, ADqRel, 8'd0);
        push(1, ARwRel, 8'd0);
        regs_default();
        if (pstate != PwrActive) note("RESET# low: deep power down / hybrid sleep left");
        pstate = PwrActive;
        if (ResetLosesData) mem_clear("hardware reset");
        n_rst++;
      end else begin
        if (now - t_rst_fall < TRp) begin
          error(ERst, $sformatf("tRP: RESET# low for %0d ns (< 200 ns)", (now - t_rst_fall) / 1000));
        end
        if (vcs_wait_rst) begin
          vcs_wait_rst = 1'b0;
          t_ready      = now + TVcs;
          ready_why    = "tVCS (power-up with RESET# low)";
          ready_rst    = 1'b0;
        end
        set_ready(now + TRh, "tRH (RESET# high to CS# low)", 1'b1);
        set_ready(t_rst_fall + TRph, "tRPH (RESET# low to CS# low)", 1'b1);
      end
    end
    `HYPERRAM_MODEL_WAKE
  end

  // ============================================================== CK edges
  // high phase h against the period p (0.45 .. 0.55, 1 % tolerance)
  function automatic void hp_check(longint h, longint p);
    if (!rep_tckhp && (h * 100 > p * 56 || h * 100 < p * 44)) begin
      rep_tckhp = 1'b1;
      error(ETckhp, $sformatf("tCKHP: CK high for %0d ps of a %0d ps period (0.45 .. 0.55)", h, p));
    end
  endfunction

  // the cycle r_(k-1) .. r_k ends (k >= 2)
  function automatic void ck_cycle(longint now);
    longint p, h, l;
    p = now - t_rp;
    h = t_fp - t_rp;
    l = now - t_fp;
    if (p < TCkMin - 1 && !rep_tck) begin
      rep_tck = 1'b1;
      error(ETck, $sformatf("tCK: CK period %0d ps (< 5 ns)", p));
    end
    if (l * 45 > h * 55) begin            // long low phase: active clock stop
      n_ck_stop++;
      if (p_ref > 0) hp_check(h, p_ref);
    end else begin
      hp_check(h, p);
      p_ref = p;
    end
  endfunction

  // the CA has been captured (f3)
  function automatic void decode();
    dec      = 1'b1;
    if (garbled) begin                     // relax: a garbled command does nothing (RWDS off as
      garble_rel = 1'b1;                   // after a write CA: no contention with any host turnaround)
      push(tdsz, ARwRel, 8'd0);
      return;
    end
    waddr_ca = {ca[44:16], ca[2:0]};
    lat      = lat_clocks(cr0_t[7:4]);
    rsel     = -1;
    if (ca[15:3] != 13'd0) error(ECa, $sformatf("reserved CA[15:3] = %04h (must be 0)", ca[15:3]));
    if (ca[46]) begin
      rsel = reg_sel(waddr_ca);
      if (!ca[47]) begin                   // register write: zero latency
        kind = KRegWr;
        dcyc = 4;
        if (!ca[45]) error(EReg, "register write with CA[45] = 0 (only linear one word register writes)");
        if (rwds_drv_i) regwr_rwds();
        if (regwr_keep) begin
          if (lat2x) push(tckdsr, ARw, 8'd0);
        end else begin
          push(tdsz, ARwRel, 8'd0);
        end
      end else begin
        kind = KRegRd;
        dcyc = (lat2x ? 2 * lat : lat) + 3;
        if (rsel < 0) begin
          error(EReg, $sformatf("register read of the unknown word address %08h (random data)", waddr_ca));
        end
        if (lat2x) push(tckdsr, ARw, 8'd0);
      end
    end else begin
      if (waddr_ca >= Words) begin
        error(ERange, $sformatf("memory word address %08h beyond the %0d MiB array (wrapped)", waddr_ca,
                                MemBytes >> 20));
      end
      waddr_s = int'(longint'(waddr_ca) % longint'(Words));
      dcyc    = (lat2x ? 2 * lat : lat) + 3;
      if (!ca[47]) begin
        kind = KMemWr;
        push(tdsz, ARwRel, 8'd0);          // the host's turn (mask preamble)
      end else begin
        kind = KMemRd;
        if (lat2x) push(tckdsr, ARw, 8'd0);
      end
    end
  endfunction

  function automatic void ck_edge(bit rise);
    longint     now;
    int         e;
    logic [7:0] g;
    now = $time;
    if (rise == ck_q) return;
    ck_q = rise;
    if (now == 0) return;
    if (!txn) begin
      if (pulse) begin
        if (!pulse_ck) begin
          pulse_ck = 1'b1;
          error(EPwr, "CK toggles during a deep power down / hybrid sleep exit pulse (a transaction to a sleeping device)");
        end
      end else if (rise && cs_q && t_cs_rise > -Big && now - t_cs_rise < TCss) begin
        error(ETcss, $sformatf("tCSS: CK rising edge %0d ps after CS# rose (< 4 ns)", now - t_cs_rise));
      end
      return;
    end
    if (rise) begin
      k++;
      if (k >= 2) ck_cycle(now);
      t_rp = now;
    end else begin
      if (k == 0) return;                  // CK was high at CS# fall (counted there)
      t_fp = now;
    end
    n_edges++;
    e = rise ? 2 * k - 2 : 2 * k - 1;
    // ------------------------------------------------ command-address
    if (e <= 5) begin
      cap_dq(now, $sformatf("CA byte %0d", e), 1'b1, e[0]);
      ca[47 - 8 * e -: 8] = dq_i;
      if (e == 0 && now - t_cs_fall < TCss) begin
        error(ETcss, $sformatf("tCSS: first CK rising edge %0d ps after CS# fell (< 4 ns)", now - t_cs_fall));
      end
      if (e == 3 && t_cs_rise > -Big && now - t_cs_rise < TRwr) begin
        error(ETrwr, $sformatf("tRWR: f2 %0d ps after the previous CS# rise (< 35 ns)", now - t_cs_rise));
      end
      if (e == 5) decode();
      return;
    end
    // ------------------------------------------------ data
    if (garbled) begin                      // relax: a garbled command does nothing
      if (!garble_rel) begin                // (garbled by the hold time of f3: RWDS off now)
        garble_rel = 1'b1;
        push(1, ARwRel, 8'd0);
      end
      return;
    end
    unique case (kind)
      KMemRd, KRegRd: begin
        g = rnd8();                         // one random byte per edge (DQ invalid / low-Z)
        if (rise && k == dcyc - 1) push(tdqlz, ADq, g);
        if (k >= dcyc) begin
          if (rise) begin
            if (k == dcyc) lat_freq_check();
            rd_word = fetch(k - dcyc);
            if (tckdi < tckd) push(tckdi, ADq, g);
            push(tckd, ADq, rd_word[15:8]);
            push(tckds, ARw, 8'd1);
          end else begin
            if (tckdi < tckd) push(tckdi, ADq, g);
            push(tckd, ADq, rd_word[7:0]);
            push(tckds, ARw, 8'd0);
            nw++;
            if (fd_log != 0) log_s = {log_s, $sformatf(" %04h", rd_word)};
          end
        end
      end
      KMemWr: begin
        if (!rise && k == dcyc - 1) begin
          if (!rwds_drv_i || rwds_i !== 1'b0) begin
            if (wr_relax) n_relaxed++;
            else error(EPre, $sformatf("write mask preamble: RWDS %s at f_(D-1) (cycle %0d, D = %0d): the host must drive it low",
                                       pick(!rwds_drv_i, "not driven by the host", "high"), k, dcyc));
          end else begin
            pre_watch = 1'b1;
          end
        end
        if (k >= dcyc) begin
          if (rise) begin
            pre_watch = 1'b0;
            word_bad  = 1'b0;
            if (k == dcyc) lat_freq_check();
            cap_dq(now, $sformatf("write byte A of word %0d", k - dcyc), 1'b0, 1'b0);
            cap_rw(now, $sformatf("the mask of byte A of word %0d", k - dcyc), 1'b0);
            wr_a  = dq_i;
            wr_ma = rwds_i;
          end else begin
            int unsigned w;
            cap_dq(now, $sformatf("write byte B of word %0d", k - dcyc), 1'b0, 1'b1);
            cap_rw(now, $sformatf("the mask of byte B of word %0d", k - dcyc), 1'b1);
            w = burst_addr(k - dcyc);
            if (word_bad) mem_write(w, ~wr_a, ~dq_i, 1'b0, 1'b0);   // relax: garbage stored
            else          mem_write(w, wr_a, dq_i, wr_ma, rwds_i);
            last_w    = w;
            last_w_ok = 1'b1;
            nw++;
            if (fd_log != 0) begin
              string sa, sb;
              if (wr_ma) sa = "--";
              else       sa = $sformatf("%02h", wr_a);
              if (rwds_i) sb = "--";
              else        sb = $sformatf("%02h", dq_i);
              log_s = {log_s, " ", sa, sb};
            end
          end
        end
      end
      default: begin                        // register write
        if (k == 4) begin
          cap_dq(now, $sformatf("register write byte %s", pick(rise, "A", "B")), 1'b1, !rise);
          if (rise) begin
            reg_a = dq_i;
          end else begin
            reg_word = {reg_a, dq_i};
            reg_ok   = 1'b1;
            nw       = 1;
            if (fd_log != 0) log_s = $sformatf(" %04h", reg_word);
          end
        end else if (k >= 5 && !rep_regwr) begin
          rep_regwr = 1'b1;
          error(EReg, "register write longer than one word (the first word is written)");
        end
      end
    endcase
  endfunction

  always @(posedge ck_i or negedge ck_i) begin
    longint wd;
    ck_edge(ck_i === 1'b1);
    `HYPERRAM_MODEL_WAKE
  end

`undef HYPERRAM_MODEL_WAKE

  // ================================================================ summary
  final begin
    if (Verbose) begin
      $display("%m: %0d transactions (memory read %0d / write %0d, register read %0d / write %0d), %0d / %0d words read / written, 2x latency %0d (refresh %0d), ignored %0d, DPD %0d, HS %0d, reset %0d, uninitialised words read %0d, errors %0d",
               n_txn, n_mem_rd, n_mem_wr, n_reg_rd, n_reg_wr, n_words_rd, n_words_wr, n_lat2x,
               n_refresh, n_ignored, n_dpd, n_hs, n_rst, info_uninit, errors);
    end
  end

endmodule
/* verilator lint_on MULTIDRIVEN */
/* verilator lint_on BLKSEQ */
