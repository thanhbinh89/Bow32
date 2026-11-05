// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// DRAM pin model for the Verilator (--timing) and xsim testbenches: the JEDEC
// device core bow_ddr_dev (Sparse storage, full capacity) behind a pin
// adapter that works on the DRAM-side split pins of ddr_board_model.
//
// Pins: the inputs are the values at the DRAM balls (dq_i / dqs_*_i include
// the model's own drive), dq_drv_i / dqs_drv_i = the controller side drives
// that lane's DQ (and DM) / DQS at the balls (shifter A port on, or the FPGA
// in a direct board). Outputs: what the DRAM drives (dq_o / dq_oe_o, dqs_*_o /
// dqs_oe_o). DQS_N is not checked (DQS_P edges are the strobes).
//
// Core clock: one pulse per CK_P rising edge, CoreDlyPs after it (the
// command pins are sampled exactly at the CK edge); core cycle = CK edge
// index (0 = first CK edge), the same numbers as err_cycle of bow_ddr_dev and
// the logs.
//
// Pin checks (ps, all against the nominal TckPs; each violation counts like a
// device error, codes 0x50.. in the bow_ddr_dev table):
//   0x50/0x51 tIS / tIH of CKE, ODT, CS#, RAS#, CAS#, WE#, BA, A at the CK
//             rising edges while CKE is high (at that edge or the one before;
//             with CKE low the inputs are ignored, e.g. the runt CK pulse when
//             the level shifters turn on); RESET# is asynchronous: not checked
//   writes (pairs the core expects): 0x52 first DQS rising edge of a pair
//             within CK +- tDQSS (0.25 tCK); 0x53 / 0x54 DQS falling edge setup
//             to the next CK / hold from its CK >= 0.2 tCK (tDSS / tDSH); 0x55 /
//             0x56 DQ and DM setup / hold to the capturing DQS edge >= tDS /
//             tDH; 0x57 preamble (DQS driven low before the first rising edge
//             of a burst that does not continue the previous one) >= tWPRE
//             (0.35 tCK DDR2, 0.9 tCK DDR3); 0x58 postamble (DQS low after the
//             last falling edge, until it rises or is released, max 2 tCK) >=
//             tWPST (0.4 / 0.3 tCK); 0x59 DQS high / low pulses >= 0.35 tCK;
//             0x5A DQ / DQS not driven at a capturing edge
//   0x5B      CK period != TckPs (+-1 %, checked while CKE is high), or TckPs
//             outside the mode: DDR2 and
//             DDR3 DLL off need tCK <= 8 ns / >= 8 ns, DDR3 DLL on <= 3.3 ns
//   0x5C      DDR3: CK not running max(5 tCK, 10 ns) before CKE goes high
// Write beats: the pair of CK edge k is the first DQS rising edge within
// [t_k - tCK/2, t_k + tCK/2) and the next falling edge, sampled at the edges;
// the core gets it (wr_v = both edges seen on every lane) at edge k+1.
// wr_relax_i = 1 (write-phase sweep of the calibration, spec 12 step 7: the
// controller moves DQS / DQ out of the JEDEC window on purpose): the write
// timing checks (0x52 .. 0x5A) count no error; a pair that violates one of
// them is stored inverted (the device behaviour is unspecified there, so the
// sweep sees the failure) and its burst is logged with the word "relax".
// A burst whose postamble is cut by a CK stop (a controller reset in the
// middle of traffic) is logged with "relax" too, without a tWPST check.
// Reads: the core's beats of edge e are driven from t_e + tDQSCK (DQS
// preamble one cycle before the first data edge, postamble = the low half of
// the last data cycle, then released). tDQSCK: DLL on (DDR2 / DDR3) in
// [TDqsckMinPs, TDqsckMaxPs], DDR3 DLL off in [TDqsckOffMinPs,
// TDqsckOffMaxPs], drawn once per run (Seed / +ddr_mem_seed=<n>), or fixed
// with +ddr_tdqsck_ps=<n>. The DLL mode is taken from the MRS commands.
//
// Logs (CmdLog / DqLog, or +ddr_cmd_log=<file> / +ddr_dq_log=<file>; empty =
// none). "edge" = index of the CK rising edge at the DRAM pins (0 = first),
// t_ps = its time; all times integer ps.
//   cmd.txt  "# tck_ps <TckPs> ddr3 <0|1> dq <8|16> banks <4|8>", then one line
//            per event "<edge> <t_ps> <KIND> ...": "CKE <0|1>", "RST <0|1>"
//            (DDR3), "ODT <0|1>" (at edge 0 and when the sampled level
//            changes), or a command "MRS|REF|PRE|ACT|WR|RD|ZQ <ba> <a 4 hex>"
//            (registered: CKE high at this and the previous edge; NOP / DES
//            not logged).
//   dq.txt   one line per burst, written when it is complete:
//            "W <WR edge> <tdqss> <wpre> <wpst> <tds_min> <tdh_min> <tdss_min>
//            <tdsh_min> <dm_hex> <data_hex>": tdqss = first DQS rising edge -
//            its CK edge (signed; x16: the lane with the largest |tdqss|);
//            wpre = DQS driven-low time before that edge (capped at 2 tCK;
//            a burst that continues the previous one: the 0.5 tCK gap, the
//            pre / postamble rules do not apply to it); wpst = DQS low time
//            after the last falling edge (capped at 2 tCK); tds / tdh = min DQ and DM setup /
//            hold to the capturing DQS edge over the 8 beats (and lanes); tdss
//            / tdsh = min DQS falling edge setup / hold to the CK rising edges;
//            dm_hex = 8 hex digits, one per beat, beat 0 first, bit l = DM of
//            lane l (1 = masked); data_hex = 8 beats, beat 0 first, DQ/4 hex
//            digits each, the data as
//            stored; a trailing word "relax" when wr_relax_i was set during
//            the burst (its timing values are not checked).
//            "R <RD edge> <tdqsck> <data_hex>": tdqsck = first read DQS rising
//            edge - its CK edge (the data edge: RD + RL, DDR3 DLL off RD + RL -
//            1).
// Status: dbg_o = {err_count != 0, init_done, 6'b0, err_code, err_count} (the
// layout of bow_ddr_lb, for ddr_dbg_i), err_* = device and pin errors merged
// (code / first of both by edge); pin_errors, pin_code, pin_edge and the core
// (u_dev) can be read hierarchically.

`timescale 1ps / 1ps

// behavioural model: blocking assignments in edge processes and event
// driven state are intended
/* verilator lint_off BLKSEQ */
/* verilator lint_off LATCH */
/* verilator lint_off SYNCASYNCNET */
module ddr_mem_model #(
  parameter bit          Ddr3           = 1'b0,
  parameter int unsigned DqBits         = 8,
  parameter int unsigned Lanes          = DqBits / 8,
  parameter int unsigned BankBits       = 2,
  parameter int unsigned RowBits        = 14,
  parameter int unsigned ColBits        = 10,
  parameter int unsigned AddrPins       = 14,
  parameter int unsigned BankPins       = 2,
  parameter int unsigned TckPs          = 7500,
  parameter bit          CheckInit      = 1'b1,
  parameter bit          FatalOnError   = 1'b0,
  parameter bit          RdqsTied       = 1'b1,
  parameter int unsigned Seed           = 1,
  parameter int unsigned CoreDlyPs      = 10,
  // JEDEC device timing (ps; converted with TckPs, nCK floors applied below).
  // Defaults: DDR2 = IS43DR86400E-25DBL (DDR2-800, 512Mb x8, 4 banks), DDR3 =
  // 1Gb x16 DDR3-800 (8 banks, 2KB page) in DLL-off mode.
  parameter int unsigned TRcdPs         = Ddr3 ? 13_750 : 12_500,
  parameter int unsigned TRpPs          = Ddr3 ? 13_750 : 12_500,
  parameter int unsigned TRasPs         = Ddr3 ? 35_000 : 45_000,
  parameter int unsigned TRcPs          = Ddr3 ? 48_750 : 57_500,
  parameter int unsigned TRrdPs         = Ddr3 ? 10_000 : 7_500,
  parameter int unsigned TFawPs         = Ddr3 ? 50_000 : 0,
  parameter int unsigned TWrPs          = 15_000,
  parameter int unsigned TRtpPs         = 7_500,
  parameter int unsigned TWtrPs         = 7_500,
  parameter int unsigned TRfcPs         = Ddr3 ? 110_000 : 105_000,
  parameter int unsigned TRefiPs        = 7_800_000,
  parameter int unsigned TRasMaxPs      = Ddr3 ? 70_200_000 : 70_000_000,
  parameter int unsigned TInitPs        = 200_000_000,   // DDR2 CKE low with clock
  parameter int unsigned TResetPs       = 200_000_000,   // DDR3 RESET# low
  parameter int unsigned TCkeLowPs      = 500_000_000,   // DDR3 RESET# high -> CKE high
  // pin timing (ps)
  parameter int unsigned TIsPs          = 200,
  parameter int unsigned TIhPs          = 275,
  parameter int unsigned TDsPs          = 100,
  parameter int unsigned TDhPs          = 175,
  parameter int          TDqsckMinPs    = -400,
  parameter int          TDqsckMaxPs    = 400,
  parameter int          TDqsckOffMinPs = 1_000,
  parameter int          TDqsckOffMaxPs = 10_000,
  parameter string       CmdLog         = "",
  parameter string       DqLog          = ""
) (
  input  logic                ck_p_i,
  input  logic                ck_n_i,
  input  logic                cke_i,
  input  logic                rst_n_i,
  input  logic                odt_i,
  input  logic                cs_n_i,
  input  logic                ras_n_i,
  input  logic                cas_n_i,
  input  logic                we_n_i,
  input  logic [BankPins-1:0] ba_i,
  input  logic [AddrPins-1:0] a_i,
  input  logic [DqBits-1:0]   dq_i,
  input  logic [Lanes-1:0]    dq_drv_i,
  output logic [DqBits-1:0]   dq_o,
  output logic                dq_oe_o,
  input  logic [Lanes-1:0]    dqs_p_i,
  input  logic [Lanes-1:0]    dqs_n_i,
  input  logic [Lanes-1:0]    dqs_drv_i,
  output logic [Lanes-1:0]    dqs_p_o,
  output logic [Lanes-1:0]    dqs_n_o,
  output logic [Lanes-1:0]    dqs_oe_o,
  input  logic [Lanes-1:0]    dm_i,
  input  logic                wr_relax_i,     // write timing outside JEDEC on purpose (see above)
  output logic [31:0]         dbg_o,
  output logic [7:0]          err_code_o,
  output logic [15:0]         err_count_o,
  output logic                init_done_o
);

  // ------------------------------------------------- JEDEC values in cycles
  function automatic int unsigned ceil_ck(int unsigned ps);
    return (ps + TckPs - 1) / TckPs;
  endfunction
  function automatic int unsigned max2(int unsigned a, int unsigned b);
    return (a > b) ? a : b;
  endfunction

  localparam int unsigned CRcd    = ceil_ck(TRcdPs);
  localparam int unsigned CRp     = ceil_ck(TRpPs);
  localparam int unsigned CRpa    = CRp + ((!Ddr3 && BankBits == 3) ? 1 : 0);
  localparam int unsigned CRas    = ceil_ck(TRasPs);
  localparam int unsigned CRc     = ceil_ck(TRcPs);
  localparam int unsigned CRrd    = Ddr3 ? max2(4, ceil_ck(TRrdPs)) : ceil_ck(TRrdPs);
  localparam int unsigned CFaw    = ceil_ck(TFawPs);
  localparam int unsigned CWr     = Ddr3 ? max2(5, ceil_ck(TWrPs)) : ceil_ck(TWrPs);
  localparam int unsigned CRtp    = Ddr3 ? max2(4, ceil_ck(TRtpPs)) : ceil_ck(TRtpPs);
  localparam int unsigned CWtr    = Ddr3 ? max2(4, ceil_ck(TWtrPs)) : ceil_ck(TWtrPs);
  localparam int unsigned CRfc    = ceil_ck(TRfcPs);
  localparam int unsigned CRefi   = TRefiPs / TckPs;
  localparam int unsigned CMrd    = Ddr3 ? 4 : 2;
  localparam int unsigned CMod    = max2(12, ceil_ck(15_000));
  localparam int unsigned CXpr    = max2(5, ceil_ck(TRfcPs + 10_000));
  localparam int unsigned CInit   = ceil_ck(TInitPs);
  localparam int unsigned CInitNop = ceil_ck(400_000);
  localparam int unsigned CReset  = ceil_ck(TResetPs);
  localparam int unsigned CCkeLow = ceil_ck(TCkeLowPs);
  localparam int unsigned CCkeRst = ceil_ck(10_000);
  localparam int unsigned CCkRun  = max2(5, ceil_ck(10_000));
  localparam int unsigned CRasMax = TRasMaxPs / TckPs;

  localparam longint T      = longint'(TckPs);
  localparam longint Big    = 64'd1 << 40;
  localparam longint TolPs  = (T / 100 > 2) ? T / 100 : 2;

  // ------------------------------------------------------------- the core
  logic                   core_clk = 1'b0, core_rst_n = 1'b0;
  logic                   c_cke = 1'b0, c_rst_n = 1'b0, c_odt = 1'b0;
  logic                   c_cs_n = 1'b1, c_ras_n = 1'b1, c_cas_n = 1'b1, c_we_n = 1'b1;
  logic [2:0]             c_ba = '0;
  logic [15:0]            c_a = '0;
  logic [1:0][DqBits-1:0] c_wr_dq = '0;
  logic [1:0][Lanes-1:0]  c_wr_dm = '0;
  logic                   c_wr_v = 1'b0;
  logic                   d_wr_expect, d_rd_oe, d_rd_pre, d_init_done;
  logic [1:0][DqBits-1:0] d_rd_dq;
  logic [7:0]             d_err_code;
  logic [15:0]            d_err_count;
  logic [31:0]            d_err_cycle;

  initial #1 core_rst_n = 1'b1;

  bow_ddr_dev #(
    .Ddr3(Ddr3), .DqBits(DqBits), .BankBits(BankBits), .RowBits(RowBits), .ColBits(ColBits),
    .MemBytes(4096), .UseUram(1'b0), .Sparse(1'b1), .CheckInit(CheckInit),
    .FatalOnError(FatalOnError), .RdqsTied(RdqsTied), .Lookahead(1'b0),
    .TRcd(CRcd), .TRp(CRp), .TRpa(CRpa), .TRas(CRas), .TRc(CRc), .TRrd(CRrd), .TFaw(CFaw),
    .TWr(CWr), .TRtp(CRtp), .TWtr(CWtr), .TRfc(CRfc), .TRefi(CRefi), .TMrd(CMrd), .TMod(CMod),
    .TXpr(CXpr), .TInit(CInit), .TInitNop(CInitNop), .TReset(CReset), .TCkeLow(CCkeLow),
    .TCkeRst(CCkeRst), .TCkRun(CCkRun), .TRasMax(CRasMax)
  ) u_dev (
    .clk_i(core_clk), .rst_ni(core_rst_n), .ck_en_i(1'b1),
    .cke_i(c_cke), .reset_n_i(c_rst_n), .odt_i(c_odt), .cs_n_i(c_cs_n), .ras_n_i(c_ras_n),
    .cas_n_i(c_cas_n), .we_n_i(c_we_n), .ba_i(c_ba), .a_i(c_a),
    .la_cs_n_i(1'b1), .la_ras_n_i(1'b1), .la_cas_n_i(1'b1), .la_we_n_i(1'b1), .la_ba_i(3'd0),
    .la_a_i(16'd0),
    .wr_dq_i(c_wr_dq), .wr_dm_i(c_wr_dm), .wr_v_i(c_wr_v),
    .wr_expect_o(d_wr_expect), .rd_dq_o(d_rd_dq), .rd_oe_o(d_rd_oe), .rd_pre_o(d_rd_pre),
    .err_code_o(d_err_code), .err_count_o(d_err_count), .err_cycle_o(d_err_cycle),
    .init_done_o(d_init_done)
  );

  // ------------------------------------------------------------ pin errors
  int unsigned pin_errors = 0;
  logic [7:0]  pin_code = '0;
  int          pin_edge = 0;
  int          edge_n = -1;          // index of the last CK rising edge

  task automatic pin_err(logic [7:0] code, string msg);
    if (pin_errors == 0) begin
      pin_code = code;
      pin_edge = edge_n;
    end
    pin_errors++;
    if (FatalOnError) $fatal(1, "%m: edge %0d (%0t ps): [0x%02h] %s", edge_n, $time, code, msg);
    else              $error("%m: edge %0d (%0t ps): [0x%02h] %s", edge_n, $time, code, msg);
  endtask

  always_comb begin
    logic [31:0] n;
    n = 32'(d_err_count) + pin_errors;
    err_count_o = (n > 32'hFFFF) ? 16'hFFFF : n[15:0];
    if (pin_errors == 0)          err_code_o = d_err_code;
    else if (d_err_count == 16'd0) err_code_o = pin_code;
    else                          err_code_o = (d_err_cycle <= 32'(pin_edge)) ? d_err_code : pin_code;
    init_done_o = d_init_done;
    dbg_o = {err_count_o != 16'd0, init_done_o, 6'd0, err_code_o, err_count_o};
  end

  // ------------------------------------------------------------------ logs
  int fd_cmd = 0, fd_dq = 0;
  initial begin
    string fn;
    fn = CmdLog;
    void'($value$plusargs("ddr_cmd_log=%s", fn));
    if (fn != "") begin
      fd_cmd = $fopen(fn, "w");
      if (fd_cmd == 0) $fatal(1, "%m: cannot open %s", fn);
      $fdisplay(fd_cmd, "# tck_ps %0d ddr3 %0d dq %0d banks %0d", TckPs, Ddr3, DqBits,
                1 << BankBits);
    end
    fn = DqLog;
    void'($value$plusargs("ddr_dq_log=%s", fn));
    if (fn != "") begin
      fd_dq = $fopen(fn, "w");
      if (fd_dq == 0) $fatal(1, "%m: cannot open %s", fn);
    end
  end
  final begin
    if (fd_cmd != 0) $fclose(fd_cmd);
    if (fd_dq != 0) $fclose(fd_dq);
  end

  function automatic string beat_hex(logic [DqBits-1:0] v);
    return (DqBits == 16) ? $sformatf("%04h", v) : $sformatf("%02h", v[7:0]);
  endfunction

  // ------------------------------------------------- tDQSCK, DLL mode, tCK
  int  tdqsck_on, tdqsck_off;
  bit  dll_off = 1'b0, tck_bad = 1'b0;
  int unsigned rng = 1;
  function automatic int urange(int lo, int hi);
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return (hi <= lo) ? lo : lo + int'(rng % (hi - lo + 1));
  endfunction
  initial begin
    int unsigned sd;
    int          fixed;
    sd = Seed;
    void'($value$plusargs("ddr_mem_seed=%d", sd));
    rng = sd ^ 32'h5bd1_e995;
    if (rng == 0) rng = 1;
    for (int k = 0; k < 8; k++) void'(urange(0, 1));
    tdqsck_on  = urange(TDqsckMinPs, TDqsckMaxPs);
    tdqsck_off = urange(TDqsckOffMinPs, TDqsckOffMaxPs);
    if ($value$plusargs("ddr_tdqsck_ps=%d", fixed)) begin
      tdqsck_on  = fixed;
      tdqsck_off = fixed;
    end
    if (!Ddr3 && TckPs > 8000) begin
      tck_bad = 1'b1;
      pin_err(8'h5B, $sformatf("DDR2 with the DLL on needs tCK <= 8 ns (TckPs %0d)", TckPs));
    end
  end

  function automatic int tdqsck();
    return (Ddr3 && dll_off) ? tdqsck_off : tdqsck_on;
  endfunction

  // ============================================================ command pins
  logic s_cke = 1'b0, s_odt = 1'b0, s_rst = 1'b0;     // levels sampled at the last CK edge
  localparam int unsigned NCmdPins = 6 + BankPins + AddrPins;   // without RESET#
  logic   [NCmdPins-1:0] cpins, cpins_q = '0;
  longint t_chg [NCmdPins];
  longint t_edge = -Big, t_edge_prev = -Big;   // last / previous CK rising edge
  longint run_start = 0;
  assign cpins = {a_i, ba_i, we_n_i, cas_n_i, ras_n_i, cs_n_i, odt_i, cke_i};

  function automatic string pin_name(int k);
    if (k == 0) return "CKE";
    if (k == 1) return "ODT";
    if (k == 2) return "CS#";
    if (k == 3) return "RAS#";
    if (k == 4) return "CAS#";
    if (k == 5) return "WE#";
    if (k < 6 + int'(BankPins)) return $sformatf("BA%0d", k - 6);
    return $sformatf("A%0d", k - 6 - int'(BankPins));
  endfunction

  initial begin
    for (int k = 0; k < int'(NCmdPins); k++) t_chg[k] = -Big;
  end

  // hold: a pin changes less than tIH after a CK edge
  always @(cpins) begin
    logic [NCmdPins-1:0] chg;
    longint              now;
    now = $time;
    chg = cpins ^ cpins_q;
    cpins_q = cpins;
    for (int k = 0; k < int'(NCmdPins); k++) begin
      if (chg[k]) begin
        t_chg[k] = now;
        if (edge_n >= 0 && s_cke && now - t_edge < longint'(TIhPs)) begin
          pin_err(8'h51, $sformatf("tIH: %s changed %0d ps after CK (< %0d)", pin_name(k),
                                   now - t_edge, TIhPs));
        end
      end
    end
  end

  // ================================================================ DQS / DQ
  typedef struct {
    longint      t;
    int          lane;
    bit          rise;
    logic [7:0]  dq;
    logic        dm;
    longint      setup;     // min DQ / DM setup to this edge
    longint      hold;      // min hold of the bits that changed after it (Big: none yet)
    logic [8:0]  chg;       // bits that changed since this edge
    bit          drv_dq, drv_dqs, own;
  } dqs_ev_t;

  dqs_ev_t hist [$];
  longint  t_dq_chg [DqBits + Lanes];   // DQ bits, then DM per lane
  logic [DqBits-1:0] dq_q = '0;
  logic [Lanes-1:0]  dm_q = '0;
  longint  t_drv_on [Lanes];            // last time the controller started driving DQS
  longint  t_drv_off [Lanes];           // last time the controller released DQS
  logic [Lanes-1:0] dqs_q = '0;

  initial begin
    for (int k = 0; k < int'(DqBits + Lanes); k++) t_dq_chg[k] = -Big;
    for (int l = 0; l < int'(Lanes); l++) begin
      t_drv_on[l]  = -Big;
      t_drv_off[l] = -Big;
    end
  end

  function automatic int last_rec(int lane);
    for (int i = hist.size() - 1; i >= 0; i--) begin
      if (hist[i].lane == lane) return i;
    end
    return -1;
  endfunction

  // DQ / DM changes: setup reference and hold of the last DQS edge of the lane
  always @(dq_i or dm_i) begin
    longint now;
    int     l, r;
    logic [3:0] bit_i;
    now = $time;
    for (int k = 0; k < int'(DqBits + Lanes); k++) begin
      logic changed;
      if (k < int'(DqBits)) begin
        changed = dq_i[k] !== dq_q[k];
        l = k / 8;
        bit_i = 4'(k % 8);
      end else begin
        changed = dm_i[k - DqBits] !== dm_q[k - DqBits];
        l = k - int'(DqBits);
        bit_i = 4'd8;
      end
      if (changed) begin
        t_dq_chg[k] = now;
        r = last_rec(l);
        if (r >= 0) begin
          logic [8:0] c;
          c = hist[r].chg;            // (whole member: Verilator 5.022 miscompiles c[i] of a queue item)
          if (!c[bit_i]) begin
            c[bit_i]    = 1'b1;
            hist[r].chg = c;
            if (now - hist[r].t < hist[r].hold) hist[r].hold = now - hist[r].t;
          end
        end
      end
    end
    dq_q = dq_i;
    dm_q = dm_i;
  end

  for (genvar gl = 0; gl < Lanes; gl++) begin : g_lane
    always @(posedge dqs_p_i[gl] or negedge dqs_p_i[gl]) begin
      dqs_ev_t e;
      longint  now;
      now = $time;
      if (dqs_p_i[gl] !== dqs_q[gl]) begin
        e.t       = now;
        e.lane    = gl;
        e.rise    = (dqs_p_i[gl] == 1'b1);
        e.dq      = dq_i[8 * gl +: 8];
        e.dm      = dm_i[gl];
        e.setup   = Big;
        for (int b = 0; b < 8; b++) begin
          if (now - t_dq_chg[8 * gl + b] < e.setup) e.setup = now - t_dq_chg[8 * gl + b];
        end
        if (now - t_dq_chg[DqBits + gl] < e.setup) e.setup = now - t_dq_chg[DqBits + gl];
        e.hold    = Big;
        e.chg     = '0;
        e.drv_dq  = dq_drv_i[gl];
        e.drv_dqs = dqs_drv_i[gl];
        e.own     = dqs_oe_o[gl];
        hist.push_back(e);
      end
      dqs_q[gl] = dqs_p_i[gl];
    end
    always @(posedge dqs_drv_i[gl]) t_drv_on[gl]  = $time;
    always @(negedge dqs_drv_i[gl]) t_drv_off[gl] = $time;
  end

  // DQS driven-low time before t on lane l: since the later of its last
  // falling edge and the start of the controller's drive
  function automatic longint t_low_at(int l, longint t);
    longint pf, on;
    pf = -Big;
    foreach (hist[i]) if (hist[i].lane == l && !hist[i].rise && hist[i].t < t && hist[i].t > pf) pf = hist[i].t;
    on = t_drv_on[l];
    if (on > t) on = -Big;
    return t - ((pf > on) ? pf : on);
  endfunction

  // ------------------------------------------------------ write bursts
  bit          wexp = 1'b0;                 // the core expects the pair of edge wexp_edge
  int          wexp_edge = -1;
  int          wr_cmd_q [$];                // WR command edges, in order
  int          rd_cmd_q [$];
  // burst being assembled
  int          wb_pairs = 0, wb_edge = 0;
  bit          wb_seam = 1'b0, wb_relax = 1'b0;
  bit          pair_bad = 1'b0;             // the pair being checked violates a write limit
  bit          ck_gap = 1'b0;               // CK stopped before the current edge
  longint      wb_tdqss, wb_wpre, wb_tds, wb_tdh, wb_tdss, wb_tdsh;
  logic [8*DqBits-1:0] wb_data;
  logic [8*Lanes-1:0]  wb_dm;               // [beat * Lanes + lane]
  int          last_pair_edge = -10;        // last edge with an expected pair
  // burst waiting for its postamble
  bit          pw_wait = 1'b0, pw_relax = 1'b0;
  int          pw_edge;
  longint      pw_tdqss, pw_wpre, pw_tds, pw_tdh, pw_tdss, pw_tdsh;
  logic [8*DqBits-1:0] pw_data;
  logic [8*Lanes-1:0]  pw_dm;
  longint      pw_tf [Lanes];

  // a write timing violation: an error, or with wr_relax_i only a bad pair
  task automatic wr_err(logic [7:0] code, string msg);
    pair_bad = 1'b1;
    if (!wr_relax_i) pin_err(code, msg);
  endtask

  // the postamble of the waiting burst: DQS low after its last falling edge
  // until DQS rises or is released, at most 2 tCK
  task automatic resolve_wpst(longint now);
    longint wpst, v;
    string  dm_s, d_s;
    if (!pw_wait) return;
    wpst = 2 * T;
    for (int l = 0; l < int'(Lanes); l++) begin
      v = Big;
      foreach (hist[i]) begin
        if (hist[i].lane == l && hist[i].rise && hist[i].t > pw_tf[l] && hist[i].t - pw_tf[l] < v) begin
          v = hist[i].t - pw_tf[l];
        end
      end
      if (t_drv_off[l] > pw_tf[l] && t_drv_off[l] - pw_tf[l] < v) v = t_drv_off[l] - pw_tf[l];
      if (v == Big && now - pw_tf[l] < 2 * T) return;       // not known yet
      if (v < wpst) wpst = v;
    end
    pw_wait = 1'b0;
    if (wpst < (Ddr3 ? (3 * T + 9) / 10 : (4 * T + 9) / 10) && !pw_relax) begin
      pin_err(8'h58, $sformatf("tWPST: write postamble %0d ps (WR edge %0d)", wpst, pw_edge));
    end
    if (fd_dq != 0) begin
      dm_s = "";
      for (int b = 0; b < 8; b++) dm_s = {dm_s, $sformatf("%1h", 4'(pw_dm[b * Lanes +: Lanes]))};
      d_s  = "";
      for (int b = 0; b < 8; b++) d_s = {d_s, beat_hex(pw_data[DqBits * b +: DqBits])};
      $fdisplay(fd_dq, "W %0d %0d %0d %0d %0d %0d %0d %0d %s %s%s", pw_edge, pw_tdqss,
                (pw_wpre > 2 * T) ? 2 * T : pw_wpre, wpst,
                pw_tds, pw_tdh, pw_tdss, pw_tdsh, dm_s, d_s, pw_relax ? " relax" : "");
    end
  endtask

  // pair of edge k (time tk), evaluated at edge k+1 (time tk1): core inputs,
  // and the checks / burst record when the core expects it
  task automatic eval_pair(int k, longint tk, longint tk1);
    int     ri [Lanes], fi [Lanes];
    bit     ok;
    longint tdqss, worst, v;
    ok = 1'b1;
    for (int l = 0; l < int'(Lanes); l++) begin
      ri[l] = -1;
      fi[l] = -1;
      for (int i = 0; i < hist.size(); i++) begin
        if (hist[i].lane == l && !hist[i].own) begin
          if (ri[l] < 0 && hist[i].rise && hist[i].t >= tk - T / 2 && hist[i].t < tk + T / 2) ri[l] = i;
          else if (ri[l] >= 0 && fi[l] < 0 && !hist[i].rise && hist[i].t < hist[ri[l]].t + T) fi[l] = i;
        end
      end
      if (ri[l] < 0 || fi[l] < 0) ok = 1'b0;
    end
    c_wr_v  = ok;
    c_wr_dq = '0;
    c_wr_dm = '0;
    if (ok) begin
      for (int l = 0; l < int'(Lanes); l++) begin
        c_wr_dq[0][8 * l +: 8] = hist[ri[l]].dq;
        c_wr_dq[1][8 * l +: 8] = hist[fi[l]].dq;
        c_wr_dm[0][l]          = hist[ri[l]].dm;
        c_wr_dm[1][l]          = hist[fi[l]].dm;
      end
    end
    if (!(wexp && wexp_edge == k)) return;
    // ------------------------------------------- an expected pair
    if (wb_pairs == 0) begin
      wb_seam  = (last_pair_edge == k - 1);
      wb_edge  = (wr_cmd_q.size() != 0) ? wr_cmd_q.pop_front() : -1;
      wb_tdqss = 0;
      wb_wpre  = Big;
      wb_tds   = Big;
      wb_tdh   = Big;
      wb_tdss  = Big;
      wb_tdsh  = Big;
      wb_data  = '0;
      wb_dm    = '0;
      wb_relax = 1'b0;
    end
    wb_relax |= wr_relax_i;
    pair_bad  = 1'b0;
    last_pair_edge = k;
    if (!ok) begin
      wb_pairs++;
      if (wb_pairs == 4) wb_pairs = 0;
      return;                                   // the core reports the missing strobes
    end
    worst = 0;
    for (int l = 0; l < int'(Lanes); l++) begin
      dqs_ev_t r, f;
      r = hist[ri[l]];
      f = hist[fi[l]];
      tdqss = r.t - tk;
      if ((tdqss < 0 ? -tdqss : tdqss) >= (worst < 0 ? -worst : worst)) worst = tdqss;
      if ((tdqss < 0 ? -tdqss : tdqss) > T / 4) begin
        wr_err(8'h52, $sformatf("tDQSS: lane %0d DQS rising edge %0d ps from CK edge %0d", l, tdqss, k));
      end
      if (f.t - tk < wb_tdsh) wb_tdsh = f.t - tk;
      if (tk1 - f.t < wb_tdss) wb_tdss = tk1 - f.t;
      if (f.t - tk < (2 * T) / 10) wr_err(8'h54, $sformatf("tDSH: lane %0d DQS fall %0d ps after CK", l, f.t - tk));
      if (tk1 - f.t < (2 * T) / 10) wr_err(8'h53, $sformatf("tDSS: lane %0d DQS fall %0d ps before CK", l, tk1 - f.t));
      // DQ / DM setup and hold at both edges (unresolved hold: at least until now)
      for (int s = 0; s < 2; s++) begin
        dqs_ev_t x;
        x = (s != 0) ? f : r;
        v = x.hold;
        if (x.chg != 9'h1FF && tk1 - x.t < v) v = tk1 - x.t;
        if (x.setup < wb_tds) wb_tds = x.setup;
        if (v < wb_tdh) wb_tdh = v;
        if (x.setup < longint'(TDsPs)) begin
          wr_err(8'h55, $sformatf("tDS: lane %0d %s beat setup %0d ps (edge %0d)", l, (s != 0) ? "fall" : "rise",
                                   x.setup, k));
        end
        if (v < longint'(TDhPs)) begin
          wr_err(8'h56, $sformatf("tDH: lane %0d %s beat hold %0d ps (edge %0d)", l, (s != 0) ? "fall" : "rise", v, k));
        end
        if (!x.drv_dq || !x.drv_dqs) begin
          wr_err(8'h5A, $sformatf("lane %0d: DQ / DQS not driven at the capturing DQS edge (edge %0d)", l, k));
        end
      end
      // DQS pulse widths
      if (f.t - r.t < (35 * T) / 100) wr_err(8'h59, $sformatf("tDQSH: lane %0d %0d ps", l, f.t - r.t));
      if (wb_pairs != 0 || wb_seam) begin
        longint pf;
        pf = -Big;
        foreach (hist[i]) if (hist[i].lane == l && !hist[i].rise && hist[i].t < r.t && hist[i].t > pf) pf = hist[i].t;
        if (r.t - pf < (35 * T) / 100) wr_err(8'h59, $sformatf("tDQSL: lane %0d %0d ps", l, r.t - pf));
      end
      // preamble (first pair of a burst that does not continue the previous one)
      if (wb_pairs == 0) begin
        if (wb_seam) begin
          longint pf;
          pf = -Big;
          foreach (hist[i]) if (hist[i].lane == l && !hist[i].rise && hist[i].t < r.t && hist[i].t > pf) pf = hist[i].t;
          v = r.t - pf;
        end else begin
          v = t_low_at(l, r.t);
        end
        if (v < wb_wpre) wb_wpre = v;
        if (!wb_seam && v < (Ddr3 ? (9 * T + 9) / 10 : (35 * T + 99) / 100)) begin
          wr_err(8'h57, $sformatf("tWPRE: lane %0d write preamble %0d ps (WR edge %0d)", l, v, wb_edge));
        end
      end
      for (int b = 0; b < 2; b++) begin
        wb_data[DqBits * (2 * wb_pairs + b) + 8 * l +: 8] = (b != 0) ? f.dq : r.dq;
        wb_dm[(2 * wb_pairs + b) * Lanes + l]             = (b != 0) ? f.dm : r.dm;
      end
      pw_tf[l] = f.t;
    end
    if (pair_bad && wr_relax_i) begin           // relaxed: the device stores garbage
      c_wr_dq = ~c_wr_dq;
      for (int b = 0; b < 2; b++) begin
        wb_data[DqBits * (2 * wb_pairs + b) +: DqBits] = c_wr_dq[b];
      end
    end
    if (wb_pairs == 0) wb_tdqss = worst;
    else if ((worst < 0 ? -worst : worst) > (wb_tdqss < 0 ? -wb_tdqss : wb_tdqss)) wb_tdqss = worst;
    wb_pairs++;
    if (wb_pairs == 4) begin
      resolve_wpst(tk1 + 4 * T);                // a previous one, if still open
      pw_wait  = 1'b1;
      pw_edge  = wb_edge;
      pw_tdqss = wb_tdqss;
      pw_wpre  = wb_wpre;
      pw_tds   = wb_tds;
      pw_tdh   = wb_tdh;
      pw_tdss  = wb_tdss;
      pw_tdsh  = wb_tdsh;
      pw_data  = wb_data;
      pw_dm    = wb_dm;
      pw_relax = wb_relax || ck_gap;
      wb_pairs = 0;
    end
  endtask


  // ================================================================ CK edges
  logic l_cke = 1'b0, l_odt = 1'b0, l_rst = 1'b0;     // last logged levels
  bit   ck_reported = 1'b0;

  always @(posedge ck_p_i) begin
    longint now, per;
    logic   p_cke;
    string  op;
    now = $time;
    edge_n++;
    // ---------------------------------------- period
    per    = now - t_edge;
    ck_gap = edge_n == 0 || per > (3 * T) / 2;
    if (ck_gap) begin
      run_start = now;
      // CK stopped during a write postamble: a controller reset (the shifters
      // isolate, the PHY stops driving); that burst is not timing checked
      // (nor the one completed at this edge, see eval_pair)
      if (pw_wait) pw_relax = 1'b1;
    end else if (s_cke && (per > T + TolPs || per < T - TolPs) && !ck_reported) begin
      ck_reported = 1'b1;
      pin_err(8'h5B, $sformatf("CK period %0d ps, TckPs %0d", per, TckPs));
    end
    // ---------------------------------------- setup
    begin
      longint worst;
      int     wk;
      worst = Big;
      wk    = 0;
      for (int k = 0; k < int'(NCmdPins); k++) begin
        if (now - t_chg[k] < worst) begin
          worst = now - t_chg[k];
          wk    = k;
        end
      end
      if (worst < longint'(TIsPs) && (cke_i || s_cke)) begin
        pin_err(8'h50, $sformatf("tIS: %s changed %0d ps before CK (< %0d)", pin_name(wk), worst, TIsPs));
      end
    end
    // ---------------------------------------- sample, log
    p_cke = s_cke;
    s_cke = cke_i;
    s_odt = odt_i;
    s_rst = rst_n_i;
    if (Ddr3 && s_cke && !p_cke && edge_n > 0 && now - run_start < ((5 * T > 10_000) ? 5 * T : 10_000)) begin
      pin_err(8'h5C, $sformatf("CK running %0d ps before CKE high", now - run_start));
    end
    if (fd_cmd != 0) begin
      if (edge_n == 0 || s_cke != l_cke) $fdisplay(fd_cmd, "%0d %0d CKE %0d", edge_n, now, s_cke);
      if (Ddr3 && (edge_n == 0 || s_rst != l_rst)) $fdisplay(fd_cmd, "%0d %0d RST %0d", edge_n, now, s_rst);
      if (edge_n == 0 || s_odt != l_odt) $fdisplay(fd_cmd, "%0d %0d ODT %0d", edge_n, now, s_odt);
    end
    l_cke = s_cke;
    l_odt = s_odt;
    l_rst = s_rst;
    op = "";
    if (s_cke && p_cke && !cs_n_i) begin
      unique case ({ras_n_i, cas_n_i, we_n_i})
        3'b000:  op = "MRS";
        3'b001:  op = "REF";
        3'b010:  op = "PRE";
        3'b011:  op = "ACT";
        3'b100:  op = "WR";
        3'b101:  op = "RD";
        3'b110:  op = "ZQ";
        default: op = "";
      endcase
    end
    if (op != "") begin
      if (fd_cmd != 0) begin
        $fdisplay(fd_cmd, "%0d %0d %s %0d %04h", edge_n, now, op, ba_i, 16'(a_i));
      end
      if (op == "WR") wr_cmd_q.push_back(edge_n);
      if (op == "RD") rd_cmd_q.push_back(edge_n);
      if (op == "MRS" && Ddr3 && 32'(ba_i) == 1) begin
        dll_off = a_i[0];
        if (!tck_bad && (dll_off ? TckPs < 8000 : TckPs > 3300)) begin
          tck_bad = 1'b1;
          pin_err(8'h5B, $sformatf("DDR3 DLL %s with tCK %0d ps", dll_off ? "off needs tCK >= 8 ns" :
                                   "on needs tCK <= 3.3 ns", TckPs));
        end
      end
    end
    // ---------------------------------------- write pair of the previous edge
    if (edge_n > 0) eval_pair(edge_n - 1, t_edge, now);
    resolve_wpst(now);
    while (hist.size() > 64 || (hist.size() != 0 && hist[0].t < now - 4 * T)) void'(hist.pop_front());
    // ---------------------------------------- core
    c_cke   = s_cke;
    c_odt   = s_odt;
    c_rst_n = Ddr3 ? s_rst : 1'b1;
    c_cs_n  = cs_n_i;
    c_ras_n = ras_n_i;
    c_cas_n = cas_n_i;
    c_we_n  = we_n_i;
    c_ba    = 3'(ba_i);
    c_a     = 16'(a_i);
    core_clk <= #(CoreDlyPs) 1'b1;
    core_clk <= #(CoreDlyPs + TckPs / 4) 1'b0;
    t_edge_prev = t_edge;
    t_edge      = now;
  end

  // ============================================================ read drive
  typedef enum int {APre, ARise, AFall, ARel} act_e;
  typedef struct {
    longint            t;
    act_e              kind;
    int                edge_;
    logic [DqBits-1:0] dq;
  } act_t;
  act_t act_q [$];
  event act_ev;
  int   drive_edge = -1;                        // last edge scheduled to drive
  int   rpairs = 0, rburst_edge = -1, rburst_tdqsck = 0;
  logic [8*DqBits-1:0] rdata;

  // a device reset (DDR3 RESET# low, DDR2 CKE-low reset: u_dev.dev_clr)
  // drops the bursts in flight: forget their commands (the labels of the
  // dq.txt records) and the half assembled bursts
  always @(posedge core_clk) begin
    if (u_dev.dev_clr) begin
      wr_cmd_q.delete();
      rd_cmd_q.delete();
      wb_pairs = 0;
      rpairs   = 0;
    end
  end

  // outputs of core cycle edge_n: wr_expect (this edge), read beats (next edge)
  always @(negedge core_clk) begin
    longint te, tq;
    wexp      = d_wr_expect;
    wexp_edge = edge_n;
    te = t_edge + (((t_edge - t_edge_prev) > (3 * T) / 2 || edge_n == 0) ? T : (t_edge - t_edge_prev));
    tq = longint'(tdqsck());
    if (d_rd_oe || d_rd_pre) begin
      act_t a;
      drive_edge = edge_n + 1;
      a.edge_ = edge_n + 1;
      a.dq    = '0;
      if (d_rd_pre) begin
        a.t    = te + tq;
        a.kind = APre;
        act_q.push_back(a);
      end else begin
        a.t    = te + tq;
        a.kind = ARise;
        a.dq   = d_rd_dq[0];
        act_q.push_back(a);
        a.t    = te + tq + T / 2;
        a.kind = AFall;
        a.dq   = d_rd_dq[1];
        act_q.push_back(a);
        // read log
        if (rpairs == 0) begin
          rburst_edge   = (rd_cmd_q.size() != 0) ? rd_cmd_q.pop_front() : -1;
          rburst_tdqsck = int'(tq);
        end
        rdata[DqBits * 2 * rpairs +: DqBits]       = d_rd_dq[0];
        rdata[DqBits * (2 * rpairs + 1) +: DqBits] = d_rd_dq[1];
        rpairs++;
        if (rpairs == 4) begin
          rpairs = 0;
          if (fd_dq != 0) begin
            string d_s;
            d_s = "";
            for (int b = 0; b < 8; b++) d_s = {d_s, beat_hex(rdata[DqBits * b +: DqBits])};
            $fdisplay(fd_dq, "R %0d %0d %s", rburst_edge, rburst_tdqsck, d_s);
          end
        end
      end
      a.t    = te + tq + T;
      a.kind = ARel;
      act_q.push_back(a);
      -> act_ev;
    end
  end

  initial begin
    dq_o     = '0;
    dq_oe_o  = 1'b0;
    dqs_p_o  = '0;
    dqs_n_o  = '1;
    dqs_oe_o = '0;
    forever begin
      act_t   a;
      longint d;
      while (act_q.size() == 0) @(act_ev);
      d = act_q[0].t - $time;
      if (d > 0) #(d);
      while (act_q.size() != 0 && act_q[0].t <= $time) begin
        a = act_q.pop_front();
        unique case (a.kind)
          APre: begin
            dqs_oe_o = '1;
            dqs_p_o  = '0;
          end
          ARise: begin
            dqs_oe_o = '1;
            dqs_p_o  = '1;
            dq_oe_o  = 1'b1;
            dq_o     = a.dq;
          end
          AFall: begin
            dqs_p_o = '0;
            dq_o    = a.dq;
          end
          default: if (drive_edge == a.edge_) begin    // nothing after this edge
            dqs_oe_o = '0;
            dq_oe_o  = 1'b0;
          end
        endcase
      end
      dqs_n_o = ~dqs_p_o;
    end
  end

  // pins of no use to the model (DQS_N: DQS_P edges are the strobes)
  logic unused;
  assign unused = ^{ck_n_i, dqs_n_i};

endmodule
/* verilator lint_on SYNCASYNCNET */
/* verilator lint_on LATCH */
/* verilator lint_on BLKSEQ */
