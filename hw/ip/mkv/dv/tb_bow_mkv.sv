// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit testbench of the Bow32 MKV block cipher (Verilator --binary --timing).
//
// Reads a test case written by `tools/mkv/mkv_model.py gen DIR`:
//   case.txt   "<op> <l> <k> <key> <in> <out>" per operation, op E / D,
//              hex in the byte order of the standard (first: Annex A)
// runs every operation through the register bus (key schedule when the
// key / version changes, random byte-enable writes, DIN written while the
// previous block is being processed, DOUT read stalled or after polling)
// and writes
//   DIR/out.txt     "<op> <output>" per operation
//   DIR/trace.txt   "<n> <step> <state>": state register after every step
//   DIR/rk.txt      "<n> <i> <h[i]>": round key memory after each key schedule
//   DIR/status.txt  "OK <operations>"
// which `mkv_model.py check DIR` compares with the model. After every key
// schedule: no key material left in the engine registers, no round key of
// a previous longer key in the RAM. Directed checks at the end: errors
// (ERR), KEY_VALID rules, KEY needs a whole new key (no byte of the old
// one), DIN / DOUT wiped, CLEAR, interrupt, CYCLES, RAM wipe after reset,
// then faults injected into the engine (each must be detected, release
// nothing and zero everything).

`timescale 1ns / 1ps

module tb_bow_mkv;
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

  localparam logic [31:0] RegId = 32'h000, RegInfo = 32'h004, RegCtrl = 32'h008, RegCmd = 32'h00C,
                          RegStatus = 32'h010, RegIrqEn = 32'h014, RegCycles = 32'h018,
                          RegKey = 32'h040, RegDin = 32'h080, RegDout = 32'h0C0;
  localparam logic [31:0] CmdKey = 32'h1, CmdEnc = 32'h2, CmdDec = 32'h4, CmdClear = 32'h8;
  localparam int unsigned StBusy = 0, StKeyValid = 1, StDone = 2, StErr = 3, StWide = 4, StFault = 5;

  // ---------------------------------------------------------------- bus BFM
  // Holds req until gnt (gnt is sampled in the middle of the cycle), returns
  // the read data of the response cycle and the number of stalled cycles.
  int unsigned last_stall;

  task automatic bus_xfer(input bit we, input logic [31:0] addr, input logic [31:0] wdata,
                          input logic [3:0] be, output logic [31:0] rdata);
    bus_req_t r;
    bit       g;
    r       = BUS_REQ_DEFAULT;
    r.req   = 1'b1;
    r.we    = we;
    r.be    = be;
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
    if (!reg_rsp.rvalid) $fatal(1, "no rvalid one cycle after the transfer (addr %03x)", addr);
    if (reg_rsp.err)     $fatal(1, "bus error (addr %03x)", addr);
    rdata = reg_rsp.rdata;
  endtask

  task automatic wr(input logic [31:0] addr, input logic [31:0] data);
    logic [31:0] d;
    bus_xfer(1'b1, addr, data, 4'hF, d);
  endtask

  // one word as four byte writes (sb), in random order
  task automatic wr_bytes(input logic [31:0] addr, input logic [31:0] data);
    logic [31:0] d;
    int unsigned order [$];
    order = '{0, 1, 2, 3};
    order.shuffle();
    foreach (order[i]) bus_xfer(1'b1, addr, data, 4'(1 << order[i]), d);
  endtask

  task automatic rd(input logic [31:0] addr, output logic [31:0] data);
    bus_xfer(1'b0, addr, '0, 4'hF, data);
  endtask

  function automatic void expect_eq(logic [31:0] got, logic [31:0] exp, string what);
    if (got !== exp) $fatal(1, "%s: %08x, expected %08x", what, got, exp);
  endfunction

  // --------------------------------------------------------------- helpers
  // standard byte order (hex string, first byte = most significant digits)
  // <-> RTL vector (byte b at [8*b +: 8])
  function automatic logic [511:0] to_rtl(logic [511:0] x, int unsigned nbytes);
    logic [511:0] r;
    r = '0;
    for (int unsigned b = 0; b < nbytes; b++) r[8*b +: 8] = x[8*(nbytes-1-b) +: 8];
    return r;
  endfunction

  function automatic string hex(logic [511:0] v, int unsigned nbytes);
    string s;
    s = "";
    for (int unsigned b = 0; b < nbytes; b++) s = {s, $sformatf("%02x", v[8*b +: 8])};
    return s;
  endfunction

  // ---------------------------------------------- state / round key monitors
  string       dir;
  int          fout, ftrace, frk;
  int          cur_op = -1;
  int unsigned cur_bytes = 16;
  bit          logging = 1'b0, log_step = 1'b0, dump_rk = 1'b0, chk_wipe = 1'b0;
  logic [4:0]  step_n;
  int unsigned trace_lines = 0;

  always @(negedge clk) begin
    if (log_step && logging) begin
      $fdisplay(ftrace, "%0d %0d %s", cur_op, step_n, hex(512'(dut.u_core.st_q), cur_bytes));
      trace_lines++;
    end
    // Encrypt (2) / Decrypt (3), first pass (the second one is the check):
    // the state register holds the result of this step after the next edge
    log_step = (dut.u_core.fsm_q == 3'd2 || dut.u_core.fsm_q == 3'd3) && !dut.u_core.chk_q;
    step_n   = dut.u_core.step_q;
    if (chk_wipe) begin
      // one cycle after the key schedule: K_R and the state are gone from the
      // engine registers (unless the next command has just loaded them)
      if (dut.u_core.fsm_q != 3'd1 && (dut.u_core.kl_q != '0 || dut.u_core.kr_q != '0))
        $fatal(1, "key schedule left K_R in the engine registers");
      if ((dut.u_core.fsm_q == 3'd0 || dut.u_core.fsm_q == 3'd4) &&
          (dut.u_core.st_q != '0 || dut.u_core.in_q != '0))
        $fatal(1, "key schedule left its state in the engine registers");
    end
    chk_wipe = dump_rk;
    if (dump_rk) begin
      // the key schedule has just ended: h[0..2R] in the RAM, nothing else
      for (int unsigned i = 2 * dut.u_core.rounds_q + 1; i < 32; i++) begin
        if (dut.u_core.rk_mem[i] != '0) $fatal(1, "round key %0d of a previous key left in the RAM", i);
      end
      if (logging) begin
        for (int unsigned i = 0; i <= 2 * dut.u_core.rounds_q; i++) begin
          $fdisplay(frk, "%0d %0d %s", cur_op, i, hex(512'(dut.u_core.rk_mem[i][255:0]), cur_bytes));
        end
      end
    end
    dump_rk = dut.u_core.done_o && dut.u_core.op_key_q;           // KEY passed its check
  end

  // -------------------------------------------------------------- operations
  string        op_s;
  int unsigned  cfg_l = 0, cfg_k = 0;
  logic [511:0] cfg_key = '0;
  int unsigned  n_ops = 0, n_keys = 0, max_stall = 0;

  // the k / 32 words of a key, each as one word or as four byte writes
  task automatic write_key(int unsigned k, logic [511:0] key);
    for (int unsigned i = 0; i < k / 32; i++) begin
      if ($urandom_range(3) == 0) wr_bytes(RegKey + 4 * i, key[32*i +: 32]);
      else                        wr(RegKey + 4 * i, key[32*i +: 32]);
    end
  endtask

  task automatic set_key(int unsigned l, int unsigned k, logic [511:0] key);
    logic [31:0] st;
    int unsigned klen;
    klen = (2 * k == 3 * l) ? 1 : (k == 2 * l) ? 2 : 0;
    wr(RegCtrl, {29'h0, 2'(klen), l == 256});
    write_key(k, key);
    rd(RegStatus, st);
    if (st[StKeyValid]) $fatal(1, "KEY_VALID after a key write");
    wr(RegCmd, CmdKey);
    n_keys++;
    if ($urandom_range(1) == 0) begin
      do rd(RegStatus, st); while (st[StBusy]);
      if (!st[StKeyValid] || st[StErr] || st[StFault]) $fatal(1, "key schedule: STATUS %08x", st);
      if (st[11:8] != 4'(7 + klen) || st[StWide] != (l == 256)) $fatal(1, "STATUS %08x for MKV-%0d/%0d", st, l, k);
    end
  endtask

  task automatic write_block(logic [255:0] blk, int unsigned nwords);
    for (int unsigned i = 0; i < nwords; i++) begin
      if ($urandom_range(5) == 0) wr_bytes(RegDin + 4 * i, blk[32*i +: 32]);
      else                        wr(RegDin + 4 * i, blk[32*i +: 32]);
    end
  endtask

  task automatic encrypt_block(input logic [255:0] blk, input int unsigned nwords,
                               output logic [255:0] out);
    logic [31:0] w;
    write_block(blk, nwords);
    wr(RegCmd, CmdEnc);
    out = '0;
    for (int unsigned j = 0; j < nwords; j++) begin
      rd(RegDout + 4 * j, w);
      out[32*j +: 32] = w;
    end
  endtask

  task automatic run_case();
    int           fd, n;
    string        line;
    int unsigned  l, k, nw;
    logic [511:0] key, din, dout, next_din;
    logic [31:0]  w, st;
    string        ops [$];
    int unsigned  ls [$], ks [$];
    logic [511:0] keys [$], ins [$], outs [$];
    bit           prewritten;

    fd = $fopen({dir, "/case.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/case.txt", dir);
    while ($fgets(line, fd) > 0) begin
      if (line.len() == 0 || line[0] == "#") continue;
      n = $sscanf(line, "%s %d %d %h %h %h", op_s, l, k, key, din, dout);
      if (n != 6) $fatal(1, "bad line in case.txt: %s", line);
      ops.push_back(op_s);
      ls.push_back(l);
      ks.push_back(k);
      keys.push_back(to_rtl(key, k / 8));
      ins.push_back(to_rtl(din, l / 8));
      outs.push_back(to_rtl(dout, l / 8));
    end
    $fclose(fd);

    prewritten = 1'b0;
    foreach (ops[i]) begin
      l         = ls[i];
      k         = ks[i];
      nw        = l / 32;
      cur_op    = i;
      cur_bytes = l / 8;
      if (l != cfg_l || k != cfg_k || keys[i] != cfg_key) begin
        set_key(l, k, keys[i]);
        cfg_l      = l;
        cfg_k      = k;
        cfg_key    = keys[i];
        prewritten = 1'b0;
      end
      if (!prewritten) write_block(ins[i][255:0], nw);
      wr(RegCmd, ops[i] == "E" ? CmdEnc : CmdDec);
      // next block of the same key while this one is being processed
      prewritten = 1'b0;
      if (i + 1 < ops.size() && ls[i+1] == l && ks[i+1] == k && keys[i+1] == keys[i] &&
          $urandom_range(1) == 0) begin
        write_block(ins[i+1][255:0], nw);
        prewritten = 1'b1;
      end
      if ($urandom_range(2) == 0) begin
        do rd(RegStatus, st); while (st[StBusy]);
        if (!st[StDone] || st[StErr] || st[StFault]) $fatal(1, "op %0d: STATUS %08x", i, st);
      end
      dout = '0;
      for (int unsigned j = 0; j < nw; j++) begin
        rd(RegDout + 4 * j, w);
        if (last_stall > max_stall) max_stall = last_stall;
        dout[32*j +: 32] = w;
      end
      for (int unsigned j = nw; j < 8; j++) begin
        rd(RegDout + 4 * j, w);
        expect_eq(w, 32'h0, $sformatf("op %0d: DOUT[%0d] of MKV-128", i, j));
      end
      $fdisplay(fout, "%s %s", ops[i], hex(dout, l / 8));
      if (dout !== outs[i]) begin
        $display("tb_bow_mkv: op %0d %s MKV-%0d/%0d: got %s expected %s", i, ops[i], l, k,
                 hex(dout, l / 8), hex(outs[i], l / 8));
        $fatal(1, "mismatch");
      end
      rd(RegCycles, w);
      expect_eq(w, 32'(4 * (7 + ((2 * k == 3 * l) ? 1 : (k == 2 * l) ? 2 : 0)) + 4),
                $sformatf("op %0d: CYCLES (4R + 4)", i));
      wr(RegStatus, 32'h0C);
      n_ops++;
    end
  endtask

  // ------------------------------------------------------ directed checks
  task automatic directed();
    logic [31:0] st, w;
    logic [511:0] key;
    logic [255:0] blk, c1, c2, c3;
    cur_op    = -1;
    cur_bytes = 16;

    // ENC / DEC without a key schedule, invalid KLEN, two command bits
    wr(RegCmd, CmdClear);
    do rd(RegStatus, st); while (st[StBusy]);
    wr(RegStatus, 32'h0C);
    wr(RegCmd, CmdEnc);
    rd(RegStatus, st);
    if (!st[StErr] || st[StBusy] || st[StDone]) $fatal(1, "ENC without key: STATUS %08x", st);
    wr(RegStatus, 32'h08);
    wr(RegCtrl, 32'h6);                       // KLEN = 3
    wr(RegCmd, CmdKey);
    rd(RegStatus, st);
    if (!st[StErr] || st[StBusy]) $fatal(1, "KEY with KLEN = 3: STATUS %08x", st);
    wr(RegStatus, 32'h08);
    wr(RegCmd, CmdEnc | CmdDec);
    rd(RegStatus, st);
    if (!st[StErr] || st[StBusy]) $fatal(1, "two command bits: STATUS %08x", st);
    wr(RegStatus, 32'h08);
    wr(RegCmd, 32'h0);                        // no command: nothing happens
    rd(RegStatus, st);
    if (st[StErr] || st[StBusy]) $fatal(1, "CMD 0: STATUS %08x", st);

    // KEY_VALID: set by KEY, cleared by a KEY write and by a change of CTRL
    key = '0;
    for (int i = 0; i < 16; i++) key[32*i +: 32] = $urandom();
    set_key(128, 128, key);
    do rd(RegStatus, st); while (st[StBusy]);
    if (!st[StKeyValid] || st[11:8] != 4'd7) $fatal(1, "KEY: STATUS %08x", st);
    wr(RegCtrl, 32'h0);                       // same version: still valid
    rd(RegStatus, st);
    if (!st[StKeyValid]) $fatal(1, "CTRL write of the same value cleared KEY_VALID");
    wr(RegCtrl, 32'h1);                       // other version
    rd(RegStatus, st);
    if (st[StKeyValid] || st[11:8] != 0) $fatal(1, "CTRL change: STATUS %08x", st);
    wr(RegCmd, CmdDec);
    rd(RegStatus, st);
    if (!st[StErr]) $fatal(1, "DEC after a CTRL change: no ERR");
    wr(RegStatus, 32'h0C);
    set_key(256, 512, key);
    do rd(RegStatus, st); while (st[StBusy]);
    wr(RegKey + 4 * 15, 32'h1234_5678);
    rd(RegStatus, st);
    if (st[StKeyValid]) $fatal(1, "KEY write did not clear KEY_VALID");

    // the KEY command zeroed the key registers: with one word written since,
    // KEY is refused
    if (dut.key_q[14:0] != '0) $fatal(1, "KEY left the master key in the key registers");
    wr(RegCmd, CmdKey);
    rd(RegStatus, st);
    if (!st[StErr] || st[StBusy] || st[StKeyValid]) $fatal(1, "KEY with one key word: STATUS %08x", st);
    wr(RegStatus, 32'h08);

    // KEY register is write only
    rd(RegKey + 4 * 15, w);
    expect_eq(w, 32'h0, "KEY read back");

    // CMD written right after KEY waits for the key schedule (gnt low)
    write_key(512, key);
    wr(RegCmd, CmdKey);
    wr(RegCmd, CmdEnc);
    if (last_stall < 60) $fatal(1, "CMD during the key schedule stalled %0d cycles", last_stall);
    rd(RegCycles, w);
    expect_eq(w, 32'd146, "CYCLES of KEY (R = 9): 16R + 2");
    rd(RegDout, w);                           // waits for the encryption
    if (last_stall == 0) $fatal(1, "DOUT read during the encryption did not stall");
    rd(RegCycles, w);
    expect_eq(w, 32'd40, "CYCLES of ENC (R = 9): 4R + 4");

    // interrupt on DONE, W1C
    wr(RegStatus, 32'h0C);
    wr(RegIrqEn, 32'h4);
    if (irq) $fatal(1, "irq without DONE");
    wr(RegCmd, CmdDec);
    do rd(RegStatus, st); while (st[StBusy]);
    if (!irq) $fatal(1, "no irq on DONE");
    wr(RegStatus, 32'h4);
    @(negedge clk);
    if (irq) $fatal(1, "irq after DONE was cleared");
    wr(RegIrqEn, 32'h8);
    wr(RegCmd, 32'h3);
    @(negedge clk);
    if (!irq) $fatal(1, "no irq on ERR");
    wr(RegStatus, 32'h8);
    wr(RegIrqEn, 32'h0);

    // a key byte that is not written again is 0 for the next KEY, never a
    // byte of the previous key: K with byte 0 not written gives the cipher
    // of K with byte 0 = 0, not the one of K
    key[7:0] = 8'h5a;
    blk      = {$urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom()};
    set_key(128, 128, key);
    encrypt_block(blk, 4, c1);
    bus_xfer(1'b1, RegKey, key[31:0], 4'b1110, w);
    for (int i = 1; i < 4; i++) wr(RegKey + 4 * i, key[32*i +: 32]);
    wr(RegCmd, CmdKey);
    do rd(RegStatus, st); while (st[StBusy]);
    if (!st[StKeyValid] || st[StErr]) $fatal(1, "KEY after a partial key write: STATUS %08x", st);
    encrypt_block(blk, 4, c2);
    key[7:0] = 8'h00;
    set_key(128, 128, key);
    encrypt_block(blk, 4, c3);
    if (c2 != c3 || c2 == c1) $fatal(1, "KEY took a byte of the previous key");

    // DIN is zeroed when ENC / DEC take it, DOUT when KEY starts
    write_block(blk, 8);
    wr(RegCmd, CmdDec);
    for (int i = 0; i < 8; i++) begin
      rd(RegDin + 4 * i, w);                  // no stall: right after the command
      expect_eq(w, 32'h0, "DIN after DEC started");
    end
    rd(RegDout, w);                           // waits for the block
    write_key(128, key);
    wr(RegCmd, CmdKey);
    for (int i = 0; i < 8; i++) begin
      rd(RegDout + 4 * i, w);                 // waits for the key schedule
      expect_eq(w, 32'h0, "DOUT after KEY");
    end
    if (dut.u_core.dout_q != '0) $fatal(1, "KEY left the previous result in the engine");
    wr(RegStatus, 32'h0C);

    // CLEAR zeroes the key registers, DIN, DOUT and every round key
    wr(RegDin, 32'hdead_beef);
    wr(RegCmd, CmdClear);
    do rd(RegStatus, st); while (st[StBusy]);
    if (st[StKeyValid]) $fatal(1, "KEY_VALID after CLEAR");
    rd(RegCycles, w);
    expect_eq(w, 32'd33, "CYCLES of CLEAR");
    if (dut.key_q != '0 || dut.din_q != '0 || dut.u_core.dout_q != '0 || dut.u_core.st_q != '0 ||
        dut.u_core.kl_q != '0 || dut.u_core.kr_q != '0) $fatal(1, "CLEAR left data in the registers");
    for (int i = 0; i < 32; i++) begin
      if (dut.u_core.rk_mem[i] != '0) $fatal(1, "CLEAR left round key %0d", i);
    end
    for (int i = 0; i < 8; i++) begin
      rd(RegDout + 4 * i, w);
      expect_eq(w, 32'h0, "DOUT after CLEAR");
    end
    wr(RegStatus, 32'h0C);
    wr(RegCmd, CmdKey);                       // no key written after CLEAR
    rd(RegStatus, st);
    if (!st[StErr] || st[StBusy] || st[StKeyValid]) $fatal(1, "KEY after CLEAR: STATUS %08x", st);
    wr(RegStatus, 32'h08);

    // reset: the engine zeroes the round key RAM (no reset) before it takes
    // a command, without DONE
    set_key(256, 512, key);
    do rd(RegStatus, st); while (st[StBusy]);
    if (dut.u_core.rk_mem[16] == '0) $fatal(1, "no round key to wipe");
    @(negedge clk);
    rst_n = 1'b0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    rd(RegStatus, st);
    expect_eq(st, 32'h1, "STATUS right after reset (BUSY: RAM wipe)");
    do rd(RegStatus, st); while (st[StBusy]);
    expect_eq(st, 32'h0, "STATUS after the RAM wipe");
    rd(RegCycles, w);
    expect_eq(w, 32'h0, "CYCLES after reset");
    for (int i = 0; i < 32; i++) begin
      if (dut.u_core.rk_mem[i] != '0) $fatal(1, "reset left round key %0d", i);
    end
  endtask

  // ------------------------------------------------------ fault injection
  // A fault must release nothing and leave nothing: FAULT, no DONE, DOUT
  // reads 0, KEY_VALID 0, the KEY / DIN registers, the engine registers and
  // every round key 0; after a new KEY the IP works again. Faults are
  // injected with force / release (a register takes a wrong value for one
  // clock) or by writing into the round key RAM (a stored bit changes).
  int unsigned n_faults = 0;

  task automatic wait_idle(string what);
    logic [31:0] st;
    for (int i = 0; i < 400; i++) begin
      rd(RegStatus, st);
      if (!st[StBusy]) return;
    end
    $fatal(1, "%s: engine still busy", what);
  endtask

  task automatic expect_fault(string what);
    logic [31:0] st, w;
    wait_idle(what);
    rd(RegStatus, st);
    if (!st[StFault] || st[StDone] || st[StKeyValid])
      $fatal(1, "%s: STATUS %08x, expected FAULT without DONE and KEY_VALID", what, st);
    for (int i = 0; i < 8; i++) begin
      rd(RegDout + 4 * i, w);
      expect_eq(w, 32'h0, {what, ": DOUT after the fault"});
    end
    if (dut.key_q != '0 || dut.din_q != '0) $fatal(1, "%s: KEY / DIN registers not zeroed", what);
    if (dut.u_core.dout_q != '0 || dut.u_core.st_q != '0 || dut.u_core.in_q != '0 ||
        dut.u_core.kl_q != '0 || dut.u_core.kr_q != '0) $fatal(1, "%s: engine registers not zeroed", what);
    for (int i = 0; i < 32; i++) begin
      if (dut.u_core.rk_mem[i] != '0) $fatal(1, "%s: round key %0d left", what, i);
    end
    wr(RegStatus, 32'h2C);                    // DONE, ERR, FAULT (W1C)
    rd(RegStatus, st);
    if (st[StFault]) $fatal(1, "%s: FAULT not cleared", what);
    n_faults++;
  endtask

  task automatic faults();
    logic [31:0]  st, w;
    logic [511:0] key;
    logic [255:0] blk, c_ref, c, v;
    logic [287:0] e;
    logic [7:0]   v8;
    cur_op = -1;
    key    = '0;
    for (int i = 0; i < 16; i++) key[32*i +: 32] = $urandom();
    for (int i = 0; i < 8; i++)  blk[32*i +: 32] = $urandom();
    set_key(256, 256, key);
    encrypt_block(blk, 8, c_ref);
    wait_idle("reference");
    wr(RegStatus, 32'h2C);

    // 1. state register in the first pass of ENC; FAULT interrupt
    wr(RegIrqEn, 32'h20);
    write_block(blk, 8);
    fork
      wr(RegCmd, CmdEnc);
      begin
        wait (dut.u_core.fsm_q == 3'd2 && !dut.u_core.chk_q && dut.u_core.step_q == 5'd3);
        @(negedge clk);
        v = dut.u_core.st_q ^ (256'd1 << 37);
        force dut.u_core.st_q = v;
        @(posedge clk);
        #1 release dut.u_core.st_q;
      end
    join
    wait_idle("state register in ENC");
    if (!irq) $fatal(1, "no interrupt on FAULT");
    expect_fault("state register in ENC");
    @(negedge clk);
    if (irq) $fatal(1, "interrupt after FAULT was cleared");
    wr(RegIrqEn, 32'h0);

    // 2. state register in the check of DEC (encryption of its result)
    set_key(256, 256, key);
    wait_idle("KEY");
    wr(RegStatus, 32'h2C);
    write_block(c_ref, 8);
    fork
      wr(RegCmd, CmdDec);
      begin
        wait (dut.u_core.fsm_q == 3'd2 && dut.u_core.chk_q && dut.u_core.step_q == 5'd2);
        @(negedge clk);
        v = dut.u_core.st_q ^ (256'd1 << 200);
        force dut.u_core.st_q = v;
        @(posedge clk);
        #1 release dut.u_core.st_q;
      end
    join
    expect_fault("state register in the check of DEC");

    // 3. a bit of a stored round key (same wrong key in both passes)
    set_key(256, 256, key);
    wait_idle("KEY");
    wr(RegStatus, 32'h2C);
    e      = dut.u_core.rk_mem[5];
    e[77]  = ~e[77];
    dut.u_core.rk_mem[5] = e;
    write_block(blk, 8);
    wr(RegCmd, CmdEnc);
    expect_fault("round key bit in the RAM");

    // 4. step counter: half-rounds skipped in the first pass of ENC
    set_key(256, 256, key);
    wait_idle("KEY");
    wr(RegStatus, 32'h2C);
    write_block(blk, 8);
    fork
      wr(RegCmd, CmdEnc);
      begin
        wait (dut.u_core.fsm_q == 3'd2 && !dut.u_core.chk_q && dut.u_core.step_q == 5'd4);
        @(negedge clk);
        force dut.u_core.step_q = 5'd8;
        @(posedge clk);
        #1 release dut.u_core.step_q;
      end
    join
    expect_fault("half-rounds skipped in ENC");

    // 5. cycle counter (the result itself is right)
    set_key(256, 256, key);
    wait_idle("KEY");
    wr(RegStatus, 32'h2C);
    write_block(blk, 8);
    fork
      wr(RegCmd, CmdEnc);
      begin
        wait (dut.u_core.fsm_q == 3'd3 && dut.u_core.chk_q && dut.u_core.step_q == 5'd6);
        @(negedge clk);
        v8 = dut.u_core.cnt_q + 8'd3;
        force dut.u_core.cnt_q = v8;
        @(posedge clk);
        #1 release dut.u_core.cnt_q;
      end
    join
    expect_fault("cycle counter");

    // 6. number of rounds while idle (value and complement disagree)
    set_key(256, 256, key);
    wait_idle("KEY");
    wr(RegStatus, 32'h2C);
    @(negedge clk);
    force dut.u_core.rounds_q = 4'd5;
    @(posedge clk);
    #1 release dut.u_core.rounds_q;
    expect_fault("number of rounds while idle");

    // 7. no such state
    set_key(256, 256, key);
    wait_idle("KEY");
    wr(RegStatus, 32'h2C);
    @(negedge clk);
    /* verilator lint_off ENUMVALUE */
    force dut.u_core.fsm_q = 3'd6;
    /* verilator lint_on ENUMVALUE */
    @(posedge clk);
    #1 release dut.u_core.fsm_q;
    expect_fault("FSM state 6");

    // 8. state machine back to Idle in the middle of ENC
    set_key(256, 256, key);
    wait_idle("KEY");
    wr(RegStatus, 32'h2C);
    write_block(blk, 8);
    fork
      wr(RegCmd, CmdEnc);
      begin
        wait (dut.u_core.fsm_q == 3'd2 && dut.u_core.step_q == 5'd5);
        @(negedge clk);
        /* verilator lint_off ENUMVALUE */
        force dut.u_core.fsm_q = 3'd0;
        /* verilator lint_on ENUMVALUE */
        @(posedge clk);
        #1 release dut.u_core.fsm_q;
      end
    join
    expect_fault("FSM back to Idle during ENC");

    // 9. state register in the first pass of the key schedule
    wr(RegCtrl, 32'h1);                       // MKV-256/256
    write_key(256, key);
    fork
      wr(RegCmd, CmdKey);
      begin
        wait (dut.u_core.fsm_q == 3'd1 && !dut.u_core.chk_q && dut.u_core.upd_q == 4'd2 &&
              dut.u_core.half_q == 2'd1);
        @(negedge clk);
        v = dut.u_core.st_q ^ (256'd1 << 9);
        force dut.u_core.st_q = v;
        @(posedge clk);
        #1 release dut.u_core.st_q;
      end
    join
    expect_fault("state register in KEY");

    // 10. KEY_VALID of the register block from a glitch, no key schedule
    wr(RegCmd, CmdClear);
    wait_idle("CLEAR");
    wr(RegStatus, 32'h2C);
    write_block(blk, 8);
    @(negedge clk);
    force dut.key_valid_q = 1'b1;
    @(posedge clk);
    #1 release dut.key_valid_q;
    wr(RegCmd, CmdEnc);
    expect_fault("ENC with KEY_VALID from a glitch");

    // 11. after a new KEY the IP works again; DOUT reads 0 without a
    // checked result
    set_key(256, 256, key);
    encrypt_block(blk, 8, c);
    if (c != c_ref) $fatal(1, "ENC after the faults: %h, expected %h", c, c_ref);
    write_block(c_ref, 8);
    wr(RegCmd, CmdDec);
    for (int j = 0; j < 8; j++) begin
      rd(RegDout + 4 * j, w);
      if (w != blk[32*j +: 32]) $fatal(1, "DEC after the faults, word %0d: %08x", j, w);
    end
    rd(RegStatus, st);
    if (st[StFault] || !st[StKeyValid]) $fatal(1, "STATUS after the faults: %08x", st);
    @(negedge clk);
    force dut.u_core.dout_ok_q = 1'b0;
    rd(RegDout, w);
    release dut.u_core.dout_ok_q;
    expect_eq(w, 32'h0, "DOUT without a checked result");
  endtask

  // ------------------------------------------------------------------- main
  initial begin
    int          fd;
    int unsigned seed = 1;
    logic [31:0] w;

    if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR=<test case> required");
    void'($value$plusargs("SEED=%d", seed));
    void'($urandom(seed));
    fout   = $fopen({dir, "/out.txt"}, "w");
    ftrace = $fopen({dir, "/trace.txt"}, "w");
    frk    = $fopen({dir, "/rk.txt"}, "w");

    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    rd(RegId, w);
    expect_eq(w, 32'h4d4b_5602, "ID");
    rd(RegInfo, w);
    expect_eq(w, 32'h0000_0407, "INFO");
    do rd(RegStatus, w); while (w[StBusy]);     // round key RAM wipe after reset
    expect_eq(w, 32'h0, "STATUS after reset");

    logging = 1'b1;
    run_case();
    @(negedge clk);
    logging = 1'b0;
    $fclose(fout);
    $fclose(ftrace);
    $fclose(frk);
    directed();
    faults();

    fd = $fopen({dir, "/status.txt"}, "w");
    $fdisplay(fd, "OK %0d", n_ops);
    $fclose(fd);
    $display("tb_bow_mkv: %0d operations, %0d key schedules, %0d states traced, DOUT stall up to %0d cycles, %0d faults detected",
             n_ops, n_keys, trace_lines, max_stall, n_faults);
    $finish;
  end

endmodule
