// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Review experiments on bow_mkv (docs/ip/mkv_review.md): fault models and
// integration effects that tb_bow_mkv does not cover. This is not a pass / fail
// test: every experiment prints one RESULT line describing what the IP does
// today. `make review` builds and runs it; it is not part of `make test`.
//
//   E1  one bit of the output register (dout_q) flips during the check pass
//   E2  two bits of the same byte of a stored round key flip (even weight)
//   E3  one round key row overwritten by another, parity included (address
//       decoder / word line fault)
//   E4  the CLEAR wipe is cut short (address counter jumps)
//   E5  the wipe after reset is cut short
//   E6  one FSM bit flips in Check of KEY (Check 101 -> Clear 100)
//   E7  longest bus stall of a single access (CMD right after KEY, R = 9)
//   E8  repeated fault / CLEAR / KEY cycles: is there any lockout?

`timescale 1ns / 1ps

module tb_mkv_review;
  import bow_bus_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b1;
  always #10.0 clk = ~clk;

  bus_req_t reg_req = BUS_REQ_DEFAULT;
  bus_rsp_t reg_rsp;
  logic     irq;

  bow_mkv dut (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .bus_req_i (reg_req),
    .bus_rsp_o (reg_rsp),
    .irq_o     (irq)
  );

  localparam logic [31:0] RegCtrl = 32'h008, RegCmd = 32'h00C, RegStatus = 32'h010,
                          RegKey = 32'h040, RegDin = 32'h080, RegDout = 32'h0C0;
  localparam logic [31:0] CmdKey = 32'h1, CmdEnc = 32'h2, CmdDec = 32'h4, CmdClear = 32'h8;
  localparam int unsigned StBusy = 0, StKeyValid = 1, StDone = 2, StFault = 5;

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
    do rd(RegStatus, st); while (st[StBusy]);
  endtask

  task automatic clear_all();
    wr(RegCmd, CmdClear);
    wait_idle();
    wr(RegStatus, 32'h2C);
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
    rd(RegStatus, st);
  endtask

  function automatic string verdict(logic [31:0] st, logic [255:0] got, logic [255:0] good);
    if (st[StFault]) return "detected (FAULT, nothing released)";
    if (got == good) return "no effect (correct result)";
    return "NOT DETECTED: wrong result released with DONE, no FAULT";
  endfunction

  function automatic int unsigned rows_left();
    int unsigned n = 0;
    for (int i = 0; i < 32; i++) if (dut.u_core.rk_mem[i] != '0) n++;
    return n;
  endfunction

  // ------------------------------------------------------------------- main
  logic [511:0] key;
  logic [255:0] p, c_ref, c, d;
  logic [31:0]  st;
  logic [287:0] row;
  int unsigned  n_det, n_acc;

  initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    wait_idle();
    key = '0;
    for (int i = 0; i < 8; i++) key[32*i +: 32] = $urandom();
    for (int i = 0; i < 8; i++) p[32*i +: 32]   = $urandom();

    set_key(key);
    run(CmdEnc, p, c_ref, st);
    if (st[StFault] || !st[StDone]) $fatal(1, "reference ENC: STATUS %08x", st);
    wr(RegStatus, 32'h2C);

    // E1: the released value is a separate register that the check never reads
    fork
      run(CmdEnc, p, c, st);
      begin
        wait (dut.u_core.fsm_q == 3'd3 && dut.u_core.chk_q && dut.u_core.step_q == 5'd4);
        @(negedge clk);
        force dut.u_core.dout_q = dut.u_core.dout_q ^ (256'd1 << 100);
        @(posedge clk);
        #1 release dut.u_core.dout_q;
      end
    join
    $display("RESULT E1 dout_q bit flip in the check pass: %s", verdict(st, c, c_ref));
    clear_all();

    // E2: parity per byte does not see an even number of flipped bits; the
    // same faulty round key is used by both passes, so D(E(P)) = P
    set_key(key);
    row = dut.u_core.rk_mem[13];
    row[8*5 + 1] = ~row[8*5 + 1];
    row[8*5 + 6] = ~row[8*5 + 6];
    dut.u_core.rk_mem[13] = row;
    run(CmdEnc, p, c, st);
    $display("RESULT E2 two-bit flip in one byte of h[13]: %s", verdict(st, c, c_ref));
    if (!st[StFault]) begin
      $display("        C xor C* = %h", c ^ c_ref);
      run(CmdDec, c, d, st);
      $display("        DEC(C*) gives P back: %0d, FAULT %0d", d == p, st[StFault]);
    end
    clear_all();

    // E3: parity is not bound to the address: a whole row in the wrong place
    // (with its own parity) is accepted
    set_key(key);
    dut.u_core.rk_mem[12] = dut.u_core.rk_mem[11];
    run(CmdEnc, p, c, st);
    $display("RESULT E3 row h[12] := h[11]: %s", verdict(st, c, c_ref));
    clear_all();

    // E4: no fault check while the engine is in Clear, no check of the wipe
    set_key(key);
    fork
      wr(RegCmd, CmdClear);
      begin
        wait (dut.u_core.fsm_q == 3'd4 && dut.u_core.step_q == 5'd1);
        @(negedge clk);
        force dut.u_core.step_q = 5'd30;
        @(posedge clk);
        #1 release dut.u_core.step_q;
      end
    join
    wait_idle();
    rd(RegStatus, st);
    $display("RESULT E4 CLEAR cut short: DONE %0d, FAULT %0d, %0d round key rows left",
             st[StDone], st[StFault], rows_left());
    clear_all();

    // E5: the same on the wipe after reset
    set_key(key);
    rst_n = 1'b0;
    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    wait (dut.u_core.fsm_q == 3'd4 && dut.u_core.step_q == 5'd1);
    @(negedge clk);
    force dut.u_core.step_q = 5'd30;
    @(posedge clk);
    #1 release dut.u_core.step_q;
    wait_idle();
    rd(RegStatus, st);
    $display("RESULT E5 reset wipe cut short: STATUS %08x, %0d round key rows left", st, rows_left());
    clear_all();

    // E6: binary FSM encoding: one flipped bit turns Check into Clear; the
    // register block then reports KEY_VALID for an empty key schedule
    wr(RegCtrl, 32'h1);
    for (int i = 0; i < 8; i++) wr(RegKey + 4 * i, key[32*i +: 32]);
    fork
      wr(RegCmd, CmdKey);
      begin
        wait (dut.u_core.fsm_q == 3'd5);
        @(negedge clk);
        force dut.u_core.fsm_q = dut.u_core.Clear;
        @(posedge clk);
        #1 release dut.u_core.fsm_q;
      end
    join
    wait_idle();
    rd(RegStatus, st);
    $display("RESULT E6 FSM Check -> Clear in KEY: KEY_VALID %0d, FAULT %0d, engine key schedule %0d",
             st[StKeyValid], st[StFault], dut.u_core.ks_valid_q);
    run(CmdEnc, p, c, st);
    $display("        next ENC: FAULT %0d (caught only when the key is used)", st[StFault]);
    clear_all();

    // E7: one access waits for the whole key schedule (gnt = 0): the
    // peripheral bus is held for every host meanwhile
    wr(RegCtrl, 32'h5);                       // MKV-256, k = 2l, R = 9
    for (int i = 0; i < 16; i++) wr(RegKey + 4 * i, key[32*i +: 32]);
    wr(RegCmd, CmdKey);
    wr(RegCmd, CmdEnc);
    $display("RESULT E7 CMD write right after KEY (R = 9) stalls the bus %0d cycles", last_stall);
    wait_idle();
    clear_all();

    // E8: a fault attempt can be repeated without limit (no counter, no lockout)
    n_det = 0;
    n_acc = 0;
    for (int t = 0; t < 50; t++) begin
      set_key(key);
      rd(RegStatus, st);
      if (st[StKeyValid]) n_acc++;
      fork
        run(CmdEnc, p, c, st);
        begin
          wait (dut.u_core.fsm_q == 3'd2 && !dut.u_core.chk_q && dut.u_core.step_q == 5'd12);
          @(negedge clk);
          force dut.u_core.st_q = dut.u_core.st_q ^ (256'd1 << (t % 256));
          @(posedge clk);
          #1 release dut.u_core.st_q;
        end
      join
      if (st[StFault]) n_det++;
      clear_all();
    end
    $display("RESULT E8 50 fault attempts: %0d detected, %0d new keys accepted after a fault",
             n_det, n_acc);

    $display("tb_mkv_review: done");
    $finish;
  end

endmodule
