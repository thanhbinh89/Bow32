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
// nothing and zero everything), the fault counter and LOCKED, TEST, bus
// errors, NOSTALL, KEY_LOCK and the use policy.

`timescale 1ns / 1ps

module tb_bow_mkv;
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

  // state codes of bow_mkv_core (sparse) and the mubi4 flags
  localparam logic [5:0] SIdle = 6'b100110, SKey = 6'b010101, SEnc = 6'b110011, SDec = 6'b101101,
                         SClear = 6'b001011, SCheck = 6'b011110;
  localparam logic [3:0] MTrue = 4'b0110, MFalse = 4'b1001;
  localparam int unsigned FaultLimit = 4;   // default of bow_mkv

  // alert_fault_o pulses
  int unsigned n_alert_fault = 0;
  always @(posedge clk) if (alert_fault) n_alert_fault++;

  localparam logic [31:0] RegId = 32'h000, RegInfo = 32'h004, RegCtrl = 32'h008, RegCmd = 32'h00C,
                          RegStatus = 32'h010, RegIrqEn = 32'h014, RegCycles = 32'h018,
                          RegKey = 32'h040, RegDin = 32'h080, RegDout = 32'h0C0;
  localparam logic [31:0] CmdKey = 32'h1, CmdEnc = 32'h2, CmdDec = 32'h4, CmdClear = 32'h8;
  localparam int unsigned StBusy = 0, StKeyValid = 1, StDone = 2, StErr = 3, StWide = 4, StFault = 5,
                          StLocked = 6, StAlert = 7;
  localparam logic [31:0] CmdTest = 32'h10, CtrlNoStall = 32'h8, CtrlKeyLock = 32'h10,
                          CtrlNoDec = 32'h20, CtrlNoEnc = 32'h40;

  // ---------------------------------------------------------------- bus BFM
  // Holds req until gnt (gnt is sampled in the middle of the cycle), returns
  // the read data of the response cycle and the number of stalled cycles.
  int unsigned last_stall;
  bit          allow_err = 1'b0;   // a bus error is expected: see last_err
  bit          last_err;

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
    last_err = reg_rsp.err;
    if (reg_rsp.err && !allow_err) $fatal(1, "bus error (addr %03x)", addr);
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
    log_step = (dut.u_core.fsm_q == SEnc || dut.u_core.fsm_q == SDec) && dut.u_core.chk_q == MFalse;
    step_n   = dut.u_core.step_q;
    if (chk_wipe) begin
      // one cycle after the key schedule: K_R and the state are gone from the
      // engine registers (unless the next command has just loaded them)
      if (dut.u_core.fsm_q != SKey && (dut.u_core.kl_q != '0 || dut.u_core.kr_q != '0))
        $fatal(1, "key schedule left K_R in the engine registers");
      if ((dut.u_core.fsm_q == SIdle || dut.u_core.fsm_q == SClear) &&
          (dut.u_core.st_q != '0 || dut.u_core.in_q != '0))
        $fatal(1, "key schedule left its state in the engine registers");
    end
    chk_wipe = dump_rk;
    if (dump_rk) begin
      // the key schedule has just ended: h[0..2R] in the RAM, nothing else
      for (int unsigned i = 2 * dut.u_core.rounds_q + 1; i < 32; i++) begin
        if (dut.u_core.rk_mem[i][255:0] != '0) $fatal(1, "round key %0d of a previous key left in the RAM", i);
      end
      if (logging) begin
        for (int unsigned i = 0; i <= 2 * dut.u_core.rounds_q; i++) begin
          $fdisplay(frk, "%0d %0d %s", cur_op, i, hex(512'(dut.u_core.rk_mem[i][255:0]), cur_bytes));
        end
      end
    end
    dump_rk = dut.u_core.done_o && dut.u_core.op_key_q == MTrue;  // KEY passed its check
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

  // the 32 rows hold zero with the code of a zero row at their address
  function automatic bit rows_wiped();
    for (int i = 0; i < 32; i++) begin
      if (dut.u_core.rk_mem[i] != {bow_mkv_pkg::rk_edc('0, 5'(i)), 256'h0}) return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic int unsigned rows_with_data();
    int unsigned n = 0;
    for (int i = 0; i < 32; i++) if (dut.u_core.rk_mem[i][255:0] != '0) n++;
    return n;
  endfunction

  // an access that has to end with a bus error and change nothing
  task automatic expect_bus_err(input bit we, input logic [31:0] addr);
    logic [31:0] d;
    allow_err = 1'b1;
    bus_xfer(we, addr, 32'hffff_ffff, 4'hF, d);
    allow_err = 1'b0;
    if (!last_err) $fatal(1, "%s of %03x without a bus error", we ? "write" : "read", addr);
    if (!we && d != '0) $fatal(1, "read of %03x with a bus error gave %08x", addr, d);
  endtask

  // power-on reset (fault counter, LOCKED) with the system reset, then the
  // wipe of the round key RAM
  task automatic power_on();
    logic [31:0] st;
    @(negedge clk);
    por_n = 1'b0;
    rst_n = 1'b0;
    repeat (3) @(negedge clk);
    por_n = 1'b1;
    rst_n = 1'b1;
    do rd(RegStatus, st); while (st[StBusy]);
    expect_eq(st, 32'h0, "STATUS after power-on");
    cfg_l = 0;
    cfg_k = 0;
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

    // the refused KEY zeroed the key word written since
    if (dut.key_q != '0) $fatal(1, "a refused KEY left key words in the key registers");

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

    // DIN is zeroed when ENC / DEC take it (write only: read in the RTL), DOUT
    // when KEY starts
    write_block(blk, 8);
    wr(RegCmd, CmdDec);
    @(negedge clk);
    if (dut.din_q != '0) $fatal(1, "DIN after DEC started: %h", dut.din_q);
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
    expect_eq(w, 32'd65, "CYCLES of CLEAR (zero 32 rows, read them back)");
    if (dut.key_q != '0 || dut.din_q != '0 || dut.u_core.dout_q != '0 || dut.u_core.st_q != '0 ||
        dut.u_core.kl_q != '0 || dut.u_core.kr_q != '0) $fatal(1, "CLEAR left data in the registers");
    if (!rows_wiped()) $fatal(1, "CLEAR left round keys");
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
    if (dut.u_core.rk_mem[16][255:0] == '0) $fatal(1, "no round key to wipe");
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
    if (!rows_wiped()) $fatal(1, "reset left round keys");
  endtask

  // ------------------------------------------------------ fault injection
  // A fault must release nothing and leave nothing: FAULT, no DONE, DOUT
  // reads 0, KEY_VALID 0, the KEY / DIN registers, the engine registers and
  // every round key 0 (with the code of a zero row); it is counted once
  // (FAULTS, alert_fault_o) unless it is the one of a TEST. Faults are
  // injected with force / release (a register takes a wrong value for one
  // clock), by writing a register of the RTL (a flipped bit that stays until
  // the RTL writes the register again) or by writing into the round key RAM
  // (stored bits change). Every check ends with a power-on reset, so the
  // fault counter only reaches FaultLimit in the lockout test.
  int unsigned n_faults = 0;
  logic [5:0]  s6_bad    [2] = '{6'b000000, 6'b111000};
  logic [5:0]  s6_states [5] = '{SIdle, SKey, SEnc, SDec, SClear};
  logic [31:0] locked_cmds [5] = '{CmdKey, CmdEnc, CmdDec, CmdEnc | CmdTest, CmdKey | CmdTest};
  logic [31:0] no_read  [12] = '{RegCmd, RegKey, RegKey + 32'h3C, RegDin, RegDin + 32'h1C, 32'h01C,
                                 32'h03C, 32'h0A0, 32'h0BC, 32'h0E0, 32'h100, 32'hFFC};
  logic [31:0] no_write [11] = '{RegId, RegInfo, RegCycles, RegDout, RegDout + 32'h1C, 32'h01C,
                                 32'h03C, 32'h0A0, 32'h0E0, 32'h100, 32'hFFC};

  task automatic wait_idle(string what);
    logic [31:0] st;
    for (int i = 0; i < 400; i++) begin
      rd(RegStatus, st);
      if (!st[StBusy]) return;
    end
    $fatal(1, "%s: engine still busy", what);
  endtask

  task automatic expect_fault(string what, bit counted = 1'b1);
    logic [31:0] st, w;
    repeat (3) @(posedge clk);                // a fault while idle is acted on 2 cycles later
    wait_idle(what);
    rd(RegStatus, st);
    if (!st[StFault] || st[StDone] || st[StKeyValid] || st[StLocked])
      $fatal(1, "%s: STATUS %08x, expected FAULT without DONE, KEY_VALID, LOCKED", what, st);
    if (st[15:12] != (counted ? 4'd1 : 4'd0) || n_alert_fault != (counted ? 1 : 0))
      $fatal(1, "%s: FAULTS %0d, %0d fault alerts, expected %0d", what, st[15:12], n_alert_fault, counted);
    for (int i = 0; i < 8; i++) begin
      rd(RegDout + 4 * i, w);
      expect_eq(w, 32'h0, {what, ": DOUT after the fault"});
    end
    if (dut.key_q != '0 || dut.din_q != '0) $fatal(1, "%s: KEY / DIN registers not zeroed", what);
    if (dut.u_core.dout_q != '0 || dut.u_core.dout_n_q != '0 || dut.u_core.st_q != '0 ||
        dut.u_core.in_q != '0 || dut.u_core.in_n_q != '0 || dut.u_core.kl_q != '0 ||
        dut.u_core.kr_q != '0) $fatal(1, "%s: engine registers not zeroed", what);
    if (!rows_wiped()) $fatal(1, "%s: round keys left (%0d rows with data)", what, rows_with_data());
    wr(RegStatus, 32'h2C);                    // DONE, ERR, FAULT (W1C)
    rd(RegStatus, st);
    if (st[StFault]) $fatal(1, "%s: FAULT not cleared", what);
    n_faults++;
    power_on();
    n_alert_fault = 0;
  endtask

  logic [511:0] fkey;
  logic [255:0] fblk, fc_ref;

  task automatic ready();                     // MKV-256/256 key schedule, STATUS clean
    set_key(256, 256, fkey);
    wait_idle("KEY");
    wr(RegStatus, 32'h2C);
  endtask

  // ENC of fblk, one cycle of the engine in which `cond` holds gets st_q ^ bit
  task automatic enc_state_fault(input logic [5:0] state, input logic [3:0] chk,
                                 input logic [4:0] step, input int unsigned bit_n);
    logic [255:0] v;
    write_block(fblk, 8);
    fork
      wr(RegCmd, CmdEnc);
      begin
        wait (dut.u_core.fsm_q == state && dut.u_core.chk_q == chk && dut.u_core.step_q == step);
        @(negedge clk);
        v = dut.u_core.st_q ^ (256'd1 << bit_n);
        force dut.u_core.st_q = v;
        @(posedge clk);
        #1 release dut.u_core.st_q;
      end
    join
  endtask

  task automatic faults();
    logic [31:0]  st, w;
    logic [255:0] c, v;
    logic [311:0] e;
    logic [7:0]   v8;
    logic [5:0]   s6;
    logic [3:0]   m4;
    cur_op = -1;
    fkey   = '0;
    for (int i = 0; i < 16; i++) fkey[32*i +: 32] = $urandom();
    for (int i = 0; i < 8; i++)  fblk[32*i +: 32] = $urandom();
    power_on();
    n_alert_fault = 0;
    set_key(256, 256, fkey);
    encrypt_block(fblk, 8, fc_ref);
    wait_idle("reference");
    wr(RegStatus, 32'h2C);

    // 1. state register in the first pass of ENC; FAULT interrupt
    wr(RegIrqEn, 32'h20);
    enc_state_fault(SEnc, MFalse, 5'd3, 37);
    wait_idle("state register in ENC");
    if (!irq) $fatal(1, "no interrupt on FAULT");
    expect_fault("state register in ENC");
    @(negedge clk);
    if (irq) $fatal(1, "interrupt after FAULT was cleared");

    // 2. state register in the check of DEC (encryption of its result)
    ready();
    write_block(fc_ref, 8);
    fork
      wr(RegCmd, CmdDec);
      begin
        wait (dut.u_core.fsm_q == SEnc && dut.u_core.chk_q == MTrue && dut.u_core.step_q == 5'd2);
        @(negedge clk);
        v = dut.u_core.st_q ^ (256'd1 << 200);
        force dut.u_core.st_q = v;
        @(posedge clk);
        #1 release dut.u_core.st_q;
      end
    join
    expect_fault("state register in the check of DEC");

    // 3. one bit of a stored round key (the same wrong key in both passes):
    // the code of the row sees it
    ready();
    e      = dut.u_core.rk_mem[5];
    e[77]  = ~e[77];
    dut.u_core.rk_mem[5] = e;
    write_block(fblk, 8);
    wr(RegCmd, CmdEnc);
    expect_fault("round key bit in the RAM");

    // 4. step counter: half-rounds skipped in the first pass of ENC
    ready();
    write_block(fblk, 8);
    fork
      wr(RegCmd, CmdEnc);
      begin
        wait (dut.u_core.fsm_q == SEnc && dut.u_core.chk_q == MFalse && dut.u_core.step_q == 5'd4);
        @(negedge clk);
        force dut.u_core.step_q = 5'd8;
        @(posedge clk);
        #1 release dut.u_core.step_q;
      end
    join
    expect_fault("half-rounds skipped in ENC");

    // 5. cycle counter (the result itself is right)
    ready();
    write_block(fblk, 8);
    fork
      wr(RegCmd, CmdEnc);
      begin
        wait (dut.u_core.fsm_q == SDec && dut.u_core.chk_q == MTrue && dut.u_core.step_q == 5'd6);
        @(negedge clk);
        v8 = dut.u_core.cnt_q + 8'd3;
        force dut.u_core.cnt_q = v8;
        @(posedge clk);
        #1 release dut.u_core.cnt_q;
      end
    join
    expect_fault("cycle counter");

    // 6. number of rounds while idle (value and complement disagree)
    ready();
    @(negedge clk);
    dut.u_core.rounds_q = 4'd5;
    expect_fault("number of rounds while idle");

    // 7. codes that are no state
    foreach (s6_bad[i]) begin
      ready();
      @(negedge clk);
      /* verilator lint_off ENUMVALUE */
      dut.u_core.fsm_q = s6_bad[i];
      /* verilator lint_on ENUMVALUE */
      expect_fault($sformatf("FSM code %06b", s6_bad[i]));
    end

    // 8. state machine back to Idle in the middle of ENC
    ready();
    write_block(fblk, 8);
    fork
      wr(RegCmd, CmdEnc);
      begin
        wait (dut.u_core.fsm_q == SEnc && dut.u_core.step_q == 5'd5);
        @(negedge clk);
        /* verilator lint_off ENUMVALUE */
        dut.u_core.fsm_q = SIdle;
        /* verilator lint_on ENUMVALUE */
      end
    join
    expect_fault("FSM back to Idle during ENC");

    // 9. state register in the first pass of the key schedule
    wr(RegCtrl, 32'h1);                       // MKV-256/256
    write_key(256, fkey);
    fork
      wr(RegCmd, CmdKey);
      begin
        wait (dut.u_core.fsm_q == SKey && dut.u_core.chk_q == MFalse && dut.u_core.upd_q == 4'd2 &&
              dut.u_core.half_q == 2'd1);
        @(negedge clk);
        v = dut.u_core.st_q ^ (256'd1 << 9);
        force dut.u_core.st_q = v;
        @(posedge clk);
        #1 release dut.u_core.st_q;
      end
    join
    expect_fault("state register in KEY");

    // 10. KEY_VALID of the register block from a glitch, no key schedule in
    // the engine: seen at once, before any command
    wr(RegCmd, CmdClear);
    wait_idle("CLEAR");
    wr(RegStatus, 32'h2C);
    write_block(fblk, 8);
    @(negedge clk);
    dut.key_valid_q = 1'b1;
    repeat (3) @(negedge clk);
    if (dut.key_valid_q || !dut.fault_q) $fatal(1, "KEY_VALID without key schedule not seen");
    expect_fault("KEY_VALID from a glitch");

    // 10b. the engine loses its key schedule while the register block has
    // KEY_VALID: STATUS shows KEY_VALID 0 at once (AND of both), then FAULT
    ready();
    @(negedge clk);
    dut.u_core.ks_valid_q = MFalse;
    rd(RegStatus, st);                        // sampled before the fault is acted on
    if (st[StKeyValid]) $fatal(1, "STATUS.KEY_VALID without a key schedule in the engine: %08x", st);
    expect_fault("key schedule lost in the engine");

    // 11. after a new KEY the IP works again; DOUT reads 0 without a
    // checked result
    set_key(256, 256, fkey);
    encrypt_block(fblk, 8, c);
    if (c != fc_ref) $fatal(1, "ENC after the faults: %h, expected %h", c, fc_ref);
    write_block(fc_ref, 8);
    wr(RegCmd, CmdDec);
    for (int j = 0; j < 8; j++) begin
      rd(RegDout + 4 * j, w);
      if (w != fblk[32*j +: 32]) $fatal(1, "DEC after the faults, word %0d: %08x", j, w);
    end
    rd(RegStatus, st);
    if (st[StFault] || !st[StKeyValid]) $fatal(1, "STATUS after the faults: %08x", st);
    @(negedge clk);
    force dut.u_core.dout_ok_q = MFalse;
    rd(RegDout, w);
    release dut.u_core.dout_ok_q;
    expect_eq(w, 32'h0, "DOUT without a checked result");
    wr(RegStatus, 32'h2C);

    // 12. two bits of one byte of a round key (E2 of the review: the byte
    // parity of version 2 did not see an even number)
    ready();
    e = dut.u_core.rk_mem[13];
    e[8*5 + 1] = ~e[8*5 + 1];
    e[8*5 + 6] = ~e[8*5 + 6];
    dut.u_core.rk_mem[13] = e;
    write_block(fblk, 8);
    wr(RegCmd, CmdEnc);
    expect_fault("two bits of one byte of a round key");

    // 13. a whole byte of a round key, and 24 adjacent bits
    ready();
    e = dut.u_core.rk_mem[2];
    e[8*9 +: 8] = ~e[8*9 +: 8];
    dut.u_core.rk_mem[2] = e;
    write_block(fblk, 8);
    wr(RegCmd, CmdEnc);
    expect_fault("one byte of a round key");
    ready();
    e = dut.u_core.rk_mem[7];
    e[100 +: 24] = ~e[100 +: 24];
    dut.u_core.rk_mem[7] = e;
    write_block(fblk, 8);
    wr(RegCmd, CmdEnc);
    expect_fault("24 adjacent bits of a round key");

    // 14. a row copied over another, code included (E3: address decoder,
    // word line)
    ready();
    dut.u_core.rk_mem[12] = dut.u_core.rk_mem[11];
    write_block(fblk, 8);
    wr(RegCmd, CmdEnc);
    expect_fault("row h[12] := h[11]");

    // 15. a check bit of the code of a row
    ready();
    e = dut.u_core.rk_mem[9];
    e[256 + 17] = ~e[256 + 17];
    dut.u_core.rk_mem[9] = e;
    write_block(fblk, 8);
    wr(RegCmd, CmdDec);
    expect_fault("check bit of a round key row");

    // 16. the result register in the check pass (E1)
    ready();
    write_block(fblk, 8);
    fork
      wr(RegCmd, CmdEnc);
      begin
        wait (dut.u_core.fsm_q == SDec && dut.u_core.chk_q == MTrue && dut.u_core.step_q == 5'd4);
        @(negedge clk);
        v = dut.u_core.dout_q ^ (256'd1 << 100);
        dut.u_core.dout_q = v;
      end
    join
    expect_fault("result register in the check pass");

    // 17. the result register while it can be read: DOUT reads 0 at once
    ready();
    encrypt_block(fblk, 8, c);
    wait_idle("ENC");
    wr(RegStatus, 32'h0C);
    @(negedge clk);
    v = dut.u_core.dout_q ^ (256'd1 << 3);
    dut.u_core.dout_q = v;
    #1;
    if (dut.u_core.dout_valid_o) $fatal(1, "a changed result is still readable");
    expect_fault("result register after the check");

    // 18. its complement copy
    ready();
    encrypt_block(fblk, 8, c);
    wait_idle("ENC");
    wr(RegStatus, 32'h0C);
    @(negedge clk);
    v = dut.u_core.dout_n_q ^ (256'd1 << 250);
    dut.u_core.dout_n_q = v;
    expect_fault("complement copy of the result");

    // 19. CLEAR cut short in the zeroing (E4): the row counter jumps; the
    // wipe is done again, CLEAR never reports DONE
    ready();
    fork
      wr(RegCmd, CmdClear);
      begin
        wait (dut.u_core.fsm_q == SClear && !dut.u_core.vfy_q && dut.u_core.step_q == 5'd1);
        @(negedge clk);
        dut.u_core.step_q = 5'd30;
      end
    join
    expect_fault("CLEAR cut short (zeroing)");

    // 20. CLEAR cut short in the read back
    ready();
    fork
      wr(RegCmd, CmdClear);
      begin
        wait (dut.u_core.fsm_q == SClear && dut.u_core.vfy_q && dut.u_core.step_q == 5'd3);
        @(negedge clk);
        dut.u_core.step_q = 5'd29;
      end
    join
    expect_fault("CLEAR cut short (read back)");

    // 20b. CLEAR: one row is not written (write enable lost for a cycle): the
    // counters are right, only the read back sees the key left in the row
    ready();
    fork
      wr(RegCmd, CmdClear);
      begin
        wait (dut.u_core.fsm_q == SClear && !dut.u_core.vfy_q && dut.u_core.step_q == 5'd6);
        @(negedge clk);
        force dut.u_core.rk_we = 1'b0;
        @(posedge clk);
        #1 release dut.u_core.rk_we;
      end
    join
    expect_fault("CLEAR: one row not written");

    // 21. the wipe after a system reset cut short (E5)
    ready();
    @(negedge clk);
    rst_n = 1'b0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    wait (dut.u_core.fsm_q == SClear && dut.u_core.step_q == 5'd1);
    @(negedge clk);
    dut.u_core.step_q = 5'd30;
    expect_fault("wipe after reset cut short");

    // 22. one flipped bit of the state register, in every state (any two
    // states differ in at least 3 bits)
    for (int b = 0; b < 6; b++) begin         // Check of KEY (E6), every bit
      wr(RegCtrl, 32'h1);
      write_key(256, fkey);
      fork
        wr(RegCmd, CmdKey);
        begin
          wait (dut.u_core.fsm_q == SCheck);
          @(negedge clk);
          /* verilator lint_off ENUMVALUE */
          dut.u_core.fsm_q = dut.u_core.fsm_q ^ (6'd1 << b);
          /* verilator lint_on ENUMVALUE */
        end
      join
      expect_fault($sformatf("FSM bit %0d in Check of KEY", b));
    end
    foreach (s6_states[i]) begin              // the others, one bit each
      ready();
      write_block(fblk, 8);
      if (s6_states[i] == SKey) write_key(256, fkey);   // the key schedule is wiped meanwhile
      fork
        begin
          case (s6_states[i])
            SClear:  wr(RegCmd, CmdClear);
            SKey:    wr(RegCmd, CmdKey);
            SEnc:    wr(RegCmd, CmdEnc);
            SDec:    wr(RegCmd, CmdDec);
            default: ;
          endcase
        end
        begin
          wait (dut.u_core.fsm_q == s6_states[i]);
          @(negedge clk);
          /* verilator lint_off ENUMVALUE */
          dut.u_core.fsm_q = dut.u_core.fsm_q ^ (6'd1 << (i + 1));
          /* verilator lint_on ENUMVALUE */
        end
      join
      expect_fault($sformatf("FSM bit %0d in state %06b", i + 1, s6_states[i]));
    end

    // 23. one bit of a mubi4 flag: second pass, operation, key schedule
    // valid, result valid
    for (int f = 0; f < 4; f++) begin
      ready();
      if (f == 3) begin
        encrypt_block(fblk, 8, c);
        wait_idle("ENC");
        wr(RegStatus, 32'h0C);
      end
      write_block(fblk, 8);
      fork
        if (f < 2) wr(RegCmd, CmdEnc);
        begin
          if (f < 2) wait (dut.u_core.fsm_q == SEnc && dut.u_core.step_q == 5'd3);
          @(negedge clk);
          case (f)
            0: dut.u_core.chk_q      = dut.u_core.chk_q ^ 4'b0010;
            1: dut.u_core.op_key_q   = dut.u_core.op_key_q ^ 4'b1000;
            2: dut.u_core.ks_valid_q = dut.u_core.ks_valid_q ^ 4'b0001;
            default: dut.u_core.dout_ok_q = dut.u_core.dout_ok_q ^ 4'b0100;
          endcase
        end
      join
      expect_fault($sformatf("bit of mubi4 flag %0d", f));
    end

    // 24. one comparator of Check stuck at "equal", then a fault in the
    // first pass: the other one, and the flag made of both, still see it
    for (int a = 0; a < 2; a++) begin
      ready();
      if (a == 0) force dut.u_core.res_eq_a = 1'b1;
      else        force dut.u_core.res_eq_b = 1'b1;
      enc_state_fault(SEnc, MFalse, 5'd5, 140);
      wait_idle("ENC");
      if (a == 0) release dut.u_core.res_eq_a;
      else        release dut.u_core.res_eq_b;
      expect_fault($sformatf("result comparator %s stuck, fault in ENC", a == 0 ? "A" : "B"));
    end
    for (int a = 0; a < 2; a++) begin         // the same for the key schedule
      wr(RegCtrl, 32'h1);
      write_key(256, fkey);
      if (a == 0) force dut.u_core.ks_eq_a = 1'b1;
      else        force dut.u_core.ks_eq_b = 1'b1;
      fork
        wr(RegCmd, CmdKey);
        begin
          wait (dut.u_core.fsm_q == SKey && dut.u_core.chk_q == MFalse && dut.u_core.upd_q == 4'd3 &&
                dut.u_core.half_q == 2'd2);
          @(negedge clk);
          v = dut.u_core.st_q ^ (256'd1 << 66);
          force dut.u_core.st_q = v;
          @(posedge clk);
          #1 release dut.u_core.st_q;
        end
      join
      wait_idle("KEY");
      if (a == 0) release dut.u_core.ks_eq_a;
      else        release dut.u_core.ks_eq_b;
      expect_fault($sformatf("key schedule comparator %s stuck, fault in KEY", a == 0 ? "A" : "B"));
    end

    // 25. KEY reads back the rows above 2R in its second pass: a row that
    // was not zeroed (or got data since) is seen
    wr(RegCtrl, 32'h1);
    write_key(256, fkey);
    fork
      wr(RegCmd, CmdKey);
      begin
        wait (dut.u_core.fsm_q == SKey && dut.u_core.chk_q == MTrue && dut.u_core.upd_q == 4'd1);
        @(negedge clk);
        v = {8{$urandom()}};
        dut.u_core.rk_mem[25] = {bow_mkv_pkg::rk_edc(v, 5'd25), v};
      end
    join
    expect_fault("stale round key row in KEY");

    // 26. TEST of KEY, ENC, DEC: the corrupted second pass is caught, not
    // counted, nothing released
    wr(RegCtrl, 32'h1);
    write_key(256, fkey);
    wr(RegCmd, CmdKey | CmdTest);
    expect_fault("TEST of KEY", 1'b0);
    for (int d = 0; d < 2; d++) begin
      ready();
      write_block(d == 0 ? fblk : fc_ref, 8);
      wr(RegCmd, (d == 0 ? CmdEnc : CmdDec) | CmdTest);
      expect_fault(d == 0 ? "TEST of ENC" : "TEST of DEC", 1'b0);
    end
    ready();                                  // TEST with two commands: refused
    wr(RegCmd, CmdEnc | CmdDec | CmdTest);
    rd(RegStatus, st);
    if (!st[StErr] || st[StBusy] || st[StFault]) $fatal(1, "TEST with two commands: STATUS %08x", st);
    wr(RegCmd, CmdClear | CmdTest);
    rd(RegStatus, st);
    if (!st[StErr] || st[StBusy]) $fatal(1, "TEST of CLEAR: STATUS %08x", st);
    power_on();
    n_alert_fault = 0;

    // 27. a TEST that is not caught (the corruption is lost): the fault
    // detection is broken, the IP locks itself
    ready();
    write_block(fblk, 8);
    fork
      wr(RegCmd, CmdEnc | CmdTest);
      begin
        wait (dut.u_core.fsm_q == SEnc && dut.u_core.step_q == 5'd2);
        @(negedge clk);
        dut.u_core.tst_q = 1'b0;
      end
    join
    wait_idle("TEST");
    rd(RegStatus, st);
    if (!st[StLocked] || !st[StAlert] || st[StFault] || st[StKeyValid] || !alert_fatal)
      $fatal(1, "TEST not caught: STATUS %08x, alert %0d", st, alert_fatal);
    for (int j = 0; j < 8; j++) begin
      rd(RegDout + 4 * j, w);
      expect_eq(w, 32'h0, "DOUT of a TEST");
    end
    repeat (3) @(posedge clk);                // the lock wipes the key schedule
    wait_idle("wipe after the lock");
    if (!rows_wiped() || dut.u_core.dout_q != '0) $fatal(1, "LOCKED left the key schedule");
    power_on();
    if (alert_fatal) $fatal(1, "fatal alert after power-on");
    n_alert_fault = 0;
    n_faults++;

    lockout();
  endtask

  // FaultLimit faults since power-on lock the IP: only CLEAR works, no access
  // waits, the fatal alert is up; a system reset keeps LOCKED and FAULTS (it
  // clears ALERT), a power-on reset clears them
  task automatic lockout();
    logic [31:0] st, w;
    logic [255:0] c;
    for (int t = 0; t < FaultLimit; t++) begin
      set_key(256, 256, fkey);
      wait_idle("KEY");
      rd(RegStatus, st);
      if (!st[StKeyValid] || st[StLocked]) $fatal(1, "lockout, try %0d: KEY refused, STATUS %08x", t, st);
      wr(RegStatus, 32'h2C);
      enc_state_fault(SEnc, MFalse, 5'(2 + t), 11 * t);
      wait_idle("ENC");
      rd(RegStatus, st);
      if (!st[StFault] || st[15:12] != 4'(t + 1)) $fatal(1, "lockout, try %0d: STATUS %08x", t, st);
      if ((t + 1 < FaultLimit) == st[StLocked]) $fatal(1, "lockout after %0d faults: STATUS %08x", t + 1, st);
      wr(RegCmd, CmdClear);
      wait_idle("CLEAR");
      wr(RegStatus, 32'h2C);
    end
    if (!alert_fatal || n_alert_fault != FaultLimit) $fatal(1, "lockout: fatal alert %0d, %0d fault alerts",
                                                            alert_fatal, n_alert_fault);
    // locked: KEY / ENC / DEC / TEST refused, KEY / DIN / CTRL writes dropped
    rd(RegStatus, st);
    if (!st[StLocked] || !st[StAlert] || st[StKeyValid]) $fatal(1, "locked: STATUS %08x", st);
    wr(RegCtrl, 32'h1);
    write_key(256, fkey);
    if (dut.key_q != '0) $fatal(1, "locked: KEY written");
    write_block(fblk, 8);
    if (dut.din_q != '0) $fatal(1, "locked: DIN written");
    rd(RegStatus, st);
    if (!st[StErr]) $fatal(1, "locked: writes dropped without ERR");
    wr(RegStatus, 32'h08);
    foreach (locked_cmds[i]) begin
      wr(RegCmd, locked_cmds[i]);
      if (last_stall != 0) $fatal(1, "locked: CMD waited");
      rd(RegStatus, st);
      if (!st[StErr] || st[StBusy]) $fatal(1, "locked: CMD %02x not refused, STATUS %08x", locked_cmds[i], st);
      wr(RegStatus, 32'h08);
    end
    wr(RegCmd, CmdClear);                      // zeroization still works
    wait_idle("CLEAR when locked");
    rd(RegStatus, st);
    if (!st[StDone] || st[StErr]) $fatal(1, "locked: CLEAR, STATUS %08x", st);
    wr(RegStatus, 32'h0C);
    wr(RegCmd, CmdClear);                      // busy and locked: nothing waits
    wr(RegCmd, CmdKey);
    if (last_stall != 0) $fatal(1, "locked: CMD during CLEAR waited %0d cycles", last_stall);
    rd(RegDout, w);
    if (last_stall != 0 || w != 32'h0) $fatal(1, "locked: DOUT during CLEAR waited / %08x", w);
    rd(RegStatus, st);
    if (!st[StErr] || !st[StBusy]) $fatal(1, "locked: CMD during CLEAR, STATUS %08x", st);
    wait_idle("CLEAR when locked");
    wr(RegStatus, 32'h0C);
    // ALERT (the NMI) is cleared by writing 1, LOCKED stays
    wr(RegStatus, 32'h80);
    @(negedge clk);
    rd(RegStatus, st);
    if (alert_fatal || st[StAlert] || !st[StLocked]) $fatal(1, "ALERT W1C: STATUS %08x", st);
    // a system reset (software, UART break) does not unlock
    @(negedge clk);
    rst_n = 1'b0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    wait_idle("reset");
    rd(RegStatus, st);
    if (!st[StLocked] || st[15:12] != 4'(FaultLimit) || st[StAlert])
      $fatal(1, "system reset unlocked: STATUS %08x", st);
    wr(RegCtrl, 32'h1);
    write_key(256, fkey);
    wr(RegCmd, CmdKey);
    rd(RegStatus, st);
    if (!st[StErr] || st[StKeyValid] || st[StBusy]) $fatal(1, "KEY after system reset when locked: STATUS %08x", st);
    // the fault counter and its copy disagree: locked at once
    power_on();
    @(negedge clk);
    dut.fcnt_q = 4'd2;
    @(negedge clk);
    rd(RegStatus, st);
    if (!st[StLocked] || !alert_fatal) $fatal(1, "fault counter changed: STATUS %08x", st);
    power_on();
    if (alert_fatal) $fatal(1, "fatal alert after power-on");
    // and the IP works after the power-on reset
    set_key(256, 256, fkey);
    encrypt_block(fblk, 8, c);
    if (c != fc_ref) $fatal(1, "ENC after the lockout: %h", c);
    wait_idle("ENC");
    wr(RegStatus, 32'h2C);
    n_alert_fault = 0;
  endtask

  // ------------------------------------------ access control and the bus
  task automatic security();
    logic [31:0]  st, w;
    logic [511:0] key;
    logic [255:0] blk, c1, c2;
    cur_op = -1;
    key    = '0;
    for (int i = 0; i < 16; i++) key[32*i +: 32] = $urandom();
    for (int i = 0; i < 8; i++)  blk[32*i +: 32] = $urandom();

    // bus errors: reads of write only registers, writes of read only ones,
    // holes; nothing changes
    set_key(256, 256, key);
    encrypt_block(blk, 8, c1);
    wait_idle("ENC");
    foreach (no_read[i])  expect_bus_err(1'b0, no_read[i]);
    foreach (no_write[i]) expect_bus_err(1'b1, no_write[i]);
    rd(RegStatus, st);
    if (!st[StKeyValid] || st[StErr] || st[StFault]) $fatal(1, "bus errors changed STATUS %08x", st);
    for (int j = 0; j < 8; j++) begin
      rd(RegDout + 4 * j, w);
      if (w != c1[32*j +: 32]) $fatal(1, "bus errors changed DOUT");
    end
    rd(RegId, w);
    expect_eq(w, 32'h4d4b_5602, "ID after the bus errors");
    wr(RegStatus, 32'h0C);

    // KEY_VALID lost by a KEY write or another version: the engine wipes the
    // key schedule and the result at once (no DONE)
    set_key(256, 512, key);
    encrypt_block(blk, 8, c1);
    wait_idle("ENC");
    wr(RegStatus, 32'h0C);
    if (rows_with_data() != 19) $fatal(1, "MKV-256/512: %0d rows", rows_with_data());
    wr(RegKey, 32'h1);
    wait_idle("wipe");
    rd(RegStatus, st);
    if (st[StDone] || st[StKeyValid] || st[StErr]) $fatal(1, "wipe on a KEY write: STATUS %08x", st);
    if (!rows_wiped() || dut.u_core.dout_q != '0) $fatal(1, "KEY write: old key schedule not wiped");
    if (dut.key_q[0] != 32'h1) $fatal(1, "KEY write during the wipe lost");
    set_key(128, 192, key);
    wait_idle("KEY");
    wr(RegCtrl, 32'h0);                       // another version
    wait_idle("wipe");
    if (!rows_wiped()) $fatal(1, "version change: old key schedule not wiped");
    // a refused KEY leaves no key words behind
    wr(RegCtrl, 32'h6);                       // KLEN = 3
    for (int i = 0; i < 4; i++) wr(RegKey + 4 * i, key[32*i +: 32]);
    wr(RegCmd, CmdKey);
    rd(RegStatus, st);
    if (!st[StErr] || dut.key_q != '0) $fatal(1, "refused KEY: STATUS %08x, key words left", st);
    wr(RegStatus, 32'h0C);

    // NOSTALL: no access waits; a CMD / CTRL / KEY write during a command is
    // dropped (ERR), DOUT reads 0; DIN can be written
    wr(RegCtrl, 32'h5 | CtrlNoStall);         // MKV-256/512, R = 9
    write_key(512, key);
    wr(RegCmd, CmdKey);
    wr(RegCmd, CmdEnc);
    if (last_stall != 0) $fatal(1, "NOSTALL: CMD during KEY waited %0d cycles", last_stall);
    wr(RegCtrl, 32'h1 | CtrlNoStall);
    if (last_stall != 0) $fatal(1, "NOSTALL: CTRL during KEY waited");
    wr(RegKey, 32'h1234_5678);
    rd(RegStatus, st);
    if (!st[StErr] || !st[StBusy]) $fatal(1, "NOSTALL: writes during KEY not dropped, STATUS %08x", st);
    if (dut.klen_q != 2'd2 || !dut.wide_q) $fatal(1, "NOSTALL: CTRL changed during KEY");
    wait_idle("KEY");
    rd(RegStatus, st);
    if (!st[StKeyValid] || st[StFault]) $fatal(1, "NOSTALL: KEY, STATUS %08x", st);
    wr(RegStatus, 32'h0C);
    write_block(blk, 8);
    wr(RegCmd, CmdEnc);
    rd(RegDout, w);                           // right after the command: still busy
    if (last_stall != 0 || w != 32'h0) $fatal(1, "NOSTALL: DOUT during ENC waited %0d / %08x", last_stall, w);
    for (int j = 0; j < 8; j++) wr(RegDin + 4 * j, ~blk[32*j +: 32]);   // DIN during the command: taken
    wait_idle("ENC");
    c2 = '0;
    for (int j = 0; j < 8; j++) begin
      rd(RegDout + 4 * j, w);
      c2[32*j +: 32] = w;
    end
    if (dut.din_q != ~blk) $fatal(1, "NOSTALL: DIN written during ENC lost");
    wr(RegCtrl, 32'h5);                       // waits again
    set_key(256, 512, key);
    encrypt_block(blk, 8, c1);
    if (c1 != c2) $fatal(1, "NOSTALL: ENC %h, expected %h", c2, c1);
    wait_idle("ENC");
    wr(RegStatus, 32'h0C);

    // use policy and KEY_LOCK
    set_key(256, 512, key);
    wait_idle("KEY");
    wr(RegCtrl, 32'h5 | CtrlNoDec | CtrlKeyLock);
    rd(RegCtrl, w);
    expect_eq(w, 32'h5 | CtrlNoDec | CtrlKeyLock, "CTRL with KEY_LOCK");
    write_block(c1, 8);
    wr(RegCmd, CmdDec);                       // policy: refused
    rd(RegStatus, st);
    if (!st[StErr] || st[StBusy]) $fatal(1, "DEC under NO_DEC: STATUS %08x", st);
    wr(RegStatus, 32'h08);
    encrypt_block(blk, 8, c2);                // ENC allowed
    if (c2 != c1) $fatal(1, "ENC under KEY_LOCK: %h", c2);
    wait_idle("ENC");
    wr(RegStatus, 32'h0C);
    wr(RegKey, 32'h1);                        // KEY_LOCK: dropped
    rd(RegStatus, st);
    if (!st[StErr] || !st[StKeyValid] || dut.key_q != '0) $fatal(1, "KEY write under KEY_LOCK: STATUS %08x", st);
    wr(RegStatus, 32'h08);
    wr(RegCtrl, 32'h1);                       // other version / policy, KEY_LOCK 0: dropped
    rd(RegCtrl, w);
    rd(RegStatus, st);
    expect_eq(w, 32'h5 | CtrlNoDec | CtrlKeyLock, "CTRL under KEY_LOCK");
    if (!st[StErr] || !st[StKeyValid]) $fatal(1, "CTRL under KEY_LOCK: STATUS %08x", st);
    wr(RegStatus, 32'h08);
    wr(RegCtrl, 32'h5 | CtrlNoDec | CtrlKeyLock | CtrlNoStall);   // NOSTALL still free
    rd(RegCtrl, w);
    expect_eq(w, 32'h5 | CtrlNoDec | CtrlKeyLock | CtrlNoStall, "NOSTALL under KEY_LOCK");
    wr(RegCmd, CmdKey);
    rd(RegStatus, st);
    if (!st[StErr] || !st[StKeyValid]) $fatal(1, "KEY under KEY_LOCK: STATUS %08x", st);
    wr(RegStatus, 32'h08);
    wr(RegCmd, CmdClear);                     // zeroization still works
    wait_idle("CLEAR");
    rd(RegStatus, st);
    if (st[StKeyValid] || !st[StDone]) $fatal(1, "CLEAR under KEY_LOCK: STATUS %08x", st);
    wr(RegStatus, 32'h0C);
    @(negedge clk);                           // only a reset clears KEY_LOCK
    rst_n = 1'b0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    wait_idle("reset");
    rd(RegCtrl, w);
    expect_eq(w, 32'h0, "CTRL after reset");
    set_key(128, 128, key);                   // NO_ENC without KEY_LOCK
    wait_idle("KEY");
    wr(RegCtrl, CtrlNoEnc);
    wr(RegCmd, CmdEnc);
    rd(RegStatus, st);
    if (!st[StErr]) $fatal(1, "ENC under NO_ENC: STATUS %08x", st);
    wr(RegCtrl, 32'h0);
    wr(RegStatus, 32'h0C);
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

    por_n = 1'b0;
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    por_n = 1'b1;
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    rd(RegId, w);
    expect_eq(w, 32'h4d4b_5602, "ID");
    rd(RegInfo, w);
    expect_eq(w, 32'h0004_04ff, "INFO");
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
    security();
    faults();

    fd = $fopen({dir, "/status.txt"}, "w");
    $fdisplay(fd, "OK %0d", n_ops);
    $fclose(fd);
    $display("tb_bow_mkv: %0d operations, %0d key schedules, %0d states traced, DOUT stall up to %0d cycles, %0d faults detected",
             n_ops, n_keys, trace_lines, max_stall, n_faults);
    $finish;
  end

endmodule
