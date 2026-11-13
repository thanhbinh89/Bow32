// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit testbench of the Bow32 CSI-2 receiver (Verilator --binary --timing): the DUT is
// bow_mipi_rx, the digital D-PHY and the CSI-2 controller joined by the PPI. The register
// window is the receiver's: the controller at 0x000, the D-PHY at 0xC00 (step 4 of
// docs/ip/mipi_rx_arch.md, docs/ip/dphy_rx.md). The D-PHY speaks the AFE interface (step 5)
// with the model csi2_tx_model, which plays the sensor and an FPGA AFE adapter with the
// adapter's own logic (bow_dphy_dly_xusp / bow_dphy_dly_xphy): pd and cal_start (AFE_CTRL.PD,
// CMD.AFE_CAL; CMD.REINIT in steps 4 and 5) re-initialise the Versal PHY model, des_rst
// (~the gate, 0 while CTRL.DES_RST_DIS = 1) drives its BurstRxRst (a test case of the Versal
// PHY with BurstRxRst 0 writes DES_RST_DIS first, the testbench checks the D-PHY's setting at
// every burst);
// status = {4{AFE ready}} (AFE_STATUS[11:8]).
//
// Reads a test case written by `tools/csi2/csi2_model.py gen DIR`:
//   DIR/cfg.txt   settings ('key value': lanes, clock mode, D-PHY timing, eye,
//                 PHY flavour, ...)
//   DIR/stim.txt  commands, executed in order by the main process:
//     rd A / wr A D / poll A MASK VALUE US    register access (hex)
//     wrbe A D BE                             write with byte enables (hex)
//     pkt ...                                 one burst for csi2_tx_model (see Burst in the model)
//     lp MASK LP NS / idle NS / clkon         LP states (MASK bit 4 = clock lane), idle time,
//                                             continuous clock start
//     clkburst NS                             clock lane only burst (deferred work)
//     wait / delay NS / waitbyte BURST BYTE   wait for the TX model to finish / time / burst progress
//     waitphy                                 wait for the PHY ready (Versal PHY model)
//     irqfe                                   (tclkpost) after a frame's FE: irq_o without a
//                                             byte clock (invariants irq_stop, irq_stop_n)
//     tready PCT / knob NAME V / mark N       m_axis tready duty, TX knob, segment marker
//   and writes
//   DIR/out.txt   one line per m_axis transfer: pixel tuser[0] tlast tuser[1], and 'mark N'
//   DIR/regs.txt  rd/poll results, 'fe FRAME_INFO FRAME_SUM FRAME_ERR' for every frame end
//                 (IRQ_STATUS.FE polled during wait/delay/poll and cleared),
//                 per segment invariants ('inv SEG NAME VALUE'), burst end
//                 times ('tend BURST PS') and 'end'
// which `csi2_model.py check DIR` compares with the reference model.
//
// Invariants measured on every burst: LP-01 -> LP-00 at the pins to hsrx_en
// (data and clock lanes) and LP-11 to hsrx_en low, the gate open while the clock
// lane is in an LP state or opened while it toggles (csi2_tx_model counters);
// with the Versal AFE (AfeKind = 2) the XPHY delay contract of the model (dly_bad,
// dly_drop, loads per lane); irq_o high whenever a poll finds IRQ_STATUS.FE with IRQ_EN.FE
// (irq_fe); at an irqfe line (test tclkpost: the byte clock stopped behind a frame's FE)
// irq_o high within 2 us (irq_stop: the misses), irq_stop_n the rises after the last byte
// clock edge (the measurements); at the end irq_o = |(IRQ_STATUS & IRQ_EN).
// On every video clock edge: the PPI v1 outputs of the D-PHY that the
// controller does not use (bow_ppi_chk, bound into bow_dphy_rx; a violation
// stops the simulation, the counts go to sim.log) and its AFE v1 outputs
// (bow_afe_chk, bound the same way; silent unless one fails or +afe_chk_report).
//
// Clocks: CPU 50 MHz, video 200 MHz (PhyClkHz, also the Versal PHY control
// clock), byte clock from the TX model; all unrelated.

`timescale 1ns / 1ps

module tb_bow_csi2rx;
  import bow_bus_pkg::*;
  import csi2_tx_pkg::*;

  parameter int unsigned Lanes     = 2;
  parameter int unsigned FifoDepth = 256;
  parameter int unsigned AfeKind   = 1;                   // 1 UltraScale+, 2 Versal adapter
  localparam bit         Versal    = (AfeKind == 2);
  localparam int unsigned CpuPs = 20000, VidPs = 5000;    // 50 MHz, 200 MHz
  localparam int unsigned PhyClkHz = 200_000_000;
  localparam int unsigned ML = 4, CL = 4;                 // TX model: lanes, clock lane index
  localparam int unsigned NEye = (Lanes > 2) ? Lanes : 2; // TX model: eye_lo / eye_hi entries

  logic clk = 1'b0, vclk = 1'b0;
  logic rst_n = 1'b1, vrst_n = 1'b1;
  always #(CpuPs / 2000.0) clk = ~clk;
  always #(VidPs / 2000.0) vclk = ~vclk;

  bus_req_t req = BUS_REQ_DEFAULT;
  bus_rsp_t rsp;
  logic     irq;

  logic                  m_tvalid, m_tlast;
  logic [1:0]            m_tuser;
  logic                  m_tready = 1'b1;
  logic [9:0]            m_tdata;
  logic                  byte_clk, clk_gate_en, des_rst, phy_rdy, pd, cal_start;
  logic                  clk_lprx_en, clk_hsrx_en, clk_term_en;
  logic [7:0]            phy_status;
  logic [1:0]            clk_lp;
  logic [Lanes-1:0][1:0] lp;
  logic [Lanes-1:0]      lprx_en, hsrx_en, term_en, dly_own, hs_valid;
  logic [Lanes-1:0][7:0] hs_data;
  logic [Lanes-1:0][8:0] dly_code, dly_q;

  bow_mipi_rx #(
    .Lanes     (Lanes),
    .PhyClkHz  (PhyClkHz),
    .CpuClkHz  (1_000_000_000 / (CpuPs / 1000)),
    .HasPhy    (1'b1),
    .FifoDepth (FifoDepth),
    .AfeKind   (AfeKind),
    .ByteClkHz (180_000_000)                   // the TX model's byte clocks: 96 .. 180 MHz
  ) dut (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .bus_req_i       (req),
    .bus_rsp_o       (rsp),
    .irq_o           (irq),
    .vid_clk_i       (vclk),
    .vid_rst_ni      (vrst_n),
    .m_axis_tvalid_o (m_tvalid),
    .m_axis_tready_i (m_tready),
    .m_axis_tdata_o  (m_tdata),
    .m_axis_tuser_o  (m_tuser),
    .m_axis_tlast_o  (m_tlast),
    .afe_hs_byte_clk_i (byte_clk),
    .afe_hs_data_i     (hs_data),
    .afe_hs_valid_i    (hs_valid),
    .afe_clk_gate_en_o (clk_gate_en),
    .afe_des_rst_o     (des_rst),
    .afe_clk_lp_i      (clk_lp),
    .afe_lp_i          (lp),
    .afe_clk_lprx_en_o (clk_lprx_en),
    .afe_lprx_en_o     (lprx_en),
    .afe_clk_hsrx_en_o (clk_hsrx_en),
    .afe_hsrx_en_o     (hsrx_en),
    .afe_clk_term_en_o (clk_term_en),
    .afe_term_en_o     (term_en),
    .afe_dly_code_o    (dly_code),
    .afe_dly_own_o     (dly_own),
    .afe_dly_q_i       (dly_q),
    .afe_pd_o          (pd),
    .afe_ready_i       (phy_rdy),
    .afe_cal_start_o   (cal_start),
    .afe_status_i      (phy_status)
  );

  assign phy_status = {4'h0, {4{phy_rdy}}};

  // cfg v_burst_rst: the BurstRxRst the test case expects of the D-PHY (~CTRL.DES_RST_DIS,
  // checked at every burst; -1: none)
  int brst_cfg = -1;

  // The PPI v1 outputs of the D-PHY that the controller does not use (Stopstate,
  // RxClkActiveHS, bit 1 of ErrControl, idle values): checked on every lp clock edge against
  // the LP state machines' inputs, counts in sim.log (hw/ip/dphy_rx/dv/bow_ppi_chk.sv)
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
    .tinit_i      (cfg_lp_q.tinit),
    .ulps_en_i    (cfg_lp_q.ulps_en),
    .force_wait_i (force_wait)
  );

  // The AFE v1 outputs of the D-PHY (hw/ip/dphy_rx/dv/bow_afe_chk.sv): des_rst = ~gate at the
  // same lp clock edge, term_en = hsrx_en, lprx_en = ~pd, lane_pd (a fresh READY after PD),
  // OWN only while ready, the tie-offs of v1, the reset values while reset is asserted
  bind bow_dphy_rx bow_afe_chk #(
    .Lanes (Lanes), .TrimW (TrimW), .AfePdRst (AfePdRst)
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

  csi2_tx_model #(.Lanes(Lanes)) u_tx (
    .hs_byte_clk_o (byte_clk),
    .hs_data_o     (hs_data),
    .hs_valid_o    (hs_valid),
    .clk_gate_en_i (clk_gate_en),
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
    .ready_o       (phy_rdy),
    .ctrl_clk_i    (vclk),
    .ctrl_rst_ni   (vrst_n)
  );

  string dir;
  int    out_fd, regs_fd;

  // ------------------------------------------------------------ m_axis sink
  int unsigned tready_pct = 100;

  always @(posedge vclk) begin
    if (m_tvalid && m_tready) begin
      $fwrite(out_fd, "%03x %0d %0d %0d\n", m_tdata, m_tuser[0], m_tlast, m_tuser[1]);
    end
    #0.5;
    m_tready = ($urandom_range(99) < tready_pct);
  end

  // -------------------------------------------------------------- invariants
  // Maxima of this segment in ps (-1: none; [CL] clock lane), TX model
  // counters at the segment start
  longint      lat_max [ML + 1], off_max [ML];
  int unsigned ce_bad0 = 0, ce_rise0 = 0, runts0 = 0, flips0 = 0, dly_bad0 = 0, dly_drop0 = 0;
  int unsigned irq_fe_bad = 0, irq_fe_bad0 = 0;      // FE polled with irq_o low (IRQ_EN.FE)
  // irqfe (test tclkpost): irq_o after a frame's FE with the byte clock stopped
  int unsigned irq_stop_bad = 0, irq_stop_bad0 = 0;  // did not rise with the byte clock stopped
  int unsigned irq_stop_n = 0, irq_stop_n0 = 0;      // rose with the byte clock stopped
  int unsigned irq_stop_pre = 0;                     // rose before its last edge
  longint      irq_stop_lat = 0;                     // most ps from the last byte clock edge
  realtime     bclk_t = 0.0;                         // time of the last byte clock edge
  always @(posedge byte_clk) bclk_t = csi2_now();
  int unsigned loads0 [ML];

  function automatic void seg_reset();
    for (int i = 0; i <= int'(ML); i++) lat_max[i] = -1;
    for (int i = 0; i < int'(ML); i++) off_max[i] = -1;
    ce_bad0   = u_tx.ce_bad;
    ce_rise0  = u_tx.ce_rise_toggle;
    runts0    = u_tx.runts;
    flips0    = u_tx.flips;
    dly_bad0  = u_tx.dly_bad;
    dly_drop0 = u_tx.dly_drop;
    irq_fe_bad0 = irq_fe_bad;
    irq_stop_bad0 = irq_stop_bad;
    irq_stop_n0 = irq_stop_n;
    for (int i = 0; i < int'(ML); i++) loads0[i] = u_tx.dly_loads[i];
  endfunction

  function automatic void seg_dump(int seg);
    for (int l = 0; l < int'(Lanes); l++) $fwrite(regs_fd, "inv %0d lat%0d %0d\n", seg, l, lat_max[l]);
    $fwrite(regs_fd, "inv %0d latclk %0d\n", seg, lat_max[CL]);
    for (int l = 0; l < int'(Lanes); l++) $fwrite(regs_fd, "inv %0d off%0d %0d\n", seg, l, off_max[l]);
    $fwrite(regs_fd, "inv %0d ce_bad %0d\n", seg, u_tx.ce_bad - ce_bad0);
    $fwrite(regs_fd, "inv %0d ce_rise_toggle %0d\n", seg, u_tx.ce_rise_toggle - ce_rise0);
    $fwrite(regs_fd, "inv %0d runts %0d\n", seg, u_tx.runts - runts0);
    $fwrite(regs_fd, "inv %0d flips %0d\n", seg, u_tx.flips - flips0);
    $fwrite(regs_fd, "inv %0d irq_fe %0d\n", seg, irq_fe_bad - irq_fe_bad0);
    $fwrite(regs_fd, "inv %0d irq_stop %0d\n", seg, irq_stop_bad - irq_stop_bad0);
    $fwrite(regs_fd, "inv %0d irq_stop_n %0d\n", seg, irq_stop_n - irq_stop_n0);
    if (Versal) begin
      $fwrite(regs_fd, "inv %0d dly_bad %0d\n", seg, u_tx.dly_bad - dly_bad0);
      $fwrite(regs_fd, "inv %0d dly_drop %0d\n", seg, u_tx.dly_drop - dly_drop0);
      for (int l = 0; l < int'(Lanes); l++) begin
        $fwrite(regs_fd, "inv %0d dly_loads%0d %0d\n", seg, l, u_tx.dly_loads[l] - loads0[l]);
      end
    end
  endfunction

  // LP-01 -> LP-00 at the pin -> hsrx_en (only HS requests of the last 1 us)
  function automatic void hs_on(int i);
    longint d;
    d = longint'((csi2_now() - u_tx.t_lp00[i]) * 1000.0);
    if (d >= 0 && d < 1_000_000 && d > lat_max[i]) lat_max[i] = d;
  endfunction

  // LP-11 at the pin -> hsrx_en low (only if the lane went LP-11 in the last 200 ns)
  function automatic void hs_off(int i);
    longint d;
    d = longint'((csi2_now() - u_tx.t_lp11[i]) * 1000.0);
    if (lp[i] == 2'b11 && d >= 0 && d < 200_000 && d > off_max[i]) off_max[i] = d;
  endfunction

  for (genvar l = 0; l < int'(Lanes); l++) begin : g_lane_mon
    always @(posedge hsrx_en[l]) hs_on(l);
    always @(negedge hsrx_en[l]) hs_off(l);
  end
  always @(posedge clk_hsrx_en) hs_on(CL);

  // ---------------------------------------------------------------- bus BFM
  task automatic bus_xfer(input bit we, input logic [31:0] addr, input logic [31:0] wdata,
                          output logic [31:0] rdata, input logic [3:0] be = 4'hF);
    bus_req_t r;
    r       = BUS_REQ_DEFAULT;
    r.req   = 1'b1;
    r.we    = we;
    r.be    = be;
    r.addr  = addr;
    r.wdata = wdata;
    @(posedge clk);
    #1;
    req = r;
    @(posedge clk);
    #1;
    rdata = rsp.rdata;
    req   = BUS_REQ_DEFAULT;
  endtask

  // irqfe (test tclkpost, IRQ_EN = FE only): the frame's FE is the last packet queued and the
  // byte clock stops after its burst. Waits until the TX model is idle (no byte clock edge comes
  // any more), then up to 2 us for irq_o: it must be high by then (irq_stop counts the
  // misses), and a rise after the last byte clock edge is a measurement of the interrupt
  // with the byte clock stopped (irq_stop_n; irq_stop_lat: the most time from that edge). A
  // rise before it (the FE through while the clock still ran) measures nothing
  // (irq_stop_pre); irq_o registered on the byte clock never rises after its last edge.
  realtime irq_rise_t = -1.0;                        // time of irq_o's last rise
  always @(posedge irq) irq_rise_t = csi2_now();

  task automatic irq_stop_check();
    realtime t0;
    longint  d;
    wait (!u_tx.busy());
    t0 = csi2_now();
    while (!irq && csi2_now() - t0 < 2000.0) @(posedge vclk);
    if (!irq) begin
      irq_stop_bad++;
      $display("[%0t] irqfe: irq_o low %0.1f ns after the byte clock stopped", $time,
               csi2_now() - bclk_t);
    end else if (irq_rise_t > bclk_t) begin
      irq_stop_n++;
      d = longint'((irq_rise_t - bclk_t) * 1000.0);
      if (d > irq_stop_lat) irq_stop_lat = d;
    end else begin
      irq_stop_pre++;
    end
  endtask

  // One poll of IRQ_STATUS.FE (frame end records), then `cycles` CPU cycles. With FE set,
  // irq_o must be high when IRQ_EN.FE is (invariant irq_fe: FE polls with irq_o low). irq_o
  // is |(IRQ_STATUS & IRQ_EN) in the CPU domain: this only fails when irq_o is decoupled from
  // IRQ_STATUS (e.g. registered on another clock: mutant irq_on_byte_clock); that the FE
  // and its interrupt come without a byte clock is irqfe's measurement (above) and the
  // checker's segment rule of the FE records.
  task automatic service(input int unsigned cycles);
    logic [31:0] st, info, fsum, ferr, en, unused;
    logic        irq_now;
    bus_xfer(1'b0, 32'h014, '0, st);
    irq_now = irq;
    if (st[1]) begin
      bus_xfer(1'b0, 32'h018, '0, en);
      if (en[1] && !irq_now) irq_fe_bad++;
      bus_xfer(1'b0, 32'h050, '0, info);
      bus_xfer(1'b0, 32'h058, '0, fsum);
      bus_xfer(1'b0, 32'h04C, '0, ferr);
      bus_xfer(1'b1, 32'h014, 32'h2, unused);
      $fwrite(regs_fd, "fe %08x %08x %03x\n", info, fsum, ferr);
    end
    repeat (cycles) @(posedge clk);
  endtask

  // ------------------------------------------------------------------ setup
  function automatic void set_knob(string key, int v);
    int l;
    case (key)
      "lanes":         u_tx.lanes = v;
      "contclk":       u_tx.contclk = v[0];
      "byte_ps":       u_tx.byte_ns = v / 1000.0;
      "lp00":          u_tx.lp00 = v[0];
      "runt":          u_tx.runt = v[0];
      "t_lpx":         u_tx.t_lpx = v;
      "t_hs_prepare":  u_tx.t_hs_prepare = v;
      "t_hs_zero":     u_tx.t_hs_zero = v;
      "t_hs_trail":    u_tx.t_hs_trail = v;
      "t_hs_exit":     u_tx.t_hs_exit = v;
      "t_clk_prepare": u_tx.t_clk_prepare = v;
      "t_clk_zero":    u_tx.t_clk_zero = v;
      "t_clk_pre":     u_tx.t_clk_pre = v;
      "t_clk_post":    u_tx.t_clk_post = v;
      "t_clk_trail":   u_tx.t_clk_trail = v;
      "t_lp11_next":   u_tx.t_lp11_next = v;
      "versal":        u_tx.versal = v[0];
      "t_phy_rdy":     u_tx.t_phy_rdy = v;
      "t_reinit":      u_tx.t_reinit = v;
      "v_burst_rst":   brst_cfg = v;               // the D-PHY drives it: checked per burst
      "v_lat_lane":    u_tx.v_lat_lane = v[0];
      "v_glitch_pct":  u_tx.v_glitch_pct = v;
      "v_gap_pm":      u_tx.v_gap_pm = v;
      "v_gap_byte":    u_tx.v_gap_byte = v;
      "l0_late_ns":    u_tx.l0_late_ns = v;
      "tready":        tready_pct = v;
      "dut_lanes":     if (v != int'(Lanes)) $fatal(1, "test case for %0d lanes, testbench built with %0d", v, Lanes);
      "vid_ps":        if (v != int'(VidPs)) $fatal(1, "vid_ps %0d", v);
      "cpu_ps":        if (v != int'(CpuPs)) $fatal(1, "cpu_ps %0d", v);
      "fifo_depth":    if (v != int'(FifoDepth)) $fatal(1, "fifo_depth %0d, testbench built with %0d", v, FifoDepth);
      "afe_kind":      if (v != int'(AfeKind)) $fatal(1, "afe_kind %0d, testbench built with %0d", v, AfeKind);
      default: begin
        // eye<l>_lo, eye<l>_hi (l < NEye), bisc<l> (l < 4)
        if (key.len() == 7 && key.substr(0, 2) == "eye" && key.substr(4, 6) == "_lo") begin
          l = key.substr(3, 3).atoi();
          if (l < int'(NEye)) u_tx.eye_lo[l] = v;
        end else if (key.len() == 7 && key.substr(0, 2) == "eye" && key.substr(4, 6) == "_hi") begin
          l = key.substr(3, 3).atoi();
          if (l < int'(NEye)) u_tx.eye_hi[l] = v;
        end else if (key.len() == 5 && key.substr(0, 3) == "bisc") begin
          l = key.substr(4, 4).atoi();
          if (l < int'(ML)) u_tx.bisc[l] = v;
        end
      end
    endcase
  endfunction

  // 'pkt VC DT WC HFLIP_A HFLIP_B PFLIP TRUNC SYNC0..3 ZEROS0..3 PHASE0..3 ZERO_NS PAYLOAD
  //  [EXTRA]': EXTRA = bytes sent after the packet in the same burst;
  //  VC < 0: a raw burst of the EXTRA bytes only (no packet), e.g. skew calibration
  function automatic void push_pkt(string line);
    int          vc, dt, wc, hf0, hf1, pf, tr, s0, s1, s2, s3, z0, z1, z2, z3, p0, p1, p2, p3, zns, n;
    string       pay, ext;
    csi2_flags_t f;
    csi2_bytes_t b;
    logic [15:0] c;
    pay = "";
    ext = "-";
    n = $sscanf(line, "pkt %d %h %h %d %d %d %d %h %h %h %h %d %d %d %d %d %d %d %d %d %s %s", vc,
                dt, wc, hf0, hf1, pf, tr, s0, s1, s2, s3, z0, z1, z2, z3, p0, p1, p2, p3, zns, pay,
                ext);
    if (n != 21 && n != 22) $fatal(1, "bad pkt line: %s", line);
    f = csi2_flags();
    f.hdr_flip_a = 8'(hf0);
    f.hdr_flip_b = 8'(hf1);
    f.pay_flip   = pf;
    f.trunc      = tr;
    f.sync       = {8'(s3), 8'(s2), 8'(s1), 8'(s0)};
    f.zeros      = {8'(z3), 8'(z2), 8'(z1), 8'(z0)};
    f.phase      = {4'(p3), 4'(p2), 4'(p1), 4'(p0)};
    f.zero_ns    = 16'(zns);
    if (ext == "-" && dt < 'h10) begin
      u_tx.push_short(vc, dt, wc, f);
    end else if (ext == "-") begin
      b.delete();
      if (pay != "-") begin
        for (int i = 0; i + 1 < pay.len(); i += 2) b.push_back(8'(pay.substr(i, i + 1).atohex()));
      end
      u_tx.push_long(vc, dt, b, f);
    end else begin
      // packet + extra bytes in one burst (raw bytes, as push_short/push_long build them)
      if (vc < 0) b.delete();
      else        b = csi2_header(vc, dt, wc);
      if (vc >= 0 && dt >= 'h10) begin
        csi2_bytes_t p;
        p.delete();
        if (pay != "-") begin
          for (int i = 0; i + 1 < pay.len(); i += 2) p.push_back(8'(pay.substr(i, i + 1).atohex()));
        end
        foreach (p[i]) b.push_back(p[i]);
        c = csi2_crc(p);
        b.push_back(c[7:0]);
        b.push_back(c[15:8]);
      end
      for (int i = 0; i + 1 < ext.len(); i += 2) b.push_back(8'(ext.substr(i, i + 1).atohex()));
      u_tx.push_burst(b, f);
    end
  endfunction

  // ---------------------------------------------------------------- watchdog
  initial begin : watchdog
    int unsigned us;
    if (!$value$plusargs("TIMEOUT_US=%d", us)) us = 20000;
    #(us * 1000.0);
    $fatal(1, "TIMEOUT after %0d us", us);
  end

  // ------------------------------------------------------------------- main
  initial begin : main
    string       line, cmd, key;
    int          fd, n, v, seg, a, d, mask, val, us, k, m;
    logic [31:0] rd, unused;
    realtime     t0;

    if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR=<test case> required");
    fd = $fopen({dir, "/cfg.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/cfg.txt", dir);
    while ($fgets(line, fd)) begin
      if ($sscanf(line, "%s %d", key, v) == 2) set_knob(key, v);
    end
    $fclose(fd);
    out_fd  = $fopen({dir, "/out.txt"}, "w");
    regs_fd = $fopen({dir, "/regs.txt"}, "w");

    // reset with real edges (two-state simulator); invariants count from here
    #1;
    rst_n  = 1'b0;
    vrst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n  = 1'b1;
    vrst_n = 1'b1;
    repeat (5) @(posedge clk);
    seg = 0;
    seg_reset();

    fd = $fopen({dir, "/stim.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/stim.txt", dir);
    while ($fgets(line, fd)) begin
      if ($sscanf(line, "%s", cmd) != 1 || cmd.substr(0, 0) == "#") continue;
      case (cmd)
        "rd": begin
          n = $sscanf(line, "rd %h", a);
          bus_xfer(1'b0, a, '0, rd);
          $fwrite(regs_fd, "rd %03x %08x\n", a, rd);
        end
        "wr": begin
          n = $sscanf(line, "wr %h %h", a, d);
          bus_xfer(1'b1, a, d, unused);
        end
        "wrbe": begin
          n = $sscanf(line, "wrbe %h %h %h", a, d, m);
          bus_xfer(1'b1, a, d, unused, 4'(m));
        end
        "poll": begin
          n = $sscanf(line, "poll %h %h %h %d", a, mask, val, us);
          t0 = csi2_now();
          do begin
            service(10);
            bus_xfer(1'b0, a, '0, rd);
          end while ((rd & mask) != val && csi2_now() - t0 < us * 1000.0);
          $fwrite(regs_fd, "poll %03x %08x\n", a, rd);
        end
        "pkt": begin
          if (u_tx.versal && brst_cfg >= 0 &&
              int'(dut.u_dphy_rx.u_regs.burst_rst_en_q) != brst_cfg) begin
            $fatal(1, "des_rst enable %0d (~CTRL.DES_RST_DIS), the test case has BurstRxRst %0d",
                   dut.u_dphy_rx.u_regs.burst_rst_en_q, brst_cfg);
          end
          push_pkt(line);
        end
        "lp": begin
          n = $sscanf(line, "lp %d %b %d", mask, val, v);
          u_tx.push_lp(mask, 2'(val), v);
        end
        "idle": begin
          n = $sscanf(line, "idle %d", v);
          u_tx.idle(v);
        end
        "clkon": u_tx.clk_on();
        "clkburst": begin
          n = $sscanf(line, "clkburst %d", v);
          u_tx.push_clk_burst(v);
        end
        "wait": begin
          while (u_tx.busy()) service(4);
          // output drained: tvalid low for 1 us (at most 50 us, e.g. tready held low)
          t0 = csi2_now();
          k = 0;
          while (k < 200 && csi2_now() - t0 < 50_000.0) begin
            @(posedge vclk);
            k = m_tvalid ? 0 : k + 1;
          end
          t0 = csi2_now();
          while (csi2_now() - t0 < 1000.0) service(4);
        end
        "delay": begin
          n = $sscanf(line, "delay %d", v);
          t0 = csi2_now();
          while (csi2_now() - t0 < real'(v)) service(4);
        end
        "waitbyte": begin
          n = $sscanf(line, "waitbyte %d %d", k, m);
          wait ((u_tx.cur_burst == k && u_tx.cur_byte >= m) || u_tx.bursts_done > k);
        end
        "irqfe": irq_stop_check();
        "waitphy": begin
          wait (phy_rdy);
          repeat (4) @(posedge clk);
        end
        "tready": n = $sscanf(line, "tready %d", tready_pct);
        "knob": begin
          n = $sscanf(line, "knob %s %d", key, v);
          wait (!u_tx.busy());
          set_knob(key, v);
        end
        "mark": begin
          n = $sscanf(line, "mark %d", v);
          seg_dump(seg);
          seg = v;
          seg_reset();
          $fwrite(regs_fd, "mark %0d\n", v);
          $fwrite(out_fd, "mark %0d\n", v);
        end
        default: ;                                   // nocheck, expect: model only
      endcase
    end
    $fclose(fd);

    // irq_o = |(IRQ_STATUS & IRQ_EN) in the final (static) state
    bus_xfer(1'b0, 32'h014, '0, rd);
    bus_xfer(1'b0, 32'h018, '0, unused);
    $fwrite(regs_fd, "inv %0d irq_bad %0d\n", seg, irq != |(rd & unused));
    seg_dump(seg);
    for (int i = 0; i < u_tx.t_end.size(); i++) begin
      $fwrite(regs_fd, "tend %0d %0d\n", i, longint'(u_tx.t_end[i] * 1000.0));
    end
    $fwrite(regs_fd, "end\n");
    $fclose(regs_fd);
    $fclose(out_fd);
    if (u_tx.ce_bad != 0) $display("tb_bow_csi2rx: first CE open in an LP state of the clock lane at %0.3f ns",
                                   u_tx.t_ce_bad);
    if (irq_stop_n + irq_stop_bad + irq_stop_pre != 0) begin
      $display("tb_bow_csi2rx: irqfe: irq_o rose %0d times with the byte clock stopped (at most %0d ps after its last edge), %0d misses, %0d rises before it",
               irq_stop_n, irq_stop_lat, irq_stop_bad, irq_stop_pre);
    end
`ifdef BOW_SYNC_JITTER
    // the jitter model of bow_sync and of the FIFO pointer synchronisers (make test sums the
    // late resolutions per build and fails a build without any)
    $display("tb_bow_csi2rx: BOW_SYNC_JITTER: %0d synchroniser inputs changed inside the window, %0d resolved one cycle late",
             bow_sync_jitter_pkg::n_window, bow_sync_jitter_pkg::n_late);
`endif
    $display("tb_bow_csi2rx: %0d bursts, %0d lanes - dumps written", u_tx.bursts_done, Lanes);
    if (u_tx.versal) begin
      $display("tb_bow_csi2rx: Versal PHY FIFOs (BurstRxRst %0d, per lane latency %0d): %0d glitch words, %0d read gaps, at most %0d words, wraps %0d/%0d/%0d/%0d",
               u_tx.v_burst_rst, u_tx.v_lat_lane, u_tx.v_glitches, u_tx.v_gaps, u_tx.v_occ_max,
               u_tx.v_wraps[0], u_tx.v_wraps[1], u_tx.v_wraps[2], u_tx.v_wraps[3]);
    end
    $finish;
  end

endmodule
