// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bench of the digital D-PHY alone (bow_dphy_rx), step 6 of docs/ip/mipi_rx_arch.md (sections
// 4, 8.3; make -C hw/ip/dphy_rx/dv test, CI): the D-PHY v1.x functions of section 4.12 with a
// bit level D-PHY transmitter on its AFE interface (csi2_tx_model of the receiver bench: the
// lanes' LP states and HS bits, the clock lane, the UltraScale+ adapter's logic), its
// registers on the bus, its PPI watched by a byte scoreboard and the controller's sampler of
// the PPI error counters (bow_ppi_err_rx) on a clock of lp_clk / 32. bow_ppi_chk and
// bow_afe_chk are bound in as in every bench (PPI and AFE rules at every cycle). Built with
// BOW_CDC_JITTER and BOW_SYNC_JITTER: every synchroniser bit may resolve one cycle late.
//
// One test per run (+TEST=<name>), each self-checking; "tb_bow_dphy_rx: PASS (<n> checks)"
// or "tb_bow_dphy_rx: FAIL (<n> errors)". Plusargs: +LP_PS (lp clock, default 5000), +BUS_PS
// (bus clock, 20000), +BYTE_PS (byte clock of the transmitter, 8772).
//   basic      bursts at the reset values (v1 behaviour): bytes of every lane after RxSyncHS,
//              HS entry counters, Stopstate (LANE_STOP), the register reset values (TIM1 2^20,
//              TIM2 0, CTRL 0, no LATE_EOT with the transmitter's CLK-POST); a deskew burst:
//              RxSkewCalHS on every lane as a level until RxActiveHS falls, once
//   apply      CTRL / TIM0..2 shadow registers: no effect before CMD.APPLY, all fields at once
//              after it, CMD reads 1 while pending, an APPLY while pending is done after it (TIM0
//              and a second APPLY 0..5 bus cycles after the first, back to back)
//   tinit      T_INIT after CMD.REINIT: LP-11 shorter than T_INIT before the first burst loses
//              it, Stopstate T_INIT after the command, later blanking shorter than T_INIT is
//              fine (once only), Enable off / on does not make it due, a READY rise does;
//              REINIT in a burst sends the lanes to WaitStop (no LATE_EOT: not the
//              transmitter's clock); T_INIT 0: at once
//   hstmo      HS_TMO: a data lane exactly HS_TMO cycles in Hs, then an LP error and an HS
//              timeout (ERR_STATUS[2], [3], CNT_LPERR, CNT_MISC, ErrControl); HS_TMO 0: none
//   esctmo     ESC_TMO: an escape entry that stalls ends after ESC_TMO x 64 cycles (ERR_STATUS
//              [10], CNT_MISC, ErrEsc); ESC_TMO 0: none
//   ulps       ULPS_EN: ULPS of the data lanes (command) and of the clock lane: LANE_STOP,
//              UlpsActiveNot / RxUlpsEsc / RxUlpsClkNot, lane_pd per lane (falls at the wake-up
//              mark), IRQ_STATUS.ULPS, CNT_DSK; another command: ERR_STATUS.ESC, ErrEsc; LP-11
//              in the entry: no error; a mark without its space: CONTROL; ULPS_EN 0: LP-10 in
//              Stop is an LP error (v1)
//   hsrx       HSRX_EARLY: the HS receiver from LP-01, the termination from LP-00; 0: together
//   missoff    CLK_MISS_OFF: the clock lane's HS receiver and termination fall with the gate at
//              the clock miss; 0: at LP-11 (v1)
//   togdiv     CLK_TOG_DIV with a byte clock of twice the lp clock (+LP_PS=20000
//              +BYTE_PS=10000): 0 sees no byte clock edge (the gate closes in the burst), 1 and
//              2 receive every burst
//   clklost    CLK_LOST_EN: a data lane in HS without the clock lane: ERR_STATUS[6], CNT_MISC,
//              ErrControl; 0: nothing (v1); a normal burst: nothing
//   lateeot    LATE_EOT: CLK-POST too short for RxActiveHS (ERR_STATUS[7], CNT_MISC, IRQ ERR),
//              every lane of every such burst; a correct CLK-POST, a burst cut by Enable, and
//              one cut by the clock lane's Enable alone: none
//   gray       the error counters at the highest LP error rate: CNT_LPERR counts every error
//              (also with +BUS_PS=50000: lp_clk 10 x clk_i), the PPI ErrControl counter steps
//              once every 16 cycles at most, the controller's sampler at lp_clk / 32 sees
//              every step; ErrControlClk none while CLK_CONT, counted in CNT_LPERR

`timescale 1ns / 1ps

module tb_bow_dphy_rx;
  import bow_bus_pkg::*;
  import bow_ppi_pkg::*;
  import csi2_tx_pkg::*;

  parameter int unsigned Lanes = 2;

  localparam int unsigned ML = 4, CL = 4;                 // TX model: lanes, clock lane index
  localparam logic [9:0] AId = 10'h000, AInfo = 10'h004, ACtrl = 10'h00C, ACmd = 10'h010,
                         ATim0 = 10'h024, ATim1 = 10'h028, ATim2 = 10'h02C, ALaneLp = 10'h030,
                         ALaneHs = 10'h034, ALaneStop = 10'h038, AIrqSt = 10'h03C,
                         AIrqEn = 10'h040, AErr = 10'h044, AErrLane = 10'h048,
                         ACntBurst0 = 10'h050, ACntClk = 10'h070, ACntLpErr = 10'h074,
                         ACntDsk = 10'h078, ACntMisc = 10'h07C;
  localparam logic [31:0] CtrlClkCont = 32'h2, CtrlUlpsEn = 32'h4, CtrlHsrxEarly = 32'h8,
                          CtrlClkLostEn = 32'h80, CtrlMissOff = 32'h1_0000;
  localparam logic [31:0] CmdApply = 32'h1, CmdReinit = 32'h2, CmdCntClr = 32'h8;
  localparam logic [31:0] ErrControl = 32'h4, ErrHsTmo = 32'h8, ErrEsc = 32'h10,
                          ErrClkLost = 32'h40, ErrLateEot = 32'h80, ErrEscTmo = 32'h400;
  localparam logic [31:0] Tim0Reset = 32'h081E_020E, Tim1Reset = 32'h0010_0000;
  localparam logic [7:0]  EscUlps = 8'b0001_1110, EscReset = 8'b0110_0010;

  int unsigned errors = 0, checks = 0;
  string       test;

  function automatic void err(string msg);
    errors++;
    if (errors <= 40) $display("[%0t] ERROR: %s", $time, msg);
  endfunction

  function automatic void expect_eq(string what, logic [31:0] got, logic [31:0] want);
    checks++;
    if (got !== want) err($sformatf("%s: 0x%08h, want 0x%08h", what, got, want));
  endfunction

  function automatic void expect_true(string what, bit c);
    checks++;
    if (!c) err(what);
  endfunction

  // ---------------------------------------------------------------------------- clocks
  realtime lp_ps = 5000.0, bus_ps = 20000.0, byte_ps = 8772.0;
  logic    clk = 1'b0, lp_clk = 1'b0, ctl_clk = 1'b0, rst_n = 1'b1;

  initial begin
    if ($value$plusargs("LP_PS=%f", lp_ps)) ;
    if ($value$plusargs("BUS_PS=%f", bus_ps)) ;
    if ($value$plusargs("BYTE_PS=%f", byte_ps)) ;
    fork
      forever #(bus_ps / 2000.0) clk = ~clk;
      forever #(lp_ps / 2000.0) lp_clk = ~lp_clk;
      forever #(16.0 * lp_ps / 1000.0) ctl_clk = ~ctl_clk;   // lp_clk / 32
    join_none
  end

  // ------------------------------------------------------------------------------- DUT
  bus_req_t req = '0;
  bus_rsp_t rsp;
  logic     irq;

  logic [Lanes-1:0]      enable = '0;
  logic                  enable_clk = 1'b0, bench_ready = 1'b1;
  logic                  byte_clk, rx_byte_clk;
  ppi_hs_t [Lanes-1:0]   ppi_hs;
  ppi_lp_t [Lanes-1:0]   ppi_lp;
  ppi_lp_clk_t           ppi_lp_clk;
  logic [Lanes-1:0][7:0] hs_data;
  logic [Lanes-1:0]      hs_valid, lprx_en, hsrx_en, term_en, dly_own, lane_pd;
  logic                  gate, des_rst, clk_lprx_en, clk_hsrx_en, clk_term_en, clk_lane_pd;
  logic                  pd, cal_start, tx_ready;
  logic [1:0]            clk_lp;
  logic [Lanes-1:0][1:0] lp;
  logic [Lanes-1:0][8:0] dly_code, dly_q;

  bow_dphy_rx #(
    .Lanes    (Lanes),
    .AfeKind  (1),
    .LpClkHz  (200_000_000),
    .BusClkHz (0)                              // the bench changes the clocks (plusargs)
  ) dut (
    .clk_i              (clk),
    .rst_ni             (rst_n),
    .lp_clk_i           (lp_clk),
    .lp_rst_ni          (rst_n),
    .bus_req_i          (req),
    .bus_rsp_o          (rsp),
    .irq_o              (irq),
    .enable_i           (enable),
    .enable_clk_i       (enable_clk),
    .rx_byte_clk_hs_o   (rx_byte_clk),
    .ppi_hs_o           (ppi_hs),
    .ppi_lp_o           (ppi_lp),
    .ppi_lp_clk_o       (ppi_lp_clk),
    .afe_hs_byte_clk_i  (byte_clk),
    .afe_hs_data_i      (hs_data),
    .afe_hs_valid_i     (hs_valid),
    .afe_clk_gate_en_o  (gate),
    .afe_des_rst_o      (des_rst),
    .afe_clk_hs_samp_i  ('0),
    .afe_clk_act_i      (1'b0),
    .afe_clk_lp_i       (clk_lp),
    .afe_lp_i           (lp),
    .afe_clk_lprx_en_o  (clk_lprx_en),
    .afe_lprx_en_o      (lprx_en),
    .afe_clk_hsrx_en_o  (clk_hsrx_en),
    .afe_hsrx_en_o      (hsrx_en),
    .afe_clk_term_en_o  (clk_term_en),
    .afe_term_en_o      (term_en),
    .afe_dly_code_o     (dly_code),
    .afe_dly_own_o      (dly_own),
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
    .afe_ready_i        (tx_ready && bench_ready),
    .afe_cal_start_o    (cal_start),
    .afe_cal_done_i     (1'b0),
    .afe_cal_err_i      (1'b0),
    .afe_trim_o         (),
    .afe_status_i       ('0),
    .afe_tst_mode_o     (),
    .afe_tst_data_o     (),
    .afe_clk_hs_raw_i   (1'b0),
    .afe_hs_raw_i       ('0),
    .afe_atb_sel_o      ()
  );

  bind bow_dphy_rx bow_ppi_chk #(.Lanes (Lanes), .Report (1'b1)) u_ppi_chk (
    .lp_clk_i     (lp_clk_i),
    .lp_rst_ni    (lrst_n),
    .byte_clk_i   (afe_hs_byte_clk_i),
    .byte_rst_ni  (brst_n),
    .ppi_hs_i     (ppi_hs_o),
    .ppi_lp_i     (ppi_lp_o),
    .ppi_lp_clk_i (ppi_lp_clk_o),
    .lane_en_i    (lane_en),
    .lp_i         (lp_st),
    .clk_force_i  (clk_force),
    .byte_ce_i    (byte_ce),
    .tinit_i      (cfg_lp_q.tinit)
  );

  bind bow_dphy_rx bow_afe_chk #(.Lanes (Lanes), .TrimW (TrimW), .AfePdRst (AfePdRst),
                                 .Report (1'b1)) u_afe_chk (
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
    .ulps_rx_i      (ulps_rx_sys),
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

  csi2_tx_model #(.Lanes(Lanes)) u_tx (
    .hs_byte_clk_o (byte_clk),
    .hs_data_o     (hs_data),
    .hs_valid_o    (hs_valid),
    .clk_gate_en_i (gate),
    .des_rst_i     (des_rst),
    .clk_lp_o      (clk_lp),
    .lp_o          (lp),
    .clk_hsrx_en_i (clk_hsrx_en),
    .hsrx_en_i     (hsrx_en),
    .clk_term_en_i (clk_term_en),
    .term_en_i     (term_en),
    .dly_code_i    (dly_code),
    .dly_own_i     (dly_own),
    .dly_q_o       (dly_q),
    .pd_i          (pd),
    .cal_start_i   (cal_start),
    .ready_o       (tx_ready),
    .ctrl_clk_i    (lp_clk),
    .ctrl_rst_ni   (rst_n)
  );

  // ------------------------------------------------------------------ internal probes
  logic [Lanes:0]      p_act, p_lane_en;
  logic [Lanes:0][1:0] p_lp;
  logic [Lanes:0][3:0] p_state;
  logic                p_ce, p_clk_tog;

  assign p_act     = dut.hs_act;
  assign p_lane_en = dut.lane_en;
  assign p_lp      = dut.lp_st;
  assign p_ce      = dut.byte_ce;
  assign p_clk_tog = dut.clk_tog_q;
  assign p_state[0] = 4'(dut.u_lp_clk.state_q);
  for (genvar l = 0; l < Lanes; l++) begin : g_probe
    assign p_state[1 + l] = 4'(dut.g_lp[l].u_lp.state_q);
  end

  // ---------------------------------------------------------- PPI byte scoreboard
  // Per lane, the bytes from RxSyncHS (with it) while RxActiveHS is high; a burst's bytes are
  // queued when RxActiveHS falls (rx_len: bytes per burst, rx_bytes: all of them)
  byte unsigned rx_bytes [Lanes][$];
  int unsigned  rx_len [Lanes][$];
  bit [Lanes-1:0] cap_on = '0, act_q = '0, skew_q = '0, skew_seen = '0;
  int unsigned  cap_n [Lanes] = '{default: 0};
  int unsigned  skew_rises [Lanes] = '{default: 0}, skew_level_cycles [Lanes] = '{default: 0};
  int unsigned  skew_bursts [Lanes] = '{default: 0};

  always @(posedge rx_byte_clk) begin
    for (int l = 0; l < int'(Lanes); l++) begin
      if (ppi_hs[l].rx_sync_hs) begin
        cap_on[l] = 1'b1;
        cap_n[l]  = 0;
      end
      if (cap_on[l] && ppi_hs[l].rx_active_hs && ppi_hs[l].rx_valid_hs) begin
        rx_bytes[l].push_back(ppi_hs[l].rx_data_hs);
        cap_n[l]++;
      end
      if (act_q[l] && !ppi_hs[l].rx_active_hs) begin
        if (cap_on[l]) rx_len[l].push_back(cap_n[l]);
        cap_on[l] = 1'b0;
        if (skew_seen[l]) skew_bursts[l]++;
        skew_seen[l] = 1'b0;
      end
      if (ppi_hs[l].rx_skew_cal_hs && !skew_q[l]) begin
        skew_rises[l]++;
        skew_seen[l] = 1'b1;
      end
      if (ppi_hs[l].rx_skew_cal_hs && skew_q[l]) skew_level_cycles[l]++;
      act_q[l]  = ppi_hs[l].rx_active_hs;
      skew_q[l] = ppi_hs[l].rx_skew_cal_hs;
    end
  end

  // ------------------------------------------------- PPI lp error counters and their sampler
  // prod: the D-PHY's steps of every counter, counted in its lp clock; ctl: the steps the
  // controller's sampler (bow_ppi_err_rx at lp_clk / 32) sees. [0] ErrControlClk, [1 + l]
  // ErrControl[l]; esc: ErrEsc[l]
  logic [Lanes:0][1:0] err_gray, err_gray_q = '0, ctl_steps_v;
  logic [Lanes-1:0][1:0] esc_gray, esc_gray_q = '0;
  int unsigned         prod_steps [Lanes + 1] = '{default: 0}, ctl_steps [Lanes + 1] = '{default: 0};
  int unsigned         esc_steps [Lanes] = '{default: 0};

  always_comb begin
    err_gray[0] = ppi_lp_clk.err_control;
    for (int l = 0; l < int'(Lanes); l++) begin
      err_gray[1 + l] = ppi_lp[l].err_control;
      esc_gray[l]     = ppi_lp[l].err_esc;
    end
  end

  always @(posedge lp_clk) begin
    for (int i = 0; i <= int'(Lanes); i++) if (err_gray[i] != err_gray_q[i]) prod_steps[i]++;
    for (int l = 0; l < int'(Lanes); l++) if (esc_gray[l] != esc_gray_q[l]) esc_steps[l]++;
    err_gray_q <= err_gray;
    esc_gray_q <= esc_gray;
  end

  bow_ppi_err_rx #(
    .N (Lanes + 1)
  ) u_ctl (
    .clk_i   (ctl_clk),
    .rst_ni  (rst_n),
    .gray_i  (err_gray),
    .ev_o    (),
    .steps_o (ctl_steps_v)
  );

  always @(posedge ctl_clk) begin
    for (int i = 0; i <= int'(Lanes); i++) ctl_steps[i] += ctl_steps_v[i];
  end

  // ----------------------------------------------------------------------------- bus
  task automatic bus(input bit we, input logic [9:0] a, input logic [31:0] d,
                     output logic [31:0] q);
    @(posedge clk);
    #1;
    req = '{req: 1'b1, we: we, be: 4'hF, addr: {20'h0, 2'b11, a}, wdata: d};
    @(posedge clk);
    #1;
    req = '0;
    q   = rsp.rdata;
  endtask

  task automatic wr(input logic [9:0] a, input logic [31:0] d);
    logic [31:0] q;
    bus(1'b1, a, d, q);
  endtask

  // wait until the burst just pushed has sent n packet bytes (the transmitter's cur_byte
  // keeps the count of the last burst until the next one sends)
  task automatic wait_bytes(input int unsigned n);
    while (u_tx.cur_burst < 0) #10;
    while (u_tx.cur_byte >= n) #10;
    while (u_tx.cur_byte < n) #10;
  endtask

  // CMD.APPLY, then gap bus cycles later TIM0 and CMD.APPLY again in two consecutive bus
  // cycles (the register file takes a request every cycle); again: the register file kept
  // an APPLY written while one was pending (white box, apply_again_q)
  task automatic apply_twice(input int gap, input logic [31:0] tim0, output bit again);
    again = 1'b0;
    @(posedge clk);
    #1;
    req = '{req: 1'b1, we: 1'b1, be: 4'hF, addr: {20'h0, 2'b11, ACmd}, wdata: CmdApply};
    for (int i = 0; i < gap; i++) begin
      @(posedge clk);
      #1;
      req = '0;
    end
    @(posedge clk);
    #1;
    req = '{req: 1'b1, we: 1'b1, be: 4'hF, addr: {20'h0, 2'b11, ATim0}, wdata: tim0};
    @(posedge clk);
    #1;
    req = '{req: 1'b1, we: 1'b1, be: 4'hF, addr: {20'h0, 2'b11, ACmd}, wdata: CmdApply};
    for (int i = 0; i < 12; i++) begin
      @(posedge clk);
      #1;
      req   = '0;
      again = again | dut.u_regs.apply_again_q;
    end
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

  // CMD.APPLY and wait until the lp domain took it (CMD reads 0)
  task automatic apply();
    logic [31:0] q;
    int          n;
    wr(ACmd, CmdApply);
    n = 0;
    do begin
      rd(ACmd, q);
      n++;
    end while (q[0] && n < 100);
    expect_true("CMD.APPLY acknowledged", !q[0]);
  endtask

  task automatic wr_apply(input logic [9:0] a, input logic [31:0] d);
    wr(a, d);
    apply();
  endtask

  task automatic bus_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  task automatic lp_cycles(input int n);
    repeat (n) @(posedge lp_clk);
  endtask

  // -------------------------------------------------------------------- transmitter
  // (Verilator 5.020 keeps the local queues of these functions from call to call: cleared
  // first)
  function automatic csi2_bytes_t make_bytes(int unsigned n, int unsigned seed);
    csi2_bytes_t b;
    b.delete();
    for (int unsigned i = 0; i < n; i++) b.push_back(8'((seed * 37 + i * 13 + 5) & 8'hFF));
    return b;
  endfunction

  function automatic void burst(csi2_bytes_t b);
    u_tx.push_burst(b, csi2_flags());
  endfunction

  // a deskew burst: HS-zero, FFFFh, then 0101... on every lane
  function automatic void deskew_burst();
    csi2_bytes_t b;
    csi2_flags_t f;
    b.delete();
    f      = csi2_flags();
    f.sync = {4{8'hFF}};
    for (int i = 0; i < int'(Lanes); i++) b.push_back(8'hFF);
    for (int i = 0; i < 64 * int'(Lanes); i++) b.push_back(8'h55);
    u_tx.push_burst(b, f);
  endfunction

  task automatic tx_wait(input int extra_ns = 400);
    while (u_tx.busy()) #10;
    #(extra_ns);
  endtask

  // the bytes of lane l of a burst of b
  function automatic csi2_bytes_t lane_bytes(csi2_bytes_t b, int l);
    csi2_bytes_t q;
    q.delete();
    for (int i = l; i < b.size(); i += Lanes) q.push_back(b[i]);
    return q;
  endfunction

  // the next received burst of every lane must start with its bytes of b
  task automatic expect_burst(input string what, input csi2_bytes_t b);
    csi2_bytes_t want;
    int unsigned n;
    for (int l = 0; l < int'(Lanes); l++) begin
      want = lane_bytes(b, l);
      checks++;
      if (rx_len[l].size() == 0) begin
        err($sformatf("%s: lane %0d received no burst", what, l));
        continue;
      end
      n = rx_len[l].pop_front();
      if (n < want.size()) err($sformatf("%s: lane %0d %0d bytes, want %0d", what, l, n, want.size()));
      for (int unsigned i = 0; i < n; i++) begin
        byte unsigned v;
        v = rx_bytes[l].pop_front();
        if (i < want.size() && v != want[i]) begin
          err($sformatf("%s: lane %0d byte %0d 0x%02h, want 0x%02h", what, l, i, v, want[i]));
          break;
        end
      end
    end
  endtask

  task automatic expect_no_burst(input string what);
    for (int l = 0; l < int'(Lanes); l++) begin
      checks++;
      if (rx_len[l].size() != 0) begin
        err($sformatf("%s: lane %0d received %0d bursts, want none", what, l, rx_len[l].size()));
      end
    end
  endtask

  task automatic flush_rx();
    for (int l = 0; l < int'(Lanes); l++) begin
      rx_len[l].delete();
      rx_bytes[l].delete();
    end
  endtask

  // LP states on the data lanes of mask (bit 4: the clock lane), the other lanes LP-11
  function automatic void lps(int unsigned mask, logic [1:0] st, int unsigned ns);
    u_tx.push_lp(mask, st, ns);
  endfunction

  function automatic int unsigned data_mask();
    return (1 << Lanes) - 1;
  endfunction

  // escape mode entry and an 8 bit command on the lanes of mask (first bit first)
  function automatic void escape(int unsigned mask, logic [7:0] cmd, int unsigned ns = 80);
    lps(mask, 2'b10, ns);
    lps(mask, 2'b00, ns);
    lps(mask, 2'b01, ns);
    lps(mask, 2'b00, ns);
    for (int i = 7; i >= 0; i--) begin
      lps(mask, cmd[i] ? 2'b10 : 2'b01, ns);
      lps(mask, 2'b00, ns);
    end
  endfunction

  // the D-PHY on: every lane enabled, the counters and errors cleared
  task automatic phy_on();
    enable     = '1;
    enable_clk = 1'b1;
    lp_cycles(20);
    wr(ACmd, CmdCntClr);
    wr(AErr, 32'hFFFF_FFFF);
    wr(AErrLane, 32'hFFFF_FFFF);
    wr(AIrqSt, 32'hFFFF_FFFF);
  endtask

  task automatic phy_off();
    enable     = '0;
    enable_clk = 1'b0;
    lp_cycles(20);
  endtask

  task automatic clear_counts();
    wr(ACmd, CmdCntClr);
    wr(AErr, 32'hFFFF_FFFF);
    wr(AErrLane, 32'hFFFF_FFFF);
    wr(AIrqSt, 32'hFFFF_FFFF);
  endtask

  // lanes of the receiver in Stop (LANE_STOP [0] clock lane, [1 + l] data lanes)
  function automatic logic [31:0] all_stop();
    return 32'((1 << (Lanes + 1)) - 1);
  endfunction

  // =============================================================================== tests
  // ---------------------------------------------------------------------------- basic
  task automatic t_basic();
    csi2_bytes_t b;
    logic [31:0] q;
    expect_rd("ID", AId, 32'h4450_5201);
    expect_rd("INFO[27] ULPS", AInfo, 32'h0800_0000, 32'h0800_0000);
    expect_rd("CTRL reset", ACtrl, 32'h0);
    expect_rd("TIM0 reset", ATim0, Tim0Reset);
    expect_rd("TIM1 reset (HS_TMO 2^20)", ATim1, Tim1Reset);
    expect_rd("TIM2 reset", ATim2, 32'h0);
    expect_rd("CMD reads 0", ACmd, 32'h0);
    expect_rd("LANE_STOP off", ALaneStop, 32'h0);
    phy_on();
    lp_cycles(40);
    expect_rd("LANE_STOP: every lane in Stop", ALaneStop, all_stop());
    for (int i = 0; i < 4; i++) begin
      b = make_bytes(24 + 7 * i, i);
      burst(b);
      tx_wait();
      expect_burst($sformatf("burst %0d", i), b);
    end
    expect_rd("CNT_BURST0", ACntBurst0, 32'd4);
    expect_rd("CNT_CLK", ACntClk, 32'd4);
    expect_rd("ERR_STATUS clean (no LATE_EOT at CLK-POST 120 ns)", AErr, 32'h0);
    expect_rd("CNT_MISC", ACntMisc, 32'h0);
    // deskew burst: RxSkewCalHS a level on every lane, once, until RxActiveHS falls
    for (int l = 0; l < int'(Lanes); l++) begin
      skew_rises[l] = 0;
      skew_level_cycles[l] = 0;
      skew_bursts[l] = 0;
    end
    deskew_burst();
    tx_wait();
    for (int l = 0; l < int'(Lanes); l++) begin
      expect_true($sformatf("deskew: RxSkewCalHS of lane %0d rose once (%0d)", l, skew_rises[l]),
                  skew_rises[l] == 1 && skew_bursts[l] == 1);
      expect_true($sformatf("deskew: RxSkewCalHS of lane %0d a level (%0d more cycles)", l,
                            skew_level_cycles[l]), skew_level_cycles[l] > 8);
    end
    flush_rx();
    b = make_bytes(40, 9);
    burst(b);
    tx_wait();
    expect_burst("after the deskew burst", b);
    rd(AErr, q);
    expect_eq("ERR_STATUS after all", q, 32'h0);
  endtask

  // ---------------------------------------------------------------------------- apply
  task automatic t_apply();
    logic [31:0] q;
    int          changes, pending;
    bit          again;
    logic [97:0] cfg_last;
    phy_off();
    // a shadow write has no effect before CMD.APPLY
    wr(ATim0, 32'h0510_0233);
    wr(ATim1, 32'h0300_1234);
    wr(ATim2, 32'h0050_0321);
    wr(ACtrl, CtrlMissOff | CtrlHsrxEarly);
    bus_cycles(20);
    expect_rd("TIM0 shadow read back", ATim0, 32'h0510_0233);
    expect_true("TIM0 not applied before CMD.APPLY", dut.cfg_lp_q.settle == 8'd14);
    expect_true("TIM1 not applied before CMD.APPLY", dut.cfg_lp_q.hs_tmo == 24'h10_0000);
    expect_true("CTRL not applied before CMD.APPLY", !dut.cfg_lp_q.miss_off);
    // one APPLY: every field at once (one lp cycle)
    changes  = 0;
    cfg_last = dut.cfg_lp_q;
    fork
      begin
        wr(ACmd, CmdApply);
        rd(ACmd, q);
        expect_true("CMD reads 1 right after APPLY", q[0]);
        bus_cycles(10);
        rd(ACmd, q);
        expect_true("CMD reads 0 once applied", !q[0]);
      end
    join_none
    repeat (100) begin
      @(posedge lp_clk);
      #0.1;
      if (dut.cfg_lp_q != cfg_last) changes++;
      cfg_last = dut.cfg_lp_q;
    end
    expect_true($sformatf("the configuration changed in one lp cycle (%0d)", changes), changes == 1);
    expect_true("TIM0 applied", dut.cfg_lp_q.settle == 8'h33 && dut.cfg_lp_q.lp_filter == 4'h2 &&
                dut.cfg_lp_q.clk_settle == 8'h10 && dut.cfg_lp_q.clk_miss == 8'h05);
    expect_true("TIM1 applied", dut.cfg_lp_q.hs_tmo == 24'h00_1234 && dut.cfg_lp_q.tog_div == 4'd3);
    expect_true("TIM2 applied", dut.cfg_lp_q.tinit == 20'h0_0321 && dut.cfg_lp_q.esc_tmo == 12'h005);
    expect_true("CTRL applied", dut.cfg_lp_q.miss_off && dut.cfg_lp_q.hsrx_early &&
                !dut.cfg_lp_q.ulps_en);
    // an APPLY while one is pending is done after it, with the latest shadow: CMD.APPLY,
    // then TIM0 and CMD.APPLY again in consecutive bus cycles, 0..5 bus cycles later (some
    // of these between the lp domain's copy and its acknowledge)
    pending = 0;
    for (int g = 0; g < 6; g++) begin
      wr(ATim0, 32'h0510_0240 | 32'(g));
      apply_twice(g, 32'h0510_0260 | 32'(g), again);
      if (again) pending++;
      rd(ACmd, q);
      expect_true($sformatf("gap %0d: both APPLYs acknowledged", g), !q[0]);
      expect_true($sformatf("gap %0d: the latest shadow applied (SETTLE 0x%02h)", g,
                            dut.cfg_lp_q.settle), dut.cfg_lp_q.settle == 8'h60 + 8'(g));
    end
    expect_true($sformatf("an APPLY while one was pending (%0d of 6)", pending), pending > 0);
    // back to the reset values
    wr(ATim0, Tim0Reset);
    wr(ATim1, Tim1Reset);
    wr(ATim2, 32'h0);
    wr_apply(ACtrl, 32'h0);
    expect_true("reset values applied", dut.cfg_lp_q.settle == 8'd14 && !dut.cfg_lp_q.miss_off &&
                dut.cfg_lp_q.hs_tmo == 24'h10_0000 && dut.cfg_lp_q.tinit == '0);
    phy_on();
    burst(make_bytes(32, 3));
    tx_wait();
    expect_burst("a burst after the APPLYs", make_bytes(32, 3));
  endtask

  // ---------------------------------------------------------------------------- tinit
  // time from now until every lane is in Stop (LANE_STOP), in ns (-1: not within max_ns)
  task automatic time_to_stop(input int max_ns, output realtime t, input bit leave = 1'b1);
    logic [31:0] q;
    realtime     t0;
    t0 = $realtime;
    t  = -1.0;
    // the command reaches the lanes, and their state the bus, a few cycles later: first wait
    // until they left Stop (leave)
    while (leave && $realtime - t0 < 400.0) begin
      rd(ALaneStop, q);
      if ((q & all_stop()) != all_stop()) break;
    end
    while ($realtime - t0 < max_ns) begin
      rd(ALaneStop, q);
      if ((q & all_stop()) == all_stop()) begin
        t = $realtime - t0;
        break;
      end
    end
  endtask

  task automatic t_tinit();
    csi2_bytes_t b;
    realtime     t;
    logic [31:0] q;
    int unsigned tinit = 400;                    // 400 lp clocks
    real         tinit_ns;
    tinit_ns = real'(tinit) * lp_ps / 1000.0;
    phy_on();
    wr_apply(ATim2, tinit);
    lp_cycles(20);
    expect_rd("in Stop before the REINIT", ALaneStop, all_stop());
    // CMD.REINIT: WaitStop, Stop only after T_INIT cycles of LP-11
    wr(ACmd, CmdReinit);
    time_to_stop(10_000, t);
    expect_true($sformatf("Stopstate %0.0f ns after CMD.REINIT, T_INIT %0.0f ns", t, tinit_ns),
                t >= tinit_ns - 50.0 && t <= tinit_ns + 300.0);
    // the first burst after a REINIT with too short an LP-11: lost (no HS entry)
    wr(ACmd, CmdReinit);
    lp_cycles(4);
    u_tx.t_lp11_next = 120;
    b = make_bytes(30, 1);
    burst(b);
    tx_wait();
    expect_no_burst("a burst after REINIT within T_INIT of LP-11");
    expect_rd("no HS entry of data lane 0", ACntBurst0, 32'd0);
    // after LP-11 for T_INIT: Stop, the next bursts are received, even with LP-11 shorter
    // than T_INIT between them (T_INIT is due once)
    #(tinit_ns + 400.0);
    expect_rd("in Stop after T_INIT", ALaneStop, all_stop());
    for (int i = 0; i < 3; i++) begin
      b = make_bytes(28 + i, 10 + i);
      burst(b);
      tx_wait(100);                               // blanking far shorter than T_INIT
      expect_burst($sformatf("burst %0d after T_INIT", i), b);
    end
    // Enable off and on (a receiver stop / start): T_INIT is not due again
    phy_off();
    enable     = '1;
    enable_clk = 1'b1;
    time_to_stop(2_000, t, 1'b0);
    expect_true($sformatf("Stopstate %0.0f ns after Enable: no T_INIT", t), t >= 0.0 && t < 300.0);
    // the AFE's ready rising (T_INIT != 0): WaitStop, Stop after T_INIT
    bench_ready = 1'b0;
    bus_cycles(10);
    bench_ready = 1'b1;
    bus_cycles(3);
    time_to_stop(10_000, t);
    expect_true($sformatf("Stopstate %0.0f ns after READY rose, T_INIT %0.0f ns", t, tinit_ns),
                t >= tinit_ns - 150.0 && t <= tinit_ns + 300.0);
    // REINIT in a burst: the lanes leave HS at once (WaitStop), the burst is lost
    flush_rx();
    b = make_bytes(400, 5);
    burst(b);
    wait_bytes(40);
    wr(ACmd, CmdReinit);
    lp_cycles(20);
    expect_true("REINIT in a burst: the data lanes left HS", p_act[Lanes:1] == '0);
    tx_wait(tinit_ns + 400.0);
    u_tx.push_clk_burst(800);                     // the byte domain ends the cut burst
    tx_wait(tinit_ns + 400.0);
    rd(AErr, q);
    expect_eq("REINIT in a burst: no LATE_EOT (not the transmitter's clock)", q & ErrLateEot, 0);
    flush_rx();
    // T_INIT 0: Stop again at once after a REINIT (v1)
    wr_apply(ATim2, 32'h0);
    wr(ACmd, CmdReinit);
    time_to_stop(2_000, t, 1'b0);                 // (out of Stop for a cycle or two only)
    expect_true($sformatf("T_INIT 0: Stopstate %0.0f ns after CMD.REINIT", t), t >= 0.0 && t < 300.0);
    b = make_bytes(26, 7);
    burst(b);
    tx_wait();
    expect_burst("a burst with T_INIT 0", b);
    rd(AErr, q);
    expect_eq("no errors from T_INIT", q, 32'h0);
  endtask

  // ---------------------------------------------------------------------------- hstmo
  // a data lane 0 HS request without LP-11 for ns: the cycles hs_active was high
  task automatic stuck_hs(input int unsigned ns, output int unsigned hi);
    hi = 0;
    lps(1, 2'b01, 100);
    lps(1, 2'b00, ns);
    fork
      begin
        while (u_tx.busy()) begin
          @(posedge lp_clk);
          if (p_act[1]) hi++;
        end
      end
    join
    tx_wait(200);
  endtask

  task automatic t_hstmo();
    int unsigned hi, n0, n1;
    phy_on();
    wr_apply(ATim1, 32'd300);
    n0 = prod_steps[1];
    stuck_hs(4000, hi);
    expect_true($sformatf("HS_TMO 300: lane 0 in Hs for %0d cycles", hi), hi == 300);
    expect_rd("ERR_STATUS CONTROL + HS_TMO", AErr, ErrControl | ErrHsTmo);
    expect_rd("CNT_MISC one HS_TMO", ACntMisc, 32'h0001_0000);
    expect_rd("CNT_LPERR one (as v1)", ACntLpErr, 32'd1);
    expect_rd("ERR_LANE CONTROL of data lane 0", AErrLane, 32'h0000_0100);
    expect_true("ErrControl[0] stepped once", prod_steps[1] - n0 == 1);
    // HS_TMO 0: no watchdog
    clear_counts();
    wr_apply(ATim1, 32'd0);
    stuck_hs(4000, hi);
    expect_true($sformatf("HS_TMO 0: lane 0 in Hs for %0d cycles (until LP-11)", hi), hi > 700);
    expect_rd("HS_TMO 0: no error", AErr, 32'h0);
    expect_rd("HS_TMO 0: CNT_MISC 0", ACntMisc, 32'h0);
    // a longer one, through the upper timer bits: 0x10_0010 cycles would take too long; 1100
    wr_apply(ATim1, 32'd1100);
    clear_counts();
    n1 = prod_steps[1];
    stuck_hs(8000, hi);
    expect_true($sformatf("HS_TMO 1100: lane 0 in Hs for %0d cycles", hi), hi == 1100);
    expect_rd("ERR_STATUS HS_TMO again", AErr, ErrControl | ErrHsTmo);
    expect_true("ErrControl[0] stepped once more", prod_steps[1] - n1 == 1);
    wr_apply(ATim1, Tim1Reset);
  endtask

  // --------------------------------------------------------------------------- esctmo
  task automatic t_esctmo();
    int unsigned e0;
    realtime     t0, t1;
    phy_on();
    wr_apply(ACtrl, CtrlUlpsEn);
    wr_apply(ATim2, 32'(2) << 20);                  // ESC_TMO 2 x 64 cycles
    e0 = esc_steps[0];
    // an escape entry that stalls in a space: timeout after 128 cycles from the LP-10
    lps(1, 2'b10, 80);
    lps(1, 2'b00, 80);
    lps(1, 2'b01, 80);
    lps(1, 2'b00, 3000);
    t0 = -1.0;
    t1 = -1.0;
    while (u_tx.busy()) begin
      @(posedge lp_clk);
      #0.1;
      if (t0 < 0.0 && p_state[1] == 4'd9) t0 = $realtime;           // EscRqst
      if (t0 >= 0.0 && t1 < 0.0 && p_state[1] == 4'd1) t1 = $realtime;   // WaitStop
    end
    tx_wait(200);
    expect_true($sformatf("ESC_TMO 2: escape mode %0.0f ns (128 lp cycles)", t1 - t0),
                t1 > t0 && (t1 - t0) > 127.5 * lp_ps / 1000.0 && (t1 - t0) < 128.5 * lp_ps / 1000.0);
    expect_rd("ERR_STATUS ESC_TMO", AErr, ErrEscTmo);
    expect_rd("CNT_MISC one ESC_TMO", ACntMisc, 32'h0001_0000);
    expect_true("ErrEsc[0] stepped once", esc_steps[0] - e0 == 1);
    // ESC_TMO 0: no timeout; the stalled entry ends with LP-11, no error
    clear_counts();
    wr_apply(ATim2, 32'h0);
    lps(1, 2'b10, 80);
    lps(1, 2'b00, 80);
    lps(1, 2'b01, 80);
    lps(1, 2'b00, 3000);
    tx_wait(200);
    expect_rd("ESC_TMO 0: no error", AErr, 32'h0);
    expect_rd("ESC_TMO 0: back in Stop", ALaneStop, all_stop());
    wr_apply(ACtrl, 32'h0);
  endtask

  // ----------------------------------------------------------------------------- ulps
  task automatic t_ulps();
    logic [31:0] q;
    int unsigned e0;
    csi2_bytes_t b;
    phy_on();
    // ULPS_EN 0: LP-10 in Stop is an LP error (v1)
    lps(1, 2'b10, 100);
    tx_wait(200);
    expect_rd("ULPS_EN 0: LP-10 is a CONTROL error", AErr, ErrControl);
    clear_counts();
    wr_apply(ACtrl, CtrlUlpsEn);
    wr(AIrqEn, 32'h2);
    // data lanes: escape entry, ULPS command, ULPS
    escape(data_mask(), EscUlps);
    lps(data_mask(), 2'b00, 1500);
    while (u_tx.busy() && u_tx.items.size() != 0) #10;
    #800;
    rd(ALaneStop, q);
    expect_eq("ULPS: LANE_STOP ULPS of the data lanes", q,
              32'(((1 << Lanes) - 1) << 17) | 32'(1));
    for (int l = 0; l < int'(Lanes); l++) begin
      expect_true($sformatf("ULPS: UlpsActiveNot / RxUlpsEsc of lane %0d", l),
                  !ppi_lp[l].ulps_active_not && ppi_lp[l].rx_ulps_esc);
    end
    expect_true("ULPS: lane_pd of the data lanes", lane_pd == '1 && !clk_lane_pd);
    expect_true("ULPS: the HS receivers off", hsrx_en == '0 && term_en == '0);
    expect_rd("IRQ_STATUS.ULPS", AIrqSt, 32'h2, 32'h2);
    expect_true("irq_o (IRQ_EN.ULPS)", irq);
    tx_wait(0);
    // wake-up: LP-10 (lane_pd falls at once, still in ULPS), then LP-11
    lps(data_mask(), 2'b10, 2000);
    #1200;
    expect_true("wake-up mark: lane_pd 0", lane_pd == '0);
    for (int l = 0; l < int'(Lanes); l++) begin
      expect_true($sformatf("wake-up mark: lane %0d UlpsActiveNot 0, RxUlpsEsc 0", l),
                  !ppi_lp[l].ulps_active_not && !ppi_lp[l].rx_ulps_esc);
    end
    tx_wait(300);
    expect_rd("out of ULPS: every lane in Stop", ALaneStop, all_stop());
    expect_rd("CNT_DSK: ULPS entries of every data lane", ACntDsk, 32'(Lanes) << 16);
    expect_rd("no error from ULPS", AErr, 32'h0);
    // clock lane ULPS: LP-10, LP-00; wake-up LP-10, LP-11
    wr(AIrqSt, 32'hF);
    lps(1 << CL, 2'b10, 100);
    lps(1 << CL, 2'b00, 1500);
    while (u_tx.items.size() != 0) #10;
    #800;
    expect_true("clock lane ULPS: RxUlpsClkNot 0, UlpsActiveNotClk 0",
                !ppi_lp_clk.rx_ulps_clk_not && !ppi_lp_clk.ulps_active_not);
    expect_true("clock lane ULPS: its lane_pd", clk_lane_pd && lane_pd == '0);
    rd(ALaneStop, q);
    expect_eq("clock lane ULPS: LANE_STOP", q, 32'h0001_0000 | (all_stop() & ~32'h1));
    tx_wait(0);
    lps(1 << CL, 2'b10, 1000);
    tx_wait(300);
    expect_true("clock lane out of ULPS", ppi_lp_clk.rx_ulps_clk_not && ppi_lp_clk.ulps_active_not &&
                !clk_lane_pd);
    expect_rd("CNT_DSK: + the clock lane", ACntDsk, 32'(Lanes + 1) << 16);
    // another command (a reset trigger): an escape error, then LP-11 ends it
    clear_counts();
    e0 = esc_steps[0];
    escape(1, EscReset);
    lps(1, 2'b00, 200);
    tx_wait(300);
    expect_rd("another command: ERR_STATUS.ESC only", AErr, ErrEsc);
    expect_true("another command: ErrEsc[0] stepped", esc_steps[0] - e0 == 1);
    expect_rd("another command: back in Stop", ALaneStop, all_stop());
    // LP-11 in the entry: no error
    clear_counts();
    lps(1, 2'b10, 80);
    lps(1, 2'b00, 80);
    tx_wait(300);
    expect_rd("LP-11 in the entry: no error", AErr, 32'h0);
    // a mark followed by the other mark (no space): an LP error
    lps(1, 2'b10, 80);
    lps(1, 2'b00, 80);
    lps(1, 2'b01, 80);
    lps(1, 2'b00, 80);
    lps(1, 2'b01, 80);
    lps(1, 2'b10, 80);
    tx_wait(300);
    expect_rd("a mark without its space: CONTROL", AErr, ErrControl);
    wr(AIrqEn, 32'h0);
    wr_apply(ACtrl, 32'h0);
    clear_counts();
    b = make_bytes(30, 4);
    burst(b);
    tx_wait();
    flush_rx();
  endtask

  // ----------------------------------------------------------------------------- hsrx
  // a burst; per data lane whether the HS receiver was on in LP-01 (HsRqst) and whether the
  // termination was on before LP-00 was seen
  task automatic hs_enables(output bit early_rx, output bit early_term);
    early_rx   = 1'b0;
    early_term = 1'b0;
    burst(make_bytes(24, 2));
    while (u_tx.busy()) begin
      @(posedge lp_clk);
      #0.1;
      for (int l = 0; l < int'(Lanes); l++) begin
        if (p_state[1 + l] == 4'd3 && hsrx_en[l]) early_rx = 1'b1;     // HsRqst
        if (p_state[1 + l] == 4'd3 && term_en[l]) early_term = 1'b1;
      end
    end
    tx_wait();
    flush_rx();
  endtask

  task automatic t_hsrx();
    bit erx, eterm;
    phy_on();
    hs_enables(erx, eterm);
    expect_true("HSRX_EARLY 0: neither enable in HS-Rqst", !erx && !eterm);
    wr_apply(ACtrl, CtrlHsrxEarly);
    hs_enables(erx, eterm);
    expect_true("HSRX_EARLY 1: the HS receiver in HS-Rqst", erx);
    expect_true("HSRX_EARLY 1: the termination not before LP-00", !eterm);
    wr_apply(ACtrl, 32'h0);
    burst(make_bytes(33, 3));
    tx_wait();
    expect_burst("HSRX_EARLY off again", make_bytes(33, 3));
  endtask

  // -------------------------------------------------------------------------- missoff
  // a burst: did the clock lane's HS receiver / termination stay on after the gate closed
  // while the lane was still in HS-0 (lp_st LP-00)?
  task automatic clk_enables(output bit on_after_gate, output bit off_with_gate);
    bit gate_q;
    on_after_gate = 1'b0;
    off_with_gate = 1'b0;
    gate_q        = 1'b0;
    burst(make_bytes(24, 6));
    while (u_tx.busy()) begin
      @(posedge lp_clk);
      #0.1;
      if (gate_q && !gate && p_lp[0] == 2'b00) begin
        off_with_gate = !clk_hsrx_en && !clk_term_en;
      end
      if (!gate && p_lp[0] == 2'b00 && p_state[0] == 4'd6 && (clk_hsrx_en || clk_term_en)) begin
        on_after_gate = 1'b1;                                         // Trail
      end
      gate_q = gate;
    end
    tx_wait();
    flush_rx();
  endtask

  task automatic t_missoff();
    bit on_after, off_with;
    phy_on();
    clk_enables(on_after, off_with);
    expect_true("CLK_MISS_OFF 0: the clock lane receiver on in Trail (v1)", on_after && !off_with);
    wr_apply(ACtrl, CtrlMissOff);
    clk_enables(on_after, off_with);
    expect_true("CLK_MISS_OFF 1: receiver and termination off with the gate", off_with && !on_after);
    wr_apply(ACtrl, 32'h0);
    burst(make_bytes(29, 8));
    tx_wait();
    expect_burst("CLK_MISS_OFF off again", make_bytes(29, 8));
  endtask

  // --------------------------------------------------------------------------- togdiv
  // bursts with the gate watched: closes while the transmitter's clock still toggles
  task automatic tog_bursts(input int n, output int unsigned early, output int unsigned got);
    csi2_bytes_t b;
    bit          gate_q;
    early = 0;
    got   = 0;
    for (int i = 0; i < n; i++) begin
      b = make_bytes(64, 20 + i);
      burst(b);
      gate_q = 1'b0;
      while (u_tx.busy()) begin
        @(posedge lp_clk);
        #0.1;
        if (gate_q && !gate && u_tx.cur_burst >= 0 && u_tx.cur_byte < 64) early++;
        gate_q = gate;
      end
      tx_wait();
      for (int l = 0; l < int'(Lanes); l++) begin
        if (rx_len[l].size() != 0) got++;
        if ($test$plusargs("tog_debug")) $display("togdiv burst %0d lane %0d: %0d bursts", i, l, rx_len[l].size());
      end
      flush_rx();
    end
  endtask

  task automatic t_togdiv();
    int unsigned early, got;
    phy_on();
    // the timers at a 50 MHz lp clock: SETTLE 2 (the sync search from 100 + 40 ns after
    // LP-00 at the pins, HS-ZERO 300 ns), LP_FILTER 2, CLK_SETTLE 8 (160 ns), CLK_MISS 6
    // (120 ns: longer than 2^2 byte clocks, 40 ns)
    u_tx.t_hs_zero  = 300;
    u_tx.t_clk_post = 300;                        // > LP-11 detection (100 ns) + 3 byte clocks
    wr_apply(ATim0, 32'h0608_0202);
    wr_apply(ATim1, Tim1Reset | (32'd0 << 24));
    tog_bursts(3, early, got);
    $display("tb_bow_dphy_rx: CLK_TOG_DIV 0 with a byte clock of 2 x lp_clk: %0d gate closes in bursts, %0d lane bursts", early, got);
    expect_true("CLK_TOG_DIV 0: the gate closes in the bursts (no edge seen)", early > 0);
    for (int d = 1; d <= 2; d++) begin
      wr_apply(ATim1, Tim1Reset | (32'(d) << 24));
      u_tx.push_clk_burst(1000);                  // the new divider into the byte domain, the
      tx_wait();                                  // cut bursts of CLK_TOG_DIV 0 ended
      flush_rx();
      tog_bursts(3, early, got);
      expect_true($sformatf("CLK_TOG_DIV %0d: no gate close in a burst (%0d), every burst (%0d)", d,
                            early, got), early == 0 && got == 3 * Lanes);
    end
    wr_apply(ATim1, Tim1Reset);
    wr_apply(ATim0, Tim0Reset);
    u_tx.t_hs_zero  = 150;
    u_tx.t_clk_post = 120;
  endtask

  // -------------------------------------------------------------------------- clklost
  // data lanes in HS without the clock lane: LP-01, LP-00 for a while, LP-11
  function automatic void hs_without_clock();
    lps(data_mask(), 2'b01, 100);
    lps(data_mask(), 2'b00, 600);
  endfunction

  task automatic t_clklost();
    int unsigned n0;
    phy_on();
    hs_without_clock();
    tx_wait(300);
    expect_rd("CLK_LOST_EN 0: nothing (v1)", AErr, 32'h0);
    expect_rd("CLK_LOST_EN 0: CNT_MISC 0", ACntMisc, 32'h0);
    wr_apply(ACtrl, CtrlClkLostEn);
    n0 = prod_steps[1];
    hs_without_clock();
    tx_wait(300);
    expect_rd("CLK_LOST_EN 1: ERR_STATUS.CLK_LOST", AErr, ErrClkLost);
    expect_rd("CLK_LOST_EN 1: one per data lane", ACntMisc, 32'(Lanes) << 16);
    expect_true("CLK_LOST_EN 1: ErrControl[0] stepped", prod_steps[1] - n0 == 1);
    expect_rd("CLK_LOST is no LP error", ACntLpErr, 32'd0);
    clear_counts();
    burst(make_bytes(30, 5));
    tx_wait();
    expect_burst("CLK_LOST_EN 1: a burst with the clock", make_bytes(30, 5));
    expect_rd("CLK_LOST_EN 1: no CLK_LOST with the clock", AErr, 32'h0);
    wr_apply(ACtrl, 32'h0);
  endtask

  // -------------------------------------------------------------------------- lateeot
  task automatic t_lateeot();
    logic [31:0] q;
    phy_on();
    wr(AIrqEn, 32'h1);
    burst(make_bytes(48, 1));
    tx_wait();
    expect_rd("CLK-POST 120 ns: no LATE_EOT", AErr, 32'h0);
    u_tx.t_clk_post = 10;                         // the clock stops before RxActiveHS falls
    for (int i = 0; i < 3; i++) begin
      burst(make_bytes(48, 2 + i));
      tx_wait();
    end
    expect_rd("CLK-POST 10 ns: LATE_EOT", AErr, ErrLateEot);
    expect_rd("CLK-POST 10 ns: every lane of every burst", ACntMisc, 32'(3 * Lanes) << 16);
    expect_rd("IRQ_STATUS.ERR", AIrqSt, 32'h1, 32'h1);
    expect_true("irq_o", irq);
    u_tx.t_clk_post = 120;
    clear_counts();
    burst(make_bytes(48, 9));
    tx_wait();
    expect_rd("CLK-POST 120 ns again: none", ACntMisc, 32'h0);
    // a burst cut by Enable: no LATE_EOT (the gate closes with the clock lane's Enable)
    burst(make_bytes(400, 3));
    wait_bytes(40);
    phy_off();
    tx_wait();
    rd(AErr, q);
    expect_eq("Enable off in a burst: no LATE_EOT", q & ErrLateEot, 32'h0);
    flush_rx();
    // the clock lane's Enable alone (the data lanes stay enabled, in HS): no LATE_EOT either
    phy_on();
    burst(make_bytes(400, 4));
    wait_bytes(40);
    enable_clk = 1'b0;
    lp_cycles(40);
    rd(AErr, q);
    expect_eq("the clock lane's Enable off in a burst: no LATE_EOT", q & ErrLateEot, 32'h0);
    tx_wait();
    phy_off();
    rd(AErr, q);
    expect_eq("the clock lane's Enable off in a burst: none at its end", q & ErrLateEot, 32'h0);
    wr(AIrqEn, 32'h0);
    flush_rx();
  endtask

  // ----------------------------------------------------------------------------- gray
  task automatic t_gray();
    logic [31:0] q;
    int unsigned n, p0, c0;
    phy_on();
    // LP errors at the highest rate on data lane 0: Stop, LP-00 (an error), LP-11, ...
    p0 = prod_steps[1];
    c0 = ctl_steps[1];
    n  = 120;
    for (int i = 0; i < int'(n); i++) begin
      lps(1, 2'b00, 20);
      lps(1, 2'b11, 20);
    end
    tx_wait(2000);
    expect_rd($sformatf("CNT_LPERR counts all %0d errors", n), ACntLpErr, n);
    expect_true($sformatf("ErrControl[0] steps merged: %0d steps for %0d errors",
                          prod_steps[1] - p0, n), prod_steps[1] - p0 > 0 && prod_steps[1] - p0 < n);
    expect_true($sformatf("the sampler at lp_clk / 32 saw every step (%0d of %0d)",
                          ctl_steps[1] - c0, prod_steps[1] - p0), ctl_steps[1] - c0 == prod_steps[1] - p0);
    // ErrControlClk: none while CLK_CONT, counted in CNT_LPERR
    clear_counts();
    phy_off();
    wr_apply(ACtrl, CtrlClkCont);
    phy_on();
    p0 = prod_steps[0];
    for (int i = 0; i < 10; i++) begin
      lps(1 << CL, 2'b00, 20);
      lps(1 << CL, 2'b11, 20);
    end
    tx_wait(1000);
    rd(ACntLpErr, q);
    expect_true($sformatf("CLK_CONT: clock lane errors counted (%0d)", q), q == 10);
    expect_true("CLK_CONT: no ErrControlClk step", prod_steps[0] == p0);
    phy_off();
    wr_apply(ACtrl, 32'h0);
  endtask

  // ------------------------------------------------------------------------------ main
  initial begin
    if (!$value$plusargs("TEST=%s", test)) test = "basic";
    u_tx.byte_ns = byte_ps / 1000.0;
    u_tx.lp00    = 1'b0;
    #1;
    rst_n = 1'b0;
    #200;
    rst_n = 1'b1;
    bus_cycles(10);
    case (test)
      "basic":   t_basic();
      "apply":   t_apply();
      "tinit":   t_tinit();
      "hstmo":   t_hstmo();
      "esctmo":  t_esctmo();
      "ulps":    t_ulps();
      "hsrx":    t_hsrx();
      "missoff": t_missoff();
      "togdiv":  t_togdiv();
      "clklost": t_clklost();
      "lateeot": t_lateeot();
      "gray":    t_gray();
      default:   err($sformatf("unknown test %s", test));
    endcase
    tx_wait(500);
    if (errors == 0) $display("tb_bow_dphy_rx: PASS (%0d checks; test %s, %0d lanes)", checks, test, Lanes);
    else             $display("tb_bow_dphy_rx: FAIL (%0d errors; test %s, %0d lanes)", errors, test, Lanes);
    $finish;
  end

  initial begin
    #20ms;
    $display("tb_bow_dphy_rx: FAIL (timeout; test %s)", test);
    $finish;
  end

endmodule
