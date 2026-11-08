// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Self-test of the HyperRAM simulation models (no bow_hyperram RTL):
// hyperram_clk_model -> bow_hyperram_io_sim -> hyperram_board_model ->
// hyperram_model, driven by a behavioural PHY-cycle host. Verilator --binary
// --timing (and xsim), self-checking ("tb_hyperram_model: PASS" / "FAIL");
// one model per configuration (parameters below, see the Makefile).
//
// Host: one hr_io_out_t per hr_clk cycle (assigned 1 ps after the hr_clk
// rising edge, like a register), with the transaction schedule of the working
// spec (5) that bow_hyperram_ctrl uses: t = 0 first cycle with CS# low, CA in
// t = 1..3, RWDS released at t = -2 and DIR (RWDS) = HyperRAM -> FPGA from t =
// -1, the latency level of RWDS taken from rwds_pad at t = lat_smp (4;
// variable latency; checked against the model's choice), data in t_D = L + 3
// or 2L + 3 (register write: 4), CS# high from t_E = t_D + N; reads: DQ
// released at max(4, D1 - RDIR_LEAD - OE_PRE) and DIR (DQ) to read OE_PRE
// cycles later, both back RDIR_TAIL / OE_POST cycles after t_E (2, 1, 1, 1);
// memory writes: DIR (RWDS) back to the FPGA at RW_DIR (5), RWDS driven low
// from RW_OE (6: mask preamble), then the masks; the next transaction at
// least CSHI cycles after t_E (CSHI from tRWR). Read data: the io_sim IDDR
// outputs in the rd_clk domain, aligned on the first word with RWDS = {B 0,
// A 1} after an arm token at t_D (an earlier arm can take the end of a 2x
// latency level, dropped after f3, for a first word), strict strobe check on
// every word. Calibration: rd_clk starts at a random phase
// (hyperram_clk_model); ID0 reads every 16 fine steps over a full period, the
// centre of the widest (cyclic) window of good reads.
//
// Flow (every configuration):
//   1  clocks, shifters enabled; an ID0 read during tVCS (ignored, power
//      error expected); wait for tVCS
//   2  read phase calibration; ID0 / ID1 / CR0 / CR1 reset values
//   3  memory writes with byte masks and reads at the default latency (7,
//      fixed)
//   4  CR0 = latency FastLatCode, fixed: read back; burst order against the
//      data sheet's table 11 (hybrid 16 / 32 / 64 / 128 bytes, legacy wrap
//      16 / 32 / 64 / 128 bytes, linear); random traffic (linear / wrapped
//      in every CR0[2:0] setting, 1..24 words, random byte masks) against a
//      byte reference model; the longest burst tCSM allows; a linear burst
//      across the end of the array
//   5  variable latency: random traffic, the host takes 1x / 2x from RWDS in
//      the CA phase (both must occur)
//   6  direct boards: write phase moved by +-PsSteps / 7 (DQ / RWDS still
//      inside tIS / tIH), traffic, back to 0
//   7  negative tests, each with its exact expected counter changes: CA
//      reserved bit, register read of two words, write to ID0, address beyond
//      the array, latency too short for the CK (CR0 latency 3), tCSM, write
//      mask preamble high, DQ contention (the host keeps DQ in a read), RWDS
//      contention and RWDS in a register write, tCSS (CS# falls 2 ns before
//      CK), tIS / tIH (a DQ bit flips 200 ps before / after a CK edge at the
//      balls), tCSHI and tRWR (CS# high for 5 ns), a transaction started with
//      CK high; the wr_relax hook (a violated CA edge: the write is ignored; a
//      violated data edge: the word is stored inverted; no error class moves)
//   8  hybrid sleep (data kept, CR1[5] back to 0, an access during tEXTHS
//      refused), hardware reset (registers default, data lost), deep power
//      down (registers default, data lost)
//   9  pad wrapper Loopback mode (a second bow_hyperram_io_sim: emulator data
//      read back by the IDDRs, pads driven, shifter controls constant)
//  10  end: every model / board counter equals the sum of the expected
//      changes (no float, no contention elsewhere), the model's output
//      timing draws inside the data sheet ranges, no ignored phase step
// Monitors (whole run): the pad wrapper pins against the bow_hyperram_pkg
// contract in every hr_clk cycle (values of PHY cycle j in pin cycle j+1, DQ
// / RWDS bytes in their slots at the current write phase); every edge of the
// model's outputs at its CK / CS# / RESET# edge + its drawn delay (tDSV,
// tCKDS, tCKDSR, tCKD, tCKDI, tDQLZ, tDSZ, tOZ) to the picosecond.
// Plusargs: +SEED=<n> (traffic; the Makefile passes the same n to the model
// seeds), +NRAND=<n> (random transactions per traffic block, default 60),
// +TIMEOUT_MS=<n> (simulated time limit, default 20), +WAVES (waves.fst, a
// model built with WAVES=1), the model plusargs (+hyperram_clk_seed,
// +hyperram_board_seed, +hyperram_mem_seed, +hyperram_refresh_pct,
// +hyperram_txn_log, +hyperram_oz_free: not with this test, its last-byte
// reads assume the default).

`timescale 1ps / 1ps

// behavioural testbench: blocking assignments in clocked processes are intended
/* verilator lint_off BLKSEQ */
module tb_hyperram_model import bow_hyperram_pkg::*; #(
  parameter bit          LevelShift  = 1'b1,      // TXV0108 card, else direct board
  parameter int unsigned TckPs       = 10000,
  parameter int unsigned PsSteps     = 672,
  parameter logic [3:0]  FastLatCode = 4'b1111,   // CR0[7:4] of the main tests
  parameter int unsigned MemBytes    = 32 << 20
);

  localparam int unsigned Words  = MemBytes / 2;
  localparam int unsigned CalStp = 16;              // calibration step (fine steps)
  localparam logic [15:0] Id0    = 16'h0E86;
  localparam logic [15:0] Id1    = 16'h0001;
  localparam logic [15:0] Cr0Def = 16'h8F2F;
  localparam logic [15:0] Cr1Def = 16'hFFC2;        // RefreshInterval 10 (the card's grade)
  localparam int          Cshi   = (37_000 - (5 * int'(TckPs)) / 2 + int'(TckPs) - 1) / int'(TckPs);
  localparam int          ColTmo = 12;              // read: rd_clk cycles from the arm to word 0

  // ================================================================ clocks
  logic ck_on = 1'b0;
  logic hr_clk, wclk, rd_clk, locked;
  logic ps_en = 1'b0, ps_inc = 1'b0, ps_done, wps_en = 1'b0, wps_inc = 1'b0, wps_done;

  hyperram_clk_model #(.TckPs(TckPs), .PsSteps(PsSteps)) u_clk (
    .en_i       (ck_on),
    .hr_clk_o   (hr_clk),
    .wclk_o     (wclk),
    .rd_clk_o   (rd_clk),
    .locked_o   (locked),
    .ps_en_i    (ps_en),
    .ps_inc_i   (ps_inc),
    .ps_done_o  (ps_done),
    .wps_en_i   (wps_en),
    .wps_inc_i  (wps_inc),
    .wps_done_o (wps_done)
  );

  // ============================================================ pads, board
  hr_io_out_t io_o = HR_IO_OUT_IDLE;
  hr_io_in_t  io_i;
  logic       rwds_pad;
  logic       f_ck_p, f_ck_n, f_cs_n, f_rst_n, f_dq_oe, f_rwds, f_rwds_oe;
  logic       f_ls_oe_n, f_ls_dir_dq, f_ls_dir_rwds, b_rwds;
  logic [7:0] f_dq, b_dq;

  bow_hyperram_io_sim #(.Loopback(1'b0), .HasLs(LevelShift)) u_io (
    .clk_i         (hr_clk),
    .wclk_i        (wclk),
    .rd_clk_i      (rd_clk),
    .io_o_i        (io_o),
    .io_i_o        (io_i),
    .rwds_pad_o    (rwds_pad),
    .lb_dq_en_i    (1'b0),
    .lb_dq_i       ('0),
    .lb_rwds_en_i  (1'b0),
    .lb_rwds_i     ('0),
    .ck_p_o        (f_ck_p),
    .ck_n_o        (f_ck_n),
    .cs_n_o        (f_cs_n),
    .rst_n_o       (f_rst_n),
    .dq_o          (f_dq),
    .dq_oe_o       (f_dq_oe),
    .dq_i          (b_dq),
    .rwds_o        (f_rwds),
    .rwds_oe_o     (f_rwds_oe),
    .rwds_i        (b_rwds),
    .ls_oe_n_o     (f_ls_oe_n),
    .ls_dir_dq_o   (f_ls_dir_dq),
    .ls_dir_rwds_o (f_ls_dir_rwds)
  );

  // test hooks on CS# at the FPGA pin:
  //   tCSS: cs_hold keeps CS# high; armed (css_arm), released TckPs - 2 ns
  //   after the FPGA's CS# falls (2 ns before the first CK rising edge)
  //   tCSHI / tRWR: cs_lo keeps CS# low; armed (cslo_arm), set when the FPGA's
  //   CS# falls, released cslo_ps after it rises
  logic   cs_hold = 1'b0, cs_lo = 1'b0;
  bit     css_arm = 1'b0, cslo_arm = 1'b0;
  longint cslo_ps = 0;
  logic   brd_cs_n;
  assign brd_cs_n = (f_cs_n | cs_hold) & !cs_lo;
  // (delays computed into longint variables: Verilator 5.022 never resumes a
  // delay written as an int expression with a negative operand)
  always @(negedge f_cs_n) begin
    longint d;
    if (cslo_arm) cs_lo = 1'b1;
    if (css_arm) begin
      d = longint'(TckPs) - 2000;
      #(d);
      cs_hold = 1'b0;
      css_arm = 1'b0;
    end
  end
  always @(posedge f_cs_n) begin
    if (cslo_arm && cs_lo) begin
      #(cslo_ps);
      cs_lo    = 1'b0;
      cslo_arm = 1'b0;
    end
  end

  logic       m_ck, m_ck_n, m_cs_n, m_rst_n, m_dq_drv, m_rwds, m_rwds_drv;
  logic [7:0] m_dq, d_dq, dq_glitch = '0;            // dq_glitch: tIS test hook at the balls
  logic       d_dq_oe, d_rwds, d_rwds_oe;
  // test hooks at the HyperRAM balls:
  //   tIS / tIH: DQ0 flips for 1.5 ns from glitch_off ps after r2 (armed by
  //   glitch_arm; negative: before r2)
  //   CK high at CS# fall: ck_glitch drives CK high; armed (ckg_arm), released
  //   2 ns after CS# falls at the balls
  logic [7:0] m_dq_dev;
  logic       m_ck_dev, ck_glitch = 1'b0;
  bit         glitch_arm = 1'b0, ckg_arm = 1'b0;
  int         glitch_off = 0;
  assign m_dq_dev = m_dq ^ dq_glitch;
  assign m_ck_dev = m_ck | ck_glitch;
  always @(negedge m_cs_n) begin
    longint d;
    if (ckg_arm) begin
      #2000;
      ck_glitch = 1'b0;
      ckg_arm   = 1'b0;
    end
    if (glitch_arm) begin
      @(posedge m_ck);
      d = longint'(TckPs) + longint'(glitch_off);
      #(d);
      dq_glitch = 8'h01;
      #1500;
      dq_glitch  = 8'h00;
      glitch_arm = 1'b0;
    end
  end

  hyperram_board_model #(.LevelShift(LevelShift)) u_brd (
    .ck_p_i         (f_ck_p),
    .ck_n_i         (f_ck_n),
    .cs_n_i         (brd_cs_n),
    .rst_n_i        (f_rst_n),
    .dq_i           (f_dq),
    .dq_oe_i        (f_dq_oe),
    .dq_o           (b_dq),
    .rwds_i         (f_rwds),
    .rwds_oe_i      (f_rwds_oe),
    .rwds_o         (b_rwds),
    .ls_oe_n_i      (f_ls_oe_n),
    .ls_dir_dq_i    (f_ls_dir_dq),
    .ls_dir_rwds_i  (f_ls_dir_rwds),
    .mem_ck_o       (m_ck),
    .mem_ck_n_o     (m_ck_n),
    .mem_cs_n_o     (m_cs_n),
    .mem_rst_n_o    (m_rst_n),
    .mem_dq_o       (m_dq),
    .mem_dq_drv_o   (m_dq_drv),
    .mem_dq_i       (d_dq),
    .mem_dq_oe_i    (d_dq_oe),
    .mem_rwds_o     (m_rwds),
    .mem_rwds_drv_o (m_rwds_drv),
    .mem_rwds_i     (d_rwds),
    .mem_rwds_oe_i  (d_rwds_oe)
  );

  hyperram_model #(.MemBytes(MemBytes)) u_hr (
    .ck_i       (m_ck_dev),
    .ck_n_i     (m_ck_n),
    .cs_n_i     (m_cs_n),
    .rst_n_i    (m_rst_n),
    .dq_i       (m_dq_dev),
    .dq_drv_i   (m_dq_drv),
    .dq_o       (d_dq),
    .dq_oe_o    (d_dq_oe),
    .rwds_i     (m_rwds),
    .rwds_drv_i (m_rwds_drv),
    .rwds_o     (d_rwds),
    .rwds_oe_o  (d_rwds_oe)
  );

  // ================================================================ errors
  int tb_errs = 0;
  bit quiet = 1'b0;                 // expected failures: no testbench error

  task automatic error(string msg);
    tb_errs++;
    $display("%0t ps: tb_hyperram_model: ERROR %s", $time, msg);
  endtask

  task automatic info(string msg);
    $display("%0t ps: tb_hyperram_model: %s", $time, msg);
  endtask

  // conditional text (string operands: no padding of the shorter literal)
  function automatic string pick(bit c, string a, string b);
    if (c) return a;
    return b;
  endfunction

  // model / board counters: snapshot, expected changes per test, totals
  localparam int NCnt = 23;
  localparam int CTcshi = 0, CTrwr = 1, CTcss = 2, CTcsh = 3, CCkcs = 4, CTcsm = 5, CTck = 6,
                 CTckhp = 7, CLatf = 8, CTis = 9, CTih = 10, CDrv = 11, CPre = 12, CContDq = 13,
                 CContRw = 14, CRegwrRwds = 15, CCa = 16, CReg = 17, CRange = 18, CPwr = 19,
                 CRst = 20, CBrdCont = 21, CBrdFloat = 22;
  int    cnt_base [NCnt];
  int    cnt_exp  [NCnt];           // expected change of the running test
  int    cnt_tot  [NCnt];           // expected totals
  string cnt_name [NCnt];

  function automatic int cnt_now(int i);
    unique case (i)
      CTcshi:     return u_hr.err_tcshi;
      CTrwr:      return u_hr.err_trwr;
      CTcss:      return u_hr.err_tcss;
      CTcsh:      return u_hr.err_tcsh;
      CCkcs:      return u_hr.err_ckcs;
      CTcsm:      return u_hr.err_tcsm;
      CTck:       return u_hr.err_tck;
      CTckhp:     return u_hr.err_tckhp;
      CLatf:      return u_hr.err_latf;
      CTis:       return u_hr.err_tis;
      CTih:       return u_hr.err_tih;
      CDrv:       return u_hr.err_drv;
      CPre:       return u_hr.err_pre;
      CContDq:    return u_hr.err_cont_dq;
      CContRw:    return u_hr.err_cont_rwds;
      CRegwrRwds: return u_hr.err_regwr_rwds;
      CCa:        return u_hr.err_ca;
      CReg:       return u_hr.err_reg;
      CRange:     return u_hr.err_range;
      CPwr:       return u_hr.err_pwr;
      CRst:       return u_hr.err_rst;
      CBrdCont:   return u_brd.contention;
      CBrdFloat:  return u_brd.floats;
      default:    return 0;
    endcase
  endfunction

  initial begin
    cnt_name = '{"tCSHI", "tRWR", "tCSS", "tCSH", "CK at CS#", "tCSM", "tCK", "tCKHP", "latency/CK",
                 "tIS", "tIH", "not driven", "mask preamble", "DQ contention", "RWDS contention",
                 "RWDS in register write", "CA", "register", "range", "power", "reset",
                 "board contention", "board floats"};
    for (int i = 0; i < NCnt; i++) begin
      cnt_base[i] = 0;
      cnt_exp[i]  = 0;
      cnt_tot[i]  = 0;
    end
  end

  // a test with the expected counter changes in cnt_exp starts
  task automatic t_begin();
    for (int i = 0; i < NCnt; i++) begin
      cnt_base[i] = cnt_now(i);
      cnt_exp[i]  = 0;
    end
  endtask

  // ... ends: every counter changed by exactly the expected amount
  task automatic t_end(string what);
    int d;
    bit bad;
    bad = 1'b0;
    for (int i = 0; i < NCnt; i++) begin
      d = cnt_now(i) - cnt_base[i];
      cnt_tot[i] += cnt_exp[i];
      if (d != cnt_exp[i]) begin
        bad = 1'b1;
        error($sformatf("%s: %s counter changed by %0d, expected %0d", what, cnt_name[i], d, cnt_exp[i]));
      end
    end
    if (!bad) info($sformatf("%s: ok", what));
  endtask

  // ============================================== pad wrapper pin contract
  // bow_hyperram_pkg: the PHY value of cycle j (io_o when hr_clk rises at the
  // end of it) on the FPGA pins in pin cycle j+1 (+ PadOutPs = 1500): CK_P
  // high in its first half when ck_en (CK_N the complement), CS# / RESET# /
  // OE# / DIR / DQ OE / RWDS OE for the whole cycle; DQ / RWDS byte A centred
  // on its start, byte B on its middle, both shifted by the write phase.
  // Sampled 100 ps into the DQ / RWDS slots, T/4 (CK high) and 0.7 T (CK
  // low) into the cycle.
  int n_pin = 0;
  always @(posedge hr_clk) begin
    hr_io_out_t v;
    longint     at [4], d, now0, w, x;
    int         kd [4], y;
    if (locked) begin
      v    = io_o;                                   // cycle j, before this edge's assignment
      now0 = $time;
      w    = longint'(real'(u_clk.wps_phase) * real'(TckPs) / real'(PsSteps));
      // sample points after this edge (sorted below): 0 DQ / RWDS byte A, 1 the
      // controls and CK high, 2 byte B, 3 CK low
      at[0] = 1500 + w + 100;
      at[1] = 1500 + longint'(TckPs) / 4;
      at[2] = 1500 + w + 100 + longint'(TckPs) / 2;
      at[3] = 1500 + 7 * longint'(TckPs) / 10;          // (all < T: every cycle is checked)
      for (int i = 0; i < 4; i++) kd[i] = i;
      for (int i = 1; i < 4; i++) begin
        for (int j = i; j > 0 && at[j] < at[j - 1]; j--) begin
          x = at[j]; at[j] = at[j - 1]; at[j - 1] = x;
          y = kd[j]; kd[j] = kd[j - 1]; kd[j - 1] = y;
        end
      end
      for (int i = 0; i < 4; i++) begin
        d = now0 + at[i] - $time;
        if (d > 0) #(d);
        unique case (kd[i])
          0: if (f_dq !== v.dq[0] || f_rwds !== v.rwds[0]) begin
            error($sformatf("pads: DQ / RWDS byte A %02h / %0d, PHY %02h / %0d", f_dq, f_rwds, v.dq[0], v.rwds[0]));
          end
          1: if (f_ck_p !== v.ck_en || f_ck_n !== !v.ck_en || f_cs_n !== v.cs_n || f_rst_n !== v.rst_n ||
                 f_dq_oe !== v.dq_oe || f_rwds_oe !== v.rwds_oe || f_ls_oe_n !== (LevelShift ? v.ls_oe_n : 1'b1) ||
                 f_ls_dir_dq !== (LevelShift && v.ls_dir_dq) || f_ls_dir_rwds !== (LevelShift && v.ls_dir_rwds)) begin
            error($sformatf("pads: CK %0d CS# %0d RESET# %0d OE %0d%0d LS %0d%0d%0d, PHY %0d %0d %0d %0d%0d %0d%0d%0d",
                            f_ck_p, f_cs_n, f_rst_n, f_dq_oe, f_rwds_oe, f_ls_oe_n, f_ls_dir_dq, f_ls_dir_rwds,
                            v.ck_en, v.cs_n, v.rst_n, v.dq_oe, v.rwds_oe, v.ls_oe_n, v.ls_dir_dq, v.ls_dir_rwds));
          end
          2: if (f_dq !== v.dq[1] || f_rwds !== v.rwds[1]) begin
            error($sformatf("pads: DQ / RWDS byte B %02h / %0d, PHY %02h / %0d", f_dq, f_rwds, v.dq[1], v.rwds[1]));
          end
          default: if (f_ck_p !== 1'b0 || f_ck_n !== 1'b1) error("pads: CK not low in the second half of the cycle");
        endcase
      end
      n_pin++;
    end
  end

  // ================================================= model output timing
  // Every edge of the model's outputs at its exact time (the action queue of
  // the model): RWDS driven tDSV after CS# fell, RWDS changes tCKDS (data) or
  // tCKDSR (latency level dropped at f3) after a CK edge, RWDS released tDSZ
  // after CS# rose or after f3 (write turnaround); DQ changes tCKD / tCKDI /
  // tDQLZ after a CK edge, DQ released tOZ after CS# rose; both 1 ps after
  // RESET# fell. The draws must lie in the data sheet ranges.
  longint ck_t [$];
  longint mcs_fall = -1, mcs_rise = -1, mrst_fall = -1;
  int     n_tim = 0;
  always @(m_ck_dev) begin
    ck_t.push_back($time);
    if (ck_t.size() > 12) void'(ck_t.pop_front());
  end
  always @(negedge m_cs_n)  mcs_fall  = $time;
  always @(posedge m_cs_n)  mcs_rise  = $time;
  always @(negedge m_rst_n) mrst_fall = $time;

  function automatic bit ck_ago(longint d);
    foreach (ck_t[i]) if ($time - ck_t[i] == d) return 1'b1;
    return 1'b0;
  endfunction

  task automatic tim_chk(bit ok, string what);
    n_tim++;
    if (!ok) error($sformatf("model output timing: %s", what));
  endtask

  always @(posedge d_rwds_oe) begin
    tim_chk($time - mcs_fall == u_hr.tdsv,
            $sformatf("RWDS driven %0d ps after CS# fell (tDSV %0d)", $time - mcs_fall, u_hr.tdsv));
  end
  always @(negedge d_rwds_oe) begin
    tim_chk($time - mcs_rise == u_hr.tdsz || ck_ago(u_hr.tdsz) || $time - mrst_fall == 1,
            $sformatf("RWDS released %0d ps after CS# rose (tDSZ %0d)", $time - mcs_rise, u_hr.tdsz));
  end
  always @(d_rwds) begin
    if (d_rwds_oe) begin
      tim_chk(ck_ago(u_hr.tckds) || ck_ago(u_hr.tckdsr) || $time - mcs_fall == u_hr.tdsv,
              $sformatf("RWDS changed to %0d at no CK edge + tCKDS (%0d) / tCKDSR (%0d)", d_rwds,
                        u_hr.tckds, u_hr.tckdsr));
    end
  end
  always @(d_dq) begin
    if (d_dq_oe) begin
      tim_chk(ck_ago(u_hr.tckd) || ck_ago(u_hr.tckdi) || ck_ago(u_hr.tdqlz),
              $sformatf("DQ changed at no CK edge + tCKD (%0d) / tCKDI (%0d) / tDQLZ (%0d)", u_hr.tckd,
                        u_hr.tckdi, u_hr.tdqlz));
    end
  end
  always @(posedge d_dq_oe) begin
    tim_chk(ck_ago(u_hr.tdqlz), $sformatf("DQ driven at no CK edge + tDQLZ (%0d)", u_hr.tdqlz));
  end
  always @(negedge d_dq_oe) begin
    tim_chk($time - mcs_rise == u_hr.toz || $time - mrst_fall == 1,
            $sformatf("DQ released %0d ps after CS# rose (tOZ %0d)", $time - mcs_rise, u_hr.toz));
  end

  task automatic draw_check();
    longint a, b;
    a = u_hr.tckd - u_hr.tckds;
    b = u_hr.tckdi - u_hr.tckds;
    if (u_hr.tdsv < 1 || u_hr.tdsv > 5000) error($sformatf("tDSV %0d ps outside 0 .. 5 ns", u_hr.tdsv));
    if (u_hr.tckds < 1000 || u_hr.tckds > 5000) error($sformatf("tCKDS %0d ps outside 1 .. 5 ns", u_hr.tckds));
    if (u_hr.tckd < 1000 || u_hr.tckd > 5000) error($sformatf("tCKD %0d ps outside 1 .. 5 ns", u_hr.tckd));
    if (u_hr.tckdi < 0 || u_hr.tckdi > 4200 || u_hr.tckdi > u_hr.tckd) begin
      error($sformatf("tCKDI %0d ps outside 0 .. 4.2 ns or after tCKD", u_hr.tckdi));
    end
    if (a < -400 || a > 400) error($sformatf("tCKD - tCKDS = %0d ps (tDSS: +-0.4 ns)", a));
    if (b < -400 || b > 400) error($sformatf("tCKDI - tCKDS = %0d ps (tDSH: +-0.4 ns)", b));
    if (u_hr.tckdsr < 1000 || u_hr.tckdsr > 5500) error($sformatf("tCKDSR %0d ps outside 1 .. 5.5 ns", u_hr.tckdsr));
    if (u_hr.tdqlz < 0 || u_hr.tdqlz > 1000) error($sformatf("tDQLZ %0d ps outside 0 .. 1 ns", u_hr.tdqlz));
    if (u_hr.tdsz < u_hr.tckds || u_hr.tdsz > 5000) error($sformatf("tDSZ %0d ps outside tCKDS .. 5 ns", u_hr.tdsz));
    if (u_hr.toz < u_hr.tckd || u_hr.toz > 5000) error($sformatf("tOZ %0d ps outside tCKD .. 5 ns", u_hr.toz));
  endtask

  // =============================================================== random
  int unsigned trng = 1;
  function automatic int unsigned trnd();
    trng ^= trng << 13;
    trng ^= trng >> 17;
    trng ^= trng << 5;
    return trng;
  endfunction

  // ============================================================ the host
  // configuration the host believes in (follows its CR0 writes)
  logic [15:0] cr0_h = Cr0Def;
  int          lat = 7;
  bit          fixed = 1'b1;
  bit          ls_en = 1'b0;          // shifters enabled (OE# low) between transactions
  // schedule knobs (working spec 5)
  int rdir_lead = 2, oe_pre = 1, rdir_tail = 1, oe_post = 1, rw_dir = 5, rw_oe = 6, lat_smp = 4;
  // read aligner armed at t_D - arm_lead: later than the drop of a 2x RWDS
  // latency level after f3 (it reaches the IDDR outputs up to ~8.3 cycles
  // after t = 0 on the card: with L = 3, D - 2 = 7 catches it as a false
  // {B 0, A 1} start), earlier than word 0 (>= t_D + 2.2 cycles)
  int arm_lead = 0;
  // fault injection (negative tests)
  bit          f_dq_hold = 1'b0;      // read: DQ kept driven, DIR (DQ) never to read
  bit          f_rwds_ca = 1'b0;      // DIR (RWDS) to write from t = 1, RWDS driven from t = 2
  bit          f_pre_high = 1'b0;     // memory write: RWDS high instead of the low preamble
  logic [47:0] ca_xor = '0;           // CA bits flipped

  function automatic int lat_of(logic [3:0] code);
    unique case (code)
      4'b1110: return 3;
      4'b1111: return 4;
      4'b0000: return 5;
      4'b0001: return 6;
      default: return 7;
    endcase
  endfunction

  function automatic void host_cr0(logic [15:0] v);
    cr0_h = v;
    lat   = lat_of(v[7:4]);
    fixed = v[3];
  endfunction

  // the transaction being run
  bit          tx_rd, tx_reg, tx_lin;
  logic [31:0] tx_waddr;
  int          tx_n;
  logic [15:0] tx_regval;
  bit          tx_regwr, tx_memwr, tx_lat2x;
  logic [47:0] tx_ca;
  int          tx_d, tx_e, tx_rdoff;
  logic [15:0] wr_q [$];              // write words {A, B}
  logic [1:0]  wm_q [$];              // masks {A, B}, 1 = byte not written
  logic [15:0] rd_q [$];              // read words {A, B}
  bit          rd_ok;
  int          n_1x = 0, n_2x = 0;

  function automatic hr_io_out_t idle_v();
    hr_io_out_t v;
    v         = HR_IO_OUT_IDLE;
    v.ls_oe_n = !ls_en;
    return v;
  endfunction

  // the host's PHY register in transaction cycle t
  function automatic hr_io_out_t pv(int t);
    hr_io_out_t v;
    v = idle_v();
    if (t >= 0 && t < tx_e) v.cs_n = 1'b0;
    if (t >= 1 && t < tx_e) v.ck_en = 1'b1;
    if (t >= 1 && t <= 3) begin
      v.dq[0] = tx_ca[47 - 16 * (t - 1) -: 8];
      v.dq[1] = tx_ca[39 - 16 * (t - 1) -: 8];
    end
    if (tx_regwr) begin
      if (t == 4) begin
        v.dq[0] = tx_regval[15:8];
        v.dq[1] = tx_regval[7:0];
      end
      if (t >= -2 && t <= tx_e + rdir_tail + oe_post) v.rwds_oe = 1'b0;
      if (t >= -1 && t <= tx_e + rdir_tail) v.ls_dir_rwds = 1'b1;
    end else if (tx_memwr) begin
      if (t >= tx_d && t < tx_e) begin
        v.dq[0]   = wr_q[t - tx_d][15:8];
        v.dq[1]   = wr_q[t - tx_d][7:0];
        v.rwds[0] = wm_q[t - tx_d][1];
        v.rwds[1] = wm_q[t - tx_d][0];
      end
      if (f_pre_high && t >= rw_oe && t < tx_d) v.rwds = 2'b11;
      if (t >= -2 && t < rw_oe) v.rwds_oe = 1'b0;
      if (t >= -1 && t < rw_dir) v.ls_dir_rwds = 1'b1;
    end else begin
      if (!f_dq_hold) begin
        if (t >= tx_rdoff && t <= tx_e + rdir_tail + oe_post) v.dq_oe = 1'b0;
        if (t >= tx_rdoff + oe_pre && t <= tx_e + rdir_tail) v.ls_dir_dq = 1'b1;
      end
      if (t >= -2 && t <= tx_e + rdir_tail + oe_post) v.rwds_oe = 1'b0;
      if (t >= -1 && t <= tx_e + rdir_tail) v.ls_dir_rwds = 1'b1;
    end
    if (f_rwds_ca && t >= 1 && t <= tx_e) begin
      v.ls_dir_rwds = 1'b0;
      v.rwds_oe     = (t >= 2);
      v.rwds        = 2'b00;
    end
    return v;
  endfunction

  // ---------------------------------------------- read data (rd_clk domain)
  bit          col_arm = 1'b0, col_busy = 1'b0, col_done = 1'b0, col_err = 1'b0;
  int          col_n = 0, col_wait = 0;
  logic [15:0] col_q [$];

  always @(posedge rd_clk) begin
    if (col_arm) begin
      col_arm  = 1'b0;
      col_busy = 1'b1;
      col_done = 1'b0;
      col_err  = 1'b0;
      col_wait = 0;
      col_q.delete();
    end
    if (col_busy) begin
      if (col_q.size() == 0 && io_i.rwds != 2'b01) begin
        col_wait++;
        if (col_wait > ColTmo) begin
          col_err  = 1'b1;
          col_busy = 1'b0;
          col_done = 1'b1;
        end
      end else begin
        if (io_i.rwds != 2'b01) col_err = 1'b1;   // the strobe must toggle on every word
        col_q.push_back({io_i.dq[0], io_i.dq[1]});
        if (col_q.size() == col_n) begin
          col_busy = 1'b0;
          col_done = 1'b1;
        end
      end
    end
  end

  function automatic logic [47:0] mk_ca(bit rd, bit regsp, bit lin, logic [31:0] w);
    return {rd, regsp, lin, w[31:3], 13'd0, w[2:0]};
  endfunction

  // one transaction with the tx_* settings (and wr_q / wm_q for writes)
  task automatic run_txn();
    int t, t_last;
    bit l2;
    tx_regwr = tx_reg && !tx_rd;
    tx_memwr = !tx_reg && !tx_rd;
    tx_ca    = mk_ca(tx_rd, tx_reg, tx_lin, tx_waddr) ^ ca_xor;
    if (tx_regwr) begin
      tx_d = 4;
      tx_e = 5;
    end else begin
      tx_lat2x = fixed;                               // variable: 1x until the CA phase says
      tx_d     = (fixed ? 2 * lat : lat) + 3;
      tx_e     = tx_d + tx_n;
    end
    tx_rdoff = tx_d - rdir_lead - oe_pre;           // D1: the 1x data cycle in variable mode
    if (tx_rdoff < 4) tx_rdoff = 4;
    rd_ok = 1'b0;
    rd_q.delete();
    t = -2;
    t_last = 1 << 30;
    while (t <= t_last) begin
      @(posedge hr_clk);
      if (t == lat_smp && !tx_regwr) begin
        l2 = rwds_pad;                               // latency level of RWDS in the CA phase
        if (!quiet && l2 != u_hr.lat2x) begin
          error($sformatf("RWDS in the CA phase %0d at the FPGA, the HyperRAM chose %0dx latency", l2,
                          u_hr.lat2x ? 2 : 1));
        end
        if (fixed && !l2 && !quiet) error("fixed latency, but RWDS low in the CA phase");
        if (!fixed) begin
          tx_lat2x = l2;
          tx_d     = (l2 ? 2 * lat : lat) + 3;
          tx_e     = tx_d + tx_n;
          if (l2) n_2x++;
          else    n_1x++;
        end
      end
      // last cycle: the first idle one after every window, and the next
      // transaction's t = 0 at least CSHI cycles after t_E
      t_last = ((tx_rd || tx_regwr) ? tx_e + rdir_tail + oe_post : tx_e) + 1;
      if (t_last < tx_e + Cshi - 3) t_last = tx_e + Cshi - 3;
      if (tx_rd && t == tx_d - arm_lead) begin
        col_n   = tx_n;
        col_arm = 1'b1;
      end
      #1;
      io_o = pv(t);
      t++;
    end
    if (tx_rd) begin
      int w;
      w = 0;
      while (!col_done && w < 4 * ColTmo) begin
        @(posedge rd_clk);
        w++;
      end
      rd_ok = col_done && !col_err && col_q.size() == tx_n;
      if (col_busy) col_busy = 1'b0;               // (an expected failure)
      foreach (col_q[i]) rd_q.push_back(col_q[i]);
      if (!rd_ok && !quiet) error($sformatf("read of %0d words at %08h (%s, %0dx latency): no clean data (%0d words, strobe error %0d)",
                                            tx_n, tx_waddr, pick(tx_reg, "register", "memory"), tx_lat2x ? 2 : 1,
                                            col_q.size(), col_err));
      col_done = 1'b0;
    end
  endtask

  task automatic idle_cycles(int n);
    repeat (n) @(posedge hr_clk);
  endtask

  task automatic wait_ns(longint n);
    #(n * 1000);
  endtask

  function automatic logic [31:0] reg_waddr(int sel);
    unique case (sel)
      0:       return 32'h0000_0000;
      1:       return 32'h0000_0001;
      2:       return 32'h0000_0800;
      default: return 32'h0000_0801;
    endcase
  endfunction

  task automatic reg_read(int sel, output logic [15:0] v, output bit ok);
    tx_rd    = 1'b1;
    tx_reg   = 1'b1;
    tx_lin   = 1'b1;
    tx_waddr = reg_waddr(sel);
    tx_n     = 1;
    run_txn();
    ok = rd_ok;
    v  = (rd_q.size() != 0) ? rd_q[0] : 16'h0;
  endtask

  task automatic reg_check(int sel, logic [15:0] exp, string what);
    logic [15:0] v;
    bit          ok;
    reg_read(sel, v, ok);
    if (!ok || v !== exp) error($sformatf("%s: read %04h (ok %0d), expected %04h", what, v, ok, exp));
  endtask

  task automatic reg_write(int sel, logic [15:0] v);
    tx_rd     = 1'b0;
    tx_reg    = 1'b1;
    tx_lin    = 1'b1;
    tx_waddr  = reg_waddr(sel);
    tx_n      = 1;
    tx_regval = v;
    run_txn();
    if (sel == 2 && v[15]) host_cr0(v);
  endtask

  // ----------------------------------------------------- reference memory
  logic [7:0] ref_b [int unsigned];   // bus byte address -> byte (2n = A, 2n + 1 = B)

  // word n of a burst from s (the host's CR0): an implementation of its own
  // (hybrid: after the first group, linear from the group's base + n)
  function automatic int unsigned tb_burst(int unsigned s, int n, bit lin);
    int unsigned g, base;
    if (lin) return int'((longint'(s) + longint'(n)) % longint'(Words));
    unique case (cr0_h[1:0])
      2'b00:   g = 64;
      2'b01:   g = 32;
      2'b10:   g = 8;
      default: g = 16;
    endcase
    base = s - (s % g);
    if (cr0_h[2] || n < int'(g)) return base + (s - base + n) % g;
    return int'((longint'(base) + longint'(n)) % longint'(Words));
  endfunction

  function automatic logic [15:0] exp_word(int unsigned w);
    logic [15:0] u, v;
    u = u_hr.uninit_word(w);
    v[15:8] = (ref_b.exists(2 * w) != 0) ? ref_b[2 * w] : u[15:8];
    v[7:0]  = (ref_b.exists(2 * w + 1) != 0) ? ref_b[2 * w + 1] : u[7:0];
    return v;
  endfunction

  // memory write of wr_q / wm_q; the reference follows
  task automatic mem_write(logic [31:0] w, bit lin, int n);
    int unsigned a;
    tx_rd    = 1'b0;
    tx_reg   = 1'b0;
    tx_lin   = lin;
    tx_waddr = w;
    tx_n     = n;
    run_txn();
    for (int i = 0; i < n; i++) begin
      a = tb_burst(w % Words, i, lin);
      if (!wm_q[i][1]) ref_b[2 * a] = wr_q[i][15:8];
      if (!wm_q[i][0]) ref_b[2 * a + 1] = wr_q[i][7:0];
    end
  endtask

  // random data and masks (mask_pct: % of masked bytes)
  task automatic fill_wr(int n, int mask_pct);
    wr_q.delete();
    wm_q.delete();
    for (int i = 0; i < n; i++) begin
      bit ma, mb;
      wr_q.push_back(16'(trnd()));
      ma = (trnd() % 100) < 32'(mask_pct);
      mb = (trnd() % 100) < 32'(mask_pct);
      wm_q.push_back({ma, mb});
    end
  endtask

  task automatic mem_read(logic [31:0] w, bit lin, int n);
    tx_rd    = 1'b1;
    tx_reg   = 1'b0;
    tx_lin   = lin;
    tx_waddr = w;
    tx_n     = n;
    run_txn();
  endtask

  task automatic mem_check(logic [31:0] w, bit lin, int n, string what);
    int unsigned a;
    logic [15:0] e;
    int          bad;
    mem_read(w, lin, n);
    if (!rd_ok) return;
    bad = 0;
    for (int i = 0; i < n; i++) begin
      a = tb_burst(w % Words, i, lin);
      e = exp_word(a);
      if (rd_q[i] !== e) begin
        bad++;
        if (bad <= 4) error($sformatf("%s: word %0d (address %06h) read %04h, expected %04h", what, i, a,
                                      rd_q[i], e));
      end
    end
  endtask

  // ------------------------------------------------- read phase calibration
  task automatic ps_move(int n, bit inc);
    for (int i = 0; i < n; i++) begin
      @(posedge hr_clk);
      #1;
      ps_en  = 1'b1;
      ps_inc = inc;
      @(posedge hr_clk);
      #1;
      ps_en = 1'b0;
      do @(posedge hr_clk); while (!ps_done);
    end
  endtask

  int cal_win = 0;

  task automatic calibrate();
    int          npts, best, best_at, run, pos, tgt, delta;
    bit          pass [$];
    logic [15:0] v;
    bit          ok;
    string       map;
    npts  = int'(PsSteps / CalStp);
    quiet = 1'b1;
    map   = "";
    for (int p = 0; p < npts; p++) begin
      reg_read(0, v, ok);
      pass.push_back(ok && v == Id0);
      map = {map, pick(ok && v == Id0, "#", ".")};
      ps_move(int'(CalStp), 1'b1);
    end
    quiet = 1'b0;
    // widest cyclic run of good points, its centre
    best    = 0;
    best_at = 0;
    for (int s = 0; s < npts; s++) begin
      if (pass[s] && !pass[(s + npts - 1) % npts]) begin
        run = 0;
        while (run < npts && pass[(s + run) % npts]) run++;
        if (run > best) begin
          best    = run;
          best_at = s;
        end
      end
    end
    if (best == 0 && pass[0]) begin                // every point good
      best    = npts;
      best_at = 0;
    end
    cal_win = best;
    info($sformatf("calibration (start phase %0.0f ps, %0d steps per point): %s, window %0d points",
                   u_clk.rd_start_ps, CalStp, map, best));
    if (best < 3 || best == npts) error($sformatf("read calibration: window of %0d points", best));
    pos   = npts * int'(CalStp);                    // = a full period: back at the start phase
    tgt   = (best_at * int'(CalStp) + ((best - 1) * int'(CalStp)) / 2) % int'(PsSteps);
    delta = ((tgt - pos) % int'(PsSteps) + int'(PsSteps)) % int'(PsSteps);
    if (delta <= int'(PsSteps) / 2) ps_move(delta, 1'b1);
    else                            ps_move(int'(PsSteps) - delta, 1'b0);
    info($sformatf("read phase: %0d steps from the start (%0.0f ps after hr_clk)", u_clk.ps_phase,
                   u_clk.rd_phase_ps()));
  endtask

  // ------------------------------------------------------- write phase
  task automatic wps_move(int n, bit inc);
    for (int i = 0; i < n; i++) begin
      @(posedge hr_clk);
      #1;
      wps_en  = 1'b1;
      wps_inc = inc;
      @(posedge hr_clk);
      #1;
      wps_en = 1'b0;
      do @(posedge hr_clk); while (!wps_done);
    end
  endtask

  // ------------------------------------------------------ power, reset
  // CS# low pulse without CK (deep power down / hybrid sleep exit)
  task automatic cs_pulse(longint ns);
    int c;
    c = int'((ns * 1000 + longint'(TckPs) - 1) / longint'(TckPs));
    @(posedge hr_clk);
    #1;
    io_o      = idle_v();
    io_o.cs_n = 1'b0;
    idle_cycles(c);
    #1;
    io_o = idle_v();
    idle_cycles(Cshi + 2);
  endtask

  task automatic hw_reset(longint low_ns, longint wait_ns_);
    @(posedge hr_clk);
    #1;
    io_o       = idle_v();
    io_o.rst_n = 1'b0;
    idle_cycles(int'((low_ns * 1000 + longint'(TckPs) - 1) / longint'(TckPs)));
    #1;
    io_o = idle_v();
    idle_cycles(int'((wait_ns_ * 1000 + longint'(TckPs) - 1) / longint'(TckPs)));
  endtask

  // ---------------------------------------------------------- traffic
  int unsigned n_rand = 60;

  task automatic traffic(string what, int n_txn);
    int unsigned w, n;
    bit          lin;
    for (int i = 0; i < n_txn; i++) begin
      lin = (trnd() % 4) != 0;
      n   = 1 + trnd() % 24;
      w   = trnd() % 32'h2000;
      if (trnd() % 2 == 0) begin
        fill_wr(n, 25);
        mem_write(w, lin, n);
      end else begin
        mem_check(w, lin, n, $sformatf("%s read %0d", what, i));
      end
    end
  endtask

  // the longest burst within tCSM (1 us)
  function automatic int max_burst();
    int d;
    d = (fixed ? 2 * lat : lat) + 3;
    return 1_000_000 / int'(TckPs) - d - 2;
  endfunction

  // ---------------------------------------- data sheet table 11 sequences
  // word values: their own address (low 16 bits ^ 5A00)
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [15:0] tag_of(int unsigned a);   // (a[15:0] only)
    return 16'(a) ^ 16'h5A00;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // a burst of the given wrap configuration from s; the expected word
  // addresses in segments [lo, hi] (inclusive)
  task automatic t11(string what, logic [2:0] cfg, bit lin, int unsigned s, int segs [6]);
    int unsigned exp_a [$];
    int          n, bad;
    for (int i = 0; i < 6; i += 2) begin
      if (segs[i] >= 0) begin
        for (int a = segs[i]; a <= segs[i + 1]; a++) exp_a.push_back(a);
      end
    end
    n = exp_a.size();
    reg_write(2, {cr0_h[15:3], cfg});
    mem_read(s, lin, n);
    if (!rd_ok) return;
    bad = 0;
    for (int i = 0; i < n; i++) begin
      if (rd_q[i] !== tag_of(exp_a[i])) begin
        bad++;
        if (bad <= 3) error($sformatf("table 11 %s: word %0d read %04h, expected address %02h", what, i,
                                      rd_q[i], exp_a[i]));
      end
    end
  endtask

  // =========================================================== loopback
  // a second pad wrapper in Loopback mode: the emulator data (a counter) on
  // the DQ / RWDS ODDRs, read back by the IDDRs on a capture clock at the
  // centre of the eye (hr_clk + PadOut + PadIn)
  logic            lb_rd_clk = 1'b0, lb_en = 1'b0;
  logic [1:0][7:0] lb_dq = '0;
  logic [1:0]      lb_rwds = 2'b01;
  hr_io_in_t       lb_in;
  logic            lb_dq_oe, lb_rwds_oe, lb_ls_oe_n, lb_ls_dir_dq, lb_ls_dir_rwds;
  logic [7:0]      lb_dq_pin;
  logic            lb_rwds_pin, lb_pad, lb_ck_p, lb_ck_n, lb_cs_n, lb_rst_n;
  always @(hr_clk) lb_rd_clk <= #(2300) hr_clk;

  bow_hyperram_io_sim #(.Loopback(1'b1), .HasLs(1'b1)) u_io_lb (
    .clk_i         (hr_clk),
    .wclk_i        (wclk),
    .rd_clk_i      (lb_rd_clk),
    .io_o_i        (HR_IO_OUT_IDLE),
    .io_i_o        (lb_in),
    .rwds_pad_o    (lb_pad),
    .lb_dq_en_i    (lb_en),
    .lb_dq_i       (lb_dq),
    .lb_rwds_en_i  (lb_en),
    .lb_rwds_i     (lb_rwds),
    .ck_p_o        (lb_ck_p),
    .ck_n_o        (lb_ck_n),
    .cs_n_o        (lb_cs_n),
    .rst_n_o       (lb_rst_n),
    .dq_o          (lb_dq_pin),
    .dq_oe_o       (lb_dq_oe),
    .dq_i          (8'hFF),
    .rwds_o        (lb_rwds_pin),
    .rwds_oe_o     (lb_rwds_oe),
    .rwds_i        (1'b1),
    .ls_oe_n_o     (lb_ls_oe_n),
    .ls_dir_dq_o   (lb_ls_dir_dq),
    .ls_dir_rwds_o (lb_ls_dir_rwds)
  );

  // checker of the read back stream: consecutive counter words; the RWDS
  // wire (rwds_pad_o) toggles with the emulator's strobe pattern
  int         seen_lb = 0, lb_pad_edges = 0;
  logic [7:0] lb_prev = '0;
  always @(lb_pad) if (lb_en) lb_pad_edges++;
  always @(posedge lb_rd_clk) begin
    if (lb_en && lb_in.rwds == 2'b01 && lb_in.dq[1] == ~lb_in.dq[0]) begin
      if (seen_lb != 0 && lb_in.dq[0] != lb_prev + 8'd1) seen_lb = 0;
      seen_lb++;
      lb_prev = lb_in.dq[0];
    end
  end

  task automatic loopback_test();
    // emulator data: A = cycle counter, B = ~A, RWDS = {B 0, A 1}
    seen_lb = 0;
    for (int c = 0; c < 40; c++) begin
      @(posedge hr_clk);
      #1;
      lb_en    = 1'b1;
      lb_dq[0] = 8'(c);
      lb_dq[1] = ~8'(c);
    end
    @(posedge hr_clk);
    #1;
    lb_en = 1'b0;
    if (seen_lb < 30) error($sformatf("loopback: %0d consecutive emulator words read back (>= 30 expected)", seen_lb));
    if (!lb_dq_oe || !lb_rwds_oe || !lb_ls_oe_n || lb_ls_dir_dq || lb_ls_dir_rwds) begin
      error("loopback: pads not driven or shifter controls not at their constants");
    end
    if (!lb_cs_n || !lb_rst_n || lb_ck_p || !lb_ck_n) error("loopback: CS# / RESET# / CK not idle (PHY idle)");
    if (lb_pad_edges < 60) error($sformatf("loopback: RWDS wire toggled %0d times (>= 60 expected)", lb_pad_edges));
    if (^{lb_dq_pin, lb_rwds_pin} === 1'bx) error("loopback: DQ / RWDS pins unknown");
    info($sformatf("loopback pads: %0d consecutive emulator words read back", seen_lb));
  endtask

  // ================================================================= main
  longint tmo_ms = 20;

  initial begin : watchdog
    if ($test$plusargs("WAVES")) begin
      $dumpfile("waves.fst");
      $dumpvars(0, tb_hyperram_model);
    end
    void'($value$plusargs("TIMEOUT_MS=%d", tmo_ms));
    #(tmo_ms * 1_000_000_000);
    $display("tb_hyperram_model: FAIL (simulated time limit of %0d ms)", tmo_ms);
    $finish;
  end

  initial begin : main
    int unsigned sd;
    logic [15:0] v, cr1_now;
    bit          ok;
    int          n, nl;
    int          total;
    longint      t_start;

    sd = 1;
    void'($value$plusargs("SEED=%d", sd));
    void'($value$plusargs("NRAND=%d", n_rand));
    trng = sd ^ 32'hC2B2_AE35;
    if (trng == 0) trng = 1;
    info($sformatf("%s board, CK %0d ps, %0d phase steps, fast latency code %b, seed %0d, CSHI %0d",
                   pick(LevelShift, "TXV0108 card", "direct"), TckPs, PsSteps, FastLatCode, sd, Cshi));

    // ------------------------------------------------- 1 clocks, power-up
    ck_on = 1'b1;
    wait (locked);
    idle_cycles(4);
    #1;
    ls_en = 1'b1;
    io_o  = idle_v();
    idle_cycles(8);

    t_begin();
    quiet = 1'b1;
    wait_ns(20_000);
    reg_read(0, v, ok);                              // during tVCS: ignored
    quiet = 1'b0;
    if (ok) error("ID0 read during tVCS answered");
    cnt_exp[CPwr] = 1;
    t_end("access during tVCS");

    t_start = $time;
    while ($time < 151_000_000) idle_cycles(100);
    info($sformatf("tVCS over (%0d us idle)", ($time - t_start) / 1_000_000));

    // ------------------------------------------------- 2 calibration, IDs
    t_begin();
    calibrate();
    reg_check(0, Id0, "ID0");
    reg_check(1, Id1, "ID1");
    reg_check(2, Cr0Def, "CR0 reset value");
    reg_check(3, Cr1Def, "CR1 reset value");
    t_end("calibration, ID0 / ID1 / CR0 / CR1 reset values");

    // ------------------------------------------- 3 default latency (7, 2x)
    t_begin();
    fill_wr(8, 0);
    mem_write(32'h100, 1'b1, 8);
    fill_wr(8, 40);
    mem_write(32'h104, 1'b1, 8);                     // overlapping, byte masks
    wr_q.delete();
    wm_q.delete();
    wr_q.push_back(16'hA1B2);
    wm_q.push_back(2'b10);                           // byte A masked
    mem_write(32'h120, 1'b1, 1);
    mem_check(32'h0FC, 1'b1, 24, "default latency");
    mem_check(32'h120, 1'b1, 1, "single word, byte A masked");
    if (u_hr.written_mask(32'h120) != 2'b01) error("word 120: only byte B written expected");
    t_end("memory at the default latency (7, fixed)");

    // ----------------------------------------- 4 fast latency, fixed
    t_begin();
    reg_write(2, {Cr0Def[15:8], FastLatCode, Cr0Def[3:0]});
    reg_check(2, {Cr0Def[15:8], FastLatCode, Cr0Def[3:0]}, "CR0 latency");
    if (u_hr.cr0 != cr0_h) error($sformatf("model CR0 %04h, host %04h", u_hr.cr0, cr0_h));
    mem_check(32'h0FC, 1'b1, 24, "fast latency re-read");
    t_end($sformatf("CR0 latency %0d clocks, fixed", lat));

    // data sheet table 11: tags at 0x000 .. 0x13F
    t_begin();
    for (int b = 0; b < 5; b++) begin
      wr_q.delete();
      wm_q.delete();
      for (int i = 0; i < 64; i++) begin
        wr_q.push_back(tag_of(64 * b + i));
        wm_q.push_back(2'b00);
      end
      mem_write(64 * b, 1'b1, 64);
    end
    t11("hybrid 128 @03", 3'b000, 1'b0, 'h03, '{'h03, 'h3F, 'h00, 'h02, 'h40, 'h51});
    t11("hybrid 64 @03",  3'b001, 1'b0, 'h03, '{'h03, 'h1F, 'h00, 'h02, 'h20, 'h31});
    t11("hybrid 64 @2E",  3'b001, 1'b0, 'h2E, '{'h2E, 'h3F, 'h20, 'h2D, 'h40, 'h51});
    t11("hybrid 16 @02",  3'b010, 1'b0, 'h02, '{'h02, 'h07, 'h00, 'h01, 'h08, 'h12});
    t11("hybrid 16 @0C",  3'b010, 1'b0, 'h0C, '{'h0C, 'h0F, 'h08, 'h0B, 'h10, 'h1A});
    t11("hybrid 32 @0A",  3'b011, 1'b0, 'h0A, '{'h0A, 'h0F, 'h00, 'h09, 'h10, 'h1A});
    t11("wrap 64 @03",    3'b101, 1'b0, 'h03, '{'h03, 'h1F, 'h00, 'h02, 'h03, 'h08});
    t11("wrap 64 @2E",    3'b101, 1'b0, 'h2E, '{'h2E, 'h3F, 'h20, 'h2D, 'h2E, 'h33});
    t11("wrap 16 @02",    3'b110, 1'b0, 'h02, '{'h02, 'h07, 'h00, 'h01, 'h02, 'h07});
    t11("wrap 16 @0C",    3'b110, 1'b0, 'h0C, '{'h0C, 'h0F, 'h08, 'h0B, 'h0C, 'h0F});
    t11("wrap 32 @0A",    3'b111, 1'b0, 'h0A, '{'h0A, 'h0F, 'h00, 'h09, 'h0A, 'h0D});
    t11("wrap 128 @41",   3'b100, 1'b0, 'h41, '{'h41, 'h7F, 'h40, 'h40, 'h41, 'h44});
    t11("linear @03",     3'b111, 1'b1, 'h03, '{'h03, 'h18, -1, -1, -1, -1});
    t11("hybrid 128 @C5 (CR0 back to legacy 32 B after)", 3'b000, 1'b0, 'hC5,
        '{'hC5, 'hFF, 'hC0, 'hC4, 'h100, 'h103});
    reg_write(2, {cr0_h[15:3], 3'b111});
    t_end("burst order of the data sheet's table 11");

    // random traffic over all wrap configurations
    t_begin();
    for (int c = 0; c < 8; c++) begin
      reg_write(2, {cr0_h[15:3], 3'(c)});
      traffic($sformatf("CR0[2:0] %b", 3'(c)), int'(n_rand) / 4);
    end
    reg_write(2, {cr0_h[15:3], 3'b111});
    n = max_burst();
    fill_wr(n, 10);
    mem_write(32'h3000, 1'b1, n);
    mem_check(32'h3000, 1'b1, n, "longest burst");
    fill_wr(10, 10);
    mem_write(Words - 5, 1'b1, 10);                  // across the end of the array
    mem_check(Words - 5, 1'b1, 10, "end of the array");
    if (wm_q[5] != 2'b11 && !u_hr.was_written(0)) error("linear burst across the end: word 0 not written");
    t_end($sformatf("random traffic (fixed latency), longest burst %0d words, end of the array", n));

    // ------------------------------------------------ 5 variable latency
    t_begin();
    reg_write(2, {cr0_h[15:4], 1'b0, cr0_h[2:0]});
    reg_check(2, cr0_h, "CR0 variable latency");
    traffic("variable latency", int'(n_rand));
    reg_write(2, {cr0_h[15:4], 1'b0, 3'b000});       // hybrid 128 B
    traffic("variable latency, hybrid 128", int'(n_rand) / 2);
    reg_write(2, {cr0_h[15:4], 1'b0, 3'b111});
    info($sformatf("variable latency: %0d transactions 1x, %0d 2x (model: %0d refresh collisions)", n_1x,
                   n_2x, u_hr.n_refresh));
    if (n_1x == 0 || n_2x == 0) error("variable latency: 1x and 2x transactions expected");
    reg_write(2, {cr0_h[15:4], 1'b1, cr0_h[2:0]});   // fixed again
    t_end("variable latency");

    // ------------------------------------------------ 6 write phase
    if (!LevelShift) begin
      t_begin();
      nl = int'(PsSteps) / 7;
      wps_move(nl, 1'b1);
      traffic("write phase +", 16);
      wps_move(2 * nl, 1'b0);
      traffic("write phase -", 16);
      wps_move(nl, 1'b1);
      if (u_clk.wps_phase != 0) error($sformatf("write phase %0d after the moves", u_clk.wps_phase));
      t_end($sformatf("write phase +-%0d steps", nl));
    end

    // ------------------------------------------------ 7 negative tests
    t_begin();
    ca_xor = 48'h0000_0000_0008;                     // CA[3] (reserved)
    mem_read(32'h100, 1'b1, 2);
    ca_xor = '0;
    cnt_exp[CCa] = 1;
    t_end("CA[15:3] reserved bit set");

    t_begin();
    tx_rd    = 1'b1;
    tx_reg   = 1'b1;
    tx_lin   = 1'b1;
    tx_waddr = reg_waddr(0);
    tx_n     = 2;
    run_txn();
    if (!rd_ok || rd_q.size() == 0) error("two-word ID0 read: no data");
    else if (rd_q[0] !== Id0) error($sformatf("two-word ID0 read: first word %04h", rd_q[0]));
    cnt_exp[CReg] = 1;
    t_end("register read of two words");

    t_begin();
    reg_write(0, 16'h1234);
    reg_check(0, Id0, "ID0 after a write");
    cnt_exp[CReg] = 1;
    t_end("write to the read-only ID0");

    t_begin();
    fill_wr(2, 0);
    mem_write(Words + 32'h40, 1'b1, 2);              // wraps to 0x40 in the model
    mem_check(32'h40, 1'b1, 2, "address beyond the array");
    cnt_exp[CRange] = 1;
    t_end("memory address beyond MemBytes");

    t_begin();
    v = cr0_h;
    reg_write(2, {cr0_h[15:8], 4'b1110, cr0_h[3:0]});   // 3 clocks: up to 85 MHz
    mem_check(32'h100, 1'b1, 4, "latency 3");
    reg_write(2, v);
    cnt_exp[CLatf] = 1;
    t_end("initial latency too short for the CK (3 clocks)");

    t_begin();
    n = 1_000_000 / int'(TckPs);                     // CS# low > 1 us
    mem_check(32'h0, 1'b1, n, "tCSM violation");
    cnt_exp[CTcsm] = 1;
    t_end($sformatf("tCSM: a read of %0d words", n));

    t_begin();
    f_pre_high = 1'b1;
    fill_wr(2, 0);
    mem_write(32'h200, 1'b1, 2);
    f_pre_high = 1'b0;
    mem_check(32'h200, 1'b1, 2, "after the preamble test");
    cnt_exp[CPre] = 1;
    t_end("write mask preamble driven high");

    t_begin();
    f_dq_hold = 1'b1;
    quiet     = 1'b1;
    mem_read(32'h100, 1'b1, 2);
    quiet     = 1'b0;
    f_dq_hold = 1'b0;
    cnt_exp[CContDq]  = 1;
    cnt_exp[CBrdCont] = 1;
    t_end("DQ contention (the host keeps DQ in a read)");

    t_begin();
    reg_read(3, cr1_now, ok);
    f_rwds_ca = 1'b1;
    reg_write(3, cr1_now);
    f_rwds_ca = 1'b0;
    cnt_exp[CContRw]    = 1;
    cnt_exp[CRegwrRwds] = 1;
    cnt_exp[CBrdCont]   = 1;
    t_end("RWDS driven by the host in a register write");

    t_begin();
    @(posedge hr_clk);
    #1;
    cs_hold = 1'b1;                                  // released 2 ns before the first CK edge
    css_arm = 1'b1;
    reg_check(0, Id0, "ID0 with a short tCSS");
    if (cs_hold || css_arm) error("tCSS test hook not released");
    cnt_exp[CTcss] = 1;
    t_end("tCSS: CS# falls 2 ns before CK");

    t_begin();
    glitch_off = -200;                               // DQ0 (CA[24]) flips 200 ps before r2: CR0 is read
    glitch_arm = 1'b1;
    reg_read(0, v, ok);
    if (glitch_arm) error("tIS test hook not run");
    if (!ok || v !== cr0_h) error($sformatf("tIS test: read %04h, expected CR0 %04h (CA[24] flipped)", v, cr0_h));
    cnt_exp[CTis] = 1;
    t_end("tIS: a DQ bit 200 ps before the CK edge");

    t_begin();
    glitch_off = 200;                                // 200 ps after r2: the CA is right, the hold is not
    glitch_arm = 1'b1;
    reg_check(0, Id0, "ID0 with a short hold");
    if (glitch_arm) error("tIH test hook not run");
    cnt_exp[CTih] = 1;
    t_end("tIH: a DQ bit 200 ps after the CK edge");

    t_begin();
    fill_wr(1, 0);
    mem_write(32'h210, 1'b1, 1);
    cslo_ps  = 4 * longint'(TckPs) - 5000;           // the next CS# fall 4 cycles after the rise
    cslo_arm = 1'b1;
    fill_wr(1, 0);
    mem_write(32'h211, 1'b1, 1);                     // its CS# rise delayed: high for 5 ns
    fill_wr(1, 0);
    mem_write(32'h212, 1'b1, 1);
    if (cslo_arm) error("tCSHI test hook not run");
    mem_check(32'h210, 1'b1, 3, "tCSHI / tRWR test");
    cnt_exp[CTcshi] = 1;
    cnt_exp[CTrwr]  = 1;
    t_end("tCSHI / tRWR: CS# high for 5 ns");

    t_begin();
    @(posedge hr_clk);
    #1;
    ck_glitch = 1'b1;                                // CK high at the balls until 2 ns after CS# falls
    ckg_arm   = 1'b1;
    reg_check(1, Id1, "ID1 started with CK high");
    if (ckg_arm || ck_glitch) error("CK test hook not run");
    cnt_exp[CCkcs] = 1;
    t_end("transaction started with CK high");

    // write phase sweep hook (wr_relax): a violated CA edge makes the device
    // ignore the transaction, a violated data edge stores the word inverted;
    // both counted in n_relaxed, no error class changes
    t_begin();
    begin
      int          nr;
      logic [15:0] old0, d0;
      fill_wr(2, 0);
      mem_write(32'h240, 1'b1, 2);
      old0 = u_hr.peek(32'h240);
      nr   = u_hr.n_relaxed;
      u_hr.wr_relax = 1'b1;
      glitch_off = -200;                             // CA byte 2: the write is ignored
      glitch_arm = 1'b1;
      tx_rd    = 1'b0;
      tx_reg   = 1'b0;
      tx_lin   = 1'b1;
      tx_waddr = 32'h240;
      tx_n     = 2;
      wr_q[0]  = ~wr_q[0];
      run_txn();
      if (u_hr.peek(32'h240) !== old0) error("relax: a write with a violated CA edge was executed");
      if (u_hr.n_relaxed != nr + 1) error($sformatf("relax: %0d relaxed events, 1 expected", u_hr.n_relaxed - nr));
      d0 = wr_q[0];
      glitch_off = ((fixed ? 2 * lat : lat) + 3 - 2) * int'(TckPs) - 200;   // byte A of word 0
      glitch_arm = 1'b1;
      run_txn();
      u_hr.wr_relax = 1'b0;
      d0 = ~(d0 ^ 16'h0100);                       // DQ0 flipped at the pin (byte A), then stored inverted
      if (u_hr.peek(32'h240) !== d0) error($sformatf("relax: word with a violated data edge %04h, %04h expected",
                                                     u_hr.peek(32'h240), d0));
      if (u_hr.n_relaxed != nr + 2) error($sformatf("relax: %0d relaxed events, 2 expected", u_hr.n_relaxed - nr));
      ref_b[2 * 32'h240]     = d0[15:8];           // the reference follows the device
      ref_b[2 * 32'h240 + 1] = d0[7:0];
      ref_b[2 * 32'h241]     = wr_q[1][15:8];
      ref_b[2 * 32'h241 + 1] = wr_q[1][7:0];
    end
    t_end("wr_relax: ignored command, inverted word");

    // ------------------------------------------------ 8 sleep, reset
    t_begin();
    fill_wr(16, 0);
    mem_write(32'h5000, 1'b1, 16);
    reg_read(3, cr1_now, ok);
    reg_write(3, cr1_now | 16'h0020);                // hybrid sleep
    if (u_hr.pstate != 2) error("hybrid sleep not entered");
    wait_ns(3_500);
    cs_pulse(100);                                   // exit (tCSHS 60 .. 3000 ns)
    quiet = 1'b1;
    reg_read(3, v, ok);                              // during tEXTHS: ignored
    quiet = 1'b0;
    if (ok) error("CR1 read during tEXTHS answered");
    wait_ns(100_500);
    reg_check(3, cr1_now, "CR1 after the hybrid sleep exit");
    mem_check(32'h5000, 1'b1, 16, "data after hybrid sleep");
    cnt_exp[CPwr] = 1;
    t_end("hybrid sleep: data kept, CR1[5] cleared, access during tEXTHS refused");

    t_begin();
    hw_reset(250, 250);
    host_cr0(Cr0Def);
    reg_check(2, Cr0Def, "CR0 after a hardware reset");
    if (u_hr.was_written(32'h5000)) error("data kept over a hardware reset (ResetLosesData)");
    ref_b.delete();
    mem_check(32'h5000, 1'b1, 4, "after a hardware reset (uninitialised)");
    t_end("hardware reset: registers default, data lost");

    t_begin();
    fill_wr(8, 0);
    mem_write(32'h6000, 1'b1, 8);
    reg_write(2, {1'b0, cr0_h[14:0]});              // deep power down
    if (u_hr.pstate != 1) error("deep power down not entered");
    wait_ns(3_500);
    cs_pulse(300);                                   // exit (tCSDPD 200 .. 3000 ns)
    wait_ns(150_500);
    host_cr0(Cr0Def);
    reg_check(2, Cr0Def, "CR0 after deep power down");
    ref_b.delete();
    mem_check(32'h6000, 1'b1, 8, "after deep power down (uninitialised)");
    if (u_hr.was_written(32'h6000)) error("data kept over deep power down");
    t_end("deep power down: registers default, data lost");

    // ------------------------------------------------ 9 loopback pads
    loopback_test();

    // ------------------------------------------------ 10 end
    idle_cycles(50);
    for (int i = 0; i < NCnt; i++) begin
      if (cnt_now(i) != cnt_tot[i]) begin
        error($sformatf("%s: %0d in total, %0d expected", cnt_name[i], cnt_now(i), cnt_tot[i]));
      end
    end
    if (u_hr.errors != cnt_now(CTcshi) + cnt_now(CTrwr) + cnt_now(CTcss) + cnt_now(CTcsh) +
                      cnt_now(CCkcs) + cnt_now(CTcsm) + cnt_now(CTck) + cnt_now(CTckhp) +
                      cnt_now(CLatf) + cnt_now(CTis) + cnt_now(CTih) + cnt_now(CDrv) + cnt_now(CPre) +
                      cnt_now(CContDq) + cnt_now(CContRw) + cnt_now(CRegwrRwds) + cnt_now(CCa) +
                      cnt_now(CReg) + cnt_now(CRange) + cnt_now(CPwr) + cnt_now(CRst)) begin
      error("the model's errors total is not the sum of its classes");
    end
    if (u_clk.ps_ignored != 0 || u_clk.wps_ignored != 0) error("phase steps ignored");
    draw_check();
    if (n_tim < 1000) error($sformatf("only %0d model output edges checked", n_tim));
    if (n_pin < 10000) error($sformatf("only %0d pad cycles checked", n_pin));
    info($sformatf("model: %0d transactions, %0d / %0d words read / written, %0d uninitialised words read, %0d output edges timed, board floats on the HyperRAM side %0d (information)",
                   u_hr.n_txn, u_hr.n_words_rd, u_hr.n_words_wr, u_hr.info_uninit, n_tim, u_brd.floats_a));
    info($sformatf("pad wrapper: %0d cycles checked against the pin contract", n_pin));
    total = tb_errs;
    $display("tb_hyperram_model: %s (%0d errors; model errors %0d as expected, calibration window %0d / %0d) at %0t ps",
             pick(total == 0, "PASS", "FAIL"), total, u_hr.errors, cal_win, int'(PsSteps / CalStp), $time);
    $finish;
  end

endmodule
/* verilator lint_on BLKSEQ */
