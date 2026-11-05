// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Board model between the FPGA pins (bow_ddr_io_sim / bow_ddr_io_xilinx,
// split pins) and the DRAM pins (ddr_mem_model, split pins, "mem_" prefix):
// a direct board (LevelShift = 0) or the FMC+ card with TI TXV0108
// direction-controlled level shifters (LevelShift = 1). Verilator (--timing)
// and xsim. Port directions are seen from the board: dq_i = what the FPGA
// drives, dq_o = the value at the FPGA pin; mem_dq_i = what the DRAM drives,
// mem_dq_o = the value at the DRAM pin.
//
// Direct board: every signal is delayed by TraceFpgaPs + TraceMemPs in both
//   directions; a pin shows its own driver, else the far driver after the
//   trace, else it keeps its last value.
// TXV0108 card (spec 0 / 9):
//   * packages: command / address / CK channels in order CK_P, CK_N, CKE, ODT,
//     CS#, RAS#, CAS#, WE#, BA.., A.., RESET# (8 per package, DIR tied to
//     B -> A); per lane one DQ package (DIR = ls_dir_dq) and one DQS package
//     (DQS_P, DQS_N, DM; DIR = ls_dir_dqs). OE# (ls_oe_n) is common. A pin
//     at DIR = LsDirReadLevel means A -> B (DRAM -> FPGA, read).
//   * delays drawn per seed (Seed, or +ddr_board_seed=<n>): per package and
//     direction a tpd in [TpdMinPs, TpdMaxPs] with the packages of one
//     direction within TpdSpreadPs of each other (the card assumption of spec
//     4.3; TpdSpreadPs >= TpdMaxPs - TpdMinPs draws them independently), plus
//     a per channel skew in +-SkewPs; per package an enable and a disable time
//     in [TenMinPs, TenMaxPs] for OE# / DIR changes (break before make: the
//     new output port turns on after max(enable, disable) when the other port
//     was on). Traces: FPGA pin <-> B port TraceFpgaPs, A port <-> DRAM pin
//     TraceMemPs (DIR / OE# reach the shifters after TraceFpgaPs).
//   * or a board read from a file (+ddr_board_cfg=<cfg.txt>): its "# ls_pkg
//     <pkg> <pins..>" lines map the pins to packages, ls_tpd_<pkg> / ls_tpd_rd_<pkg> are the package tpd
//     FPGA -> DRAM / DRAM -> FPGA, ls_skew_<pin> the channel skew (both
//     directions), ls_ten_ps / ls_tdis_ps the enable / disable time of every
//     package; a channel without values keeps its own draw.
//   * with OE# high (or before the port is enabled) the DRAM side of the
//     command channels is pulled: CKE low, ODT low, CS# high, RESET# low; other
//     undriven lines keep their last value (no new edges).
//   * DmTied = 1 (the card: DM ball tied to GND): mem_dm_o = 0, no DM channel.
//   * mem_dq_drv_o / mem_dqs_drv_o (per lane): the controller side drives the
//     DRAM pin (shifter A port on, or the FPGA in a direct board), for the
//     write-capture checks of ddr_mem_model.
// Counters (integers, read them hierarchically; any count > 0 fails a test):
//   contention     a net with two drivers: FPGA and shifter B port, DRAM and
//                  shifter A port (direct: FPGA and DRAM), counted per
//                  package / lane group each time it starts; contention_ps =
//                  total time
//   floats         a shifter input port that is enabled but not driven by the
//                  FPGA (B side, DIR = write: IDLE_DRIVE = 0 behind the
//                  shifters, or OE_PRE / OE_POST too long) for longer than
//                  FloatGracePs (one count per float period). A-side floats
//                  around the DRAM's read bursts (DIR = read, DRAM not yet
//                  driving) are inherent to the card and only counted in
//                  floats_a (information).
// Every event is reported with $display when Verbose.

`timescale 1ps / 1ps

// behavioural model: blocking assignments in edge processes and lines that
// keep their last value (latches) are intended
/* verilator lint_off BLKSEQ */
/* verilator lint_off LATCH */
/* verilator lint_off SYNCASYNCNET */
/* verilator lint_off UNOPTFLAT */
module ddr_board_model #(
  parameter int unsigned DqBits         = 8,
  parameter int unsigned Lanes          = DqBits / 8,
  parameter int unsigned AddrPins       = 14,
  parameter int unsigned BankPins       = 2,
  parameter bit          LevelShift     = 1'b1,
  parameter bit          LsDirReadLevel = 1'b1,
  parameter bit          DmTied         = 1'b1,
  parameter int unsigned Seed           = 1,
  parameter int unsigned TraceFpgaPs    = 300,
  parameter int unsigned TraceMemPs     = 200,
  parameter int unsigned TpdMinPs       = 1600,
  parameter int unsigned TpdMaxPs       = 4800,
  parameter int unsigned TpdSpreadPs    = 600,
  parameter int unsigned SkewPs         = 450,
  parameter int unsigned TenMinPs       = 1200,
  parameter int unsigned TenMaxPs       = 7000,
  parameter int unsigned FloatGracePs   = 22500,
  parameter bit          Verbose        = 1'b1
) (
  // FPGA side
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
  input  logic                dq_oe_i,
  output logic [DqBits-1:0]   dq_o,
  input  logic [Lanes-1:0]    dqs_p_i,
  input  logic [Lanes-1:0]    dqs_n_i,
  input  logic [Lanes-1:0]    dqs_oe_i,
  output logic [Lanes-1:0]    dqs_p_o,
  output logic [Lanes-1:0]    dqs_n_o,
  input  logic [Lanes-1:0]    dm_i,
  input  logic                ls_oe_n_i,
  input  logic                ls_dir_dq_i,
  input  logic                ls_dir_dqs_i,
  // DRAM side
  output logic                mem_ck_p_o,
  output logic                mem_ck_n_o,
  output logic                mem_cke_o,
  output logic                mem_rst_n_o,
  output logic                mem_odt_o,
  output logic                mem_cs_n_o,
  output logic                mem_ras_n_o,
  output logic                mem_cas_n_o,
  output logic                mem_we_n_o,
  output logic [BankPins-1:0] mem_ba_o,
  output logic [AddrPins-1:0] mem_a_o,
  output logic [DqBits-1:0]   mem_dq_o,
  output logic [Lanes-1:0]    mem_dq_drv_o,
  input  logic [DqBits-1:0]   mem_dq_i,
  input  logic                mem_dq_oe_i,
  output logic [Lanes-1:0]    mem_dqs_p_o,
  output logic [Lanes-1:0]    mem_dqs_n_o,
  output logic [Lanes-1:0]    mem_dqs_drv_o,
  input  logic [Lanes-1:0]    mem_dqs_p_i,
  input  logic [Lanes-1:0]    mem_dqs_n_i,
  input  logic [Lanes-1:0]    mem_dqs_oe_i,
  output logic [Lanes-1:0]    mem_dm_o
);

  localparam int unsigned NCmd    = 9 + BankPins + AddrPins;
  localparam int unsigned NCmdPkg = (NCmd + 7) / 8;
  localparam int unsigned NPkg    = NCmdPkg + 2 * Lanes;   // cmd.., DQ lane l, DQS lane l
  // trace delays (never 0: Verilator --timing), float grace
  localparam real         TTot    = (TraceFpgaPs + TraceMemPs > 0) ? real'(TraceFpgaPs + TraceMemPs) : 1.0;
  localparam real         TF      = (TraceFpgaPs > 0) ? real'(TraceFpgaPs) : 1.0;
  localparam real         TM      = (TraceMemPs > 0) ? real'(TraceMemPs) : 1.0;
  localparam real         TG      = (FloatGracePs > 0) ? real'(FloatGracePs) : 1.0;

  // ----------------------------------------------------------- counters
  // (the shifter values exist in both variants: one set of names for the tb)
  /* verilator lint_off UNUSEDSIGNAL */
  int  contention = 0, floats = 0, floats_a = 0;
  real contention_ps = 0.0;

  // ----------------------------------------------------------- delays
  real tpd_ba [NPkg];          // B -> A (FPGA -> DRAM)
  real tpd_ab [NPkg];          // A -> B (DRAM -> FPGA)
  real t_en   [NPkg];
  real t_dis  [NPkg];
  real sk_cmd [NCmd];
  real sk_dq  [DqBits][2];     // [0] B -> A, [1] A -> B
  real sk_dqs [Lanes][2][2];   // [P/N][direction]
  real sk_dm  [Lanes];
  // the delays used by the channels (>= 1 ps; no function call in a delay)
  // (set at time 0, used from TraceFpgaPs / TraceMemPs on)
  real d_cmd  [NCmd];
  real d_dq   [DqBits][2];
  real d_dqs  [Lanes][2][2];
  real d_dm   [Lanes];
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

  initial begin
    int unsigned sd;
    real         base_ba, base_ab, span;
    sd = Seed;
    void'($value$plusargs("ddr_board_seed=%d", sd));
    rng = sd ^ 32'h9E37_79B9;
    if (rng == 0) rng = 1;
    for (int k = 0; k < 8; k++) void'(urand(0.0, 1.0));
    span = real'(TpdMaxPs) - real'(TpdMinPs);
    if (real'(TpdSpreadPs) < span) span = real'(TpdSpreadPs);
    base_ba = urand(real'(TpdMinPs), real'(TpdMaxPs) - span);
    base_ab = urand(real'(TpdMinPs), real'(TpdMaxPs) - span);
    for (int p = 0; p < int'(NPkg); p++) begin
      tpd_ba[p] = base_ba + urand(0.0, span);
      tpd_ab[p] = base_ab + urand(0.0, span);
      t_en[p]   = urand(real'(TenMinPs), real'(TenMaxPs));
      t_dis[p]  = urand(real'(TenMinPs), real'(TenMaxPs));
    end
    for (int k = 0; k < int'(NCmd); k++) sk_cmd[k] = urand(-real'(SkewPs), real'(SkewPs));
    for (int k = 0; k < int'(DqBits); k++) begin
      sk_dq[k][0] = urand(-real'(SkewPs), real'(SkewPs));
      sk_dq[k][1] = urand(-real'(SkewPs), real'(SkewPs));
    end
    for (int l = 0; l < int'(Lanes); l++) begin
      for (int k = 0; k < 2; k++) begin
        sk_dqs[l][k][0] = urand(-real'(SkewPs), real'(SkewPs));
        sk_dqs[l][k][1] = urand(-real'(SkewPs), real'(SkewPs));
      end
      sk_dm[l] = urand(-real'(SkewPs), real'(SkewPs));
    end
    for (int k = 0; k < int'(NCmd); k++) d_cmd[k] = dly(tpd_ba[k / 8] + sk_cmd[k]);
    for (int k = 0; k < int'(DqBits); k++) begin
      d_dq[k][0] = dly(tpd_ba[NCmdPkg + k / 8] + sk_dq[k][0]);
      d_dq[k][1] = dly(tpd_ab[NCmdPkg + k / 8] + sk_dq[k][1]);
    end
    for (int l = 0; l < int'(Lanes); l++) begin
      for (int k = 0; k < 2; k++) begin
        d_dqs[l][k][0] = dly(tpd_ba[NCmdPkg + Lanes + l] + sk_dqs[l][k][0]);
        d_dqs[l][k][1] = dly(tpd_ab[NCmdPkg + Lanes + l] + sk_dqs[l][k][1]);
      end
      d_dm[l] = dly(tpd_ba[NCmdPkg + Lanes + l] + sk_dm[l]);
    end
    for (int p = 0; p < int'(NPkg); p++) begin
      d_en[p]  = dly(t_en[p]);
      d_dis[p] = dly(t_dis[p]);
      d_bbm[p] = dly((t_en[p] > t_dis[p]) ? t_en[p] : t_dis[p]);
    end
    if (Verbose) begin
      if (!LevelShift) begin
        $display("%m: direct board, trace %0d ps", TraceFpgaPs + TraceMemPs);
      end else begin
        $display("%m: TXV0108 card, seed %0d, traces FPGA %0d ps / DRAM %0d ps", sd,
                 TraceFpgaPs, TraceMemPs);
        for (int p = 0; p < int'(NPkg); p++) begin
          $display("%m:   package %0d (%s): tpd B->A %0.0f ps, A->B %0.0f ps, enable %0.0f ps, disable %0.0f ps",
                   p, (p < int'(NCmdPkg)) ? "cmd" : (p < int'(NCmdPkg + Lanes)) ? "DQ" : "DQS",
                   tpd_ba[p], tpd_ab[p], t_en[p], t_dis[p]);
        end
      end
    end
  end

  // ------------------------------------------ board read from a cfg.txt file
  typedef string strq_t[$];
  function automatic strq_t words(string line);
    strq_t q;
    string w;
    q.delete();                           // (else kept from the last call: Verilator 5.022)
    w = "";
    for (int i = 0; i < line.len(); i++) begin
      if (line[i] == " " || line[i] == "\t" || line[i] == "\n" || line[i] == "\r") begin
        if (w != "") q.push_back(w);
        w = "";
      end else begin
        w = {w, line.substr(i, i)};
      end
    end
    if (w != "") q.push_back(w);
    return q;
  endfunction

  function automatic string cmd_pin(int k);       // name of command channel k (cfg.txt)
    if (k < 8) begin
      unique case (k)
        0: return "ck_p";
        1: return "ck_n";
        2: return "cke";
        3: return "odt";
        4: return "cs_n";
        5: return "ras_n";
        6: return "cas_n";
        default: return "we_n";
      endcase
    end
    if (k < 8 + int'(BankPins)) return $sformatf("ba%0d", k - 8);
    if (k < 8 + int'(BankPins + AddrPins)) return $sformatf("a%0d", k - 8 - int'(BankPins));
    return "rst_n";
  endfunction

  task automatic load_cfg(string fn);
    int    fd, nset;
    string line, key;
    strq_t w;
    string pkg_of [string];
    real   tpd [string], tpd_rd [string], skew [string];
    real   ten, tdis, v;
    bit    have_en;
    fd = $fopen(fn, "r");
    if (fd == 0) $fatal(1, "%m: cannot open %s", fn);
    have_en = 1'b0;
    ten     = 0.0;
    tdis    = 0.0;
    while (!$feof(fd)) begin
      string w0, w1, w2;
      line = "";
      void'($fgets(line, fd));
      w  = words(line);
      // (queue items copied first: Verilator 5.022 mishandles methods of queue items)
      w0 = (w.size() > 0) ? w[0] : "";
      w1 = (w.size() > 1) ? w[1] : "";
      w2 = (w.size() > 2) ? w[2] : "";
      if (w.size() >= 3 && w0 == "#" && w1 == "ls_pkg") begin
        for (int i = 3; i < w.size(); i++) begin
          string pin;
          pin         = w[i];
          pkg_of[pin] = w2;
        end
      end else if (w.size() == 2 && w0.len() > 3 && w0.substr(0, 2) == "ls_") begin
        key = w0;
        v   = real'(w1.atoi());
        if (key.len() > 10 && key.substr(0, 9) == "ls_tpd_rd_") tpd_rd[key.substr(10, key.len() - 1)] = v;
        else if (key.len() > 7 && key.substr(0, 6) == "ls_tpd_") tpd[key.substr(7, key.len() - 1)] = v;
        else if (key.len() > 8 && key.substr(0, 7) == "ls_skew_") skew[key.substr(8, key.len() - 1)] = v;
        else if (key == "ls_ten_ps") begin
          ten     = v;
          have_en = 1'b1;
        end else if (key == "ls_tdis_ps") tdis = v;
      end
    end
    $fclose(fd);
    nset = 0;
    for (int k = 0; k < int'(NCmd); k++) begin
      string n;
      n = cmd_pin(k);
      if (pkg_of.exists(n) && tpd.exists(pkg_of[n])) begin
        d_cmd[k] = dly(tpd[pkg_of[n]] + (skew.exists(n) ? skew[n] : 0.0));
        nset++;
      end
    end
    for (int k = 0; k < int'(DqBits); k++) begin
      string n;
      n = $sformatf("dq%0d", k);
      if (pkg_of.exists(n) && tpd.exists(pkg_of[n]) && tpd_rd.exists(pkg_of[n])) begin
        d_dq[k][0] = dly(tpd[pkg_of[n]] + (skew.exists(n) ? skew[n] : 0.0));
        d_dq[k][1] = dly(tpd_rd[pkg_of[n]] + (skew.exists(n) ? skew[n] : 0.0));
        nset++;
      end
    end
    for (int l = 0; l < int'(Lanes); l++) begin
      for (int s = 0; s < 3; s++) begin
        string n;
        n = (s == 2) ? $sformatf("dm%0d", l) : $sformatf("dqs%0d_%s", l, (s == 0) ? "p" : "n");
        if (pkg_of.exists(n) && tpd.exists(pkg_of[n])) begin
          v = skew.exists(n) ? skew[n] : 0.0;
          if (s == 2) begin
            d_dm[l] = dly(tpd[pkg_of[n]] + v);
          end else begin
            d_dqs[l][s][0] = dly(tpd[pkg_of[n]] + v);
            if (tpd_rd.exists(pkg_of[n])) d_dqs[l][s][1] = dly(tpd_rd[pkg_of[n]] + v);
          end
          nset++;
        end
      end
    end
    if (have_en) begin
      for (int p = 0; p < int'(NPkg); p++) begin
        d_en[p]  = dly(ten);
        d_dis[p] = dly(tdis);
        d_bbm[p] = dly((ten > tdis) ? ten : tdis);
      end
    end
    if (Verbose) begin
      $display("%m: board of %s: %0d channels, enable %0.0f ps, disable %0.0f ps", fn, nset, ten, tdis);
      foreach (tpd[p]) begin
        $display("%m:   package %s: tpd FPGA->DRAM %0.0f ps, DRAM->FPGA %0.0f ps", p, tpd[p],
                 tpd_rd.exists(p) ? tpd_rd[p] : 0.0);
      end
    end
  endtask

  initial begin
    string fn;
    if (LevelShift && $value$plusargs("ddr_board_cfg=%s", fn)) begin
      #1;                                 // after the draw of time 0
      load_cfg(fn);
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

  // =====================================================================
  if (!LevelShift) begin : g_direct
    // ------------------------------------------------- command channels
    logic [NCmd-1:0] f_cmd, m_cmd;
    assign f_cmd = {rst_n_i, a_i, ba_i, we_n_i, cas_n_i, ras_n_i, cs_n_i, odt_i, cke_i, ck_n_i, ck_p_i};
    initial m_cmd = '0;
    for (genvar k = 0; k < NCmd; k++) begin : g_cmd
      always @(f_cmd[k] or kick) m_cmd[k] <= #(TTot) f_cmd[k];
    end
    assign {mem_rst_n_o, mem_a_o, mem_ba_o, mem_we_n_o, mem_cas_n_o, mem_ras_n_o, mem_cs_n_o,
            mem_odt_o, mem_cke_o, mem_ck_n_o, mem_ck_p_o} = m_cmd;

    // --------------------------------------------- bidirectional groups
    logic             fd_dq_oe = 1'b0, md_dq_oe = 1'b0;    // far driver enables after the trace
    logic [Lanes-1:0] fd_dqs_oe = '0, md_dqs_oe = '0;
    always @(dq_oe_i or kick)      fd_dq_oe  <= #(TTot) dq_oe_i;
    always @(mem_dq_oe_i or kick)  md_dq_oe  <= #(TTot) mem_dq_oe_i;
    always @(dqs_oe_i or kick)     fd_dqs_oe <= #(TTot) dqs_oe_i;
    always @(mem_dqs_oe_i or kick) md_dqs_oe <= #(TTot) mem_dqs_oe_i;

    for (genvar c = 0; c < DqBits; c++) begin : g_dq
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

    for (genvar l = 0; l < Lanes; l++) begin : g_lane
      logic [1:0] fd_v = 2'b10, md_v = 2'b10, f_pin = 2'b10, m_pin = 2'b10;   // {N, P}
      always @(dqs_p_i[l] or dqs_n_i[l] or kick)         fd_v <= #(TTot) {dqs_n_i[l], dqs_p_i[l]};
      always @(mem_dqs_p_i[l] or mem_dqs_n_i[l] or kick) md_v <= #(TTot) {mem_dqs_n_i[l], mem_dqs_p_i[l]};
      always @(dqs_oe_i[l] or dqs_p_i[l] or dqs_n_i[l] or md_dqs_oe[l] or md_v) begin
        if (dqs_oe_i[l])       f_pin = {dqs_n_i[l], dqs_p_i[l]};
        else if (md_dqs_oe[l]) f_pin = md_v;
      end
      always @(mem_dqs_oe_i[l] or mem_dqs_p_i[l] or mem_dqs_n_i[l] or fd_dqs_oe[l] or fd_v) begin
        if (mem_dqs_oe_i[l])   m_pin = {mem_dqs_n_i[l], mem_dqs_p_i[l]};
        else if (fd_dqs_oe[l]) m_pin = fd_v;
      end
      assign {dqs_n_o[l], dqs_p_o[l]}         = f_pin;
      assign {mem_dqs_n_o[l], mem_dqs_p_o[l]} = m_pin;
      assign mem_dq_drv_o[l]  = fd_dq_oe;
      assign mem_dqs_drv_o[l] = fd_dqs_oe[l];

      logic dm_d = 1'b0;
      always @(dm_i[l] or kick) dm_d <= #(TTot) dm_i[l];
      assign mem_dm_o[l] = DmTied ? 1'b0 : dm_d;

      // contention at either end of the line
      logic c_dq, c_dqs;
      real  t0_dq = 0.0, t0_dqs = 0.0;
      assign c_dq  = (dq_oe_i && md_dq_oe) || (mem_dq_oe_i && fd_dq_oe);
      assign c_dqs = (dqs_oe_i[l] && md_dqs_oe[l]) || (mem_dqs_oe_i[l] && fd_dqs_oe[l]);
      // (edge triggered: shared counters must not sit in combinational logic)
      if (l == 0) begin : g_cdq
        always @(posedge c_dq) begin
          contention++;
          t0_dq = $realtime;
          note("contention on DQ");
        end
        always @(negedge c_dq) contention_ps += $realtime - t0_dq;
      end
      always @(posedge c_dqs) begin
        contention++;
        t0_dqs = $realtime;
        note($sformatf("contention on DQS lane %0d", l));
      end
      always @(negedge c_dqs) contention_ps += $realtime - t0_dqs;
    end

    logic unused;
    assign unused = ^{ls_oe_n_i, ls_dir_dq_i, ls_dir_dqs_i};

  // =====================================================================
  end else begin : g_txv
    // control pins at the shifters
    logic oe_n_s = 1'b1, dir_dq_s = !LsDirReadLevel, dir_dqs_s = !LsDirReadLevel;
    always @(ls_oe_n_i or kick)    oe_n_s    <= #(TF) ls_oe_n_i;
    always @(ls_dir_dq_i or kick)  dir_dq_s  <= #(TF) ls_dir_dq_i;
    always @(ls_dir_dqs_i or kick) dir_dqs_s <= #(TF) ls_dir_dqs_i;

    // port enables per package: a_en = A port drives (B -> A), b_en = B port drives
    logic [NPkg-1:0] a_en, b_en;
    for (genvar p = 0; p < NPkg; p++) begin : g_pkg
      logic want_a, want_b;
      logic a_on = 1'b0, b_on = 1'b0;
      assign a_en[p] = a_on;
      assign b_en[p] = b_on;
      if (p < NCmdPkg) begin : g_c
        assign want_a = !oe_n_s;
        assign want_b = 1'b0;
      end else if (p < NCmdPkg + Lanes) begin : g_d
        assign want_a = !oe_n_s && (dir_dq_s != LsDirReadLevel);
        assign want_b = !oe_n_s && (dir_dq_s == LsDirReadLevel);
      end else begin : g_s
        assign want_a = !oe_n_s && (dir_dqs_s != LsDirReadLevel);
        assign want_b = !oe_n_s && (dir_dqs_s == LsDirReadLevel);
      end
      // a request (change of want_*) schedules the port changes; a later
      // request makes the pending ones void (seq). Edge triggered blocks only.
      int unsigned seq = 0;
      int unsigned tok_a_on = 0, tok_a_off = 0, tok_b_on = 0, tok_b_off = 0;
      logic        ev_a_on = 1'b0, ev_a_off = 1'b0, ev_b_on = 1'b0, ev_b_off = 1'b0;
      logic        nx_a_on = 1'b0, nx_a_off = 1'b0, nx_b_on = 1'b0, nx_b_off = 1'b0;
      always @(posedge want_a or negedge want_a or posedge want_b or negedge want_b) begin
        seq++;
        if (!want_a && a_on) begin
          tok_a_off <= #(d_dis[p]) seq;
          nx_a_off   = !nx_a_off;
          ev_a_off  <= #(d_dis[p]) nx_a_off;
        end
        if (!want_b && b_on) begin
          tok_b_off <= #(d_dis[p]) seq;
          nx_b_off   = !nx_b_off;
          ev_b_off  <= #(d_dis[p]) nx_b_off;
        end
        if (want_a && !a_on) begin
          tok_a_on <= #(b_on ? d_bbm[p] : d_en[p]) seq;
          nx_a_on   = !nx_a_on;
          ev_a_on  <= #(b_on ? d_bbm[p] : d_en[p]) nx_a_on;
        end
        if (want_b && !b_on) begin
          tok_b_on <= #(a_on ? d_bbm[p] : d_en[p]) seq;
          nx_b_on   = !nx_b_on;
          ev_b_on  <= #(a_on ? d_bbm[p] : d_en[p]) nx_b_on;
        end
      end
      always @(posedge ev_a_on or negedge ev_a_on)   if (tok_a_on == seq)  a_on = 1'b1;
      always @(posedge ev_a_off or negedge ev_a_off) if (tok_a_off == seq) a_on = 1'b0;
      always @(posedge ev_b_on or negedge ev_b_on)   if (tok_b_on == seq)  b_on = 1'b1;
      always @(posedge ev_b_off or negedge ev_b_off) if (tok_b_off == seq) b_on = 1'b0;
    end

    // ------------------------------------------------- command channels
    logic [NCmd-1:0] f_cmd, m_cmd;
    assign f_cmd = {rst_n_i, a_i, ba_i, we_n_i, cas_n_i, ras_n_i, cs_n_i, odt_i, cke_i, ck_n_i, ck_p_i};
    // pulls on the DRAM side: CKE (2) / ODT (3) / RESET# (last) down, CS# (4) up
    function automatic logic pulled(int k, logic cur);
      if (k == 2 || k == 3 || k == int'(NCmd) - 1) return 1'b0;
      if (k == 4) return 1'b1;
      return cur;
    endfunction
    for (genvar k = 0; k < NCmd; k++) begin : g_cmd
      localparam int unsigned P = k / 8;
      logic b_v = 1'b0, a_v = 1'b0, a_pin = pulled(k, 1'b0), m_v = pulled(k, 1'b0);
      always @(f_cmd[k] or kick) b_v <= #(TF) f_cmd[k];
      always @(b_v)      a_v <= #(d_cmd[k]) b_v;
      always @(a_v or a_en[P]) a_pin = a_en[P] ? a_v : pulled(k, a_pin);
      always @(a_pin)    m_v <= #(TM) a_pin;
      assign m_cmd[k] = m_v;
    end
    assign {mem_rst_n_o, mem_a_o, mem_ba_o, mem_we_n_o, mem_cas_n_o, mem_ras_n_o, mem_cs_n_o,
            mem_odt_o, mem_cke_o, mem_ck_n_o, mem_ck_p_o} = m_cmd;

    // ------------------------------------------- driver enables at the ports
    logic             fb_dq_oe = 1'b0, ma_dq_oe = 1'b0;
    logic [Lanes-1:0] fb_dqs_oe = '0, ma_dqs_oe = '0;
    logic [NPkg-1:0]  ad_en = '0, bd_en = '0;   // A port on, seen at the DRAM / B port on, at the FPGA
    always @(dq_oe_i or kick)      fb_dq_oe  <= #(TF) dq_oe_i;
    always @(dqs_oe_i or kick)     fb_dqs_oe <= #(TF) dqs_oe_i;
    always @(mem_dq_oe_i or kick)  ma_dq_oe  <= #(TM) mem_dq_oe_i;
    always @(mem_dqs_oe_i or kick) ma_dqs_oe <= #(TM) mem_dqs_oe_i;
    always @(a_en)         ad_en     <= #(TM) a_en;
    always @(b_en)         bd_en     <= #(TF) b_en;

    // -------------------------------------------------------- DQ channels
    for (genvar c = 0; c < DqBits; c++) begin : g_dq
      localparam int unsigned P = NCmdPkg + c / 8;
      logic fb_v = 1'b0, b_pin = 1'b0, a_out = 1'b0, ma_v = 1'b0, a_pin = 1'b0, b_out = 1'b0;
      logic ad_v = 1'b0, bd_v = 1'b0, f_pin = 1'b0, m_pin = 1'b0;
      always @(dq_i[c] or kick)     fb_v <= #(TF) dq_i[c];
      always @(mem_dq_i[c] or kick) ma_v <= #(TM) mem_dq_i[c];
      always @(fb_v or fb_dq_oe or b_out or b_en[P]) begin
        if (fb_dq_oe)     b_pin = fb_v;
        else if (b_en[P]) b_pin = b_out;
      end
      always @(b_pin) a_out <= #(d_dq[c][0]) b_pin;
      always @(a_out or a_en[P] or ma_v or ma_dq_oe) begin
        if (a_en[P])       a_pin = a_out;
        else if (ma_dq_oe) a_pin = ma_v;
      end
      always @(a_pin) b_out <= #(d_dq[c][1]) a_pin;
      always @(a_out) ad_v  <= #(TM) a_out;
      always @(b_out) bd_v  <= #(TF) b_out;
      always @(mem_dq_oe_i or mem_dq_i[c] or ad_en[P] or ad_v) begin
        if (mem_dq_oe_i)   m_pin = mem_dq_i[c];
        else if (ad_en[P]) m_pin = ad_v;
      end
      always @(dq_oe_i or dq_i[c] or bd_en[P] or bd_v) begin
        if (dq_oe_i)       f_pin = dq_i[c];
        else if (bd_en[P]) f_pin = bd_v;
      end
      assign dq_o[c]     = f_pin;
      assign mem_dq_o[c] = m_pin;
    end

    // ------------------------------------------------ DQS, DM per lane
    for (genvar l = 0; l < Lanes; l++) begin : g_lane
      localparam int unsigned PD = NCmdPkg + l;           // DQ package
      localparam int unsigned PS = NCmdPkg + Lanes + l;   // DQS package
      for (genvar s = 0; s < 2; s++) begin : g_s          // 0: DQS_P, 1: DQS_N
        logic f_drv, m_drv;
        localparam logic Idle = 1'(s);                    // DQS_P 0, DQS_N 1
        logic fb_v = Idle, b_pin = Idle, a_out = Idle, ma_v = Idle, a_pin = Idle, b_out = Idle;
        logic ad_v = Idle, bd_v = Idle, f_pin = Idle, m_pin = Idle;
        assign f_drv = s ? dqs_n_i[l] : dqs_p_i[l];
        assign m_drv = s ? mem_dqs_n_i[l] : mem_dqs_p_i[l];
        always @(f_drv or kick) fb_v <= #(TF) f_drv;
        always @(m_drv or kick) ma_v <= #(TM) m_drv;
        always @(fb_v or fb_dqs_oe[l] or b_out or b_en[PS]) begin
          if (fb_dqs_oe[l]) b_pin = fb_v;
          else if (b_en[PS]) b_pin = b_out;
        end
        always @(b_pin) a_out <= #(d_dqs[l][s][0]) b_pin;
        always @(a_out or a_en[PS] or ma_v or ma_dqs_oe[l]) begin
          if (a_en[PS])          a_pin = a_out;
          else if (ma_dqs_oe[l]) a_pin = ma_v;
        end
        always @(a_pin) b_out <= #(d_dqs[l][s][1]) a_pin;
        always @(a_out) ad_v  <= #(TM) a_out;
        always @(b_out) bd_v  <= #(TF) b_out;
        always @(mem_dqs_oe_i[l] or m_drv or ad_en[PS] or ad_v) begin
          if (mem_dqs_oe_i[l]) m_pin = m_drv;
          else if (ad_en[PS])  m_pin = ad_v;
        end
        always @(dqs_oe_i[l] or f_drv or bd_en[PS] or bd_v) begin
          if (dqs_oe_i[l])    f_pin = f_drv;
          else if (bd_en[PS]) f_pin = bd_v;
        end
      end
      assign dqs_p_o[l]       = g_s[0].f_pin;
      assign dqs_n_o[l]       = g_s[1].f_pin;
      assign mem_dqs_p_o[l]   = g_s[0].m_pin;
      assign mem_dqs_n_o[l]   = g_s[1].m_pin;
      assign mem_dq_drv_o[l]  = ad_en[PD];
      assign mem_dqs_drv_o[l] = ad_en[PS];

      // DM: FPGA -> DRAM through the DQS package (no DRAM driver)
      if (DmTied) begin : g_dm_tied
        assign mem_dm_o[l] = 1'b0;
      end else begin : g_dm
        logic fb_v = 1'b0, b_pin = 1'b0, a_out = 1'b0, a_pin = 1'b0, m_v = 1'b0;
        always @(dm_i[l] or kick) fb_v <= #(TF) dm_i[l];
        always @(fb_v or fb_dq_oe) if (fb_dq_oe) b_pin = fb_v;
        always @(b_pin) a_out <= #(d_dm[l]) b_pin;
        always @(a_out or a_en[PS]) if (a_en[PS]) a_pin = a_out;
        always @(a_pin) m_v <= #(TM) a_pin;
        assign mem_dm_o[l] = m_v;
      end

      // contention (B side: FPGA and B port, A side: A port and DRAM)
      logic c_dq, c_dqs, c_dm;
      real  t0_dq = 0.0, t0_dqs = 0.0, t0_dm = 0.0;
      assign c_dq  = (fb_dq_oe && b_en[PD]) || (a_en[PD] && ma_dq_oe);
      assign c_dqs = (fb_dqs_oe[l] && b_en[PS]) || (a_en[PS] && ma_dqs_oe[l]);
      assign c_dm  = !DmTied && fb_dq_oe && b_en[PS];
      // (edge triggered: shared counters must not sit in combinational logic)
      always @(posedge c_dq) begin
        contention++;
        t0_dq = $realtime;
        note($sformatf("contention on DQ lane %0d (FPGA %0d / B %0d, A %0d / DRAM %0d)", l,
                       fb_dq_oe, b_en[PD], a_en[PD], ma_dq_oe));
      end
      always @(negedge c_dq) contention_ps += $realtime - t0_dq;
      always @(posedge c_dqs) begin
        contention++;
        t0_dqs = $realtime;
        note($sformatf("contention on DQS lane %0d (FPGA %0d / B %0d, A %0d / DRAM %0d)", l,
                       fb_dqs_oe[l], b_en[PS], a_en[PS], ma_dqs_oe[l]));
      end
      always @(negedge c_dqs) contention_ps += $realtime - t0_dqs;
      always @(posedge c_dm) begin
        contention++;
        t0_dm = $realtime;
        note($sformatf("contention on DM lane %0d", l));
      end
      always @(negedge c_dm) contention_ps += $realtime - t0_dm;

      // floats: B input (DIR = write, port on) not driven by the FPGA
      // a float that still holds FloatGracePs after it started counts once
      logic f_dq, f_dqs, fa_dq;
      int unsigned fseq_dq = 0, fseq_dqs = 0, fseq_a = 0;
      int unsigned ftok_dq = 0, ftok_dqs = 0, ftok_a = 0;
      logic        fev_dq = 1'b0, fev_dqs = 1'b0, fev_a = 1'b0;
      logic        fnx_dq = 1'b0, fnx_dqs = 1'b0, fnx_a = 1'b0;
      assign f_dq  = a_en[PD] && !fb_dq_oe;
      assign f_dqs = a_en[PS] && !fb_dqs_oe[l];
      assign fa_dq = b_en[PD] && !ma_dq_oe;
      always @(posedge f_dq or negedge f_dq) begin
        fseq_dq++;
        if (f_dq) begin
          ftok_dq <= #(TG) fseq_dq;
          fnx_dq   = !fnx_dq;
          fev_dq  <= #(TG) fnx_dq;
        end
      end
      always @(posedge f_dqs or negedge f_dqs) begin
        fseq_dqs++;
        if (f_dqs) begin
          ftok_dqs <= #(TG) fseq_dqs;
          fnx_dqs   = !fnx_dqs;
          fev_dqs  <= #(TG) fnx_dqs;
        end
      end
      always @(posedge fa_dq or negedge fa_dq) begin
        fseq_a++;
        if (fa_dq) begin
          ftok_a <= #(TG) fseq_a;
          fnx_a   = !fnx_a;
          fev_a  <= #(TG) fnx_a;
        end
      end
      always @(posedge fev_dq or negedge fev_dq) if (ftok_dq == fseq_dq && f_dq) begin
        floats++;
        note($sformatf("DQ lane %0d: shifter B input floating (FPGA not driving, DIR = write)", l));
      end
      always @(posedge fev_dqs or negedge fev_dqs) if (ftok_dqs == fseq_dqs && f_dqs) begin
        floats++;
        note($sformatf("DQS lane %0d: shifter B input floating (FPGA not driving, DIR = write)", l));
      end
      always @(posedge fev_a or negedge fev_a) if (ftok_a == fseq_a && fa_dq) floats_a++;
    end

    logic unused;
    assign unused = ^{dm_i & {Lanes{DmTied}}};
  end

endmodule
/* verilator lint_on UNOPTFLAT */
/* verilator lint_on SYNCASYNCNET */
/* verilator lint_on LATCH */
/* verilator lint_on BLKSEQ */
