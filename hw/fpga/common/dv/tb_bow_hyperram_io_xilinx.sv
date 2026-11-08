// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Pin level test of the HyperRAM pads and clocks on UltraScale+ (Vivado
// simulator with the unisim models, `make -C hw/fpga/common/dv test-hr-io`):
//
//   random io_o / lb_* bundles -> bow_hyperram_io_xilinx -> pads <-> testbench "HyperRAM"
//   (PHY register delay LAUNCH)   (ODDRE1, IDDRE1, IOBUF,         (drives DQ / RWDS
//                                  OBUF, T flops)                  for reads)
//   clocked by bow_hyperram_clk_xusp (two MMCME4_ADV: hr_clk at 270 deg,
//   hr_wclk = hr_clk + T/4 and hr_rd_clk with fine phase shift, 100 MHz from
//   the 100 MHz oscillator, 672 steps per CK: the MPS4 configuration), checked
//   against the pin timing contract of bow_hyperram_pkg (T = 10 ns; "PHY
//   cycle j" = the hr_clk cycle in which io_o holds a value, its pin cycle
//   j+1 = the next hr_clk cycle).
//
// Checks:
//  * values in the middle and near both ends of every window: CK_P = ck_en in
//    the first half of pin cycle j+1, 0 in the second half, CK_N the
//    complement; CS#, RESET#, LS OE#, DIR_DQ, DIR_RWDS = value of PHY cycle j
//    during pin cycle j+1 (HasLs = 0 or Loopback = 1: OE# 1, DIR 0
//    constants); DQ / RWDS byte A on [(j+0.75)T, (j+1.25)T), byte B on
//    [(j+1.25)T, (j+1.75)T), both delayed by the write phase; drive state of
//    DQ / RWDS = dq_oe / rwds_oe of PHY cycle j during pin cycle j+1;
//  * every pin edge at its allowed phase after the hr_clk rising edge (+ the
//    ODDRE1 C -> Q of the model): CK_P rises at 0 and falls at T/2 (CK_N the
//    other way round, CK_N = ~CK_P at every instant), CS# / RESET# / LS at 0,
//    DQ / RWDS data at T/4 and 3T/4 + write phase, DQ / RWDS drivers on / off
//    at 0 (T flops on hr_clk);
//  * idle levels before any clock edge, during GSR and after it, before lock
//    (the ODDRE1 SRVALs: CS#, CK_N, RESET#, OE# 1; CK_P, DIR, DQ, RWDS 0;
//    DQ / RWDS released by the T flops until the first hr_clk edge, driven at
//    SRVAL in loopback); from configuration to lock no pin moves except the
//    DQ / RWDS drivers turning on at an hr_clk edge (the T flops take dq_oe =
//    rwds_oe = 1 of HR_IO_OUT_IDLE: the MMCM model pulses its outputs once
//    5 ns after time 0 and runs before LOCKED, and the RTL T flops, unlike
//    the FDREs of a netlist, do not wait for the end of GSR);
//  * read capture: io_i.dq[0] / rwds[0] after rd_clk rising edge k+1 (and
//    still at edge k+2, where the PHY's register takes them) = the pad at
//    rising edge k, [1] = the pad at the following falling edge, for every
//    sample whose pad level is known and stable within 20 ps of the edge. The
//    testbench drives DQ / RWDS (wrapper released, no contention) while the
//    read phase moves by 4 x 97 steps up and 2 x 97 down; the data the wrapper
//    drives itself (written data, loopback emulator data) come back through
//    the IOBs and IDDRs as predicted from the PHY history (read-back check);
//  * rwds_pad_o = the RWDS pad level;
//  * write phase +T/4, -T/4, +17 steps, back to 0 (random traffic at each):
//    DQ / RWDS move by the phase, CK / CS# / RESET# / LS do not (hr_clk keeps
//    its phase to the oscillator); hr_wclk - hr_clk = T/4 + write phase;
//  * clocks: periods T, hr_wclk = hr_clk + T/4 at lock, read steps move
//    hr_rd_clk only, write steps hr_wclk only (T / 672 per step), PSDONE a one
//    cycle pulse 12 hr_clk cycles after PSEN on the stepped port only, every
//    high / low phase T/2 +- 40 ps while stepping, locked_o stays high and is
//    only ever high while all three clocks run; rst_i returns both phases to
//    0; so does a loss of lock of MMCM_R alone or MMCM_H alone (its LOCKED
//    forced low: locked_o stays low, the lock-loss reset restarts both MMCMs)
//    and of both (oscillator stopped for 5 us);
//  * Loopback = 1: DQ / RWDS always driven, lb_dq / lb_rwds on the pads while
//    lb_dq_en / lb_rwds_en (independent), read back through the IOBs and
//    IDDRs at every read phase of the sweep.
// The PHY register -> ODDR path delay LAUNCH is drawn every cycle in
// [T/4 + 0.1, T/2 - 0.1] ns: the DQ / RWDS ODDRs then take the value of their
// cycle over the whole write phase range of the bow_hyperram_pkg contract
// (|w| <= T/4; bow_hyperram_ctrl uses +-3T/16 of it, the range the board XDC
// times these paths for). The pad wrapper parameters are parameters of this
// testbench (xelab -generic_top, see the Makefile configurations); the random
// traffic comes from $urandom (xsim -sv_seed).
// The test prints "tb_bow_hyperram_io_xilinx: PASS" or "... FAIL (<n> errors)".

`timescale 1ns/1ps

module tb_bow_hyperram_io_xilinx import bow_hyperram_pkg::*; #(
  parameter bit Loopback = 1'b0,
  parameter bit HasLs    = 1'b1
);
  localparam real T   = 10.0;
  localparam int  PS  = 672;      // fine phase steps per CK (56 * HrDivide)
  localparam int  WQ  = PS / 4;   // write phase limit (+-T/4)
  localparam real D   = 0.1;      // ODDRE1 C -> Q of the unisim model
  localparam real TOL = 0.004;    // edge time tolerance (the model rounds to 1 ps)
  localparam real E   = 0.03;     // window end checks: this far inside the window
  localparam real G   = 0.02;     // a sample counts when its pad is stable within +-G
  localparam real LaunchMin = T / 4 + 0.1;
  localparam real LaunchMax = T / 2 - 0.1;
  localparam bit  LsPins = HasLs && !Loopback;

  // ---------------------------------------------------------------- clocks
  logic osc = 1'b0;
  logic osc_run = 1'b1;
  logic rst = 1'b0;
  always #(T / 2) if (osc_run) osc = ~osc;
  wire  hr_clk, wclk, rd_clk, locked;
  logic ps_en = 0, ps_inc = 0, wps_en = 0, wps_inc = 0;
  wire  ps_done, wps_done;

  bow_hyperram_clk_xusp #(
    .ClkInPeriodNs (10.0),
    .InDivide      (1),
    .VcoMult       (12.0),
    .HrDivide      (12)
  ) u_clk (
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

  // ---------------------------------------------------------------- DUT
  hr_io_out_t      io_o;
  hr_io_in_t       io_i;
  wire             rwds_pad;
  logic            lb_dq_en = 1'b0, lb_rwds_en = 1'b0;
  logic [1:0][7:0] lb_dq = '0;
  logic [1:0]      lb_rwds = '0;

  wire       ck_p, ck_n, cs_n, rst_n, ls_oe_n, ls_dir_dq, ls_dir_rwds;
  wire [7:0] dq;
  wire       rwds;

  // testbench side of the bidirectional pads (the "HyperRAM")
  logic       tb_drv = 1'b0;
  logic [7:0] tb_dq = '0;
  logic       tb_rw = 1'b0;
  realtime    t_tbdrv = -1.0;   // last change of tb_drv
  assign dq   = tb_drv ? tb_dq : 8'hzz;
  assign rwds = tb_drv ? tb_rw : 1'bz;

  initial io_o = HR_IO_OUT_IDLE;

  bow_hyperram_io_xilinx #(
    .Loopback (Loopback),
    .HasLs    (HasLs)
  ) dut (
    .clk_i         (hr_clk),
    .wclk_i        (wclk),
    .rd_clk_i      (rd_clk),
    .io_o_i        (io_o),
    .io_i_o        (io_i),
    .rwds_pad_o    (rwds_pad),
    .lb_dq_en_i    (lb_dq_en),
    .lb_dq_i       (lb_dq),
    .lb_rwds_en_i  (lb_rwds_en),
    .lb_rwds_i     (lb_rwds),
    .ck_p_o        (ck_p),
    .ck_n_o        (ck_n),
    .cs_n_o        (cs_n),
    .rst_n_o       (rst_n),
    .dq_io         (dq),
    .rwds_io       (rwds),
    .ls_oe_n_o     (ls_oe_n),
    .ls_dir_dq_o   (ls_dir_dq),
    .ls_dir_rwds_o (ls_dir_rwds)
  );

  // ---------------------------------------------------------------- utils
  int errors = 0;
  int n_chk = 0, n_edge = 0, n_rd = 0, n_rb = 0, n_rb_lb = 0, n_ckn = 0, n_rwp = 0;
  int n_unst = 0;   // known pad samples skipped: the pad moved within G of the edge
  task automatic fail(string msg);
    errors++;
    if (errors <= 30) $display("ERROR @%0t: %s", $time, msg);
  endtask

  function automatic real modt(real x);
    while (x < 0) x += T;
    while (x >= T) x -= T;
    return x;
  endfunction
  function automatic bit near(real x, real target);   // x == target (mod T)
    real d;
    d = modt(x - target);
    return (d < TOL) || (d > T - TOL);
  endfunction

  task automatic wait_until(realtime t);
    if (t < $realtime - 0.0005) fail($sformatf("check time %0.4f already passed (test setup)", t));
    else if (t > $realtime) #(t - $realtime);
  endtask

  // got / exp compared on their low w bits
  task automatic check_eq(string what, int j, logic [63:0] got, logic [63:0] exp, int w);
    logic [63:0] m;
    m = (w >= 64) ? '1 : ((64'd1 << w) - 64'd1);
    n_chk++;
    if ((got & m) !== (exp & m))
      fail($sformatf("%s of PHY cycle %0d: pin %h, expected %h", what, j, got & m, exp & m));
  endtask

  // ---------------------------------------------------------------- stimulus
  int              ne = 0;        // hr_clk rising edges = PHY cycle launched at that edge
  int              cyc = 0;       // latest PHY cycle with a history entry
  hr_io_out_t      hist[int];
  logic            hlbd[int], hlbr[int];
  logic [1:0][7:0] hlbdq[int];
  logic [1:0]      hlbrw[int];
  realtime         tcyc[int];     // hr_clk edge of PHY cycle j (launch)
  int              mode = 0;      // 0 idle bundle, 1 random write traffic, 2 read (dq_oe = rwds_oe = 0)
  bit              chk_en = 0;    // pin value / edge checks enabled (write phase constant)
  real             phw = 0.0;     // write phase, ns
  real             l_min = 100.0, l_max = 0.0;
  int unsigned     rnd = 1;       // xorshift32 state, from $urandom (xsim -sv_seed)

  function automatic logic [31:0] r32();
    rnd = rnd ^ (rnd << 13);
    rnd = rnd ^ (rnd >> 17);
    rnd = rnd ^ (rnd << 5);
    return rnd;
  endfunction

  // The PHY register launches at the hr_clk edge; its path delay to the ODDRs
  // and T flops is LAUNCH, drawn every cycle in [T/4, T/2] (minus margins):
  // the DQ / RWDS ODDRs sample at (j+0.75)T + write phase, i.e. anywhere in
  // [(j+0.5)T, (j+1)T] over the write phase range.
  always @(posedge hr_clk) begin
    realtime     t0;
    real         dl;
    int          c;
    logic [31:0] v;
    t0 = $realtime;
    ne++;
    c = ne;
    tcyc[c] = t0;
    dl = LaunchMin + (LaunchMax - LaunchMin) * real'(r32() % 1001) / 1000.0;
    if (mode != 0) begin
      if (dl < l_min) l_min = dl;
      if (dl > l_max) l_max = dl;
    end
    #(dl);
    if (mode == 0) begin
      io_o       = HR_IO_OUT_IDLE;
      lb_dq_en   = 1'b0;
      lb_rwds_en = 1'b0;
    end else begin
      v = r32();
      io_o = v[$bits(hr_io_out_t)-1:0];
      io_o.dq_oe   = (mode == 1) ? (r32() % 10 != 0) : 1'b0;
      io_o.rwds_oe = (mode == 1) ? (r32() % 10 != 0) : 1'b0;
      v = r32();
      lb_dq   = v[15:0];
      lb_rwds = v[17:16];
      // emulator bursts: each enable in runs of a few cycles, independently
      if (r32() % 4 == 0) lb_dq_en = ~lb_dq_en;
      if (r32() % 4 == 0) lb_rwds_en = ~lb_rwds_en;
    end
    hist[c]  = io_o;
    hlbd[c]  = lb_dq_en;
    hlbr[c]  = lb_rwds_en;
    hlbdq[c] = lb_dq;
    hlbrw[c] = lb_rwds;
    cyc = c;
    if (chk_en && c > 4) schedule_checks(c);
  end

  // contract values of PHY cycle j
  function automatic logic [7:0] exp_dq(int j, int b);   // byte b (0 = A) on the DQ pads
    return (Loopback && hlbd[j]) ? hlbdq[j][b] : hist[j].dq[b];
  endfunction
  function automatic logic exp_rw(int j, int b);
    return (Loopback && hlbr[j]) ? hlbrw[j][b] : hist[j].rwds[b];
  endfunction
  function automatic bit dq_drv(int j);                  // DQ driven in pin cycle j+1
    return Loopback || hist[j].dq_oe;
  endfunction
  function automatic bit rw_drv(int j);
    return Loopback || hist[j].rwds_oe;
  endfunction

  // PHY cycle s whose drive state (T flops) is on the pads at time t: the pin
  // cycle that starts at hr_clk edge q shows cycle q-1. 0 when t is within G
  // of a pin cycle boundary or the history is missing.
  function automatic bit shown(realtime t, output int s);
    int q;
    q = ne;
    while (q > 1 && tcyc[q] > t) q--;
    s = q - 1;
    return (t - tcyc[q] >= G) && (tcyc[q] + T - t >= G) && hist.exists(s);
  endfunction

  function automatic int nz8(logic [7:0] v);   // bits not at z (driven)
    int n;
    n = 0;
    for (int i = 0; i < 8; i++) if (v[i] !== 1'bz) n++;
    return n;
  endfunction

  // ------------------------------------------------------- value checks
  task automatic chk_ck(int j, bit first, string where);
    logic e;
    if (!chk_en) return;
    e = first ? hist[j].ck_en : 1'b0;
    check_eq({"CK_P ", where}, j, ck_p, e, 1);
    check_eq({"CK_N ", where}, j, ck_n, ~e, 1);
  endtask

  task automatic chk_ctl(int j, string where);
    if (!chk_en) return;
    check_eq({"CS# ", where}, j, cs_n, hist[j].cs_n, 1);
    check_eq({"RESET# ", where}, j, rst_n, hist[j].rst_n, 1);
    if (LsPins) begin
      check_eq({"LS_OE# ", where}, j, ls_oe_n, hist[j].ls_oe_n, 1);
      check_eq({"LS_DIR_DQ ", where}, j, ls_dir_dq, hist[j].ls_dir_dq, 1);
      check_eq({"LS_DIR_RWDS ", where}, j, ls_dir_rwds, hist[j].ls_dir_rwds, 1);
    end else begin
      check_eq({"LS_OE# (constant) ", where}, j, ls_oe_n, 1'b1, 1);
      check_eq({"LS_DIR_DQ (constant) ", where}, j, ls_dir_dq, 1'b0, 1);
      check_eq({"LS_DIR_RWDS (constant) ", where}, j, ls_dir_rwds, 1'b0, 1);
    end
  endtask

  task automatic chk_drv(int j, string where);   // pin cycle j+1
    if (!chk_en || tb_drv) return;
    n_chk++;
    if (dq_drv(j) ? (nz8(dq) != 8) : (dq !== 8'hzz))
      fail($sformatf("DQ drive state (%s) of PHY cycle %0d: dq_oe %0d, pads %b", where, j, dq_drv(j), dq));
    n_chk++;
    if (rw_drv(j) ? (rwds === 1'bz) : (rwds !== 1'bz))
      fail($sformatf("RWDS drive state (%s) of PHY cycle %0d: rwds_oe %0d, pad %b", where, j, rw_drv(j),
                     rwds));
  endtask

  task automatic chk_byte(int j, int b, string where);
    int s;
    if (!chk_en || tb_drv) return;
    if (!shown($realtime, s)) return;   // at a driver switch
    if (dq_drv(s)) check_eq({"DQ ", where}, j, dq, exp_dq(j, b), 8);
    if (rw_drv(s)) check_eq({"RWDS ", where}, j, rwds, exp_rw(j, b), 1);
  endtask

  task automatic schedule_checks(int j);
    realtime tj;
    real     pw;
    tj = tcyc[j];
    pw = phw;
    fork
      begin   // CK: pin cycle j+1, ck_en in the first half, low in the second
        wait_until(tj + T + D + E);        chk_ck(j, 1, "first half start");
        wait_until(tj + 1.25 * T);         chk_ck(j, 1, "first half middle");
        wait_until(tj + 1.5 * T + D - E);  chk_ck(j, 1, "first half end");
        wait_until(tj + 1.5 * T + D + E);  chk_ck(j, 0, "second half start");
        wait_until(tj + 1.75 * T);         chk_ck(j, 0, "second half middle");
        wait_until(tj + 2.0 * T + D - E);  chk_ck(j, 0, "second half end");
      end
      begin   // CS#, RESET#, level shifter controls: pin cycle j+1
        wait_until(tj + T + D + E);        chk_ctl(j, "start");
        wait_until(tj + 1.5 * T + D);      chk_ctl(j, "middle");
        wait_until(tj + 2.0 * T + D - E);  chk_ctl(j, "end");
      end
      begin   // drive state of DQ / RWDS: pin cycle j+1 (T flops, no ODDR delay)
        wait_until(tj + T + E);            chk_drv(j, "start");
        wait_until(tj + 1.5 * T);          chk_drv(j, "middle");
        wait_until(tj + 2.0 * T - E);      chk_drv(j, "end");
      end
      begin   // DQ / RWDS bytes, delayed by the write phase
        wait_until(tj + 0.75 * T + pw + D + E);  chk_byte(j, 0, "byte A start");
        wait_until(tj + 1.0 * T + pw + D);       chk_byte(j, 0, "byte A middle (CK rise)");
        wait_until(tj + 1.25 * T + pw + D - E);  chk_byte(j, 0, "byte A end");
        wait_until(tj + 1.25 * T + pw + D + E);  chk_byte(j, 1, "byte B start");
        wait_until(tj + 1.5 * T + pw + D);       chk_byte(j, 1, "byte B middle (CK fall)");
        wait_until(tj + 1.75 * T + pw + D - E);  chk_byte(j, 1, "byte B end");
      end
    join_none
  endtask

  // ------------------------------------------------- transition phase checks
  realtime t_hr = 0;   // last hr_clk rising edge
  always @(posedge hr_clk) t_hr = $realtime;

  task automatic edge_chk(string what, real ph0, real ph1);
    real ph;
    if (!chk_en) return;
    ph = $realtime - t_hr;
    n_edge++;
    if (!near(ph, ph0) && !near(ph, ph1))
      fail($sformatf("%s edge at phase %0.4f ns, allowed %0.4f / %0.4f", what, modt(ph), modt(ph0),
                     modt(ph1)));
  endtask

  always @(ck_p) begin
    if (ck_p === 1'b1) edge_chk("CK_P rise", D, D);
    else edge_chk("CK_P fall", 0.5 * T + D, 0.5 * T + D);
  end
  always @(ck_n) begin
    if (ck_n === 1'b0) edge_chk("CK_N fall", D, D);
    else edge_chk("CK_N rise", 0.5 * T + D, 0.5 * T + D);
  end
  always @(cs_n) edge_chk("CS#", D, D);
  always @(rst_n) edge_chk("RESET#", D, D);
  always @(ls_oe_n or ls_dir_dq or ls_dir_rwds) begin
    if (LsPins) edge_chk("LS_OE# / LS_DIR", D, D);
    else if ($realtime > 1.0) fail("constant LS_OE# / LS_DIR pin moved");
  end

  // CK_N = ~CK_P at every instant (two ODDRE1 on the same clock)
  always @(ck_p or ck_n) begin
    #0.001;
    if ($realtime > 1.0) begin
      n_ckn++;
      if (ck_n !== ~ck_p) fail($sformatf("CK_N %b not the complement of CK_P %b", ck_n, ck_p));
    end
  end

  // DQ / RWDS: data edges between two driven levels, driver switches (to / from
  // z) at the hr_clk edge; not while the testbench drives the pads
  function automatic bit pad_mine();
    return !tb_drv && ($realtime - t_tbdrv > 0.0005);
  endfunction
  logic [7:0] dq_last = 8'hzz;
  always @(dq) begin
    if (pad_mine()) begin
      for (int i = 0; i < 8; i++) begin
        if (dq[i] !== dq_last[i]) begin
          if (dq[i] !== 1'bz && dq_last[i] !== 1'bz)
            edge_chk($sformatf("DQ%0d", i), 0.25 * T + phw + D, 0.75 * T + phw + D);
          else
            edge_chk($sformatf("DQ%0d driver", i), 0.0, 0.0);
        end
      end
    end
    dq_last = dq;
  end
  logic rw_last = 1'bz;
  always @(rwds) begin
    if (pad_mine() && rwds !== rw_last) begin
      if (rwds !== 1'bz && rw_last !== 1'bz) edge_chk("RWDS", 0.25 * T + phw + D, 0.75 * T + phw + D);
      else edge_chk("RWDS driver", 0.0, 0.0);
    end
    rw_last = rwds;
  end

  // rwds_pad_o = the RWDS pad (IOBUF output, no register)
  always @(rwds or rwds_pad) begin
    #0.001;
    if (rwds === 1'b0 || rwds === 1'b1) begin
      n_rwp++;
      if (rwds_pad !== rwds) fail($sformatf("rwds_pad_o %b, RWDS pad %b", rwds_pad, rwds));
    end
  end

  // From configuration to lock the PHY bundle is HR_IO_OUT_IDLE: no pin moves
  // except the DQ / RWDS drivers turning on (z -> 0) at an hr_clk rising edge
  // (the T flops take dq_oe = rwds_oe = 1 of the idle bundle; the MMCM model
  // pulses its outputs once 5 ns after time 0 and runs before locked_o).
  bit idle_mon = 1;   // from configuration to the first lock
  int n_hr_pre = 0;   // hr_clk rising edges before locked_o
  always @(posedge hr_clk) if (idle_mon && $realtime > 0.5) n_hr_pre++;
  always @(ck_p or ck_n or cs_n or rst_n or ls_oe_n or ls_dir_dq or ls_dir_rwds)
    if (idle_mon && $realtime > 1.0) fail("a CK / CS# / RESET# / LS pin moved before lock");
  always @(dq or rwds) begin
    realtime tc;
    tc = $realtime;
    #0.001;   // settled value of the time step
    if (idle_mon && tc > 1.0) begin
      if (Loopback || tc != t_hr || dq !== 8'h00 || rwds !== 1'b0)
        fail($sformatf("DQ %b / RWDS %b changed before lock other than the drivers turning on at hr_clk",
                       dq, rwds));
    end
  end

  task automatic chk_idle(string when);
    if (locked === 1'b1) fail("clocks locked already (test setup)");
    if ({cs_n, rst_n, ck_p, ck_n} !== 4'b1101)
      fail($sformatf("%s: CS# RESET# CK_P CK_N = %b, expected 1101", when, {cs_n, rst_n, ck_p, ck_n}));
    if ({ls_oe_n, ls_dir_dq, ls_dir_rwds} !== 3'b100)
      fail($sformatf("%s: LS_OE# DIR_DQ DIR_RWDS = %b, expected 100", when,
                     {ls_oe_n, ls_dir_dq, ls_dir_rwds}));
    if (Loopback || n_hr_pre > 0) begin
      // loopback: T = 0 from the start; else the T flops took the idle bundle
      if (dq !== 8'h00 || rwds !== 1'b0 || rwds_pad !== 1'b0)
        fail($sformatf("%s: DQ %b RWDS %b rwds_pad_o %b, expected driven at 0", when, dq, rwds, rwds_pad));
    end else begin
      if (dq !== 8'hzz || rwds !== 1'bz)
        fail($sformatf("%s: DQ %b / RWDS %b driven before the first hr_clk edge", when, dq, rwds));
    end
    // ODDRE1 SRVAL of DQ / RWDS (behind released drivers in the PHY configurations)
    for (int i = 0; i < 8; i++) begin
      logic q;
      unique case (i)
        0: q = dut.g_dq[0].q;
        1: q = dut.g_dq[1].q;
        2: q = dut.g_dq[2].q;
        3: q = dut.g_dq[3].q;
        4: q = dut.g_dq[4].q;
        5: q = dut.g_dq[5].q;
        6: q = dut.g_dq[6].q;
        default: q = dut.g_dq[7].q;
      endcase
      if (q !== 1'b0) fail($sformatf("%s: DQ%0d ODDRE1 output %b, SRVAL 0", when, i, q));
    end
    if (dut.g_rwds.q !== 1'b0) fail($sformatf("%s: RWDS ODDRE1 output not at SRVAL 0", when));
    $write("tb_bow_hyperram_io_xilinx: idle pins %s (%0d hr_clk edges so far): ", when, n_hr_pre);
    $display("CS# %b RESET# %b CK %b%b LS %b%b%b DQ %h RWDS %b", cs_n, rst_n, ck_p, ck_n, ls_oe_n,
             ls_dir_dq, ls_dir_rwds, dq, rwds);
  endtask

  // ---------------------------------------------------------- read capture
  // Pad levels at each hr_rd_clk edge (rising edge m: sr[m], the falling edge
  // after it: sf[m]); *_ok = known and no pad change within +-G of the edge.
  // e* = the contract value of the pad at that instant when the wrapper drives
  // it (from the PHY / emulator history), lbd = it came from lb_dq.
  typedef struct packed {
    logic [7:0] dq;
    logic       rw;
    logic       dq_ok;
    logic       rw_ok;
    logic [7:0] edq;
    logic       erw;
    logic       edq_ok;
    logic       erw_ok;
    logic       lbd;
  } smp_t;

  int      nrd = 0;          // hr_rd_clk rising edges
  smp_t    sr[int], sf[int];
  bit      rd_chk_en = 0;
  realtime t_dq_chg = -1.0, t_rw_chg = -1.0;
  always @(dq)   t_dq_chg = $realtime;
  always @(rwds) t_rw_chg = $realtime;

  // Contract value of the DQ / RWDS pads at time t while the wrapper drives
  // them: byte b of PHY cycle j on [tcyc[j] + (0.75 + b/2)T + w + D, + T/2),
  // driver of the pin cycle containing t. Not known (ok = 0) within G of a
  // byte or driver boundary, while the write phase moves, while the testbench
  // drives.
  task automatic exp_pad(input realtime t, output logic [7:0] edq, output logic erw,
                         output logic dq_ok, output logic rw_ok, output logic lbd);
    int  j, b, s;
    real x, f;
    dq_ok = 0;
    rw_ok = 0;
    lbd   = 0;
    edq   = 'x;
    erw   = 1'bx;
    if (!chk_en || tb_drv || ne < 8) return;
    x = t - (0.75 * T + phw + D);
    j = ne;
    while (j > ne - 4 && tcyc[j] > x) j--;
    f = x - tcyc[j];
    if (f < 0.0 || f >= T || !hist.exists(j)) return;
    b = (f >= T / 2) ? 1 : 0;
    f = f - b * T / 2;
    if (f < G || f > T / 2 - G) return;
    if (!shown(t, s)) return;
    if (dq_drv(s)) begin
      dq_ok = 1;
      edq   = exp_dq(j, b);
      lbd   = Loopback && hlbd[j];
    end
    if (rw_drv(s)) begin
      rw_ok = 1;
      erw   = exp_rw(j, b);
    end
  endtask

  task automatic take(output smp_t s);
    logic [7:0] edq;
    logic       erw, a, b, c;
    s.dq    = dq;
    s.rw    = rwds;
    s.dq_ok = !$isunknown(dq);
    s.rw_ok = !$isunknown(rwds);
    if (tb_drv && (!s.dq_ok || !s.rw_ok))
      fail($sformatf("DQ %b / RWDS %b while the testbench drives them (contention)", dq, rwds));
    exp_pad($realtime, edq, erw, a, b, c);
    s.edq    = edq;
    s.erw    = erw;
    s.edq_ok = a;
    s.erw_ok = b;
    s.lbd    = c;
  endtask

  // io_i after rising edge m+1 (after C -> Q, and still at edge m+2) = the
  // samples of rising edge m and of the falling edge after it
  task automatic cap_chk(int m, string when);
    if (!sr.exists(m) || !sf.exists(m)) return;
    if (sr[m].dq_ok) begin
      n_rd++;
      if (io_i.dq[0] !== sr[m].dq)
        fail($sformatf("IDDR DQ rise (%s): got %h, pad was %h", when, io_i.dq[0], sr[m].dq));
    end
    if (sf[m].dq_ok) begin
      n_rd++;
      if (io_i.dq[1] !== sf[m].dq)
        fail($sformatf("IDDR DQ fall (%s): got %h, pad was %h", when, io_i.dq[1], sf[m].dq));
    end
    if (sr[m].rw_ok) begin
      n_rd++;
      if (io_i.rwds[0] !== sr[m].rw)
        fail($sformatf("IDDR RWDS rise (%s): got %b, pad was %b", when, io_i.rwds[0], sr[m].rw));
    end
    if (sf[m].rw_ok) begin
      n_rd++;
      if (io_i.rwds[1] !== sf[m].rw)
        fail($sformatf("IDDR RWDS fall (%s): got %b, pad was %b", when, io_i.rwds[1], sf[m].rw));
    end
    // read-back of what the wrapper drives (written data / loopback emulator)
    if (sr[m].edq_ok) begin
      n_rb++;
      n_rb_lb += sr[m].lbd;
      if (io_i.dq[0] !== sr[m].edq)
        fail($sformatf("read-back DQ rise (%s): got %h, contract %h", when, io_i.dq[0], sr[m].edq));
    end
    if (sf[m].edq_ok) begin
      n_rb++;
      n_rb_lb += sf[m].lbd;
      if (io_i.dq[1] !== sf[m].edq)
        fail($sformatf("read-back DQ fall (%s): got %h, contract %h", when, io_i.dq[1], sf[m].edq));
    end
    if (sr[m].erw_ok) begin
      n_rb++;
      if (io_i.rwds[0] !== sr[m].erw)
        fail($sformatf("read-back RWDS rise (%s): got %b, contract %b", when, io_i.rwds[0], sr[m].erw));
    end
    if (sf[m].erw_ok) begin
      n_rb++;
      if (io_i.rwds[1] !== sf[m].erw)
        fail($sformatf("read-back RWDS fall (%s): got %b, contract %b", when, io_i.rwds[1], sf[m].erw));
    end
  endtask

  always @(posedge rd_clk) begin
    int      m;
    realtime ts;
    smp_t    s;
    nrd++;
    m  = nrd;
    ts = $realtime;
    if (rd_chk_en) cap_chk(m - 2, "at the next edge");   // what a flop on hr_rd_clk takes here
    take(s);
    #(G);
    if (rd_chk_en) n_unst += (s.dq_ok && t_dq_chg >= ts - G) + (s.rw_ok && t_rw_chg >= ts - G);
    s.dq_ok = s.dq_ok && (t_dq_chg < ts - G);
    s.rw_ok = s.rw_ok && (t_rw_chg < ts - G);
    sr[m] = s;
    if (sr.exists(m - 8)) begin
      sr.delete(m - 8);
      sf.delete(m - 8);
    end
    #(0.15 - G);   // IDDRE1 C -> Q1/Q2 is 100 ps in the unisim model
    if (rd_chk_en) cap_chk(m - 1, "after C->Q");
  end

  always @(negedge rd_clk) begin
    int      m;
    realtime ts;
    smp_t    s;
    m  = nrd;
    ts = $realtime;
    take(s);
    #(G);
    if (rd_chk_en) n_unst += (s.dq_ok && t_dq_chg >= ts - G) + (s.rw_ok && t_rw_chg >= ts - G);
    s.dq_ok = s.dq_ok && (t_dq_chg < ts - G);
    s.rw_ok = s.rw_ok && (t_rw_chg < ts - G);
    sf[m] = s;
  end

  // HyperRAM side read data: new values half way between hr_rd_clk edges,
  // following the edges while the read phase moves
  bit rd_drive = 0;
  task automatic drive_reads();
    n_chk++;
    if (dq !== 8'hzz || rwds !== 1'bz)
      fail($sformatf("pads not released for the read: DQ %b RWDS %b", dq, rwds));
    tb_dq   = r32();
    tb_rw   = r32();
    t_tbdrv = $realtime;
    tb_drv  = 1'b1;
    while (rd_drive) begin
      @(posedge rd_clk);
      #(T / 4);
      tb_dq = r32();
      tb_rw = r32();
      #(T / 2);
      tb_dq = r32();
      tb_rw = r32();
    end
    @(posedge rd_clk);
    #(T / 4);
    t_tbdrv = $realtime;
    tb_drv  = 1'b0;
  endtask

  // ---------------------------------------------------------- clock checks
  // every high and low phase of the HyperRAM clocks T/2 +- 40 ps (a fine step
  // changes one phase by 14.9 ps); hr_clk keeps its phase to the oscillator;
  // locked_o stays high; PSDONE pulses counted per port
  bit  mon_on = 0;
  int  pw_err = 0, osc_err = 0, osc_chk = 0, lock_err = 0;
  real pw_min = 100.0, pw_max = 0.0, ph_osc0 = 0.0;
  task automatic pw_check(string name, realtime w);
    if (!mon_on) return;
    if (w < pw_min) pw_min = w;
    if (w > pw_max) pw_max = w;
    if (w < T / 2 - 0.040 || w > T / 2 + 0.040) begin
      pw_err++;
      if (pw_err < 10) $display("ERROR @%0t: %s pulse width %0.4f ns", $time, name, w);
    end
  endtask
  realtime e_hr = 0, e_w = 0, e_rd = 0, t_osc = 0;
  always @(hr_clk) begin pw_check("hr_clk", $realtime - e_hr); e_hr = $realtime; end
  always @(wclk)   begin pw_check("hr_wclk", $realtime - e_w);  e_w  = $realtime; end
  always @(rd_clk) begin pw_check("hr_rd_clk", $realtime - e_rd); e_rd = $realtime; end
  always @(posedge osc) t_osc = $realtime;
  always @(posedge hr_clk) begin
    if (mon_on) begin
      osc_chk++;
      if (!near($realtime - t_osc, ph_osc0)) begin
        osc_err++;
        if (osc_err < 5)
          $display("ERROR @%0t: hr_clk %0.4f ns after the oscillator, %0.4f at lock", $time,
                   modt($realtime - t_osc), ph_osc0);
      end
    end
  end
  always @(locked) begin
    if (mon_on && locked !== 1'b1) begin
      lock_err++;
      if (lock_err < 5) $display("ERROR @%0t: locked_o dropped", $time);
    end
  end
  int n_ps = 0, n_wps = 0, n_psd = 0, n_wpsd = 0;
  always @(posedge hr_clk) begin
    #0.05;
    if (ps_done === 1'b1) n_psd++;
    if (wps_done === 1'b1) n_wpsd++;
  end

  // locked_o (the HyperRAM link reset hr_rst_ni) only while all three clocks
  // run: every T/4 while it is high, each clock had a rising edge within the
  // last T + 2 ns (the model drops LOCKED 1 ns after RST); from the first lock
  // to the end, rst_i and the lock-loss resets included. Not while the
  // oscillator is stopped: there the MMCM model stops its outputs some 15 ns
  // before it drops LOCKED, which locked_o (the AND of both) cannot change.
  realtime r_hr = -1.0e6, r_w = -1.0e6, r_rd = -1.0e6;
  int      run_err = 0, run_chk = 0;
  bit      run_mon = 1;
  always @(posedge hr_clk) r_hr = $realtime;
  always @(posedge wclk)   r_w  = $realtime;
  always @(posedge rd_clk) r_rd = $realtime;
  always begin
    #(T / 4);
    if (locked === 1'b1 && !idle_mon && run_mon) begin
      run_chk++;
      if ($realtime - r_hr > T + 2.0 || $realtime - r_w > T + 2.0 || $realtime - r_rd > T + 2.0) begin
        run_err++;
        if (run_err < 5)
          $display("ERROR @%0t: locked_o high, last edges of hr_clk / hr_wclk / hr_rd_clk %0.3f / %0.3f / %s",
                   $time, $realtime - r_hr, $realtime - r_w, $sformatf("%0.3f ns ago", $realtime - r_rd));
      end
    end
  end

  // phase of a clock after the hr_clk rising edge, in [0, T)
  task automatic phase_of(input int sel, output real ph);
    realtime t0;
    @(posedge hr_clk);
    t0 = $realtime;
    unique case (sel)
      0: @(posedge wclk);
      1: @(posedge rd_clk);
      default: @(posedge osc);
    endcase
    ph = modt($realtime - t0);
  endtask

  task automatic period_of(input int sel, output real p);
    realtime t0;
    unique case (sel)
      0: @(posedge hr_clk);
      1: @(posedge wclk);
      default: @(posedge rd_clk);
    endcase
    t0 = $realtime;
    repeat (200) begin
      unique case (sel)
        0: @(posedge hr_clk);
        1: @(posedge wclk);
        default: @(posedge rd_clk);
      endcase
    end
    p = ($realtime - t0) / 200;
  endtask

  // n fine steps on port w (0 = read ps_*, 1 = write wps_*): PSEN for one
  // hr_clk cycle, PSDONE (one cycle) 12 cycles after the edge that took PSEN
  int lat_err = 0;
  task automatic step(bit w, bit inc, int n);
    int lat;
    $display("tb_bow_hyperram_io_xilinx: step port %0d inc %0d x%0d @%0t", w, inc, n, $time);
    repeat (n) begin
      @(posedge hr_clk);
      #0.05;
      if (w) begin wps_en = 1; wps_inc = inc; end
      else   begin ps_en = 1;  ps_inc = inc;  end
      @(posedge hr_clk);   // the MMCM takes PSEN here
      #0.05;
      wps_en = 0;
      ps_en  = 0;
      if (w) n_wps++;
      else   n_ps++;
      // PSDONE is set at a PSCLK edge and cleared at the next one: look at it
      // just after each edge
      lat = 0;
      do begin
        @(posedge hr_clk);
        #0.05;
        lat++;
      end while ((w ? wps_done : ps_done) !== 1'b1 && lat < 40);
      if (lat != 12) begin
        lat_err++;
        if (lat_err < 5) fail($sformatf("PSDONE of port %0d %0d cycles after PSEN, expected 12", w, lat));
      end
      @(posedge hr_clk);
      #0.05;
      if ((w ? wps_done : ps_done) !== 1'b0) fail("PSDONE longer than one cycle");
    end
  endtask

  real ph_rd0 = 0.0;   // hr_rd_clk after hr_clk at read phase 0
  int  wnow = 0, rnow = 0;

  task automatic chk_phases(string what);
    real ph;
    phase_of(0, ph);
    $display("tb_bow_hyperram_io_xilinx: %s: hr_wclk - hr_clk = %0.4f ns (expected %0.4f), ", what, ph,
             modt(T / 4 + wnow * T / PS));
    if (!near(ph, T / 4 + wnow * T / PS)) fail($sformatf("%s: write phase not at %0d steps", what, wnow));
    phase_of(1, ph);
    $display("tb_bow_hyperram_io_xilinx:   hr_rd_clk - hr_clk = %0.4f ns (expected %0.4f)", ph,
             modt(ph_rd0 + rnow * T / PS));
    if (!near(ph, ph_rd0 + rnow * T / PS)) fail($sformatf("%s: read phase not at %0d steps", what, rnow));
  endtask

  task automatic set_wphase(int k);   // absolute write phase in steps
    chk_en = 0;
    repeat (8) @(posedge hr_clk);
    if (k > wnow) step(1, 1, k - wnow);
    if (k < wnow) step(1, 0, wnow - k);
    wnow = k;
    phw  = k * T / PS;
    repeat (8) @(posedge hr_clk);
    chk_phases($sformatf("write phase %0d", k));
    chk_en = 1;
  endtask

  // read phase sweep: 4 x 97 steps up, 2 x 97 down, capture checked throughout
  task automatic rd_sweep();
    for (int k = 0; k < 6; k++) begin
      step(0, k < 4, 97);
      rnow += (k < 4) ? 97 : -97;
      repeat (4) @(posedge hr_clk);
      chk_phases($sformatf("read phase %0d", rnow));
      repeat (100) @(posedge rd_clk);
    end
  endtask

  // Loss of lock with both phases moved first: which = 0 / 1: the LOCKED
  // output of MMCM_R / MMCM_H forced low for 3 us (the MMCM itself keeps
  // running until the lock-loss reset restarts both and they relock under the
  // force), 2: the oscillator stopped for 5 us (both lose lock; the
  // synchroniser on the input clock sees it when the clock is back).
  // locked_o must stay low while a LOCKED is low, the lock-loss reset must
  // come, and after the relock both phases must be back at 0.
  bit lk_seen = 0;
  always @(posedge u_clk.lk_rst) lk_seen = 1;

  task automatic lock_loss(int which);
    string name;
    name = (which == 0) ? "MMCM_R lock loss" : (which == 1) ? "MMCM_H lock loss" : "oscillator stop";
    step(1, 1, 30);
    step(0, 1, 20);
    wnow = 30;
    rnow = 20;
    chk_phases({"before the ", name});
    lk_seen = 0;
    unique case (which)
      0: force u_clk.locked_r = 1'b0;
      1: force u_clk.locked_h = 1'b0;
      default: begin
        run_mon = 0;
        osc_run = 1'b0;
      end
    endcase
    #((which == 2) ? 5us : 3us);
    if (locked !== 1'b0) fail($sformatf("locked_o high at the end of the %s", name));
    // xsim keeps a released variable at its forced value until its driver
    // changes: let it follow the MMCM's LOCKED first, then release it
    unique case (which)
      0: begin
        force u_clk.locked_r = u_clk.u_mmcm_r.LOCKED;
        #0.001;
        release u_clk.locked_r;
      end
      1: begin
        force u_clk.locked_h = u_clk.u_mmcm_h.LOCKED;
        #0.001;
        release u_clk.locked_h;
      end
      default: osc_run = 1'b1;
    endcase
    #0.001;
    if (u_clk.locked_r !== u_clk.u_mmcm_r.LOCKED || u_clk.locked_h !== u_clk.u_mmcm_h.LOCKED)
      fail("LOCKED nets do not follow the MMCMs after the release (test setup)");
    fork
      wait (lk_seen && locked === 1'b1);
      #300us;
    join_any
    disable fork;
    if (!lk_seen) fail($sformatf("no lock-loss reset after the %s", name));
    if (locked !== 1'b1) fail($sformatf("no relock after the %s", name));
    run_mon = 1;
    repeat (20) @(posedge hr_clk);
    wnow = 0;
    rnow = 0;
    chk_phases({"after the ", name});
  endtask

  // ---------------------------------------------------------------- main
  real p, ph;

  initial begin
    rnd = $urandom;
    if (rnd == 0) rnd = 1;
    $display("tb_bow_hyperram_io_xilinx: Loopback %0d HasLs %0d, xorshift seed %08h", Loopback, HasLs, rnd);
    // idle levels after configuration: before any clock edge, during GSR (glbl,
    // first 100 ns: ODDRE1 held at SRVAL), after GSR before lock
    #1.0;
    if (n_hr_pre != 0) fail("hr_clk edge in the first ns (test setup)");
    chk_idle("before any clock edge");
    #49.0;
    chk_idle("during GSR");
    #100.0;
    chk_idle("after GSR, before lock");
    wait (locked === 1'b1);
    idle_mon = 0;
    $display("tb_bow_hyperram_io_xilinx: %0d hr_clk rising edges before locked_o (MMCM model)", n_hr_pre);
    if (!Loopback && n_hr_pre == 0) fail("DQ / RWDS driver turn-on before lock not exercised (test setup)");
    repeat (20) @(posedge hr_clk);
    $display("tb_bow_hyperram_io_xilinx: clocks locked at %0t", $time);

    // ---- clocks at lock
    period_of(0, p);
    if (p < T - 0.001 || p > T + 0.001) fail($sformatf("hr_clk period %0.4f", p));
    period_of(1, p);
    if (p < T - 0.001 || p > T + 0.001) fail($sformatf("hr_wclk period %0.4f", p));
    period_of(2, p);
    if (p < T - 0.001 || p > T + 0.001) fail($sformatf("hr_rd_clk period %0.4f", p));
    phase_of(1, ph_rd0);
    phase_of(2, ph);
    ph_osc0 = modt(T - ph);   // hr_clk after the oscillator edge
    $display("tb_bow_hyperram_io_xilinx: hr_clk %0.4f ns after the oscillator, %s %0.4f ns after hr_clk",
             ph_osc0, "hr_rd_clk", ph_rd0);
    chk_phases("at lock");
    mon_on = 1;

    // ---- idle bundle after reset (HR_IO_OUT_IDLE): CS# high, CK low, DQ / RWDS driven low
    mode = 0;
    repeat (10) @(posedge hr_clk);
    chk_en    = 1;
    rd_chk_en = 1;
    repeat (30) @(posedge hr_clk);

    // ---- random traffic at write phase 0
    $display("tb_bow_hyperram_io_xilinx: random traffic @%0t", $time);
    mode = 1;
    repeat (1500) @(posedge hr_clk);

    // ---- read capture while the read phase moves
    $display("tb_bow_hyperram_io_xilinx: read capture / read phase sweep @%0t", $time);
    if (!Loopback) begin
      mode = 2;                       // dq_oe = rwds_oe = 0: the T flops release the pads
      repeat (4) @(posedge hr_clk);
      rd_drive = 1;
      fork
        drive_reads();
        begin
          repeat (300) @(posedge rd_clk);
          rd_sweep();
          rd_drive = 0;
        end
      join
      mode = 1;
      repeat (300) @(posedge hr_clk);
    end else begin
      rd_sweep();                     // loopback traffic goes on, read back at every phase
    end

    // ---- write phase +T/4, -T/4, +17 steps, back to 0
    $display("tb_bow_hyperram_io_xilinx: write phase sweep @%0t", $time);
    set_wphase(WQ);
    repeat (800) @(posedge hr_clk);
    set_wphase(0 - WQ);
    repeat (800) @(posedge hr_clk);
    set_wphase(17);
    repeat (800) @(posedge hr_clk);
    set_wphase(0);
    repeat (300) @(posedge hr_clk);

    chk_en    = 0;
    rd_chk_en = 0;
    repeat (10) @(posedge hr_clk);
    $write("tb_bow_hyperram_io_xilinx: %0d value checks, %0d edge checks, %0d IDDR checks, ", n_chk,
           n_edge, n_rd);
    $display("%0d read-back checks (%0d of loopback data), %0d CK_N checks, %0d rwds_pad_o checks, %0d %s",
             n_rb, n_rb_lb, n_ckn, n_rwp, cyc, "PHY cycles");
    $display("tb_bow_hyperram_io_xilinx: %0d pad samples not checked (pad moving within %0.0f ps of %s)",
             n_unst, G * 1000, "the hr_rd_clk edge");
    $display("tb_bow_hyperram_io_xilinx: LAUNCH %0.3f .. %0.3f ns; %0d read / %0d write steps, %s %0d / %0d",
             l_min, l_max, n_ps, n_wps, "PSDONE", n_psd, n_wpsd);
    $write("tb_bow_hyperram_io_xilinx: clock pulse widths %0.4f .. %0.4f ns, %0d errors; ", pw_min,
           pw_max, pw_err);
    $display("hr_clk to oscillator: %0d checks, %0d errors; locked_o drops %0d", osc_chk, osc_err,
             lock_err);
    if (n_chk < 50000 || n_edge < 10000 || n_rd < 10000 || n_rb < 10000 || n_ckn < 1000 || n_rwp < 1000)
      fail("too few checks");
    if (Loopback && n_rb_lb < 5000) fail("too few loopback read-back checks");
    if (n_psd != n_ps || n_wpsd != n_wps) fail("PSDONE pulses do not match the steps of their port");
    errors += pw_err + osc_err + lock_err;
    mon_on = 0;

    // ---- rst_i returns both phases to 0
    step(1, 1, 40);
    step(0, 1, 30);
    wnow = 40;
    rnow += 30;
    chk_phases("before rst_i");
    rst = 1;
    #100;
    if (locked !== 1'b0) fail("locked_o high during rst_i");
    rst = 0;
    wait (locked === 1'b1);
    repeat (20) @(posedge hr_clk);
    wnow = 0;
    rnow = 0;
    chk_phases("after rst_i");

    // ---- a loss of lock of either MMCM, then of both (oscillator stopped):
    // the lock-loss reset restarts both, both phases back to 0
    lock_loss(0);
    lock_loss(1);
    lock_loss(2);
    $display("tb_bow_hyperram_io_xilinx: locked_o only with the clocks running: %0d checks, %0d errors",
             run_chk, run_err);
    errors += run_err;

    if (errors == 0) $display("tb_bow_hyperram_io_xilinx: PASS");
    else $display("tb_bow_hyperram_io_xilinx: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #5ms;
    $display("tb_bow_hyperram_io_xilinx: FAIL (timeout)");
    $finish;
  end
endmodule
