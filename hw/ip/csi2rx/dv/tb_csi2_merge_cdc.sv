// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit test of the lane merge's two clock FIFO (bow_csi2_lane_merge, u_cdc_fifo: byte clock
// -> csi_clk), step 7 of docs/ip/mipi_rx_arch.md, section 10 (Verilator --binary --timing,
// make -C hw/ip/csi2rx/dv cdc; part of test-rx). Built with BOW_SYNC_JITTER: every bit of the
// two pointer synchronisers whose input changed less than 0.5 ns before the clock edge may
// resolve one cycle late (hw/ip/common/rtl/bow_fifo_async.sv, bow_sync.sv), so a pointer
// that crosses with more than one bit changing at a time shows values it never had. The
// clocks are no multiples of each other and the byte clock restarts at a random phase after
// every stop, so the window sees the changes of both pointers; the run fails when no bit
// ever resolved late (the jitter model then tested nothing).
//
// The bench drives the PPI side of the lane merge (Lanes active lanes in lockstep, common
// RxValidHS gaps, ErrSotSyncHS / deskew events at random cycles, also in the cycle after
// RxActiveHS falls as the D-PHY of Bow32 gives them) in bursts with a non-continuous byte
// clock, and checks at the csi_clk side:
//   order     every entry written into the FIFO (its write port, the byte clock edges) comes
//             out once, in order, as written (word, sop, end of burst, skew, events), none
//             else;
//   stop      the byte clock stops exactly POST edges after the edge at which RxActiveHS
//             falls (2: the least step 7 needs, or 3, 6); before it runs again (LP time
//             >= 120 ns) every burst's end and every entry are out: nothing waits for a byte
//             clock. Some bursts stop the clock before the fall (0, 1 edges): their end
//             comes with the next run, before its first word;
//   depth     at a csi_clk at least the byte clock the writer never sees the FIFO almost full
//             (no word dropped); the most entries it sees in flight is reported;
//   overflow  (byte clock 312.5 MHz against 200 MHz, case 'fast') long bursts drop words:
//             every burst still ends, the ones that dropped one with the skew flag.
// "tb_csi2_merge_cdc: PASS (<n> checks)" or "FAIL (<n> errors)".

`timescale 1ns / 1ps

module tb_csi2_merge_cdc;
  parameter int unsigned Lanes = 4;
  localparam int unsigned EntryW = 4 + Lanes + 1 + 8 * Lanes;
  localparam realtime CsiNs = 5.0;                       // 200 MHz
  localparam int unsigned CdcDepth = 16;                  // bow_csi2_lane_merge's default

  int unsigned errors = 0, checks = 0;

  function automatic void err(string msg);
    errors++;
    if (errors <= 30) $display("[%0t] ERROR: %s", $time, msg);
  endfunction

  // ------------------------------------------------------------------ clocks, resets
  logic    csi_clk = 1'b0, byte_clk = 1'b0;
  bit      brun = 1'b0;
  realtime byte_ns = 8.772;
  logic    rst_n = 1'b0;

  always #(CsiNs / 2.0) csi_clk = ~csi_clk;

  initial begin : bclk
    forever begin
      if (brun) begin
        #(byte_ns / 2.0) byte_clk = 1'b1;
        #(byte_ns / 2.0) byte_clk = 1'b0;
      end else begin
        wait (brun);
      end
    end
  end

  // ------------------------------------------------------------------ DUT
  logic [Lanes-1:0]      arm = '0, valid = '0, sot = '0, ev_sot = '0;
  logic [Lanes-1:0][7:0] data = '0;
  logic                  ev_dsk = 1'b0;
  logic                  lanes2, lanes4;
  logic                  o_valid, o_sop, o_eob, o_skew, o_dsk;
  logic [Lanes-1:0][7:0] o_data;
  logic [Lanes-1:0]      o_sot;

  assign lanes2 = (Lanes >= 2);
  assign lanes4 = (Lanes == 4);

  bow_csi2_lane_merge #(
    .Lanes (Lanes)
  ) dut (
    .clk_i      (byte_clk),
    .rst_ni     (rst_n),
    .lanes2_i   (lanes2),
    .lanes4_i   (lanes4),
    .arm_i      (arm),
    .valid_i    (valid),
    .data_i     (data),
    .sot_i      (sot),
    .ev_sot_i   (ev_sot),
    .ev_dsk_i   (ev_dsk),
    .csi_clk_i  (csi_clk),
    .csi_rst_ni (rst_n),
    .valid_o    (o_valid),
    .data_o     (o_data),
    .sop_o      (o_sop),
    .eob_o      (o_eob),
    .ev_skew_o  (o_skew),
    .ev_sot_o   (o_sot),
    .ev_dsk_o   (o_dsk)
  );

  // ------------------------------------------------------------------ write side record
  logic [EntryW-1:0] exp_q [$];
  int unsigned       written = 0, dropped = 0, words_lost = 0, occ_max = 0, eob_written = 0;

  always @(posedge byte_clk) begin
    int unsigned occ;
    if (rst_n) begin
      if (dut.u_cdc_fifo.push_i) begin
        if (dut.u_cdc_fifo.full_o) dropped++;
        else begin
          exp_q.push_back(dut.u_cdc_fifo.wdata_i);
          written++;
          if (dut.m_eob_q) eob_written++;
        end
      end
      if (dut.m_valid_q && dut.f_afull) words_lost++;
      occ = (int'(dut.u_cdc_fifo.wbin_q) - int'(dut.u_cdc_fifo.rbin_w)) & (2 * CdcDepth - 1);
      if (occ > occ_max) occ_max = occ;
    end
  end

  // ------------------------------------------------------------------ read side check
  int unsigned got = 0, eob_seen = 0, skew_seen = 0;

  always @(posedge csi_clk) begin
    logic [EntryW-1:0]     e;
    logic                  e_valid, e_sop, e_eob, e_skew, e_dsk;
    logic [Lanes-1:0]      e_sot;
    logic [Lanes-1:0][7:0] e_data;
    if (rst_n && (o_valid || o_eob || (o_sot != '0) || o_dsk)) begin
      checks++;
      got++;
      if (exp_q.size() == 0) begin
        err($sformatf("entry %0d out (valid %0b eob %0b), none was written", got, o_valid, o_eob));
      end else begin
        e = exp_q.pop_front();
        {e_valid, e_sop, e_eob, e_skew, e_sot, e_dsk, e_data} = e;
        if (o_valid != e_valid || o_sop != e_sop || o_eob != e_eob || o_skew != e_skew ||
            o_sot != e_sot || o_dsk != e_dsk || (e_valid && o_data != e_data)) begin
          err($sformatf("entry %0d: out valid %0b sop %0b eob %0b skew %0b sot %b dsk %0b data %h, written %0b %0b %0b %0b %b %0b %h",
                        got, o_valid, o_sop, o_eob, o_skew, o_sot, o_dsk, o_data, e_valid, e_sop,
                        e_eob, e_skew, e_sot, e_dsk, e_data));
        end
      end
      if (o_eob) eob_seen++;
      if (o_eob && o_skew) skew_seen++;
      if (o_valid && o_eob) err("a word and an end of burst in one cycle");
    end
  end

  // ------------------------------------------------------------------ driver
  int unsigned bursts = 0, post_hist [8];

  // values of the next byte clock cycle: set just after an edge, as flop outputs
  task automatic edge_n(input int unsigned n);
    repeat (n) @(posedge byte_clk);
    #0.1;
  endtask

  // one burst of `words` words with gaps (probability gap / 100), events, the clock stopped
  // `post` edges after the edge at which RxActiveHS falls (-1: before the fall, the fall in
  // the next run), or left running (cont)
  int  pend_fall = 0;                      // RxActiveHS still to fall in the next run
  task automatic burst(input int unsigned words, input int unsigned gap, input int post,
                       input bit cont);
    int unsigned sent;
    if (!brun) begin
      #($urandom_range(5, 30) * 1.0);    // the clock restarts at a random phase
      brun = 1'b1;
    end
    edge_n(1);
    ev_sot = '0;                         // (events of the cycle the last run stopped in)
    ev_dsk = 1'b0;
    if (pend_fall != 0) begin            // the fall of the previous burst, deferred
      arm = '0;
      edge_n(1);
      ev_sot = (pend_fall == 2) ? Lanes'(1) : '0;
      edge_n(1);
      ev_sot = '0;
      pend_fall = 0;
      edge_n(2);
    end
    // RxActiveHS from SETTLE, sync a few cycles later
    arm = '1;
    edge_n($urandom_range(1, 4));
    sent = 0;
    while (sent < words) begin
      if (sent != 0 && $urandom_range(99) < gap) begin
        valid = '0;
        sot = '0;
      end else begin
        valid = '1;
        sot = (sent == 0) ? '1 : '0;
        for (int l = 0; l < int'(Lanes); l++) data[l] = 8'($urandom);
        sent++;
      end
      ev_sot = ($urandom_range(199) == 0) ? Lanes'($urandom) : '0;
      ev_dsk = ($urandom_range(199) == 0);
      edge_n(1);
    end
    valid = '0;
    sot = '0;
    ev_sot = '0;
    ev_dsk = 1'b0;
    edge_n($urandom_range(1, 6));        // trail
    bursts++;
    if (post < 0) begin
      // the clock stops before the fall: the fall (with an ErrSotSyncHS sometimes) in the
      // next run
      pend_fall = $urandom_range(1, 2);
      brun = cont;
      post_hist[7]++;
      return;
    end
    arm = '0;                            // the fall, at the edge before this cycle
    edge_n(1);
    // ErrSotSyncHS in the cycle after the fall (the D-PHY of Bow32), sometimes
    if ($urandom_range(3) == 0) ev_sot = Lanes'($urandom) | Lanes'(1);
    if ($urandom_range(7) == 0) ev_dsk = 1'b1;
    if (post == 1) begin
      // the clock stops after edge 1 of the fall: the end of the burst (registered there)
      // and these events are written at the first edge of the next run
      brun = cont;
      post_hist[1]++;
      return;
    end
    edge_n(1);
    ev_sot = '0;
    ev_dsk = 1'b0;
    if (post > 2) edge_n(post - 2);
    brun = cont;                         // the clock stops after edge `post`
    post_hist[(post > 6) ? 6 : post]++;
  endtask

  // LP time with the clock stopped; then everything written must be out: the end of every
  // burst whose clock ran 2 edges past its fall (`deferred`: one burst's end waits)
  task automatic lp_gap(input int unsigned ns, input bit deferred);
    #(ns * 1.0);
    checks++;
    if (!brun && exp_q.size() != 0) begin
      err($sformatf("%0d entries still in the FIFO %0d ns into the LP time (burst %0d): they wait for a byte clock",
                    exp_q.size(), ns, bursts));
    end
    checks++;
    if (!brun && eob_seen + 32'(deferred) != bursts) begin
      err($sformatf("%0d bursts ended, %0d ends out (%0s) %0d ns into the LP time", bursts,
                    eob_seen, deferred ? "the last one deferred" : "none deferred", ns));
    end
  endtask

  // a case: the byte clock period, bursts, the stop after them
  task automatic run_case(input string name, input realtime bns, input int unsigned n,
                          input int unsigned wmax, input bit overflow);
    int unsigned b0, s0, l0, post, gap;
    bit          defer;
    byte_ns = bns;
    occ_max = 0;
    b0 = bursts;
    s0 = skew_seen;
    l0 = words_lost;
    for (int i = 0; i < int'(n); i++) begin
      gap = $urandom_range(2) == 0 ? 0 : $urandom_range(1, 40);
      // post: mostly the least (2), then 3, 6; 1 / before the fall: deferred ends
      case ($urandom_range(9))
        0:       post = 1;
        1:       post = 32'hFFFF_FFFF;   // -1
        2, 3:    post = 3;
        4:       post = 6;
        default: post = 2;
      endcase
      defer = (int'(post) < 2);
      burst($urandom_range(1, wmax), gap, int'(post), 1'b0);
      lp_gap($urandom_range(120, 400), defer);
    end
    // the last deferred end: one more burst
    burst(1, 0, 2, 1'b0);
    lp_gap(200, 1'b0);
    $display("tb_csi2_merge_cdc: case %s, byte clock %0.3f ns: %0d bursts, at most %0d entries in flight (the writer's view), %0d words dropped, %0d ends with the skew flag",
             name, bns, bursts - b0, occ_max, words_lost - l0, skew_seen - s0);
    if (overflow) begin
      checks++;
      if (words_lost == l0) err($sformatf("case %s: no word dropped (the FIFO never filled)", name));
      checks++;
      if (skew_seen == s0) err($sformatf("case %s: no burst with the skew flag", name));
    end else begin
      checks++;
      if (words_lost != l0 || skew_seen != s0) begin
        err($sformatf("case %s: %0d words dropped, %0d skew flags at a csi_clk faster than the byte clock",
                      name, words_lost - l0, skew_seen - s0));
      end
    end
  endtask

  initial begin : watchdog
    #(20_000_000.0);
    $fatal(1, "TIMEOUT");
  end

  initial begin : main
    for (int i = 0; i < 8; i++) post_hist[i] = 0;
    // reset with real edges of both clocks
    #1;
    brun = 1'b1;
    rst_n = 1'b0;
    repeat (4) @(posedge csi_clk);
    repeat (4) @(posedge byte_clk);
    rst_n = 1'b1;
    repeat (4) @(posedge byte_clk);
    brun = 1'b0;
    #50;

    run_case("kv260", 8.772, 60, 300, 1'b0);               // 114 MHz (912 Mbit/s)
    run_case("huins", 5.556, 60, 300, 1'b0);               // 180 MHz (1440 Mbit/s)
    run_case("equal_slow", 5.0013, 40, 600, 1'b0);         // ratio 1, csi_clk 260 ppm faster
    run_case("equal_fast", 4.9987, 40, 600, 1'b0);         // byte clock 260 ppm faster
    run_case("slow", 10.417, 30, 200, 1'b0);               // 96 MHz
    run_case("fast", 3.2, 20, 400, 1'b1);                  // 312.5 MHz: overflow

    // drain, then the checks of the whole run
    #500;
    checks++;
    if (exp_q.size() != 0) err($sformatf("%0d entries never came out", exp_q.size()));
    checks++;
    if (dropped != 0) begin
      // a full FIFO only in the overflow case, and never for an end of burst
      if (eob_seen != bursts) err($sformatf("%0d entries pushed into a full FIFO, ends lost", dropped));
    end
    checks++;
    if (eob_seen != bursts) err($sformatf("%0d bursts, %0d ends out", bursts, eob_seen));
    $display("tb_csi2_merge_cdc: %0d bursts, %0d entries written and read, stops of the byte clock after the fall: %0d at edge 1, %0d at 2, %0d at 3, %0d at 6, %0d before it",
             bursts, written, post_hist[1], post_hist[2], post_hist[3], post_hist[6],
             post_hist[7]);
`ifdef BOW_SYNC_JITTER
    $display("tb_csi2_merge_cdc: BOW_SYNC_JITTER: %0d synchroniser inputs changed inside the window, %0d resolved one cycle late",
             bow_sync_jitter_pkg::n_window, bow_sync_jitter_pkg::n_late);
    checks++;
    if (bow_sync_jitter_pkg::n_late == 0) err("the synchronisers' jitter never fired");
`else
    err("built without BOW_SYNC_JITTER");
`endif
    if (errors == 0) $display("tb_csi2_merge_cdc: PASS (%0d checks)", checks);
    else             $display("tb_csi2_merge_cdc: FAIL (%0d errors)", errors);
    $finish;
  end

endmodule
