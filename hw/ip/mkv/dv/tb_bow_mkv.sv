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
// which `mkv_model.py check DIR` compares with the model. Directed checks
// at the end: errors (ERR), KEY_VALID rules, CLEAR, interrupt, CYCLES.

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
  localparam int unsigned StBusy = 0, StKeyValid = 1, StDone = 2, StErr = 3, StWide = 4;

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
  bit          logging = 1'b0, log_step = 1'b0, dump_rk = 1'b0;
  logic [4:0]  step_n;
  int unsigned trace_lines = 0;

  always @(negedge clk) begin
    if (log_step && logging) begin
      $fdisplay(ftrace, "%0d %0d %s", cur_op, step_n, hex(512'(dut.u_core.st_q), cur_bytes));
      trace_lines++;
    end
    // Encrypt (2) / Decrypt (3): the state register holds the result of
    // this step after the next clock edge
    log_step = (dut.u_core.fsm_q == 3'd2 || dut.u_core.fsm_q == 3'd3);
    step_n   = dut.u_core.step_q;
    if (dump_rk && logging) begin
      for (int unsigned i = 0; i <= 2 * dut.u_core.rounds_q; i++) begin
        $fdisplay(frk, "%0d %0d %s", cur_op, i, hex(512'(dut.u_core.rk_mem[i]), cur_bytes));
      end
    end
    dump_rk = dut.u_core.done_o && (dut.u_core.fsm_q == 3'd1);   // KeySched
  end

  // -------------------------------------------------------------- operations
  string        op_s;
  int unsigned  cfg_l = 0, cfg_k = 0;
  logic [511:0] cfg_key = '0;
  int unsigned  n_ops = 0, n_keys = 0, max_stall = 0;

  task automatic set_key(int unsigned l, int unsigned k, logic [511:0] key);
    logic [31:0] st;
    int unsigned klen;
    klen = (2 * k == 3 * l) ? 1 : (k == 2 * l) ? 2 : 0;
    wr(RegCtrl, {29'h0, 2'(klen), l == 256});
    for (int unsigned i = 0; i < k / 32; i++) begin
      if ($urandom_range(3) == 0) wr_bytes(RegKey + 4 * i, key[32*i +: 32]);
      else                        wr(RegKey + 4 * i, key[32*i +: 32]);
    end
    rd(RegStatus, st);
    if (st[StKeyValid]) $fatal(1, "KEY_VALID after a key write");
    wr(RegCmd, CmdKey);
    n_keys++;
    if ($urandom_range(1) == 0) begin
      do rd(RegStatus, st); while (st[StBusy]);
      if (!st[StKeyValid] || st[StErr]) $fatal(1, "key schedule: STATUS %08x", st);
      if (st[11:8] != 4'(6 + klen) || st[StWide] != (l == 256)) $fatal(1, "STATUS %08x for MKV-%0d/%0d", st, l, k);
    end
  endtask

  task automatic write_block(logic [255:0] blk, int unsigned nwords);
    for (int unsigned i = 0; i < nwords; i++) begin
      if ($urandom_range(5) == 0) wr_bytes(RegDin + 4 * i, blk[32*i +: 32]);
      else                        wr(RegDin + 4 * i, blk[32*i +: 32]);
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
        if (!st[StDone] || st[StErr]) $fatal(1, "op %0d: STATUS %08x", i, st);
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
      expect_eq(w, 32'(2 * (6 + ((2 * k == 3 * l) ? 1 : (k == 2 * l) ? 2 : 0)) + 2),
                $sformatf("op %0d: CYCLES (2R + 2)", i));
      wr(RegStatus, 32'h0C);
      n_ops++;
    end
  endtask

  // ------------------------------------------------------ directed checks
  task automatic directed();
    logic [31:0] st, w;
    logic [511:0] key;
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
    if (!st[StKeyValid] || st[11:8] != 4'd6) $fatal(1, "KEY: STATUS %08x", st);
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

    // KEY register is write only
    rd(RegKey + 4 * 15, w);
    expect_eq(w, 32'h0, "KEY read back");

    // CMD written right after KEY waits for the key schedule (gnt low)
    wr(RegCmd, CmdKey);
    wr(RegCmd, CmdEnc);
    if (last_stall < 60) $fatal(1, "CMD during the key schedule stalled %0d cycles", last_stall);
    rd(RegCycles, w);
    expect_eq(w, 32'd65, "CYCLES of KEY (R = 8)");
    rd(RegDout, w);                           // waits for the encryption
    if (last_stall == 0) $fatal(1, "DOUT read during the encryption did not stall");
    rd(RegCycles, w);
    expect_eq(w, 32'd18, "CYCLES of ENC (R = 8)");

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
    expect_eq(w, 32'h4d4b_5601, "ID");
    rd(RegInfo, w);
    expect_eq(w, 32'h0000_0203, "INFO");
    rd(RegStatus, w);
    expect_eq(w, 32'h0, "STATUS after reset");

    logging = 1'b1;
    run_case();
    @(negedge clk);
    logging = 1'b0;
    $fclose(fout);
    $fclose(ftrace);
    $fclose(frk);
    directed();

    fd = $fopen({dir, "/status.txt"}, "w");
    $fdisplay(fd, "OK %0d", n_ops);
    $fclose(fd);
    $display("tb_bow_mkv: %0d operations, %0d key schedules, %0d states traced, DOUT stall up to %0d cycles",
             n_ops, n_keys, trace_lines, max_stall);
    $finish;
  end

endmodule
