// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit test of the AFE controls and status of the digital D-PHY (bow_dphy_rx, step 5 of
// docs/ip/mipi_rx_arch.md, sections 3.2, 3.5, 3.6; make -C hw/ip/csi2rx/dv afe, part of
// test-rx and CI): what the whole receiver bench cannot reach because bow_mipi_rx ties it
// off or the FPGA adapters ignore it. bow_dphy_rx alone, its registers on the bus, an AFE
// model on the AFE ports (ready falls t_off after pd rises and comes back t_on after pd
// falls; a mode in which ready stays 1 as with the UltraScale+ adapter; cal_done, cal_err,
// status and dly_q driven by the test), bow_afe_chk bound in as in every bench. Two builds:
// the ASIC configuration (AfeKind 0, AfePdRst 1, 4 lanes, TrimW 32) and the FPGA one
// (AfeKind 1, AfePdRst 0, 2 lanes).
//   * reset values while reset is asserted (section 3.6, both reset domains), at power up
//     and again in the middle of a run; INFO, AFE_CTRL;
//   * AFE_STATUS: READY [0], CAL_DONE [1], CAL_ERR [2], status [15:8], each bit on its own;
//   * AFE_CTRL.PD: pd and lprx_en at once, lane_pd 1 until a fresh READY (ASIC power up;
//     PD pulses of two back to back writes and a few cycles longer, which the D-PHY's READY
//     synchroniser still shows as ready; with an AFE that keeps ready at 1, lane_pd stays
//     1 after the pulse); bow_afe_chk checks lane_pd at every cycle;
//   * DLYn: a write sets CODE always, OWN only while READY (a write while READY = 0 does
//     not raise it); READY falling clears OWN; a write without byte 0 or 1 changes nothing;
//   * CMD.AFE_CAL (CMD.REINIT up to step 5): cal_start for 32 bus cycles, restarted by a
//     second AFE_CAL, none without byte 0, none from CMD.REINIT (step 6: the state machines);
//   * CTRL.DES_RST_DIS (a shadow register, step 6: CMD.APPLY): des_rst 0 while set (gate
//     closed), 1 again when cleared; nothing before the APPLY.
// Prints "tb_dphy_afe: PASS (<n> checks)" or "tb_dphy_afe: FAIL (<n> errors)".

`timescale 1ns / 1ps

module tb_dphy_afe;
  import bow_bus_pkg::*;

  parameter int unsigned Lanes    = 4;
  parameter int unsigned AfeKind  = 0;
  parameter bit          AfePdRst = 1'b1;
  parameter int unsigned TrimW    = 32;

  localparam logic [9:0] AId = 10'h000, AInfo = 10'h004, ACtrl = 10'h00C, ACmd = 10'h010,
                         AAfeCtrl = 10'h014, AAfeStatus = 10'h018, ADly0 = 10'h080;

  int unsigned errors = 0, checks = 0;

  function automatic void err(string msg);
    errors++;
    if (errors <= 30) $display("[%0t] ERROR: %s", $time, msg);
  endfunction

  function automatic void expect_eq(string what, logic [31:0] got, logic [31:0] want);
    checks++;
    if (got !== want) err($sformatf("%s: 0x%08h, want 0x%08h", what, got, want));
  endfunction

  logic clk = 1'b0, lp_clk = 1'b0, rst_n = 1'b1;
  always #10 clk = ~clk;                          // 50 MHz bus
  always #2.5 lp_clk = ~lp_clk;                   // 200 MHz lp

  bus_req_t req = '0;
  bus_rsp_t rsp;

  // AFE model
  logic                       ready = 1'b0, cal_done = 1'b0, cal_err = 1'b0;
  logic [7:0]                 status = '0;
  logic [Lanes-1:0][8:0]      dly_q = '0;
  logic                       pd, clk_lane_pd, cal_start, gate, des_rst;
  logic [Lanes-1:0]           lane_pd, own, lprx_en;
  logic [Lanes-1:0][8:0]      code;
  logic                       clk_lprx_en, clk_hsrx_en, clk_term_en;
  logic [Lanes-1:0]           hsrx_en, term_en;
  bit                         ready_stuck = 1'b0;     // the AFE keeps ready at 1 (UltraScale+)
  realtime                    t_off = 20.0, t_on = 1500.0;

  bow_dphy_rx #(
    .Lanes    (Lanes),
    .AfeKind  (AfeKind),
    .BusClkHz (50_000_000),
    .AfePdRst (AfePdRst),
    .TrimW    (TrimW)
  ) dut (
    .clk_i              (clk),
    .rst_ni             (rst_n),
    .lp_clk_i           (lp_clk),
    .lp_rst_ni          (rst_n),
    .bus_req_i          (req),
    .bus_rsp_o          (rsp),
    .irq_o              (),
    .enable_i           ('0),
    .enable_clk_i       (1'b0),
    .rx_byte_clk_hs_o   (),
    .ppi_hs_o           (),
    .ppi_lp_o           (),
    .ppi_lp_clk_o       (),
    .afe_hs_byte_clk_i  (1'b0),
    .afe_hs_data_i      ('0),
    .afe_hs_valid_i     ('1),
    .afe_clk_gate_en_o  (gate),
    .afe_des_rst_o      (des_rst),
    .afe_clk_hs_samp_i  ('0),
    .afe_clk_act_i      (1'b0),
    .afe_clk_lp_i       (2'b11),
    .afe_lp_i           ('1),
    .afe_clk_lprx_en_o  (clk_lprx_en),
    .afe_lprx_en_o      (lprx_en),
    .afe_clk_hsrx_en_o  (clk_hsrx_en),
    .afe_hsrx_en_o      (hsrx_en),
    .afe_clk_term_en_o  (clk_term_en),
    .afe_term_en_o      (term_en),
    .afe_dly_code_o     (code),
    .afe_dly_own_o      (own),
    .afe_dly_q_i        (dly_q),
    .afe_clk_dly_code_o (),
    .afe_clk_dly_own_o  (),
    .afe_clk_dly_q_i    ('0),
    .afe_mon_en_o       (),
    .afe_mon_code_o     (),
    .afe_mon_data_i     ('0),
    .afe_pd_o           (pd),
    .afe_clk_lane_pd_o  (clk_lane_pd),
    .afe_lane_pd_o      (lane_pd),
    .afe_ready_i        (ready),
    .afe_cal_start_o    (cal_start),
    .afe_cal_done_i     (cal_done),
    .afe_cal_err_i      (cal_err),
    .afe_trim_o         (),
    .afe_status_i       (status),
    .afe_tst_mode_o     (),
    .afe_tst_data_o     (),
    .afe_clk_hs_raw_i   (1'b0),
    .afe_hs_raw_i       ('0),
    .afe_atb_sel_o      ()
  );

  bind bow_dphy_rx bow_afe_chk #(
    .Lanes (Lanes), .TrimW (TrimW), .AfePdRst (AfePdRst), .Report (1'b1)
  ) u_afe_chk (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .lp_clk_i       (lp_clk_i),
    .lp_rst_ni      (lrst_n),
    .gate_i         (afe_clk_gate_en_o),
    .des_rst_i      (afe_des_rst_o),
    .des_rst_en_i   (des_rst_en),
    .hsrx_early_i   (cfg_lp_q.hsrx_early),
    .clk_hsrx_en_i  (afe_clk_hsrx_en_o),
    .hsrx_en_i      (afe_hsrx_en_o),
    .clk_term_en_i  (afe_clk_term_en_o),
    .term_en_i      (afe_term_en_o),
    .pd_i           (afe_pd_o),
    .clk_lprx_en_i  (afe_clk_lprx_en_o),
    .lprx_en_i      (afe_lprx_en_o),
    .clk_lane_pd_i  (afe_clk_lane_pd_o),
    .lane_pd_i      (afe_lane_pd_o),
    .ready_i        (phy_rdy_sys),
    .ulps_act_i     (ulps_act_sys),
    .dly_own_i      (afe_dly_own_o),
    .clk_dly_code_i (afe_clk_dly_code_o),
    .clk_dly_own_i  (afe_clk_dly_own_o),
    .mon_en_i       (afe_mon_en_o),
    .mon_code_i     (afe_mon_code_o),
    .trim_i         (afe_trim_o),
    .tst_mode_i     (afe_tst_mode_o),
    .tst_data_i     (afe_tst_data_o),
    .atb_sel_i      (afe_atb_sel_o)
  );

  // The AFE: ready falls t_off after pd rises (section 3.2: outputs clamped while pd), also
  // when the pd pulse is shorter, and comes back t_on after pd falls; ready_stuck: ready
  // stays 1 (no power down). in_restart: from the rise of pd until ready is back, in which
  // lane_pd must stay 1. A 0.5 ns tick (no fork in an always block: Verilator 5.020).
  bit      in_restart = 1'b0, off_pend = 1'b0;
  realtime t_rise = 0.0, t_fall = 0.0;

  always @(posedge pd) begin
    if (!ready_stuck) begin
      in_restart = 1'b1;
      off_pend   = 1'b1;
      t_rise     = $realtime;
    end
  end
  always @(negedge pd) t_fall = $realtime;

  initial forever begin
    #0.5;
    if (off_pend && $realtime - t_rise >= t_off) begin
      ready    = 1'b0;
      off_pend = 1'b0;
    end
    if (in_restart && !off_pend && !pd && $realtime - t_fall >= t_on) begin
      ready      = 1'b1;
      in_restart = 1'b0;
    end
  end

  int unsigned bad_cycles = 0;
  always @(posedge clk) begin
    if (in_restart && !clk_lane_pd) bad_cycles++;
  end

  // --------------------------------------------------------------------------- bus
  task automatic bus(input bit we, input logic [9:0] a, input logic [31:0] d,
                     output logic [31:0] q, input logic [3:0] be = 4'hF);
    @(posedge clk);
    #1;
    req = '{req: 1'b1, we: we, be: be, addr: {20'h0, 2'b11, a}, wdata: d};
    @(posedge clk);
    #1;
    req = '0;
    q   = rsp.rdata;
  endtask

  task automatic wr(input logic [9:0] a, input logic [31:0] d, input logic [3:0] be = 4'hF);
    logic [31:0] q;
    bus(1'b1, a, d, q, be);
  endtask

  task automatic rd(input logic [9:0] a, output logic [31:0] q);
    bus(1'b0, a, '0, q);
  endtask

  task automatic expect_rd(input string what, input logic [9:0] a, input logic [31:0] want,
                           input logic [31:0] mask = '1);
    logic [31:0] q;
    rd(a, q);
    expect_eq(what, q & mask, want & mask);
  endtask

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  // the controls the D-PHY must show while reset is asserted (section 3.6), checked here
  // directly too
  task automatic check_reset_values(input string what);
    checks++;
    if (pd !== AfePdRst || clk_lprx_en !== !AfePdRst || lprx_en !== {Lanes{!AfePdRst}} ||
        clk_lane_pd !== 1'b1 || lane_pd !== '1 || own !== '0 || code !== '0 ||
        cal_start !== 1'b0 || gate !== 1'b0 || des_rst !== 1'b1 || clk_hsrx_en !== 1'b0 ||
        hsrx_en !== '0 || clk_term_en !== 1'b0 || term_en !== '0) begin
      err($sformatf("%s: pd %b lprx_en %b/%b lane_pd %b/%b own %b code %h cal_start %b gate %b des_rst %b hsrx %b/%b term %b/%b",
                    what, pd, clk_lprx_en, lprx_en, clk_lane_pd, lane_pd, own, code, cal_start,
                    gate, des_rst, clk_hsrx_en, hsrx_en, clk_term_en, term_en));
    end
  endtask

  task automatic do_reset(input string what);
    #3;
    rst_n = 1'b0;
    cycles(2);
    check_reset_values(what);
    cycles(3);
    check_reset_values(what);
    rst_n = 1'b1;
    cycles(4);
  endtask

  // wait for lane_pd to fall after the AFE became ready; within a few bus cycles
  task automatic expect_lane_pd_release(input string what);
    int n;
    n = 0;
    while (clk_lane_pd && n < 2000) begin
      @(posedge clk);
      n++;
    end
    checks++;
    if (clk_lane_pd) err($sformatf("%s: lane_pd still 1 %0d cycles later", what, n));
  endtask

  // one PD pulse: PD = 1, then PD = 0 after gap more bus cycles (gap 0: back to back writes)
  task automatic pd_pulse(input int gap);
    wr(AAfeCtrl, 32'h1);
    cycles(gap);
    wr(AAfeCtrl, 32'h0);
  endtask

  // ------------------------------------------------------------------------- main
  initial begin
    logic [31:0] q;
    logic [31:0] info;
    // reset with real edges (two-state simulator)
    #1;
    rst_n = 1'b0;
    cycles(3);
    check_reset_values("power-up reset");
    rst_n = 1'b1;
    cycles(4);
    expect_rd("ID (register map version 2)", AId, 32'h4450_5202);
    // [27] ULPS (step 6)
    info = {4'h0, 1'b1, 3'h0, 1'(AfeKind == 2), 1'b0, 4'd9, 10'd200, 3'(AfeKind), 1'b0, 4'(Lanes)};
    expect_rd("INFO", AInfo, info);
    expect_rd("AFE_CTRL after reset", AAfeCtrl, {31'h0, AfePdRst});
    expect_rd("AFE_STATUS after reset", AAfeStatus, 32'h0);

    // AFE_STATUS bits, each on its own (the AFE: not ready yet)
    status = 8'hA5;
    cycles(4);
    expect_rd("AFE_STATUS status", AAfeStatus, 32'h0000_A500);
    cal_done = 1'b1;
    cycles(4);
    expect_rd("AFE_STATUS CAL_DONE", AAfeStatus, 32'h0000_A502);
    cal_done = 1'b0;
    cal_err  = 1'b1;
    status   = 8'h5A;
    cycles(4);
    expect_rd("AFE_STATUS CAL_ERR", AAfeStatus, 32'h0000_5A04);
    cal_done = 1'b1;
    cycles(4);
    expect_rd("AFE_STATUS CAL_DONE + CAL_ERR", AAfeStatus, 32'h0000_5A06);
    cal_done = 1'b0;
    cal_err  = 1'b0;
    status   = 8'h00;

    // power up: the AFE comes up t_on after pd falls (FPGA: pd is 0 from reset)
    if (AfePdRst) begin
      cycles(50);
      checks++;
      if (!clk_lane_pd || !pd || clk_lprx_en) err("powered down AFE: lane_pd / pd / lprx_en");
      wr(ADly0, 32'h0000_0123);                     // READY 0: CODE only
      cycles(2);
      checks++;
      if (own !== '0 || code[0] !== 9'h123) err($sformatf("DLY0 written while not ready: own %b code %h", own, code[0]));
      expect_rd("DLY0 while not ready", ADly0, 32'h0000_0123, 32'h8000_01FF);
      wr(AAfeCtrl, 32'h0);                           // the AFE comes up t_on later
      checks++;
      if (pd || !clk_lprx_en || lprx_en !== '1) err("PD = 0: pd / lprx_en");
      cycles(20);
      checks++;
      if (!clk_lane_pd) err("power up: lane_pd 0 before the AFE was ready");
    end else begin
      #(t_on);                                       // the FPGA AFE is up after its own init
      ready = 1'b1;
    end
    expect_lane_pd_release("power up");
    expect_rd("AFE_STATUS ready", AAfeStatus, 32'h0000_0001);

    // DLYn: OWN while READY, CODE always, nothing without byte 0 / 1
    wr(ADly0, 32'h0000_0045);
    cycles(2);
    checks++;
    if (own[0] !== 1'b1 || code[0] !== 9'h045) err($sformatf("DLY0 while ready: own %b code %h", own[0], code[0]));
    dly_q[0] = 9'h045;
    cycles(4);
    expect_rd("DLY0 OWN, applied", ADly0, 32'h8045_0045);
    wr(ADly0, 32'hFFFF_FFFF, 4'hC);                 // bytes 2, 3 only: no change
    expect_rd("DLY0 bytes 2-3 write", ADly0, 32'h8045_0045);
    if (Lanes > 1) begin
      wr(ADly0 + 10'h4, 32'h0000_01AB);
      dly_q[1] = 9'h0AA;                             // not applied yet: PEND
      cycles(4);
      expect_rd("DLY1 OWN, pending", ADly0 + 10'h4, 32'h80AA_81AB);
    end

    // PD pulses (back to back writes and a few cycles longer): the AFE restarts; lane_pd
    // stays 1 until its fresh READY (bow_afe_chk), OWN of every lane falls
    for (int gap = 0; gap < 4; gap++) begin
      pd_pulse(gap);
      cycles(8);
      checks++;
      if (!clk_lane_pd) err($sformatf("PD pulse (+%0d cycles): lane_pd 0 after it", gap));
      if (own !== '0) err($sformatf("PD pulse (+%0d cycles): OWN %b after READY fell", gap, own));
      expect_rd($sformatf("AFE_STATUS in the restart %0d", gap), AAfeStatus, 32'h0, 32'h1);
      expect_lane_pd_release($sformatf("PD pulse +%0d", gap));
      wr(ADly0, 32'h0000_0045);                     // OWN again
      cycles(4);
    end
    // a PD pulse with the AFE's ready falling late (60 ns): still a restart
    t_off = 60.0;
    pd_pulse(0);
    cycles(10);
    checks++;
    if (!clk_lane_pd) err("PD pulse, late ready fall: lane_pd 0");
    expect_lane_pd_release("PD pulse, late ready fall");
    t_off = 20.0;

    // an AFE that keeps ready at 1 through pd (the UltraScale+ adapter): no fresh READY,
    // lane_pd stays 1 (that adapter has no lane_pd); OWN stays
    ready_stuck = 1'b1;
    wr(ADly0, 32'h0000_0046);
    pd_pulse(0);
    cycles(100);
    checks++;
    if (!clk_lane_pd) err("AFE with ready stuck at 1: lane_pd released without a fresh READY");
    if (own[0] !== 1'b1) err("AFE with ready stuck at 1: OWN fell");
    ready_stuck = 1'b0;
    wr(AAfeCtrl, 32'h1);                             // a real restart releases it
    cycles(20);
    wr(AAfeCtrl, 32'h0);
    expect_lane_pd_release("restart after the stuck ready");

    // READY falls without PD (a loss of lock): OWN cleared, lane_pd stays 0
    wr(ADly0, 32'h0000_0047);
    cycles(4);
    ready = 1'b0;
    cycles(6);
    checks++;
    if (own !== '0) err($sformatf("READY fell: OWN %b", own));
    if (clk_lane_pd) err("READY fell without PD: lane_pd rose");
    wr(ADly0, 32'h0000_0048);                       // while not ready: CODE only
    cycles(2);
    checks++;
    if (own[0] !== 1'b0 || code[0] !== 9'h048) err("DLY0 written while READY 0: OWN rose");
    ready = 1'b1;
    cycles(6);
    checks++;
    if (own[0] !== 1'b0) err("READY back: OWN rose without a write");
    wr(ADly0, 32'h0000_0048);                       // the same code: OWN rises
    cycles(2);
    checks++;
    if (own[0] !== 1'b1) err("DLY0 write after READY: no OWN");

    // CMD.AFE_CAL: cal_start for 32 bus cycles; a second AFE_CAL restarts the count; CMD.REINIT
    // (the state machines, step 6) none
    begin
      int n;
      wr(ACmd, 32'h0000_0004, 4'hE);                // no byte 0: nothing
      cycles(2);
      checks++;
      if (cal_start) err("CMD.AFE_CAL without byte 0 started cal_start");
      wr(ACmd, 32'h0000_0002);                      // REINIT: not the AFE
      cycles(2);
      checks++;
      if (cal_start) err("CMD.REINIT started cal_start");
      wr(ACmd, 32'h0000_0004);
      n = 0;
      while (cal_start && n < 100) begin
        n++;
        @(posedge clk);
        #1;
      end
      checks++;
      if (n != 32) err($sformatf("cal_start for %0d bus cycles, want 32", n));
      wr(ACmd, 32'h0000_0004);
      cycles(10);
      wr(ACmd, 32'h0000_0004);
      n = 0;
      while (cal_start && n < 100) begin
        n++;
        @(posedge clk);
        #1;
      end
      checks++;
      if (n != 32) err($sformatf("cal_start after a second AFE_CAL: %0d bus cycles, want 32", n));
    end

    // CTRL.DES_RST_DIS: des_rst 0 while set (gate closed: clock lane off), from CMD.APPLY on
    wr(ACtrl, 32'h0000_0040);
    cycles(4);
    checks++;
    if (des_rst !== 1'b1) err("DES_RST_DIS = 1 before CMD.APPLY: des_rst already 0");
    wr(ACmd, 32'h0000_0001);
    cycles(4);
    checks++;
    if (des_rst !== 1'b0) err("DES_RST_DIS = 1: des_rst still 1");
    wr(ACtrl, 32'h0000_0000);
    wr(ACmd, 32'h0000_0001);
    cycles(4);
    checks++;
    if (des_rst !== 1'b1) err("DES_RST_DIS = 0: des_rst not back to 1");

    // reset in the middle of a run (PD 0, lane_pd 0, OWN 1): every control back to its reset
    // value while reset is asserted, as after power up once released
    checks++;
    if (clk_lane_pd || own[0] !== 1'b1 || pd) err("before the reset: lane_pd / OWN / pd");
    do_reset("reset in a run");
    expect_rd("AFE_CTRL after the second reset", AAfeCtrl, {31'h0, AfePdRst});
    if (AfePdRst) begin
      cycles(20);                                     // pd from the reset: the AFE went down
      checks++;
      if (!clk_lane_pd || ready) err("after the reset with AfePdRst: lane_pd 0 or the AFE up");
      wr(AAfeCtrl, 32'h0);
    end
    expect_lane_pd_release("after the second reset");

    // random PD pulses and holds
    for (int i = 0; i < 20; i++) begin
      t_off = real'($urandom_range(0, 80));
      t_on  = real'($urandom_range(200, 1500));
      pd_pulse($urandom_range(0, 6));
      if ($urandom_range(0, 1)) cycles($urandom_range(0, 100));
      expect_lane_pd_release($sformatf("random PD pulse %0d", i));
    end

    checks++;
    if (bad_cycles != 0) err($sformatf("lane_pd 0 for %0d bus cycles while the AFE was not ready", bad_cycles));
    if (errors == 0) $display("tb_dphy_afe: PASS (%0d checks; AfeKind %0d, AfePdRst %0d, %0d lanes)",
                              checks, AfeKind, AfePdRst, Lanes);
    else             $display("tb_dphy_afe: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("tb_dphy_afe: FAIL (timeout)");
    $finish;
  end

endmodule
