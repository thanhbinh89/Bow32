// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// The eight experiments of the security review (docs/mkv_security_review.md,
// section 7) as a pass / fail test: each one injects the fault model or
// measures the effect the review found, and checks the behaviour of the
// fixed IP. `make review` (also part of `make test`).
//
//   E1  one bit of the output register (dout_q) flips during the check pass
//   E2  two bits of the same byte of a stored round key flip (even weight)
//   E3  one round key row overwritten by another, code included (address
//       decoder / word line fault)
//   E4  the CLEAR wipe is cut short (row counter jumps)
//   E5  the wipe after reset is cut short
//   E6  one FSM bit flips in Check of KEY; the state jumps from Check to Clear
//   E7  longest bus stall of a single access (CMD right after KEY, R = 9),
//       without and with NOSTALL
//   E8  repeated fault / CLEAR / KEY cycles: lockout after FaultLimit faults
//
// Before the fixes (review commit) E1-E3 released a wrong result with DONE
// and no FAULT, E4 / E5 left 14 round key rows, E6 reported KEY_VALID for
// an empty key schedule, E7 stalled 144 cycles, E8 took 50 new keys.

`timescale 1ns / 1ps

module tb_mkv_review;
  import bow_bus_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b1;
  logic por_n = 1'b1;
  always #10.0 clk = ~clk;

  bus_req_t reg_req = BUS_REQ_DEFAULT;
  bus_rsp_t reg_rsp;
  logic     irq, alert_fault, alert_fatal;

  bow_mkv dut (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .por_rst_ni    (por_n),
    .bus_req_i     (reg_req),
    .bus_rsp_o     (reg_rsp),
    .irq_o         (irq),
    .alert_fault_o (alert_fault),
    .alert_fatal_o (alert_fatal)
  );

  localparam logic [31:0] RegCtrl = 32'h008, RegCmd = 32'h00C, RegStatus = 32'h010,
                          RegKey = 32'h040, RegDin = 32'h080, RegDout = 32'h0C0;
  localparam logic [31:0] CmdKey = 32'h1, CmdEnc = 32'h2, CmdDec = 32'h4, CmdClear = 32'h8;
  localparam logic [31:0] CtrlNoStall = 32'h8;
  localparam int unsigned StBusy = 0, StKeyValid = 1, StDone = 2, StErr = 3, StFault = 5, StLocked = 6;
  localparam logic [5:0]  SEnc = 6'b110011, SDec = 6'b101101, SClear = 6'b001011, SCheck = 6'b011110;
  localparam logic [3:0]  MTrue = 4'b0110, MFalse = 4'b1001;
  localparam int unsigned FaultLimit = 4;

  // ---------------------------------------------------------------- bus BFM
  int unsigned last_stall;

  task automatic bus_xfer(input bit we, input logic [31:0] addr, input logic [31:0] wdata,
                          output logic [31:0] rdata);
    bus_req_t r;
    bit       g;
    r       = BUS_REQ_DEFAULT;
    r.req   = 1'b1;
    r.we    = we;
    r.be    = 4'hF;
    r.addr  = addr;
    r.wdata = wdata;
    @(posedge clk);
    #1;
    reg_req    = r;
    last_stall = 0;
    do begin
      @(negedge clk);
      g = reg_rsp.gnt;
      if (!g) last_stall++;
      @(posedge clk);
      #1;
    end while (!g);
    reg_req = BUS_REQ_DEFAULT;
    @(negedge clk);
    rdata = reg_rsp.rdata;
  endtask

  task automatic wr(input logic [31:0] addr, input logic [31:0] data);
    logic [31:0] d;
    bus_xfer(1'b1, addr, data, d);
  endtask

  task automatic rd(input logic [31:0] addr, output logic [31:0] data);
    bus_xfer(1'b0, addr, '0, data);
  endtask

  task automatic wait_idle();
    logic [31:0] st;
    repeat (3) @(posedge clk);                // a fault is acted on 2 cycles later
    do rd(RegStatus, st); while (st[StBusy]);
  endtask

  task automatic clear_all();
    wr(RegCmd, CmdClear);
    wait_idle();
    wr(RegStatus, 32'h2C);
  endtask

  // power-on reset between the experiments: the fault counter starts at 0
  task automatic power_on();
    @(negedge clk);
    por_n = 1'b0;
    rst_n = 1'b0;
    repeat (3) @(negedge clk);
    por_n = 1'b1;
    rst_n = 1'b1;
    wait_idle();
  endtask

  // MKV-256 with a 256 bit key (R = 7, h[0..14])
  task automatic set_key(logic [511:0] key);
    wr(RegCtrl, 32'h1);
    for (int i = 0; i < 8; i++) wr(RegKey + 4 * i, key[32*i +: 32]);
    wr(RegCmd, CmdKey);
    wait_idle();
    wr(RegStatus, 32'h2C);
  endtask

  task automatic run(input logic [31:0] cmd, input logic [255:0] blk, output logic [255:0] out,
                     output logic [31:0] st);
    logic [31:0] w;
    for (int i = 0; i < 8; i++) wr(RegDin + 4 * i, blk[32*i +: 32]);
    wr(RegCmd, cmd);
    out = '0;
    for (int j = 0; j < 8; j++) begin
      rd(RegDout + 4 * j, w);
      out[32*j +: 32] = w;
    end
    wait_idle();
    rd(RegStatus, st);
  endtask

  int unsigned n_pass = 0, n_run = 0;

  task automatic result(string id, string what, bit ok, string detail);
    string verdict;
    n_run++;
    if (ok) begin
      n_pass++;
      verdict = "FIXED";
    end else begin
      verdict = "STILL OPEN";
    end
    $display("RESULT %s %s: %s: %s", id, what, verdict, detail);
    if (!ok) $fatal(1, "%s: the fix does not hold", id);
  endtask

  // detected: FAULT, no DONE, nothing released
  function automatic bit detected(logic [31:0] st, logic [255:0] got);
    return st[StFault] && !st[StDone] && got == '0;
  endfunction

  function automatic int unsigned rows_left();
    int unsigned n = 0;
    for (int i = 0; i < 32; i++) if (dut.u_core.rk_mem[i][255:0] != '0) n++;
    return n;
  endfunction

  // ------------------------------------------------------------------- main
  logic [511:0] key;
  logic [255:0] p, c_ref, c, v;
  logic [31:0]  st;
  logic [311:0] row;
  int unsigned  n_det, n_acc, stall_default;

  initial begin
    power_on();
    key = '0;
    for (int i = 0; i < 8; i++) key[32*i +: 32] = $urandom();
    for (int i = 0; i < 8; i++) p[32*i +: 32]   = $urandom();

    set_key(key);
    run(CmdEnc, p, c_ref, st);
    if (st[StFault] || !st[StDone]) $fatal(1, "reference ENC: STATUS %08x", st);
    wr(RegStatus, 32'h2C);

    // E1: the result register has a complement copy, checked in Check
    fork
      run(CmdEnc, p, c, st);
      begin
        wait (dut.u_core.fsm_q == SDec && dut.u_core.chk_q == MTrue && dut.u_core.step_q == 5'd4);
        @(negedge clk);
        v = dut.u_core.dout_q ^ (256'd1 << 100);
        dut.u_core.dout_q = v;
      end
    join
    result("E1", "dout_q bit flip in the check pass", detected(st, c), $sformatf("FAULT, STATUS %08x", st));
    power_on();

    // E2: the code of the row sees an even number of flipped bits in a byte
    set_key(key);
    row = dut.u_core.rk_mem[13];
    row[8*5 + 1] = ~row[8*5 + 1];
    row[8*5 + 6] = ~row[8*5 + 6];
    dut.u_core.rk_mem[13] = row;
    run(CmdEnc, p, c, st);
    result("E2", "two-bit flip in one byte of h[13]", detected(st, c), $sformatf("FAULT, STATUS %08x", st));
    power_on();

    // E3: the code is bound to the row address
    set_key(key);
    dut.u_core.rk_mem[12] = dut.u_core.rk_mem[11];
    run(CmdEnc, p, c, st);
    result("E3", "row h[12] := h[11]", detected(st, c), $sformatf("FAULT, STATUS %08x", st));
    power_on();

    // E4: the wipe is read back and counted; a cut makes it start again
    set_key(key);
    fork
      wr(RegCmd, CmdClear);
      begin
        wait (dut.u_core.fsm_q == SClear && dut.u_core.step_q == 5'd1);
        @(negedge clk);
        dut.u_core.step_q = 5'd30;
      end
    join
    wait_idle();
    rd(RegStatus, st);
    result("E4", "CLEAR cut short", st[StFault] && !st[StDone] && rows_left() == 0,
           $sformatf("DONE %0d, FAULT %0d, %0d round key rows left", st[StDone], st[StFault], rows_left()));
    power_on();

    // E5: the same on the wipe after reset
    set_key(key);
    @(negedge clk);
    rst_n = 1'b0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    wait (dut.u_core.fsm_q == SClear && dut.u_core.step_q == 5'd1);
    @(negedge clk);
    dut.u_core.step_q = 5'd30;
    wait_idle();
    rd(RegStatus, st);
    result("E5", "reset wipe cut short", st[StFault] && rows_left() == 0,
           $sformatf("STATUS %08x, %0d round key rows left", st, rows_left()));
    power_on();

    // E6: sparse state code (one bit gives no state); a jump between states
    // (Check -> Clear) is caught by the cycle count of Clear; KEY_VALID is the
    // AND of the register block and the engine
    wr(RegCtrl, 32'h1);
    for (int i = 0; i < 8; i++) wr(RegKey + 4 * i, key[32*i +: 32]);
    fork
      wr(RegCmd, CmdKey);
      begin
        wait (dut.u_core.fsm_q == SCheck);
        @(negedge clk);
        /* verilator lint_off ENUMVALUE */
        dut.u_core.fsm_q = dut.u_core.fsm_q ^ 6'b000001;
        /* verilator lint_on ENUMVALUE */
      end
    join
    wait_idle();
    rd(RegStatus, st);
    result("E6", "FSM bit flip in Check of KEY", st[StFault] && !st[StKeyValid] && !dut.key_valid_q,
           $sformatf("KEY_VALID %0d, FAULT %0d, engine key schedule %0d", st[StKeyValid], st[StFault],
                     dut.u_core.ks_valid_q == MTrue));
    power_on();
    wr(RegCtrl, 32'h1);
    for (int i = 0; i < 8; i++) wr(RegKey + 4 * i, key[32*i +: 32]);
    fork
      wr(RegCmd, CmdKey);
      begin
        wait (dut.u_core.fsm_q == SCheck);
        @(negedge clk);
        /* verilator lint_off ENUMVALUE */
        dut.u_core.fsm_q = SClear;
        /* verilator lint_on ENUMVALUE */
      end
    join
    wait_idle();
    rd(RegStatus, st);
    result("E6", "FSM Check -> Clear in KEY", st[StFault] && !st[StKeyValid] && !dut.key_valid_q,
           $sformatf("KEY_VALID %0d, FAULT %0d", st[StKeyValid], st[StFault]));
    power_on();

    // E7: by default an access still waits for the command; with NOSTALL
    // nothing waits (the write is dropped with ERR, software polls BUSY)
    wr(RegCtrl, 32'h5);                       // MKV-256, k = 2l, R = 9
    for (int i = 0; i < 16; i++) wr(RegKey + 4 * i, key[32*i +: 32]);
    wr(RegCmd, CmdKey);
    wr(RegCmd, CmdEnc);
    stall_default = last_stall;
    wait_idle();
    clear_all();
    wr(RegCtrl, 32'h5 | CtrlNoStall);
    for (int i = 0; i < 16; i++) wr(RegKey + 4 * i, key[32*i +: 32]);
    wr(RegCmd, CmdKey);
    wr(RegCmd, CmdEnc);
    rd(RegStatus, st);
    result("E7", "CMD write right after KEY (R = 9)", last_stall == 0 && st[StErr] && st[StBusy],
           $sformatf("stalls %0d cycles by default, %0d with NOSTALL (dropped, ERR)", stall_default,
                     last_stall));
    wait_idle();
    power_on();

    // E8: after FaultLimit faults since power-on the IP locks itself: no new
    // key until the next power-on reset
    n_det = 0;
    n_acc = 0;
    for (int t = 0; t < 50; t++) begin
      set_key(key);
      rd(RegStatus, st);
      if (st[StKeyValid]) n_acc++;
      fork
        run(CmdEnc, p, c, st);
        begin
          if (n_acc == t + 1) begin             // only an accepted key runs ENC
            wait (dut.u_core.fsm_q == SEnc && dut.u_core.chk_q == MFalse && dut.u_core.step_q == 5'd12);
            @(negedge clk);
            v = dut.u_core.st_q ^ (256'd1 << (t % 256));
            force dut.u_core.st_q = v;
            @(posedge clk);
            #1 release dut.u_core.st_q;
          end
        end
      join
      if (st[StFault]) n_det++;
      clear_all();
    end
    rd(RegStatus, st);
    result("E8", "50 fault attempts", n_acc == FaultLimit && n_det == FaultLimit && st[StLocked] && alert_fatal,
           $sformatf("%0d detected, %0d new keys accepted, then LOCKED (fatal alert)", n_det, n_acc));

    $display("tb_mkv_review: PASS (%0d/%0d)", n_pass, n_run);
    $finish;
  end

endmodule
