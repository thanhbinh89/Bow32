// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Pin level test of the DDR2/DDR3 pads on UltraScale+ (Vivado simulator with
// the unisim models, `make -C hw/fpga/common/dv test-ddr-io`):
//
//   random io_o / lb_* bundles -> bow_ddr_io_xilinx -> pads <-> testbench "DRAM"
//   (PHY register delay T/3)      (ODDRE1, IDDRE1,     (drives DQ/DQS for reads)
//                                  IOBUF, OBUF(DS)/T)
//   clocked by bow_ddr_clk_xusp (three MMCME4_ADV, fine phase shift), checked
//   against the pin timing contract of bow_ddr_pkg / spec 4.2 (T = 7.5 ns).
//
// Checks:
//  * values in the middle and near both ends of every window: CK (ck_en in
//    the first half of pin cycle j+1), command group (value of PHY cycle j on
//    [(j+1.5)T, (j+2.5)T)), DQS ({second, first} half of pin cycle j+1, DQS_N
//    the complement), DQ/DM (beat 0 on [(j+0.75)T, (j+1.25)T), beat 1 on
//    [(j+1.25)T, (j+1.75)T)), level shifter pins, drive state of DQ/DQS/DM
//    (output enables of pin cycle j+1);
//  * every pin edge at its allowed phase (command, CK, DQ, DQS, DM);
//  * read capture: io_i.dq[0] / dqs[0] after rd_clk edge k+1 = pad at rising
//    edge k, dq[1] / dqs[1] = pad at the following falling edge; unused bits 0;
//  * idle levels during GSR and after it, before the clocks run;
//  * read phase steps (4 x 37 steps, capture stays exact) and write phase
//    steps (+T/4, -T/4, +17 steps, back to 0: DQ/DQS/DM move by the phase,
//    CK and commands do not; wclk - ddr_clk measured);
//  * Loopback = 1: pads always driven, lb_* on the pads during lb_en, the
//    emulator's DM 0, read back through the IOBs and IDDRs;
//  * TFromOddr = 1 (Versal XPIO: T from an ODDRE1 in the pad site, unisim
//    SIM_DEVICE "VERSAL_PREMIUM"): DQ / DM drive state of PHY cycle j on
//    [(j+1.25)T, (j+2.25)T) + write phase, DQS P and N per lane on [(j+1)T,
//    (j+2)T) + write phase, the driver edges at those phases (instead of the
//    pin cycle j+1 of the fabric T flops).
// In every configuration DQS_N is driven exactly when DQS_P is.
// The pad wrapper parameters are parameters of this testbench (xelab
// -generic_top, see the Makefile configurations); the random traffic comes
// from $urandom (xsim -sv_seed). The test prints "tb_bow_ddr_io_xilinx: PASS"
// or "... FAIL (<n> errors)".

`timescale 1ns/1ps

module tb_bow_ddr_io_xilinx import bow_ddr_pkg::*; #(
  parameter int unsigned DqBits         = 8,
  parameter int unsigned AddrPins       = 14,
  parameter int unsigned BankPins       = 2,
  parameter bit          HasDm          = 1'b0,
  parameter bit          HasResetN      = 1'b0,
  parameter bit          HasLs          = 1'b1,
  parameter bit          CkSingleEnded  = 1'b1,
  parameter bit          Loopback       = 1'b0,
  parameter bit          LsDirReadLevel = 1'b1,
  parameter bit          TFromOddr      = 1'b0
);
  localparam int unsigned Lanes = DqBits / 8;
  localparam real T  = 7.5;
  localparam int  PS = 504;
  localparam real D  = 0.1;     // ODDRE1 C -> Q of the unisim model
  localparam real TOL = 0.004;  // edge time tolerance (model rounds to 1 ps)
  // (LAUNCH, the PHY register to ODDR delay, is defined with the stimulus)

  // ---------------------------------------------------------------- clocks
  logic osc = 1'b0;
  always #5.0 osc = ~osc;
  wire clk_sys, ddr_clk, wclk, wclk90, rd_clk, locked_sys, locked_ddr;
  logic ps_en = 0, ps_inc = 0, wps_en = 0, wps_inc = 0;
  wire  ps_done, wps_done;

  bow_ddr_clk_xusp u_clk (
    .clk_pad_i    (osc),
    .rst_i        (1'b0),
    .clk_sys_o    (clk_sys),
    .ddr_clk_o    (ddr_clk),
    .ddr_sys_clk_o(),
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

  // ---------------------------------------------------------------- DUT
  ddr_io_out_t             io_o;
  ddr_io_in_t              io_i;
  logic                    lb_en = 1'b0;
  logic [1:0][MaxDq-1:0]   lb_dq = '0;
  logic [MaxLanes-1:0][1:0] lb_dqs = '0;

  wire ck_p, ck_n, cke, rst_n, odt, cs_n, ras_n, cas_n, we_n;
  wire [BankPins-1:0] ba;
  wire [AddrPins-1:0] a;
  wire [DqBits-1:0]   dq;
  wire [Lanes-1:0]    dqs_p, dqs_n, dm;
  wire ls_oe_n, ls_dir_dq, ls_dir_dqs;

  // testbench side of the bidirectional pads (the "DRAM")
  logic              tb_drv = 1'b0;
  realtime           t_tbdrv = -10.0;   // last change of tb_drv
  always @(tb_drv) t_tbdrv = $realtime;
  logic [DqBits-1:0] tb_dq = '0;
  logic [Lanes-1:0]  tb_dqs = '0;
  assign dq    = tb_drv ? tb_dq : 'z;
  assign dqs_p = tb_drv ? tb_dqs : 'z;
  assign dqs_n = tb_drv ? ~tb_dqs : 'z;

  initial io_o = DDR_IO_OUT_DEFAULT;

  bow_ddr_io_xilinx #(
    .DqBits         (DqBits),
    .Lanes          (Lanes),
    .AddrPins       (AddrPins),
    .BankPins       (BankPins),
    .HasDm          (HasDm),
    .HasResetN      (HasResetN),
    .HasLs          (HasLs),
    .CkSingleEnded  (CkSingleEnded),
    .Loopback       (Loopback),
    .LsDirReadLevel (LsDirReadLevel),
    .TFromOddr      (TFromOddr),
    .SimDevice      (TFromOddr ? "VERSAL_PREMIUM" : "ULTRASCALE_PLUS")
  ) dut (
    .clk_i        (ddr_clk),
    .wclk_i       (wclk),
    .wclk90_i     (wclk90),
    .rd_clk_i     (rd_clk),
    .io_o_i       (io_o),
    .io_i_o       (io_i),
    .lb_en_i      (lb_en),
    .lb_dq_i      (lb_dq),
    .lb_dqs_i     (lb_dqs),
    .ck_p_o       (ck_p),
    .ck_n_o       (ck_n),
    .cke_o        (cke),
    .rst_n_o      (rst_n),
    .odt_o        (odt),
    .cs_n_o       (cs_n),
    .ras_n_o      (ras_n),
    .cas_n_o      (cas_n),
    .we_n_o       (we_n),
    .ba_o         (ba),
    .a_o          (a),
    .dq_io        (dq),
    .dqs_p_io     (dqs_p),
    .dqs_n_io     (dqs_n),
    .dm_o         (dm),
    .ls_oe_n_o    (ls_oe_n),
    .ls_dir_dq_o  (ls_dir_dq),
    .ls_dir_dqs_o (ls_dir_dqs)
  );

  // ---------------------------------------------------------------- utils
  int errors = 0;
  int n_chk = 0, n_edge = 0, n_rd = 0;
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

  // command group as one vector: {a, ba, we, cas, ras, cs, odt, cke, rst_n}
  localparam int unsigned CB = 7 + BankPins + AddrPins;
  function automatic logic [CB-1:0] cmd_of(ddr_io_out_t v);
    return {v.a[AddrPins-1:0], v.ba[BankPins-1:0], v.we_n, v.cas_n, v.ras_n, v.cs_n, v.odt, v.cke,
            (HasResetN ? v.rst_n : 1'b0)};
  endfunction
  wire [CB-1:0] cmd_pins = {a, ba, we_n, cas_n, ras_n, cs_n, odt, cke, rst_n};

  // ---------------------------------------------------------------- stimulus
  int          cyc = 0;
  ddr_io_out_t hist[int];
  logic        hlb[int];
  logic [1:0][MaxDq-1:0]    hlbdq[int];
  logic [MaxLanes-1:0][1:0] hlbdqs[int];
  realtime     tcyc[int];
  int          mode = 0;        // 0 idle (default bundle), 1 random write traffic, 2 read (oe = 0)
  bit          chk_en = 0;      // value / edge checks enabled
  real         phw = 0.0;       // write phase, ns
  realtime     t_ddr = 0;
  int unsigned rnd = 1;        // xorshift32 state, from $urandom (xsim -sv_seed)

  function automatic logic [31:0] r32();
    rnd = rnd ^ (rnd << 13);
    rnd = rnd ^ (rnd >> 17);
    rnd = rnd ^ (rnd << 5);
    return rnd;
  endfunction

  always @(posedge ddr_clk) t_ddr = $realtime;

  // The PHY registers launch at the ddr_clk edge; their path delay to the
  // ODDRs is modelled as LAUNCH: it must lie in [T/4, T/2] for the contract to
  // hold over write phases -T/4..+T/4 (the T/4 clock uncertainty of the board
  // XDC makes static timing enforce exactly this window). TFromOddr: the DQS
  // stage takes the PHY value on the falling edge of wclk ((j+0.5)T + write
  // phase), so the delay must stay below T/4 (static timing: the same
  // uncertainty on ddr_clk -> ddr_wclk).
  localparam real LAUNCH = TFromOddr ? T / 6 : T / 3;
  always @(posedge ddr_clk) begin
    realtime t0;
    t0 = $realtime;
    #(LAUNCH);
    cyc++;
    if (mode == 0) begin
      io_o = DDR_IO_OUT_DEFAULT;
      lb_en = 1'b0;
    end else begin
      io_o = {r32(), r32(), r32(), r32()};
      io_o.dq_oe  = (mode == 1) ? (r32() % 10 != 0) : 1'b0;
      // TFromOddr: the lanes have their own T ODDRs, so their enables differ
      io_o.dqs_oe = (mode != 1) ? 2'b00 :
                    TFromOddr   ? {r32() % 10 != 0, r32() % 10 != 0} : {2{r32() % 10 != 0}};
      lb_dq  = {r32(), r32()};
      lb_dqs = r32();
      // emulator bursts: lb_en in runs of a few cycles
      if (r32() % 4 == 0) lb_en = ~lb_en;
    end
    hist[cyc]   = io_o;
    hlb[cyc]    = lb_en;
    hlbdq[cyc]  = lb_dq;
    hlbdqs[cyc] = lb_dqs;
    tcyc[cyc]   = t0;
    if (chk_en && cyc > 4) schedule_checks(cyc);
  end

  // expected DQ beat b of cycle j (pin value)
  function automatic logic [DqBits-1:0] exp_dq(int j, int b);
    if (Loopback && hlb[j]) return hlbdq[j][b][DqBits-1:0];
    return hist[j].dq[b][DqBits-1:0];
  endfunction
  function automatic logic [Lanes-1:0] exp_dqs(int j, int h);
    logic [Lanes-1:0] v;
    for (int l = 0; l < Lanes; l++) v[l] = (Loopback && hlb[j]) ? hlbdqs[j][l][h] : hist[j].dqs[l][h];
    return v;
  endfunction
  function automatic logic [Lanes-1:0] exp_dm(int j, int b);
    if (Loopback && hlb[j]) return '0;
    return hist[j].dm[b][Lanes-1:0];
  endfunction
  function automatic bit dq_driven(int j);
    return Loopback || hist[j].dq_oe;
  endfunction
  function automatic bit dqs_driven(int j);
    return Loopback || (&hist[j].dqs_oe[Lanes-1:0]);
  endfunction

  // got/exp are compared on their low w bits (an operand of ~ is extended to
  // 64 bits first, the low bits are still right)
  task automatic check_eq(string what, int j, logic [63:0] got, logic [63:0] exp, int w);
    logic [63:0] m;
    m = (w >= 64) ? '1 : ((64'd1 << w) - 64'd1);
    n_chk++;
    if ((got & m) !== (exp & m))
      fail($sformatf("%s of PHY cycle %0d: pin %h, expected %h", what, j, got & m, exp & m));
  endtask

  // TFromOddr drive state checks (every pad of the group; not right after the
  // testbench stops / starts driving)
  task automatic chk_dq_drv(int j, string where);
    if (!chk_en || tb_drv || ($realtime - t_tbdrv) < 1.0) return;
    for (int i = 0; i < DqBits; i++) begin
      n_chk++;
      if (dq_driven(j) != (dq[i] !== 1'bz))
        fail($sformatf("DQ%0d drive state (%s) of cycle %0d: oe %0d pin %b", i, where, j,
                       dq_driven(j), dq[i]));
    end
    if (HasDm) for (int l = 0; l < Lanes; l++) begin
      n_chk++;
      if (dq_driven(j) != (dm[l] !== 1'bz))
        fail($sformatf("DM%0d drive state (%s) of cycle %0d: oe %0d pin %b", l, where, j,
                       dq_driven(j), dm[l]));
    end
  endtask
  task automatic chk_dqs_drv(int j, string where);
    if (!chk_en || tb_drv || ($realtime - t_tbdrv) < 1.0) return;
    for (int l = 0; l < Lanes; l++) begin
      bit e;
      e = Loopback || hist[j].dqs_oe[l];
      n_chk += 2;
      if (e != (dqs_p[l] !== 1'bz))
        fail($sformatf("DQS_P%0d drive state (%s) of cycle %0d: oe %0d pin %b", l, where, j, e,
                       dqs_p[l]));
      if (e != (dqs_n[l] !== 1'bz))
        fail($sformatf("DQS_N%0d drive state (%s) of cycle %0d: oe %0d pin %b", l, where, j, e,
                       dqs_n[l]));
    end
  endtask

  task automatic schedule_checks(int j);
    realtime tj;
    real     pw;
    tj = tcyc[j];
    pw = phw;
    fork
      begin   // CK: pin cycle j+1
        #(tj + 1.25 * T - $realtime);
        if (chk_en) begin
          check_eq("CK_P first half", j, ck_p, hist[j].ck_en, 1);
          check_eq("CK_N first half", j, ck_n, ~hist[j].ck_en, 1);
        end
        #(0.5 * T);
        if (chk_en) begin
          check_eq("CK_P second half", j, ck_p, 1'b0, 1);
          check_eq("CK_N second half", j, ck_n, 1'b1, 1);
        end
      end
      begin   // command group: [(j+1.5)T, (j+2.5)T), centred on CK edge j+2
        #(tj + 1.5 * T + D + 0.03 - $realtime);
        if (chk_en) check_eq("command (window start)", j, cmd_pins, cmd_of(hist[j]), CB);
        #(0.5 * T - 0.03 + 0.05);
        if (chk_en) check_eq("command (CK edge)", j, cmd_pins, cmd_of(hist[j]), CB);
        #(0.5 * T - 0.05 - 0.03);
        if (chk_en) check_eq("command (window end)", j, cmd_pins, cmd_of(hist[j]), CB);
      end
      begin   // level shifters and output enables: pin cycle j+1
        #(tj + 1.5 * T - $realtime);
        if (chk_en) begin
          if (HasLs && !Loopback) begin
            check_eq("LS_OE_N", j, ls_oe_n, hist[j].ls_oe_n, 1);
            check_eq("LS_DIR_DQ", j, ls_dir_dq, hist[j].ls_dir_dq ? LsDirReadLevel : ~LsDirReadLevel, 1);
            check_eq("LS_DIR_DQS", j, ls_dir_dqs, hist[j].ls_dir_dqs ? LsDirReadLevel : ~LsDirReadLevel, 1);
          end else begin
            check_eq("LS_OE_N (const)", j, ls_oe_n, 1'b1, 1);
            check_eq("LS_DIR_DQ (const)", j, ls_dir_dq, ~LsDirReadLevel, 1);
            check_eq("LS_DIR_DQS (const)", j, ls_dir_dqs, ~LsDirReadLevel, 1);
          end
          if (!tb_drv && !TFromOddr) begin   // fabric T flops (TFromOddr: below)
            n_chk++;
            if (dq_driven(j) != (dq[0] !== 1'bz))
              fail($sformatf("DQ drive state of cycle %0d: oe %0d pin %b", j, dq_driven(j), dq[0]));
            n_chk++;
            if (dqs_driven(j) != (dqs_p[0] !== 1'bz)) fail($sformatf("DQS drive state of cycle %0d", j));
            if (HasDm) begin
              n_chk++;
              if (dq_driven(j) != (dm[0] !== 1'bz)) fail($sformatf("DM drive state of cycle %0d", j));
            end
          end
        end
      end
      begin   // TFromOddr: DQ / DM drive state on [(j+1.25)T, (j+2.25)T) + write phase
        if (TFromOddr) begin
          #(tj + 1.25 * T + pw + D + 0.03 - $realtime);
          chk_dq_drv(j, "start");
          #(0.5 * T - 0.03);
          chk_dq_drv(j, "middle");
          #(0.5 * T - 0.03);
          chk_dq_drv(j, "end");
        end
      end
      begin   // TFromOddr: DQS P / N drive state on [(j+1)T, (j+2)T) + write phase
        if (TFromOddr) begin
          #(tj + 1.0 * T + pw + D + 0.03 - $realtime);
          chk_dqs_drv(j, "start");
          #(0.5 * T - 0.03);
          chk_dqs_drv(j, "middle");
          #(0.5 * T - 0.03);
          chk_dqs_drv(j, "end");
        end
      end
      begin   // DQS: pin cycle j+1 shifted by the write phase
        #(tj + 1.25 * T + pw + D - $realtime);
        if (chk_en && dqs_driven(j) && !tb_drv) begin
          check_eq("DQS_P first half", j, dqs_p, exp_dqs(j, 0), Lanes);
          check_eq("DQS_N first half", j, dqs_n, ~exp_dqs(j, 0), Lanes);
        end
        #(0.5 * T);
        if (chk_en && dqs_driven(j) && dqs_driven(j + 1) && !tb_drv) begin
          check_eq("DQS_P second half", j, dqs_p, exp_dqs(j, 1), Lanes);
          check_eq("DQS_N second half", j, dqs_n, ~exp_dqs(j, 1), Lanes);
        end
      end
      begin   // DQ / DM beats
        #(tj + 0.75 * T + pw + D + 0.03 - $realtime);
        if (chk_en && dq_driven(j - 1) && dq_driven(j) && !tb_drv) begin
          check_eq("DQ beat 0 (start)", j, dq, exp_dq(j, 0), DqBits);
          if (HasDm) check_eq("DM beat 0 (start)", j, dm, exp_dm(j, 0), Lanes);
        end
        #(0.25 * T - 0.03);
        if (chk_en && dq_driven(j - 1) && dq_driven(j) && !tb_drv) begin
          check_eq("DQ beat 0 (DQS rise)", j, dq, exp_dq(j, 0), DqBits);
          if (HasDm) check_eq("DM beat 0 (DQS rise)", j, dm, exp_dm(j, 0), Lanes);
        end
        #(0.25 * T - 0.03);
        if (chk_en && dq_driven(j - 1) && dq_driven(j) && !tb_drv) begin
          check_eq("DQ beat 0 (end)", j, dq, exp_dq(j, 0), DqBits);
          if (HasDm) check_eq("DM beat 0 (end)", j, dm, exp_dm(j, 0), Lanes);
        end
        #(0.25 * T + 0.03);
        if (chk_en && dq_driven(j) && dq_driven(j + 1) && !tb_drv) begin
          check_eq("DQ beat 1 (DQS fall)", j, dq, exp_dq(j, 1), DqBits);
          if (HasDm) check_eq("DM beat 1 (DQS fall)", j, dm, exp_dm(j, 1), Lanes);
        end
        #(0.25 * T - 0.03);
        if (chk_en && dq_driven(j) && dq_driven(j + 1) && !tb_drv) begin
          check_eq("DQ beat 1 (end)", j, dq, exp_dq(j, 1), DqBits);
          if (HasDm) check_eq("DM beat 1 (end)", j, dm, exp_dm(j, 1), Lanes);
        end
      end
    join_none
  endtask

  // ------------------------------------------------- transition phase checks
  task automatic edge_chk(string what, real ph0, real ph1);
    real ph;
    if (!chk_en) return;
    ph = $realtime - t_ddr;
    n_edge++;
    if (!near(ph, ph0) && !near(ph, ph1))
      fail($sformatf("%s edge at phase %0.4f ns, allowed %0.4f / %0.4f", what, modt(ph), modt(ph0),
                     modt(ph1)));
  endtask

  always @(cmd_pins) edge_chk("command", 0.5 * T + D, 0.5 * T + D);
  always @(ck_p)     edge_chk("CK_P", D, 0.5 * T + D);

  // DQ / DQS / DM edges between two driven levels: data edges only
  logic [DqBits-1:0] dq_last = 'z;
  always @(dq) begin
    for (int i = 0; i < DqBits; i++) begin
      if (dq[i] !== 1'bz && dq_last[i] !== 1'bz && dq[i] !== dq_last[i] && !tb_drv)
        edge_chk($sformatf("DQ%0d", i), 0.25 * T + phw + D, 0.75 * T + phw + D);
      if (TFromOddr && (dq[i] === 1'bz) != (dq_last[i] === 1'bz) && !tb_drv &&
          ($realtime - t_tbdrv) > 0.0005)
        edge_chk($sformatf("DQ%0d driver", i), 0.25 * T + phw + D, 0.25 * T + phw + D);
    end
    dq_last = dq;
  end
  logic [Lanes-1:0] dqs_last = 'z;
  always @(dqs_p) begin
    for (int l = 0; l < Lanes; l++) begin
      if (dqs_p[l] !== 1'bz && dqs_last[l] !== 1'bz && dqs_p[l] !== dqs_last[l] && !tb_drv)
        edge_chk("DQS_P", phw + D, 0.5 * T + phw + D);
      if (TFromOddr && (dqs_p[l] === 1'bz) != (dqs_last[l] === 1'bz) && !tb_drv &&
          ($realtime - t_tbdrv) > 0.0005)
        edge_chk("DQS_P driver", phw + D, phw + D);
    end
    dqs_last = dqs_p;
  end
  logic [Lanes-1:0] dm_last = 'z;
  always @(dm) begin
    if (HasDm) begin
      for (int l = 0; l < Lanes; l++) begin
        if (dm[l] !== 1'bz && dm_last[l] !== 1'bz && dm[l] !== dm_last[l])
          edge_chk("DM", 0.25 * T + phw + D, 0.75 * T + phw + D);
        if (TFromOddr && (dm[l] === 1'bz) != (dm_last[l] === 1'bz))
          edge_chk("DM driver", 0.25 * T + phw + D, 0.25 * T + phw + D);
      end
    end
    dm_last = dm;
  end

  // DQS_N is driven exactly when DQS_P is (one T flop per pair, or one T ODDR
  // per pad on the same enable)
  int n_pn = 0;
  always @(dqs_p or dqs_n) begin
    #0.001;
    if (!tb_drv && ($realtime - t_tbdrv) > 0.0005 && $realtime > 1.0) begin
      for (int l = 0; l < Lanes; l++) begin
        n_pn++;
        if ((dqs_p[l] === 1'bz) != (dqs_n[l] === 1'bz))
          fail($sformatf("DQS_P%0d %b / DQS_N%0d %b drive states differ", l, dqs_p[l], l, dqs_n[l]));
      end
    end
  end

  // ---------------------------------------------------------- read capture
  logic [DqBits-1:0] s_r = 'x, s_f = 'x;
  logic [Lanes-1:0]  q_r = 'x, q_f = 'x;
  bit rd_chk_en = 0;
  always @(negedge rd_clk) begin
    s_f = dq;
    q_f = dqs_p;
  end
  always @(posedge rd_clk) begin
    logic [DqBits-1:0] nr;
    logic [Lanes-1:0]  nq;
    logic [DqBits-1:0] pr, pf;
    logic [Lanes-1:0]  pqr, pqf;
    nr  = dq;
    nq  = dqs_p;
    pr  = s_r;
    pf  = s_f;
    pqr = q_r;
    pqf = q_f;
    #0.15;   // IDDRE1 C -> Q1/Q2 is 100 ps in the unisim model
    if (rd_chk_en) begin
      if (!$isunknown(pr)) begin
        n_rd++;
        if (io_i.dq[0][DqBits-1:0] !== pr)
          fail($sformatf("IDDR DQ rise: got %h, pad was %h", io_i.dq[0][DqBits-1:0], pr));
      end
      if (!$isunknown(pf)) begin
        n_rd++;
        if (io_i.dq[1][DqBits-1:0] !== pf)
          fail($sformatf("IDDR DQ fall: got %h, pad was %h", io_i.dq[1][DqBits-1:0], pf));
      end
      if (!$isunknown(pqr) && io_i.dqs[0][Lanes-1:0] !== pqr) fail("IDDR DQS rise");
      if (!$isunknown(pqf) && io_i.dqs[1][Lanes-1:0] !== pqf) fail("IDDR DQS fall");
      for (int b = DqBits; b < MaxDq; b++)
        if (io_i.dq[0][b] !== 1'b0 || io_i.dq[1][b] !== 1'b0) fail("unused io_i.dq bit not 0");
      for (int l = Lanes; l < MaxLanes; l++)
        if (io_i.dqs[0][l] !== 1'b0 || io_i.dqs[1][l] !== 1'b0) fail("unused io_i.dqs bit not 0");
    end
    s_r = nr;
    q_r = nq;
  end

  // DRAM side read data: change half way between rd_clk edges
  task automatic drive_reads(int n);
    tb_drv = 1'b1;
    repeat (n) begin
      @(posedge rd_clk);
      #(T / 4);
      tb_dq = r32();
      tb_dqs = r32();
      #(T / 2);
      tb_dq = r32();
      tb_dqs = r32();
    end
    @(posedge rd_clk);
    #(T / 4);
    tb_drv = 1'b0;
  endtask

  // ---------------------------------------------------------- phase steps
  task automatic step(bit w, bit inc, int n);
    $display("tb_bow_ddr_io_xilinx: step port %0d inc %0d x%0d @%0t", w, inc, n, $time);
    repeat (n) begin
      @(posedge ddr_clk);
      #0.05;
      if (w) begin wps_en = 1; wps_inc = inc; end
      else   begin ps_en = 1;  ps_inc = inc;  end
      @(posedge ddr_clk);
      #0.05;
      wps_en = 0; ps_en = 0;
      // PSDONE is set at a PSCLK edge and cleared at the next one: look at it
      // just after each edge (no race with the model's process)
      do begin
        @(posedge ddr_clk);
        #0.05;
      end while ((w ? wps_done : ps_done) !== 1'b1);
    end
  endtask

  task automatic set_wphase(int k);   // absolute write phase in steps (from 0)
    static int now = 0;
    chk_en = 0;
    repeat (8) @(posedge ddr_clk);
    if (k > now) step(1, 1, k - now);
    if (k < now) step(1, 0, now - k);
    now = k;
    phw = k * T / PS;
    repeat (8) @(posedge ddr_clk);
    begin
      realtime t0, t1;
      @(posedge ddr_clk);
      t0 = $realtime;
      @(posedge wclk);
      t1 = $realtime;
      $display("tb_bow_ddr_io_xilinx: write phase %0d steps: wclk - ddr_clk = %0.4f ns (expected %0.4f mod T) @%0t",
               k, t1 - t0, phw, $time);
      if (!near(t1 - t0, phw)) fail("write phase not where expected");
    end
    chk_en = 1;
  endtask

  // ---------------------------------------------------------------- main
  initial begin
    rnd = $urandom;
    if (rnd == 0) rnd = 1;
    $write("tb_bow_ddr_io_xilinx: DqBits %0d AddrPins %0d BankPins %0d HasDm %0d HasResetN %0d ",
           DqBits, AddrPins, BankPins, HasDm, HasResetN);
    $display("HasLs %0d CkSE %0d Loopback %0d LsDirRead %0d, xorshift seed %08h",
             HasLs, CkSingleEnded, Loopback, LsDirReadLevel, rnd);
    // idle levels during GSR (glbl, first 100 ns) and after it, before the clocks run
    for (int k = 0; k < 2; k++) begin
      #(k == 0 ? 50.0 : 100.0);
      if (ddr_clk === 1'b1 || locked_sys === 1'b1) fail("clocks already running (test setup)");
      if ({cs_n, ras_n, cas_n, we_n} !== 4'b1111)
        fail($sformatf("idle CS/RAS/CAS/WE = %b", {cs_n, ras_n, cas_n, we_n}));
      if ({cke, odt} !== 2'b00 || ba !== '0 || a !== '0) fail("idle CKE/ODT/BA/A not 0");
      if (ck_p !== 1'b0 || ck_n !== 1'b1) fail($sformatf("idle CK_P/CK_N = %b%b", ck_p, ck_n));
      if (HasResetN && rst_n !== 1'b0) fail("idle RESET# not 0");
      if (ls_oe_n !== 1'b1 || ls_dir_dq !== ~LsDirReadLevel || ls_dir_dqs !== ~LsDirReadLevel)
        fail("idle level shifter pins");
      if (Loopback) begin
        if (dq !== '0 || dqs_p !== '0 || dqs_n !== '1) fail("loopback idle DQ/DQS not driven at SRVAL");
        if (HasDm && dm !== '0) fail("loopback idle DM");
      end else begin
        if (dq !== 'z || dqs_p !== 'z || dqs_n !== 'z) fail("DQ/DQS driven before the clocks run");
        if (HasDm && dm !== 'z) fail("DM driven before the clocks run");
      end
    end
    wait (locked_ddr === 1'b1);
    repeat (20) @(posedge ddr_clk);
    $display("tb_bow_ddr_io_xilinx: clocks locked at %0t", $time);

    // ---- idle bundle after reset: commands DES, CK stopped
    mode = 0;
    repeat (10) @(posedge ddr_clk);
    chk_en = 1;
    rd_chk_en = 1;
    repeat (20) @(posedge ddr_clk);

    // ---- random traffic at write phase 0
    $display("tb_bow_ddr_io_xilinx: random traffic @%0t", $time);
    mode = 1;
    repeat (1500) @(posedge ddr_clk);

    // ---- read capture (non-loopback: the TB drives the pads)
    $display("tb_bow_ddr_io_xilinx: read capture / read phase sweep @%0t", $time);
    if (!Loopback) begin
      mode = 2;
      repeat (4) @(posedge ddr_clk);
      drive_reads(400);
      // read phase sweep: capture stays exact at any rd_clk phase
      for (int k = 0; k < 4; k++) begin
        rd_chk_en = 0;
        step(0, 1, 37);
        rd_chk_en = 1;
        drive_reads(100);
      end
      mode = 1;
    end else begin
      for (int k = 0; k < 4; k++) begin
        rd_chk_en = 0;
        step(0, 1, 37);
        rd_chk_en = 1;
        repeat (300) @(posedge ddr_clk);
      end
    end

    // ---- write phase +T/4, -T/4, +17 steps
    $display("tb_bow_ddr_io_xilinx: write phase sweep @%0t", $time);
    set_wphase(126);       // +PS/4
    repeat (800) @(posedge ddr_clk);
    $display("tb_bow_ddr_io_xilinx: +T/4 traffic done @%0t", $time);
    set_wphase(0 - 126);   // -PS/4 (xsim evaluated -PS / 4 as unsigned)
    repeat (800) @(posedge ddr_clk);
    set_wphase(17);
    repeat (800) @(posedge ddr_clk);
    set_wphase(0);
    repeat (300) @(posedge ddr_clk);

    chk_en = 0;
    repeat (10) @(posedge ddr_clk);
    $display("tb_bow_ddr_io_xilinx: %0d value checks, %0d edge checks, %0d IDDR checks, %0d PHY cycles",
             n_chk, n_edge, n_rd, cyc);
    if (n_chk < 10000 || n_edge < 1000 || n_rd < 1000) fail("too few checks");
    if (errors == 0) $display("tb_bow_ddr_io_xilinx: PASS");
    else $display("tb_bow_ddr_io_xilinx: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #3ms;
    $display("tb_bow_ddr_io_xilinx: FAIL (timeout)");
    $finish;
  end
endmodule
