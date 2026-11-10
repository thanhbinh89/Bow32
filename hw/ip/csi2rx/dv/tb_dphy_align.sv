// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit test of bow_dphy_align (make -C hw/ip/csi2rx/dv test): the search
// window placed at the edges the D-PHY level test cannot reach. Every case
// drives the ISERDES words of one burst (the words before the arm rise are
// the q1/q2 history of the first search cycle), lowers arm after the last
// word and expects one outcome from the documented rule (see the header of
// bow_dphy_align.sv):
//   LOCK     one sot, with the first byte after the sync
//   DESKEW   one ev_deskew: 8 zero bits then FFFFh where the HS-zero leader
//            ends; up to 2 non-zero words at the start of the search
//   SYNCERR  one ev_sync_err at the fall of arm: no 0xB8, no deskew
// Prints "tb_dphy_align: PASS (<n> cases)" or "... FAIL (<n> errors)".

`timescale 1ns / 1ps

module tb_dphy_align;

  logic       clk = 1'b0, rst_n = 1'b0, arm = 1'b0;
  logic [7:0] rx = '0;
  logic       valid, sot, locked, serr, dsk;
  logic [7:0] data;

  bow_dphy_align dut (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .arm_i         (arm),
    .rx_i          (rx),
    .valid_o       (valid),
    .data_o        (data),
    .sot_o         (sot),
    .locked_o      (locked),
    .ev_sync_err_o (serr),
    .ev_deskew_o   (dsk)
  );

  always #5 clk = ~clk;

  typedef enum int {LOCK, DESKEW, SYNCERR} res_e;
  typedef bit          bits_t[$];
  typedef logic [7:0]  words_t[$];

  int unsigned errors = 0, cases = 0;
  int unsigned n_sot, n_dsk, n_err;
  logic [7:0]  first;
  bit          count = 1'b0;

  always @(posedge clk) begin
    if (count) begin
      if (sot) begin
        if (n_sot == 0) first = data;
        n_sot++;
      end
      if (dsk)  n_dsk++;
      if (serr) n_err++;
    end
  end

  // ------------------------------------------------------------- stimulus
  function automatic void add_byte(ref bits_t b, input logic [7:0] v);
    for (int i = 0; i < 8; i++) b.push_back(v[i]);           // LSB first on the wire
  endfunction

  function automatic void add_bits(ref bits_t b, input int unsigned n, input bit v);
    repeat (n) b.push_back(v);
  endfunction

  // bits -> words (bit 0 of a word received first); the last word is padded
  // with the last bit (the HS-TRAIL holds it)
  function automatic words_t pack(input bits_t b);
    words_t      w;
    logic [7:0]  x;
    bit          last;
    last = (b.size() > 0) ? b[b.size() - 1] : 1'b0;
    while (b.size() % 8 != 0) b.push_back(last);
    for (int i = 0; i < b.size(); i += 8) begin
      for (int k = 0; k < 8; k++) x[k] = b[i + k];
      w.push_back(x);
    end
    return w;
  endfunction

  // a queue of n words (up to 8)
  function automatic words_t mk(input int n, input logic [7:0] b0 = 0, input logic [7:0] b1 = 0,
                                input logic [7:0] b2 = 0, input logic [7:0] b3 = 0,
                                input logic [7:0] b4 = 0, input logic [7:0] b5 = 0,
                                input logic [7:0] b6 = 0, input logic [7:0] b7 = 0);
    logic [7:0] v [8];
    words_t     w;
    v = '{b0, b1, b2, b3, b4, b5, b6, b7};
    for (int i = 0; i < n; i++) w.push_back(v[i]);
    return w;
  endfunction

  // pre: words before the arm rise (q2, q1 of the first search cycle);
  // w: words while arm is high
  task automatic play(input string name, input words_t pre, input words_t w, input res_e exp,
                      input logic [7:0] exp_byte = 8'h00);
    string res;
    cases++;
    foreach (pre[i]) begin
      @(negedge clk);
      rx = pre[i];
    end
    n_sot = 0;
    n_dsk = 0;
    n_err = 0;
    count = 1'b1;
    foreach (w[i]) begin
      @(negedge clk);
      rx  = w[i];
      arm = 1'b1;
    end
    @(negedge clk);
    arm = 1'b0;
    rx  = '0;
    repeat (4) @(negedge clk);
    count = 1'b0;
    res = $sformatf("sot %0d deskew %0d sync_err %0d", n_sot, n_dsk, n_err);
    case (exp)
      LOCK: begin
        if (n_sot != 1 || n_dsk != 0 || n_err != 0 || first !== exp_byte) begin
          errors++;
          $display("ERROR %s: %s first byte %02h, expected a lock, first byte %02h", name, res,
                   first, exp_byte);
        end
      end
      DESKEW: begin
        if (n_dsk != 1 || n_sot != 0 || n_err != 0) begin
          errors++;
          $display("ERROR %s: %s, expected a deskew burst", name, res);
        end
      end
      default: begin
        if (n_err != 1 || n_sot != 0 || n_dsk != 0) begin
          errors++;
          $display("ERROR %s: %s, expected a sync error", name, res);
        end
      end
    endcase
    repeat (3) @(negedge clk);
  endtask

  // ---------------------------------------------------------------- cases
  initial begin
    bits_t      b;
    words_t     none, w;
    logic [7:0] noise [3] = '{8'hA5, 8'h3C, 8'h96};
    logic [7:0] bad_sync [3] = '{8'hFC, 8'hFE, 8'hFF};

    repeat (3) @(negedge clk);
    // arm already high when the reset is released: no search in that burst
    arm = 1'b1;
    rx  = 8'h00;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    count = 1'b1;
    n_sot = 0;
    n_dsk = 0;
    n_err = 0;
    repeat (6) begin
      @(negedge clk);
      rx = 8'hB8;
    end
    @(negedge clk);
    arm = 1'b0;
    rx  = '0;
    repeat (4) @(negedge clk);
    count = 1'b0;
    cases++;
    if (n_sot + n_dsk + n_err != 0) begin
      errors++;
      $display("ERROR arm high at reset release: events %0d/%0d/%0d", n_sot, n_dsk, n_err);
    end

    for (int ph = 0; ph < 8; ph++) begin
      // normal burst: HS-zero, 0xB8, header
      b.delete();
      add_bits(b, 32 + ph, 1'b0);
      add_byte(b, 8'hB8);
      add_byte(b, 8'h2B);
      add_byte(b, 8'h14);
      add_byte(b, 8'h00);
      play($sformatf("sync phase %0d", ph), none, pack(b), LOCK, 8'h2B);
      // skew calibration burst: HS-zero, FFFFh, 0101...
      b.delete();
      add_bits(b, 32 + ph, 1'b0);
      add_byte(b, 8'hFF);
      add_byte(b, 8'hFF);
      repeat (8) add_byte(b, 8'h55);
      play($sformatf("deskew phase %0d", ph), none, pack(b), DESKEW);
      // only 8 ones (0xFF, then a packet header): no deskew, no sync
      b.delete();
      add_bits(b, 32 + ph, 1'b0);
      add_byte(b, 8'hFF);
      add_byte(b, 8'h10);
      repeat (8) add_byte(b, 8'h55);
      play($sformatf("8 ones phase %0d", ph), none, pack(b), SYNCERR);
      // 15 ones (0xFF, 0x7F): no deskew
      b.delete();
      add_bits(b, 32 + ph, 1'b0);
      add_byte(b, 8'hFF);
      add_byte(b, 8'h7F);
      repeat (8) add_byte(b, 8'h55);
      play($sformatf("15 ones phase %0d", ph), none, pack(b), SYNCERR);
      // corrupted syncs whose ones run into the low bits of DI 0x2B (8, 9, 10 ones)
      for (int k = 0; k < 3; k++) begin
        b.delete();
        add_bits(b, 32 + ph, 1'b0);
        add_byte(b, bad_sync[k]);
        add_byte(b, 8'h2B);
        add_byte(b, 8'h14);
        add_byte(b, 8'h00);
        repeat (6) add_byte(b, 8'hFF);
        play($sformatf("sync %02h + DI 2B phase %0d", bad_sync[k], ph), none, pack(b), SYNCERR);
      end
      // corrupted sync, then black and white pixels (00 FF FF)
      b.delete();
      add_bits(b, 32 + ph, 1'b0);
      add_byte(b, 8'hB9);
      add_byte(b, 8'h2B);
      repeat (4) begin
        add_byte(b, 8'h00);
        add_byte(b, 8'hFF);
        add_byte(b, 8'hFF);
      end
      play($sformatf("sync B9 + 00 FF FF phase %0d", ph), none, pack(b), SYNCERR);
    end

    // up to 2 noise words at the start of the search (the q2, q1 history of
    // the first cycle): deskew and sync still found
    for (int n = 1; n <= 2; n++) begin
      words_t pre;
      pre = mk(2, noise[0], (n == 1) ? 8'h00 : noise[1]);
      b.delete();
      add_bits(b, 32, 1'b0);
      add_byte(b, 8'hFF);
      add_byte(b, 8'hFF);
      repeat (8) add_byte(b, 8'h55);
      play($sformatf("%0d noise words, deskew", n), pre, pack(b), DESKEW);
      b.delete();
      add_bits(b, 29, 1'b0);
      add_byte(b, 8'hB8);
      add_byte(b, 8'h12);
      add_byte(b, 8'h40);
      play($sformatf("%0d noise words, sync", n), pre, pack(b), LOCK, 8'h12);
    end
    // a zero word, then noise: the leader is over, no deskew (the sync is found)
    b.delete();
    add_bits(b, 32, 1'b0);
    add_byte(b, 8'hFF);
    add_byte(b, 8'hFF);
    repeat (8) add_byte(b, 8'h55);
    play("zero word then noise, deskew", mk(2, 8'h00, noise[0]), pack(b), SYNCERR);
    // a third noise word: the search did not start in the leader
    b.delete();
    add_byte(b, noise[2]);
    add_bits(b, 32, 1'b0);
    add_byte(b, 8'hFF);
    add_byte(b, 8'hFF);
    repeat (8) add_byte(b, 8'h55);
    play("3 noise words, deskew", mk(2, noise[0], noise[1]), pack(b), SYNCERR);

    // window starting in the last zero word, the sync (corrupted) in q1: an
    // FS with frame number 0 (zero header) then the 0xFF trail is no deskew
    w = mk(8, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'hFF, 8'hFF, 8'hFF);
    play("last zero word, sync B9, zero header", mk(2, 8'h00, 8'hB9), w, SYNCERR);
    // window starting after the leader (SETTLE too late): payload words,
    // then 00 00 FF FF (black, white pixels) is no deskew
    w = mk(7, 8'h96, 8'h00, 8'h00, 8'hFF, 8'hFF, 8'hFF, 8'hFF);
    play("after the leader, 00 00 FF FF", mk(2, 8'h2B, 8'h14), w, SYNCERR);
    // a single 1 bit at the end of the leader, then 8 zeros and FFFFh
    w = mk(8, 8'h00, 8'h00, 8'h01, 8'hFE, 8'hFF, 8'hFF, 8'h55, 8'h55);
    play("1 bit before 00 FFFF", mk(2, 8'h00, 8'h00), w, SYNCERR);
    // the same without the stray bit is a deskew burst
    w = mk(8, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'hFF, 8'h55, 8'h55);
    play("00 FFFF", mk(2, 8'h00, 8'h00), w, DESKEW);
    // a lock after a deskew-looking first window is still a lock: 0xB8 wins
    w = mk(6, 8'h00, 8'h00, 8'hB8, 8'hFF, 8'hFF, 8'h55);
    play("sync then FF FF", mk(2, 8'h00, 8'h00), w, LOCK, 8'hFF);

    if (errors == 0) $display("tb_dphy_align: PASS (%0d cases)", cases);
    else             $display("tb_dphy_align: FAIL (%0d errors)", errors);
    $finish;
  end

endmodule
