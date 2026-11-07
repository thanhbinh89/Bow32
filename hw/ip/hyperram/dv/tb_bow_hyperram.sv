// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// IP-level testbench of the Bow32 HyperRAM controller bow_hyperram (the real
// RTL: window, registers, controller, BIST, PHY) against the DV models of
// this directory, Verilator --binary --timing (and xsim), self-checking
// ("tb_bow_hyperram: PASS" / "FAIL"). One Verilator model per configuration
// (parameters below, see the Makefile).
//
// Board side (PhyKind):
//   2  the MPS4 loopback build: bow_hyperram_io_sim (Loopback) + the RTL's
//      emulator bow_hyperram_dev (EmuBytes; its protocol checks: DBG)
//   1  bow_hyperram_io_sim (pads) + hyperram_board_model (HasLs = 1: the
//      FMC+ card with TXV0108 level shifters; 0: direct board) +
//      hyperram_model (S80KS2562 from its data sheet: tIS / tIH / tCSM /
//      tRWR / latency / RWDS / power state checks, independent of the RTL)
// Stub = 1: the DUT is bow_hyperram_stub (HrEn = 0, same ports).
// Every model is instantiated in every configuration (the unused one sees
// idle pins): the testbench reaches the model's backdoor without generate
// scopes. Clocks: clk_i 50 MHz; hyperram_clk_model (hr_clk, write clock,
// read clock at a random start phase, two fine phase shift ports); hr_rst_ni
// = MMCM locked. The pads show the PHY register only once the MMCMs are
// locked (the FPGA's configuration state before: see pin_io).
//
// The IP is driven through its register slot and window exactly like the
// driver sw/common/src/bow_hyperram.c (bow_hr_cmd: wait !BUSY, clear
// CMD_DONE / CMD_ERR, write CMD, poll; the functions below carry the C
// names). The bus transfer and the CMD protocol run in two engine processes
// (Verilator inlines every task call; nested timing tasks with many call
// sites made an 18 MB C++ function). Flow:
//   1  probe: ID, INFO, CLK_HZ, PS_NOW[31:16], EMU, reset values of CTRL /
//      LAT / TIM0 / WB_TMO; the stub: INFO.HR_EN = 0, window bus errors, done
//   2  bow_hr_enable (CTRL / LAT / TIM0 for the PHY kind; TRST / TWAKE matched
//      to the shortened model times), CLK_OK, APPLY; bow_hr_reset (HW_RESET)
//   3  error paths before the calibration: window access before INIT_DONE
//      (bus error, NOT_READY, ERR_ADDR), CMD with two bits (CMD_ERR)
//   4  the rest of bow_hr_init: coarse read sweep (step 8, REG_RD ID0 with
//      CAP_ARM raw capture, RWDS-located first byte A, eye centre,
//      RFIFO_SYNC, RD_DLY from bow_hr_cap_first_a), ID0 / ID1, bow_hr_configure
//      (CR0 latency for the CK, fixed, legacy 32 byte wrap; CR1 -> TCSM),
//      bow_hr_calibrate (ID0 sweep and 32 byte pattern line-fill sweep,
//      step 4), INIT_DONE; the card: bow_hr_calibrate_write (write phase
//      +-HR_WPS_LIMIT = +-3 * PsSteps / 16, step 8; the model's wr_relax hook
//      is set for its duration: the sweep moves CA and data out of tIS / tIH
//      on purpose)
//   5  device registers: REG_RD ID0 / ID1 / CR0 / CR1 against the model and the
//      CR0 / CR1 shadow registers (CR1: the writable bits; a shadow that keeps
//      the read-only [1:0] of its reset value is a NOTE)
//   6  window traffic in all 8 modes of RBUF_EN / WRAP_FILL / WPOST: random
//      byte / halfword / word reads and writes (hot region and the whole
//      device), FLUSH, INVAL, against a byte reference and (pads) the model's
//      backdoor (byte 2n = byte A of word n); RANGE (bus error, ERR_ADDR)
//   7  BIST: PRBS and counter patterns, write + read passes, BIST_ERRS = 0, the
//      device contents against an SV twin of the BIST data (backdoor), window
//      reads of BIST data; a BIST burst longer than TCSM refused (TCSM_ERR,
//      BIST_ERR, BIST_DONE, ERR_CODE[15:8] = 3)
//   7b (pads) FLUSH: the posted block must be in the device when WIN_IDLE
//      reads 1 (24 tries); a posted write right before bow_hr_hybrid_sleep
//      must survive the sleep (6 tries)
//   8  VarLat: variable latency (CR0[3] = 0) traffic and BIST with the model's
//      refresh collisions (2x latency counted by the model and by ST[4])
//   9  hybrid sleep (window refused, WAKE after tHSIN, data kept, CR1[5] back
//      to 0), deep power down (WAKE after tDPDIN, data lost, CR0 back to its
//      default, a read buffer line kept from before is a NOTE,
//      bow_hr_configure again, traffic); IRQ (CMD_DONE); SNAP statistics
//  10  end: no testbench error, model errors 0, board contention / floats 0,
//      emulator DBG 0, STATUS without RD_ERR / WR_ERR / RFIFO_ERR /
//      BUS_TIMEOUT / TCSM_ERR / BROKEN / RFIFO_BROKEN, bus protocol clean
// Observations that are not errors of the configured checks are printed as
// "tb_bow_hyperram: NOTE" and counted at the end.
//
// RTL issues the testbench recognises (and recovers from: CTRL.CORE_RST,
// APPLY, RFIFO_SYNC, INVAL) are reported as "ERROR RTL ISSUE (<tag>)";
// +WAIVE_<tag> reports them as waived instead (tags: BIST_REFUSE: a refused
// BIST burst never ends the run; WIN_IDLE: WIN_IDLE before the posted data is
// in the device; SLEEP_LOSS: a posted write lost by the sleep entry). The
// first two were found by this testbench and fixed in the RTL (2026-11-07:
// bow_hyperram_bist BReq, posted blocks answered and counted by the window);
// the checks stay as regressions.
// Plusargs: +SEED=<n> (traffic; the Makefile passes the same n to the model
// seeds), +RD_HOLD=<n> (TIM0.RD_HOLD of the configuration, default 1),
// +NTRAF=<n> (random window accesses per window mode, default 150),
// +TIMEOUT_MS=<n> (simulated time limit, default 40), +WAVES, +WAIVE_<tag>,
// and the model plusargs (+hyperram_clk_seed, +hyperram_board_seed,
// +hyperram_mem_seed, +hyperram_refresh_pct, +hyperram_oz_free,
// +hyperram_txn_log).

`timescale 1ps / 1ps

// behavioural testbench: blocking assignments in clocked processes, register
// fields read in part and rst_n as both the DUT's reset and a condition are
// intended
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */
module tb_bow_hyperram import bow_bus_pkg::*; import bow_hyperram_pkg::*; #(
  parameter int unsigned PhyKind  = 1,            // 1 pads + board + S80KS2562 model, 2 loopback emulator
  parameter bit          HasLs    = 1'b1,         // PhyKind 1: TXV0108 card, else direct board
  parameter bit          Stub     = 1'b0,         // DUT = bow_hyperram_stub (HrEn = 0)
  parameter int unsigned TckPs    = 10000,
  parameter int unsigned ClkHz    = 100_000_000,
  parameter int unsigned PsSteps  = 672,
  parameter int unsigned EmuBytes = 1 << 20,      // PhyKind 2: emulator storage
  parameter bit          VarLat   = 1'b0          // variable latency traffic (no level shifters)
);

  localparam int unsigned MemBytes  = 32 << 20;   // S80KS2562
  localparam int unsigned TestBytes = (PhyKind == 2) ? EmuBytes : MemBytes;
  localparam logic [31:0] RegBase   = 32'h4000_F000;
  localparam logic [31:0] MemBase   = 32'h6000_0000;
  localparam int unsigned Mhz       = ClkHz / 1_000_000;
  localparam bit          Pads      = (PhyKind == 1);
  // shortened device recovery times (model parameters) and the matching
  // TRST / TWAKE of the controller
  localparam int unsigned TvcsNs    = 20_000;
  localparam int unsigned TextDpdNs = 15_000;
  localparam int unsigned TextHsNs  = 10_000;
  localparam logic [15:0] Id0Val    = 16'h0E86;   // S80KS2562
  localparam logic [15:0] Id1Val    = 16'h0001;   // HyperRAM 2.0

  function automatic int unsigned cyc(longint ns);   // CK cycles in ns, rounded up
    return int'((ns * longint'(ClkHz) + 64'd999_999_999) / 64'd1_000_000_000);
  endfunction

  localparam logic [31:0] TrstVal  = {16'(cyc(22_000)), 16'(cyc(1_000))};   // wait > tVCS left, low 1 us
  localparam logic [31:0] TwakeVal = {16'(cyc(17_000)), 16'(cyc(400))};     // wait > tEXTDPD / tEXTHS, pulse 400 ns

  // ================================================================ clocks
  logic clk = 1'b0, rst_n = 1'b0;
  always #10_000 clk = ~clk;                       // clk_i 50 MHz

  logic ck_on = 1'b0;
  logic hr_clk, wclk, rd_clk, locked;
  logic ps_en, ps_inc, ps_done, wps_en, wps_inc, wps_done;

  hyperram_clk_model #(.TckPs(TckPs), .PsSteps(PsSteps)) u_clk (
    .en_i       (ck_on),
    .hr_clk_o   (hr_clk),
    .wclk_o     (wclk),
    .rd_clk_o   (rd_clk),
    .locked_o   (locked),
    .ps_en_i    (ps_en),
    .ps_inc_i   (ps_inc),
    .ps_done_o  (ps_done),
    .wps_en_i   (wps_en),
    .wps_inc_i  (wps_inc),
    .wps_done_o (wps_done)
  );

  // =================================================================== DUT
  bus_req_t    mem_req = '0, reg_req = '0;
  bus_rsp_t    mem_rsp, reg_rsp;
  logic        irq;
  hr_io_out_t  hr_io_o;
  hr_io_in_t   hr_io_i;
  logic        hr_rwds_pad;
  logic [31:0] hr_dbg;

  if (Stub) begin : g_stub
    bow_hyperram_stub dut (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .mem_req_i     (mem_req),
      .mem_rsp_o     (mem_rsp),
      .reg_req_i     (reg_req),
      .reg_rsp_o     (reg_rsp),
      .irq_o         (irq),
      .hr_clk_i      (hr_clk),
      .hr_rst_ni     (locked),
      .hr_rd_clk_i   (rd_clk),
      .hr_ps_en_o    (ps_en),
      .hr_ps_inc_o   (ps_inc),
      .hr_ps_done_i  (ps_done),
      .hr_wps_en_o   (wps_en),
      .hr_wps_inc_o  (wps_inc),
      .hr_wps_done_i (wps_done),
      .hr_io_o       (hr_io_o),
      .hr_io_i       (hr_io_i),
      .hr_rwds_pad_i (hr_rwds_pad),
      .hr_dbg_i      (hr_dbg)
    );
  end else begin : g_ip
    bow_hyperram #(
      .ClkHz      (ClkHz),
      .PsSteps    (PsSteps),
      .PhyKind    (PhyKind),
      .HasLs      (HasLs),
      .MemBytes   (MemBytes),
      .EmuBytes   ((PhyKind == 2) ? EmuBytes : 0),
      .WinTimeout (1 << 15)
    ) dut (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .mem_req_i     (mem_req),
      .mem_rsp_o     (mem_rsp),
      .reg_req_i     (reg_req),
      .reg_rsp_o     (reg_rsp),
      .irq_o         (irq),
      .hr_clk_i      (hr_clk),
      .hr_rst_ni     (locked),
      .hr_rd_clk_i   (rd_clk),
      .hr_ps_en_o    (ps_en),
      .hr_ps_inc_o   (ps_inc),
      .hr_ps_done_i  (ps_done),
      .hr_wps_en_o   (wps_en),
      .hr_wps_inc_o  (wps_inc),
      .hr_wps_done_i (wps_done),
      .hr_io_o       (hr_io_o),
      .hr_io_i       (hr_io_i),
      .hr_rwds_pad_i (hr_rwds_pad),
      .hr_dbg_i      (hr_dbg)
    );
  end

  // ============================================================ board side
  // The pads show the PHY register once the MMCMs are locked: before that the
  // FPGA holds its configuration state (HR_IO_OUT_IDLE: CS# / RESET# high).
  // (Verilator starts the PHY flops at 0 and applies their asynchronous reset
  // only at the first hr_clk edge: without this, the first cycle would put a
  // CS# / RESET# low glitch on the pins that the hardware cannot show.)
  hr_io_out_t pin_io;
  assign pin_io = locked ? hr_io_o : HR_IO_OUT_IDLE;

  // pad wrapper (loopback in the MPS4 build)
  logic            lb_dq_en, lb_rwds_en, lb_rst_n;
  logic [1:0][7:0] lb_dq;
  logic [1:0]      lb_rwds;
  logic            f_ck_p, f_ck_n, f_cs_n, f_rst_n, f_dq_oe, f_rwds, f_rwds_oe;
  logic            f_ls_oe_n, f_ls_dir_dq, f_ls_dir_rwds, b_rwds;
  logic [7:0]      f_dq, b_dq;

  bow_hyperram_io_sim #(
    .Loopback (PhyKind == 2),
    .HasLs    (Pads && HasLs)
  ) u_io (
    .clk_i         (hr_clk),
    .wclk_i        (wclk),
    .rd_clk_i      (rd_clk),
    .io_o_i        (pin_io),
    .io_i_o        (hr_io_i),
    .rwds_pad_o    (hr_rwds_pad),
    .lb_dq_en_i    (lb_dq_en),
    .lb_dq_i       (lb_dq),
    .lb_rwds_en_i  (lb_rwds_en),
    .lb_rwds_i     (lb_rwds),
    .ck_p_o        (f_ck_p),
    .ck_n_o        (f_ck_n),
    .cs_n_o        (f_cs_n),
    .rst_n_o       (f_rst_n),
    .dq_o          (f_dq),
    .dq_oe_o       (f_dq_oe),
    .dq_i          (b_dq),
    .rwds_o        (f_rwds),
    .rwds_oe_o     (f_rwds_oe),
    .rwds_i        (b_rwds),
    .ls_oe_n_o     (f_ls_oe_n),
    .ls_dir_dq_o   (f_ls_dir_dq),
    .ls_dir_rwds_o (f_ls_dir_rwds)
  );

  // the RTL's emulator (PhyKind 2; else it sees an idle PHY)
  bow_rst_sync u_lb_rst (
    .clk_i  (hr_clk),
    .rst_ni (locked),
    .rst_no (lb_rst_n)
  );

  hr_io_out_t dev_io;
  assign dev_io = (PhyKind == 2) ? pin_io : HR_IO_OUT_IDLE;

  bow_hyperram_dev #(
    .MemBytes   (EmuBytes),
    .UseUram    (1'b0),
    .WaitCycles (cyc(10_000))
  ) u_dev (
    .clk_i        (hr_clk),
    .rst_ni       (lb_rst_n),
    .io_i         (dev_io),
    .lb_dq_en_o   (lb_dq_en),
    .lb_dq_o      (lb_dq),
    .lb_rwds_en_o (lb_rwds_en),
    .lb_rwds_o    (lb_rwds),
    .dbg_o        (hr_dbg)
  );

  // board and S80KS2562 model (PhyKind 1; else idle pins)
  logic       p_ck_p, p_ck_n, p_cs_n, p_rst_n, p_dq_oe, p_rwds, p_rwds_oe, p_ls_oe_n, p_ls_dir_dq, p_ls_dir_rwds;
  logic [7:0] p_dq;
  assign p_ck_p        = Pads ? f_ck_p        : 1'b0;
  assign p_ck_n        = Pads ? f_ck_n        : 1'b1;
  assign p_cs_n        = Pads ? f_cs_n        : 1'b1;
  assign p_rst_n       = Pads ? f_rst_n       : 1'b1;
  assign p_dq          = Pads ? f_dq          : 8'h00;
  assign p_dq_oe       = Pads ? f_dq_oe       : 1'b1;
  assign p_rwds        = Pads ? f_rwds        : 1'b0;
  assign p_rwds_oe     = Pads ? f_rwds_oe     : 1'b1;
  assign p_ls_oe_n     = Pads ? f_ls_oe_n     : 1'b1;
  assign p_ls_dir_dq   = Pads ? f_ls_dir_dq   : 1'b0;
  assign p_ls_dir_rwds = Pads ? f_ls_dir_rwds : 1'b0;

  logic       m_ck, m_ck_n, m_cs_n, m_rst_n, m_dq_drv, m_rwds, m_rwds_drv, d_dq_oe, d_rwds, d_rwds_oe;
  logic [7:0] m_dq, d_dq;

  hyperram_board_model #(.LevelShift(HasLs)) u_brd (
    .ck_p_i         (p_ck_p),
    .ck_n_i         (p_ck_n),
    .cs_n_i         (p_cs_n),
    .rst_n_i        (p_rst_n),
    .dq_i           (p_dq),
    .dq_oe_i        (p_dq_oe),
    .dq_o           (b_dq),
    .rwds_i         (p_rwds),
    .rwds_oe_i      (p_rwds_oe),
    .rwds_o         (b_rwds),
    .ls_oe_n_i      (p_ls_oe_n),
    .ls_dir_dq_i    (p_ls_dir_dq),
    .ls_dir_rwds_i  (p_ls_dir_rwds),
    .mem_ck_o       (m_ck),
    .mem_ck_n_o     (m_ck_n),
    .mem_cs_n_o     (m_cs_n),
    .mem_rst_n_o    (m_rst_n),
    .mem_dq_o       (m_dq),
    .mem_dq_drv_o   (m_dq_drv),
    .mem_dq_i       (d_dq),
    .mem_dq_oe_i    (d_dq_oe),
    .mem_rwds_o     (m_rwds),
    .mem_rwds_drv_o (m_rwds_drv),
    .mem_rwds_i     (d_rwds),
    .mem_rwds_oe_i  (d_rwds_oe)
  );

  hyperram_model #(
    .MemBytes  (MemBytes),
    .TvcsNs    (TvcsNs),
    .TextDpdNs (TextDpdNs),
    .TextHsNs  (TextHsNs)
  ) u_hr (
    .ck_i       (m_ck),
    .ck_n_i     (m_ck_n),
    .cs_n_i     (m_cs_n),
    .rst_n_i    (m_rst_n),
    .dq_i       (m_dq),
    .dq_drv_i   (m_dq_drv),
    .dq_o       (d_dq),
    .dq_oe_o    (d_dq_oe),
    .rwds_i     (m_rwds),
    .rwds_drv_i (m_rwds_drv),
    .rwds_o     (d_rwds),
    .rwds_oe_o  (d_rwds_oe)
  );

  // ================================================================ errors
  int tb_errs = 0, proto_errs = 0, notes = 0, rtl_issues = 0, rtl_waived = 0;

  // conditional text (string operands: no padding of the shorter literal)
  function automatic string pick(bit c, string a, string b);
    if (c) return a;
    return b;
  endfunction

  task automatic error(string msg);
    tb_errs++;
    $display("%0t ps: tb_bow_hyperram: ERROR %s", $time, msg);
  endtask

  task automatic info(string msg);
    $display("%0t ps: tb_bow_hyperram: %s", $time, msg);
  endtask

  task automatic note(string msg);
    notes++;
    $display("%0t ps: tb_bow_hyperram: NOTE %s", $time, msg);
  endtask

  // a known kind of RTL failure: an error, unless +WAIVE_<tag> (then reported
  // as waived); the test recovers and goes on either way
  // (literal plusargs: xelab 2025.2 aborts on $test$plusargs of a concatenation)
  task automatic rtl_issue(string tag, string msg);
    bit waived;
    rtl_issues++;
    unique case (tag)
      "BIST_REFUSE": waived = $test$plusargs("WAIVE_BIST_REFUSE");
      "WIN_IDLE":    waived = $test$plusargs("WAIVE_WIN_IDLE");
      "SLEEP_LOSS":  waived = $test$plusargs("WAIVE_SLEEP_LOSS");
      default:       waived = 1'b0;
    endcase
    if (waived) begin
      rtl_waived++;
      $display("%0t ps: tb_bow_hyperram: WAIVED RTL ISSUE (%s) %s", $time, tag, msg);
    end else begin
      tb_errs++;
      $display("%0t ps: tb_bow_hyperram: ERROR RTL ISSUE (%s) %s", $time, tag, msg);
    end
  endtask

  // =============================================================== random
  int unsigned trng = 1;
  function automatic int unsigned trnd();
    trng ^= trng << 13;
    trng ^= trng >> 17;
    trng ^= trng << 5;
    return trng;
  endfunction

  // ============================================================== bus BFMs
  // one access at a time, request held until gnt, the answer taken in the
  // cycle after the transfer (rvalid). The transfer itself runs in one engine
  // process (level handshake bx_busy): Verilator inlines every task call and
  // cannot keep a task that touches module variables out of line, so the
  // timing code lives once and the call sites stay small.
  localparam bit PMem = 1'b0, PReg = 1'b1;
  localparam int unsigned GntTmo = (1 << 15) + 256;

  bit          bx_busy = 1'b0, bx_port = 1'b0, bx_we = 1'b0, bx_err = 1'b0;
  logic [31:0] bx_addr = '0, bx_wdata = '0, bx_rdata = '0;
  logic [3:0]  bx_be = '0;

  initial begin : bus_engine
    bus_req_t    r;
    bit          g;
    int unsigned w;
    forever begin
      wait (bx_busy);
      r       = '0;
      r.req   = 1'b1;
      r.we    = bx_we;
      r.be    = bx_be;
      r.addr  = bx_addr;
      r.wdata = bx_wdata;
      @(posedge clk);
      #1;
      if (bx_port == PMem) mem_req = r;
      else                 reg_req = r;
      w = 0;
      do begin
        @(negedge clk);
        g = (bx_port == PMem) ? mem_rsp.gnt : reg_rsp.gnt;
        @(posedge clk);
        #1;
        if (++w > GntTmo) $fatal(1, "tb_bow_hyperram: port %0d access %08h: no gnt for %0d cycles", bx_port,
                                 bx_addr, w);
      end while (!g);
      if (bx_port == PMem) mem_req = '0;
      else                 reg_req = '0;
      @(negedge clk);
      if (bx_port == PMem) begin
        bx_rdata = mem_rsp.rdata;
        bx_err   = mem_rsp.err;
      end else begin
        bx_rdata = reg_rsp.rdata;
        bx_err   = reg_rsp.err;
      end
      bx_busy = 1'b0;
    end
  end

  task automatic bus_xfer(input bit port, input bit we, input logic [31:0] addr, input logic [31:0] wdata,
                          input logic [3:0] be, output logic [31:0] rdata, output bit err);
    wait (!bx_busy);
    bx_port  = port;
    bx_we    = we;
    bx_addr  = addr;
    bx_wdata = wdata;
    bx_be    = be;
    bx_busy  = 1'b1;
    wait (!bx_busy);
    rdata = bx_rdata;
    err   = bx_err;
  endtask

  // rvalid exactly one cycle after req && gnt, on both ports
  logic [1:0] xfer_q = '0;
  always @(posedge clk) begin
    if (rst_n) begin
      if (mem_rsp.rvalid !== xfer_q[0]) begin
        proto_errs++;
        $display("%0t ps: tb_bow_hyperram: ERROR window rvalid %b, transfer in the previous cycle %b", $time,
                 mem_rsp.rvalid, xfer_q[0]);
      end
      if (reg_rsp.rvalid !== xfer_q[1]) begin
        proto_errs++;
        $display("%0t ps: tb_bow_hyperram: ERROR register rvalid %b, transfer in the previous cycle %b", $time,
                 reg_rsp.rvalid, xfer_q[1]);
      end
    end
    xfer_q[0] = mem_req.req && mem_rsp.gnt;
    xfer_q[1] = reg_req.req && reg_rsp.gnt;
  end

  task automatic reg_wr(input logic [11:0] off, input logic [31:0] v);
    logic [31:0] d;
    bit          e;
    bus_xfer(PReg, 1'b1, RegBase | 32'(off), v, 4'hF, d, e);
    if (e) error($sformatf("register write %03h answered with a bus error", off));
  endtask

  task automatic reg_rd(input logic [11:0] off, output logic [31:0] v);
    bit e;
    bus_xfer(PReg, 1'b0, RegBase | 32'(off), '0, 4'hF, v, e);
    if (e) error($sformatf("register read %03h answered with a bus error", off));
  endtask

  // window access at a byte offset: word aligned address, byte enables (like Ibex)
  task automatic win_rd(input logic [31:0] off, output logic [31:0] v, output bit err);
    bus_xfer(PMem, 1'b0, MemBase + (off & ~32'd3), '0, 4'hF, v, err);
  endtask

  task automatic win_wr(input logic [31:0] off, input logic [31:0] v, input logic [3:0] be, output bit err);
    logic [31:0] d;
    bus_xfer(PMem, 1'b1, MemBase + (off & ~32'd3), v, be, d, err);
  endtask

  // ============================================================== driver
  // bow_hyperram.c, register for register (timeouts in simulated time)
  localparam longint CmdTmoPs = 64'd3_000_000_000;    // 3 ms

  logic [31:0] st_last;

  task automatic hr_st(output logic [31:0] st);
    reg_rd(RegStatusOff, st);
    st_last = st;
  endtask

  // bow_hr_cmd with the raw CMD value (in its own engine process, like the bus)
  bit          cx_busy = 1'b0, cx_ok = 1'b0;
  logic [31:0] cx_cmd = '0;

  initial begin : cmd_engine
    logic [31:0] st;
    longint      t0;
    bit          done;
    forever begin
      wait (cx_busy);
      cx_ok = 1'b0;
      done  = 1'b0;
      t0    = $time;
      do begin
        hr_st(st);
        if ($time - t0 > CmdTmoPs) done = 1'b1;
      end while (st[StBusy] && !done);
      if (!done) begin
        reg_wr(RegStatusOff, (32'd1 << StCmdDone) | (32'd1 << StCmdErr));
        reg_wr(RegCmdOff, cx_cmd);
        t0 = $time;
        while (!done) begin
          hr_st(st);
          if ((st[StCmdDone] || st[StCmdErr]) && !st[StBusy]) begin
            cx_ok = st[StCmdDone] && !st[StCmdErr];
            done  = 1'b1;
          end else if ($time - t0 > CmdTmoPs) begin
            done = 1'b1;
          end
        end
      end
      cx_busy = 1'b0;
    end
  end

  task automatic hr_cmd_raw(input logic [31:0] c, output bit ok);
    wait (!cx_busy);
    cx_cmd  = c;
    cx_busy = 1'b1;
    wait (!cx_busy);
    ok = cx_ok;
  endtask

  task automatic hr_cmd(input int unsigned bitn, output bit ok);
    hr_cmd_raw(32'd1 << bitn, ok);
  endtask

  task automatic hr_cmd_must(input int unsigned bitn, input string what);
    bit ok;
    hr_cmd(bitn, ok);
    if (!ok) error($sformatf("command %s failed (STATUS %08h)", what, st_last));
  endtask

  task automatic hr_reg_read(input int unsigned sel, output logic [15:0] v, output bit ok);
    logic [31:0] d;
    reg_wr(RegSelOff, 32'(sel));
    hr_cmd(CmdRegRd, ok);
    reg_rd(RegDataOff, d);
    v = d[15:0];
  endtask

  task automatic hr_reg_write(input int unsigned sel, input logic [15:0] v, output bit ok);
    reg_wr(RegSelOff, 32'(sel));
    reg_wr(RegDataOff, 32'(v));
    hr_cmd(CmdRegWr, ok);
  endtask

  function automatic int unsigned cr0_l(logic [15:0] c0);
    unique case (c0[7:4])
      4'hE:    return 3;
      4'hF:    return 4;
      4'h0:    return 5;
      4'h1:    return 6;
      default: return 7;
    endcase
  endfunction

  function automatic logic [3:0] lat_code(int unsigned l);
    unique case (l)
      3:       return 4'hE;
      4:       return 4'hF;
      5:       return 4'h0;
      6:       return 4'h1;
      default: return 4'h2;
    endcase
  endfunction

  // first data cycle of a read (CR0 shadow)
  task automatic hr_td(output int unsigned td);
    logic [31:0] c0;
    reg_rd(RegCr0Off, c0);
    td = c0[3] ? 2 * cr0_l(c0[15:0]) + 3 : cr0_l(c0[15:0]) + 3;
  endtask

  task automatic phase_now(output int p);
    logic [31:0] v;
    reg_rd(RegPsNowOff, v);
    p = int'($signed(v[15:0]));
  endtask

  task automatic wphase_now(output int p);
    logic [31:0] v;
    reg_rd(RegWpsNowOff, v);
    p = int'($signed(v[15:0]));
  endtask

  task automatic hr_set_phase(input int p, output bit ok);
    reg_wr(RegPsTgtOff, 32'(p) & 32'hFFFF);
    hr_cmd(CmdPsGo, ok);
  endtask

  task automatic hr_set_wphase(input int p, output bit ok);
    reg_wr(RegWpsTgtOff, 32'(p) & 32'hFFFF);
    hr_cmd(CmdWpsGo, ok);
  endtask

  // CTRL[11:9]
  task automatic hr_window(input bit rbuf, input bit wrap, input bit posted);
    logic [31:0] c;
    reg_rd(RegCtrlOff, c);
    c[CtrlRbufEn]   = rbuf;
    c[CtrlWrapFill] = wrap;
    c[CtrlWpost]    = posted;
    reg_wr(RegCtrlOff, c);
  endtask

  // poll STATUS until (STATUS & mask) == value, at most tmo ps (no return
  // inside a loop that waits: the xsim 2025.2 kernel aborts on it)
  task automatic wait_st(input logic [31:0] mask, input logic [31:0] value, input longint tmo, output bit ok);
    logic [31:0] st;
    longint      t0;
    t0 = $time;
    do begin
      hr_st(st);
    end while ((st & mask) != value && $time - t0 <= tmo);
    ok = (st & mask) == value;
  endtask

  task automatic hr_flush(output bit ok);
    hr_cmd(CmdFlush, ok);
    if (ok) wait_st(32'd1 << StWinIdle, 32'd1 << StWinIdle, CmdTmoPs, ok);
  endtask

  // ------------------------------------------------------- configuration
  typedef struct {
    int unsigned lat;
    bit          fixed;
    logic [31:0] ctrl, lat_reg, tim0;
  } hr_cfg_t;

  hr_cfg_t cfg;
  int      rd_hold = 1;

  function automatic logic [31:0] lat_val(int lead, int tail, int pre, int post, int rw_dir, int rw_oe, int arm,
                                          int dly);
    return 32'(lead) | (32'(tail) << 4) | (32'(pre) << 8) | (32'(post) << 10) | (32'(rw_dir) << 12) |
           (32'(rw_oe) << 16) | (32'(arm) << 20) | (32'(dly) << 24);
  endfunction

  // bow_hr_config_for
  task automatic hr_config_for(output hr_cfg_t c);
    int unsigned tcsm, cshi;
    c.lat   = (Mhz <= 85) ? 3 : (Mhz <= 104) ? 4 : (Mhz <= 133) ? 5 : (Mhz <= 166) ? 6 : 7;
    c.fixed = 1'b1;
    c.ctrl  = (32'd1 << CtrlEn) | (32'd1 << CtrlIdleDrive) | (32'd1 << CtrlStrict) | (32'd1 << CtrlRbufEn) |
              (32'd1 << CtrlWrapFill) | (32'd1 << CtrlWpost) | ((Pads && HasLs) ? (32'd1 << CtrlLsEn) : 32'd0);
    if (PhyKind == 2)        c.lat_reg = lat_val(2, 1, 1, 1, 4, 5, 3, 0);
    else if (HasLs)          c.lat_reg = lat_val(2, 2, 1, 1, 5, 6, 3, 0);
    else                     c.lat_reg = lat_val(2, 1, 1, 1, 4, 5, 3, 0);
    tcsm   = Mhz - 5;
    cshi   = (35 * Mhz + 999) / 1000;
    if (cshi < 1) cshi = 1;
    c.tim0 = 32'(tcsm) | (32'(cshi) << 12) | (32'((c.lat >= 4) ? 6 : 5) << 16) | (32'd12 << 20) |
             (32'(rd_hold) << 24);
  endtask

  // bow_hr_enable (+ TRST / TWAKE for the shortened model times)
  task automatic hr_enable(input hr_cfg_t c, output bit ok);
    logic [31:0] ctrl;
    reg_rd(RegCtrlOff, ctrl);
    reg_wr(RegCtrlOff, (c.ctrl & ~(32'd1 << CtrlInitDone)) | (ctrl & (32'd1 << CtrlInitDone)));
    reg_wr(RegLatOff, c.lat_reg);
    reg_wr(RegTim0Off, c.tim0);
    reg_wr(RegTrstOff, TrstVal);
    reg_wr(RegTwakeOff, TwakeVal);
    wait_st(32'd1 << StClkOk, 32'd1 << StClkOk, 64'd10_000_000_000, ok);
    if (ok) hr_cmd(CmdApply, ok);
  endtask

  // bow_hr_configure
  task automatic hr_configure(inout hr_cfg_t c, output bit ok);
    logic [15:0] cr0, rd0, cr1;
    logic [31:0] hz;
    int unsigned us, tcsm;
    cr0 = 16'h8000 | 16'h0F00 | (16'(lat_code(c.lat)) << 4) | (c.fixed ? 16'h0008 : 16'h0) | 16'h0004 | 16'h0003;
    hr_reg_write(2, cr0, ok);
    if (!ok) return;
    hr_reg_read(2, rd0, ok);
    if (!ok || rd0 != cr0) begin
      ok = 1'b0;
      return;
    end
    hr_reg_read(3, cr1, ok);
    if (!ok) return;
    us = (cr1[1:0] == 2'b01) ? 4 : 1;
    reg_rd(RegClkHzOff, hz);
    tcsm = hz / 1_000_000 * us - 5;
    if (tcsm > 4095) tcsm = 4095;
    c.tim0 = (c.tim0 & ~32'hFFF) | 32'(tcsm);
    reg_wr(RegTim0Off, c.tim0);
    hr_cmd(CmdApply, ok);
  endtask

  // ----------------------------------------------------------- capture
  logic [31:0] cap [64];

  function automatic bit cap_rw(int s);
    return (s % 2 != 0) ? cap[s / 2][17] : cap[s / 2][16];
  endfunction

  function automatic logic [7:0] cap_dq(int s);
    return (s % 2 != 0) ? cap[s / 2][15:8] : cap[s / 2][7:0];
  endfunction

  // bow_hr_cap_first_a
  function automatic int cap_first_a(int unsigned from);
    int unsigned lows;
    lows = 0;
    for (int s = 0; s + 1 < 128; s++) begin
      if (!cap_rw(s)) begin
        if (lows < 2) lows++;
      end else begin
        if (lows >= 2 && s >= 2 * int'(from) && !cap_rw(s + 1)) return s;
        lows = 0;
      end
    end
    return -1;
  endfunction

  localparam logic [7:0] CalPattern [32] = '{
    8'h00, 8'hFF, 8'h55, 8'hAA, 8'h33, 8'hCC, 8'h0F, 8'hF0, 8'hFF, 8'h00, 8'hAA, 8'h55, 8'hCC, 8'h33, 8'hF0, 8'h0F,
    8'h01, 8'hFE, 8'h80, 8'h7F, 8'h96, 8'h69, 8'hA5, 8'h5A, 8'h3C, 8'hC3, 8'h18, 8'hE7, 8'h81, 8'h7E, 8'h24, 8'hDB};

  // cap_match: kind 0 = ID0 (0E 86), 1 = the calibration pattern (32 bytes)
  function automatic bit cap_match(int s, int kind);
    int unsigned n;
    logic [7:0]  e;
    n = (kind == 0) ? 2 : 32;
    if (s < 0 || s + int'(n) > 128) return 1'b0;
    for (int k = 0; k < int'(n); k++) begin
      if (kind == 0) e = (k == 0) ? 8'h0E : 8'h86;
      else           e = CalPattern[k];
      if (cap_rw(s + k) != ((k % 2 != 0) ? 1'b0 : 1'b1) || cap_dq(s + k) != e) return 1'b0;
    end
    return 1'b1;
  endfunction

  task automatic read_cap();
    for (int i = 0; i < 64; i++) reg_rd(RegCapOff + 12'(4 * i), cap[i]);
  endtask

  task automatic wait_cap(output bit ok);
    wait_st(32'd1 << StCapDone, 32'd1 << StCapDone, 64'd100_000_000, ok);
  endtask

  // bow_hr_capture_reg
  task automatic hr_capture_reg(input int unsigned sel, output bit ok);
    logic [15:0] v;
    bit          rd;
    reg_wr(RegStatusOff, 32'd1 << StCapDone);
    hr_cmd(CmdCapArm, ok);
    if (!ok) return;
    hr_reg_read(sel, v, rd);                         // may fail before calibration
    wait_cap(ok);
    if (!ok) return;
    read_cap();
  endtask

  // --------------------------------------------------------- calibration
  typedef struct {
    int          phase;
    int unsigned width, points, good, rd_dly, first_half;
    int          wphase;
    int unsigned wwidth;
  } hr_cal_t;

  hr_cal_t cal;
  bit      good_pts [$];

  task automatic longest_run(output int unsigned start, output int unsigned len);
    int unsigned n, best, best_s, l;
    n      = good_pts.size();
    best   = 0;
    best_s = 0;
    for (int unsigned s = 0; s < n; s++) begin
      if (!good_pts[s] || good_pts[(s + n - 1) % n]) continue;
      l = 0;
      while (l < n && good_pts[(s + l) % n]) l++;
      if (l > best) begin
        best   = l;
        best_s = s;
      end
    end
    if (best == 0 && n != 0 && good_pts[0]) best = n;
    start = best_s;
    len   = best;
  endtask

  function automatic string eye_map();
    string m;
    m = "";
    foreach (good_pts[k]) m = {m, pick(good_pts[k], "#", ".")};
    return m;
  endfunction

  // sweep point: kind 0 ID0 register read, 1 line fill of the pattern at offset 0
  task automatic sweep_point(input int kind, input int unsigned td, output bit good, output int first);
    bit          ok, e;
    logic [31:0] v;
    good  = 1'b0;
    first = -1;
    if (kind == 0) begin
      hr_capture_reg(0, ok);
      if (!ok) return;
      first = cap_first_a(td);
      good  = cap_match(first, 0);
      return;
    end
    reg_wr(RegStatusOff, 32'd1 << StCapDone);
    hr_cmd(CmdInval, ok);
    if (!ok) return;
    hr_cmd(CmdCapArm, ok);
    if (!ok) return;
    win_rd(32'd0, v, e);                              // a line fill, wrapped from word 0
    wait_cap(ok);
    if (!ok) return;
    read_cap();
    first = cap_first_a(td);
    good  = cap_match(first, 1);
  endtask

  task automatic set_rd_dly(input int unsigned d, output bit ok);
    logic [31:0] l;
    reg_rd(RegLatOff, l);
    reg_wr(RegLatOff, (l & ~(32'h1F << 24)) | (32'(d & 32'h1F) << 24));
    hr_cmd(CmdApply, ok);
  endtask

  task automatic sweep(input int kind, input int unsigned step, output bit ok);
    logic [31:0] v;
    int unsigned steps, td, s, len, gcount, dly;
    int          base, centre, first, p;
    bit          good;
    reg_rd(RegPsNowOff, v);
    steps = 32'(v[31:16]);
    phase_now(base);
    hr_td(td);
    if (step == 0) step = 4;
    good_pts.delete();
    hr_cmd(CmdRfifoSync, ok);
    if (!ok) return;
    for (int unsigned q = 0; ok && q < steps && good_pts.size() < 1024; q += step) begin
      hr_set_phase(base + int'(q), ok);
      if (ok) begin
        sweep_point(kind, td, good, first);
        good_pts.push_back(good);
      end
    end
    if (!ok) return;
    longest_run(s, len);
    gcount = 0;
    foreach (good_pts[k]) gcount += 32'(good_pts[k]);
    info($sformatf("eye (%s) |%s|", pick(kind != 0, "pattern", "ID0"), eye_map()));
    cal.points = good_pts.size();
    cal.good   = gcount;
    if (len == 0) begin
      ok = 1'b0;
      return;
    end
    centre    = base + int'(((s + len / 2) % good_pts.size()) * step);
    cal.width = len * step;
    if (centre - base > int'(steps) / 2) centre -= int'(steps);
    hr_set_phase(centre, ok);
    if (!ok) return;
    hr_cmd(CmdRfifoSync, ok);
    if (!ok) return;
    phase_now(p);
    cal.phase = p;
    sweep_point(kind, td, good, first);
    if (!good) begin
      ok = 1'b0;
      return;
    end
    dly = int'(first) / 2;
    if (dly < td || dly - td > 31) begin
      ok = 1'b0;
      return;
    end
    cal.rd_dly     = dly - td;
    cal.first_half = int'(first);
    set_rd_dly(cal.rd_dly, ok);
  endtask

  task automatic write_pattern(output bit ok);
    logic [31:0] w;
    bit          e;
    ok = 1'b1;
    for (int i = 0; ok && i < 8; i++) begin
      w = {CalPattern[4 * i + 3], CalPattern[4 * i + 2], CalPattern[4 * i + 1], CalPattern[4 * i]};
      win_wr(32'(4 * i), w, 4'hF, e);
      if (e) ok = 1'b0;
    end
    if (ok) hr_flush(ok);
  endtask

  task automatic check_pattern(output bit ok);
    logic [31:0] w, v;
    bit          e;
    ok = 1'b1;
    for (int i = 0; ok && i < 8; i++) begin
      w = {CalPattern[4 * i + 3], CalPattern[4 * i + 2], CalPattern[4 * i + 1], CalPattern[4 * i]};
      win_rd(32'(4 * i), v, e);
      if (e || v != w) ok = 1'b0;
    end
  endtask

  // bow_hr_calibrate
  task automatic hr_calibrate(input int unsigned step, output bit ok);
    logic [15:0] v;
    logic [31:0] ctrl;
    bit          r;
    int          wp;
    sweep(0, step, ok);
    if (!ok) begin
      error($sformatf("calibration: no ID0 eye (%0d of %0d points)", cal.good, cal.points));
      return;
    end
    hr_reg_read(0, v, ok);
    if (!ok || v != Id0Val) begin
      error($sformatf("calibration: ID0 %04h at phase %0d", v, cal.phase));
      ok = 1'b0;
      return;
    end
    reg_rd(RegCtrlOff, ctrl);
    reg_wr(RegCtrlOff, ctrl | (32'd1 << CtrlInitDone));
    write_pattern(ok);
    if (ok) sweep(1, step, ok);
    if (ok) hr_cmd(CmdInval, ok);
    if (ok) check_pattern(ok);
    if (ok) begin
      hr_reg_read(0, v, r);
      ok = r && v == Id0Val;
    end
    reg_wr(RegCtrlOff, ok ? (ctrl | (32'd1 << CtrlInitDone)) : (ctrl & ~(32'd1 << CtrlInitDone)));
    wphase_now(wp);
    cal.wphase = wp;
    if (ok) begin
      info($sformatf("read phase %0d width %0d RD_DLY %0d (first byte A at half cycle %0d)", cal.phase,
                     cal.width, cal.rd_dly, cal.first_half));
    end else begin
      error($sformatf("calibration failed: pattern eye (%0d of %0d points)", cal.good, cal.points));
    end
  endtask

  // bow_hr_calibrate_write
  task automatic hr_calibrate_write(input int unsigned step, output bit ok);
    logic [31:0] v;
    int          lim, old, w, wp;
    int unsigned s, len;
    logic [15:0] id;
    bit          r, g;
    reg_rd(RegWpsNowOff, v);
    lim = int'((3 * v[31:16]) / 16);                   // HR_WPS_LIMIT (the controller refuses beyond)
    wphase_now(old);
    if (step == 0) step = 8;
    good_pts.delete();
    for (w = -lim; w <= lim; w += int'(step)) begin
      hr_set_wphase(w, r);
      g = 1'b0;
      if (r) begin
        write_pattern(g);
        if (g) hr_cmd(CmdInval, g);
        if (g) check_pattern(g);
        if (g) begin
          hr_reg_read(0, id, g);
          g = g && id == Id0Val;
        end
      end
      good_pts.push_back(g);
    end
    longest_run(s, len);
    info($sformatf("write eye |%s|", eye_map()));
    if (len == 0) begin
      hr_set_wphase(old, r);
      ok = 1'b0;
      return;
    end
    w = -lim + int'((s + len / 2) % good_pts.size() * step);
    hr_set_wphase(w, ok);
    if (ok) write_pattern(ok);
    if (ok) hr_cmd(CmdInval, ok);
    if (ok) check_pattern(ok);
    wphase_now(wp);
    cal.wphase = wp;
    cal.wwidth = len * step;
    info($sformatf("write phase %0d width %0d", wp, len * step));
  endtask

  // bow_hr_init (from the enable on)
  task automatic hr_init(output bit ok);
    logic [15:0] id0, id1;
    logic [31:0] ctrl;
    reg_rd(RegCtrlOff, ctrl);
    reg_wr(RegCtrlOff, ctrl & ~(32'd1 << CtrlInitDone));
    sweep(0, 8, ok);
    if (!ok) begin
      error($sformatf("init: no ID0 eye (%0d of %0d points)", cal.good, cal.points));
      return;
    end
    hr_reg_read(0, id0, ok);
    if (ok) hr_reg_read(1, id1, ok);
    if (!ok || id0 != Id0Val || id1 != Id1Val) begin
      error($sformatf("init: ID0 %04h ID1 %04h", id0, id1));
      ok = 1'b0;
      return;
    end
    hr_configure(cfg, ok);
    if (!ok) begin
      error("init: CR0 / CR1 configuration failed");
      return;
    end
    hr_calibrate(4, ok);
    if (!ok) return;
    reg_rd(RegLatOff, cfg.lat_reg);
  endtask

  // ------------------------------------------------------------------- BIST
  longint bist_tmo_ps = 64'd2_000_000_000;          // 2 ms

  task automatic hr_bist(input int unsigned waddr, input int unsigned words, input int unsigned burst,
                         input int unsigned mode, input logic [31:0] seed, output bit ok,
                         output logic [31:0] errs);
    logic [31:0] v;
    reg_wr(RegBAddrOff, 32'(waddr));
    reg_wr(RegBLenOff, 32'(words));
    reg_wr(RegBSeedOff, seed);
    reg_wr(RegBCtrlOff, 32'(mode & 7) | ((32'(burst) & 32'hFF) << 8));
    reg_wr(RegStatusOff, (32'd1 << StBistDone) | (32'd1 << StBistErr));
    hr_cmd(CmdBistGo, ok);
    errs = '1;
    if (ok) wait_st(32'd1 << StBistDone, 32'd1 << StBistDone, bist_tmo_ps, ok);
    if (ok) begin
      reg_rd(RegBErrsOff, errs);
      reg_rd(RegStatusOff, v);
      ok = !v[StBistErr] && errs == 0;
    end
  endtask

  task automatic hr_bist_burst_max(output int unsigned n);
    logic [31:0] c0, t0;
    int unsigned tcsm, td2;
    reg_rd(RegCr0Off, c0);
    reg_rd(RegTim0Off, t0);
    tcsm = 32'(t0[11:0]);
    td2  = 2 * cr0_l(c0[15:0]) + 3 + 32'(t0[25:24]);
    n    = (tcsm > td2) ? tcsm - td2 : 1;
    if (n > 255) n = 255;
  endtask

  // the BIST data of word k (an SV twin of bow_hyperram_bist: PRBS = the
  // xorshift32 state from the seed (0 -> 1) before k steps, counter = word
  // address ^ seed; byte A = data[7:0])
  function automatic logic [31:0] xs32(logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13);
    y = y ^ (y >> 17);
    y = y ^ (y << 5);
    return y;
  endfunction

  // --------------------------------------------------------------- power
  task automatic wait_power(input logic [1:0] pwr, output bit ok);
    wait_st(32'd3 << StPwr0, 32'(pwr) << StPwr0, CmdTmoPs, ok);
  endtask

  task automatic hr_hybrid_sleep(output bit ok);
    logic [31:0] c1;
    hr_flush(ok);
    if (!ok) return;
    reg_rd(RegCr1Off, c1);
    hr_reg_write(3, c1[15:0] | 16'h0020, ok);
    if (ok) wait_power(PwrHs, ok);
  endtask

  task automatic hr_deep_power_down(output bit ok);
    logic [31:0] c0;
    hr_flush(ok);
    if (!ok) return;
    reg_rd(RegCr0Off, c0);
    hr_reg_write(2, c0[15:0] & ~16'h8000, ok);
    if (ok) wait_power(PwrDpd, ok);
  endtask

  task automatic hr_wake(output bit ok);
    hr_cmd(CmdWake, ok);
    if (ok) wait_power(PwrActive, ok);
  endtask

  // channel reset (CTRL.CORE_RST) and back: APPLY, RFIFO_SYNC, INVAL, READY
  task automatic hr_recover(output bit ok);
    logic [31:0] c, st;
    reg_rd(RegCtrlOff, c);
    reg_wr(RegCtrlOff, c | (32'd1 << CtrlCoreRst));
    repeat (32) @(posedge clk);
    reg_wr(RegCtrlOff, c & ~(32'd1 << CtrlCoreRst));
    wait_st(32'd1 << StClkOk, 32'd1 << StClkOk, 64'd10_000_000_000, ok);
    if (ok) hr_cmd(CmdApply, ok);
    if (ok) hr_cmd(CmdRfifoSync, ok);
    if (ok) hr_cmd(CmdInval, ok);
    reg_rd(RegStatusOff, st);
    ok = ok && st[StReady];
  endtask

  // ===================================================== reference memory
  logic [7:0] ref_b [int unsigned];      // window byte offset -> byte

  // the byte the window must return: the reference, else (pads) the device
  // (the model's backdoor: an uninitialised word reads its pattern), else
  // unknown (emulator)
  function automatic bit exp_byte(int unsigned off, output logic [7:0] b);
    if (ref_b.exists(off) != 0) begin
      b = ref_b[off];
      return 1'b1;
    end
    if (Pads) begin
      b = u_hr.peek_byte(off);
      return 1'b1;
    end
    b = 8'h00;
    return 1'b0;
  endfunction

  task automatic check_word(input logic [31:0] off, input logic [31:0] v, input logic [3:0] be,
                            input string what);
    logic [7:0] e;
    int         bad;
    bad = 0;
    for (int b = 0; b < 4; b++) begin
      if (be[b] && exp_byte((off & ~32'd3) + 32'(b), e) && v[8 * b +: 8] !== e) bad++;
    end
    if (bad != 0) begin
      logic [31:0] ew;
      for (int b = 0; b < 4; b++) begin
        if (!exp_byte((off & ~32'd3) + 32'(b), e)) e = 8'hxx;
        ew[8 * b +: 8] = e;
      end
      error($sformatf("%s: window offset %07h read %08h, expected %08h (be %b)", what, off & ~32'd3, v, ew, be));
    end
  endtask

  // the device contents against the reference (pads: the model's backdoor),
  // after FLUSH (posted data in the device)
  task automatic model_check(input string what);
    int n, bad;
    if (!Pads) return;
    #(64'd2_000_000);                                // posted data in flight after WIN_IDLE (race test)
    n   = 0;
    bad = 0;
    foreach (ref_b[k]) begin
      n++;
      if (u_hr.peek_byte(k) !== ref_b[k]) begin
        bad++;
        if (bad <= 4) error($sformatf("%s: device byte %07h = %02h, reference %02h", what, k, u_hr.peek_byte(k),
                                      ref_b[k]));
      end
    end
    if (bad == 0) info($sformatf("%s: %0d bytes of the device match the reference", what, n));
  endtask

  // ---------------------------------------------------------------- traffic
  int unsigned n_traf = 150;
  int          n_rd = 0, n_wr = 0;

  task automatic win_write_ref(input logic [31:0] off, input logic [31:0] v, input logic [3:0] be,
                               input string what);
    bit e;
    win_wr(off, v, be, e);
    n_wr++;
    if (e) error($sformatf("%s: window write %07h answered with a bus error", what, off));
    for (int b = 0; b < 4; b++) if (be[b]) ref_b[(off & ~32'd3) + 32'(b)] = v[8 * b +: 8];
  endtask

  task automatic win_read_check(input logic [31:0] off, input logic [3:0] be, input string what);
    logic [31:0] v;
    bit          e;
    win_rd(off, v, e);
    n_rd++;
    if (e) error($sformatf("%s: window read %07h answered with a bus error", what, off));
    else   check_word(off, v, be, what);
  endtask

  // random accesses: byte / halfword / word, a hot region and the whole test area
  task automatic traffic(input string what, input int unsigned n, input int unsigned hot_base,
                         input int unsigned hot_bytes);
    logic [31:0] off, v;
    logic [3:0]  be;
    int unsigned sz, op;
    bit          ok;
    for (int unsigned i = 0; i < n; i++) begin
      op = trnd() % 100;
      if (trnd() % 8 == 0) off = trnd() % TestBytes;
      else                 off = hot_base + trnd() % hot_bytes;
      sz = trnd() % 3;                                   // 0 byte, 1 halfword, 2 word
      if (sz == 1) off[0] = 1'b0;
      if (sz == 2) off[1:0] = 2'b00;
      be = (sz == 0) ? (4'b0001 << off[1:0]) : (sz == 1) ? (4'b0011 << off[1:0]) : 4'b1111;
      v  = trnd();
      if (op < 46) begin
        win_write_ref(off, v, be, what);
      end else if (op < 94) begin
        win_read_check(off, be, what);
      end else if (op < 97) begin
        hr_flush(ok);
        if (!ok) error($sformatf("%s: FLUSH failed", what));
      end else begin
        hr_cmd(CmdInval, ok);
        if (!ok) error($sformatf("%s: INVAL failed", what));
      end
    end
  endtask

  // a sequential block (the line fills / bursts of the window)
  task automatic block(input string what, input logic [31:0] base, input int unsigned words);
    for (int unsigned i = 0; i < words; i++) win_write_ref(base + 4 * i, trnd(), 4'hF, what);
    for (int unsigned i = 0; i < words; i++) win_read_check(base + 4 * i, 4'hF, what);
  endtask

  // ============================================================ helpers
  task automatic clear_status();
    reg_wr(RegStatusOff, 32'hFFFF_FFFF & ~32'(StatusRoMask));
  endtask

  task automatic expect_status(input logic [31:0] must, input logic [31:0] mustnot, input string what);
    logic [31:0] st;
    reg_rd(RegStatusOff, st);
    if ((st & must) != must || (st & mustnot) != 0) begin
      error($sformatf("%s: STATUS %08h (must %08h, must not %08h)", what, st, must, mustnot));
    end
  endtask

  function automatic logic [31:0] sbit(int unsigned b);
    return 32'd1 << b;
  endfunction

  localparam logic [31:0] StBad = (32'd1 << StRdErr) | (32'd1 << StWrErr) | (32'd1 << StRfifoErr) |
                                  (32'd1 << StBusTimeout) | (32'd1 << StTcsmErr) | (32'd1 << StBroken) |
                                  (32'd1 << StRfifoBrk) | (32'd1 << StBistErr);

  // ================================================================= main
  longint tmo_ms = 40;

  initial begin : watchdog
    if ($test$plusargs("WAVES")) begin
      $dumpfile("waves.fst");
      $dumpvars(0, tb_bow_hyperram);
    end
    void'($value$plusargs("TIMEOUT_MS=%d", tmo_ms));
    #(tmo_ms * 1_000_000_000);
    $display("tb_bow_hyperram: FAIL (simulated time limit of %0d ms)", tmo_ms);
    $finish;
  end

  initial begin : main
    int unsigned sd, burst, refresh0;
    logic [31:0] v, st, c0, c1, t0v, info_exp, errs;
    logic [15:0] r16;
    bit          ok, e;
    longint      t_init;

    sd = 1;
    void'($value$plusargs("SEED=%d", sd));
    void'($value$plusargs("RD_HOLD=%d", rd_hold));
    void'($value$plusargs("NTRAF=%d", n_traf));
    trng = sd ^ 32'h1F12_3BB5;
    if (trng == 0) trng = 1;
    info($sformatf("%s, CK %0d MHz, %0d phase steps%s, seed %0d, RD_HOLD %0d",
                   Stub ? "stub (HrEn = 0)" : (PhyKind == 2) ? "MPS4 loopback emulator" :
                   HasLs ? "TXV0108 card + S80KS2562 model" : "direct board + S80KS2562 model",
                   Mhz, PsSteps, VarLat ? ", variable latency" : "", sd, rd_hold));

    repeat (5) @(posedge clk);
    #1 rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ---------------------------------------------------------- 1 probe
    reg_rd(RegIdOff, v);
    if (v != IdValue) error($sformatf("ID %08h", v));
    reg_rd(RegInfoOff, v);
    if (Stub) begin
      if (v[3] || v != 32'd0) error($sformatf("stub INFO %08h (HR_EN must be 0)", v));
      ck_on = 1'b1;
      win_rd(32'h0, v, e);
      if (!e) error("stub: window read without a bus error");
      win_wr(32'h40, 32'h1234_5678, 4'hF, e);
      if (!e) error("stub: window write without a bus error");
      reg_wr(RegCmdOff, sbit(CmdApply));
      reg_rd(RegStatusOff, v);
      if (v != 32'd0) error($sformatf("stub: STATUS %08h", v));
      repeat (100) @(posedge clk);
      if (irq) error("stub: interrupt");
      if (u_hr.n_txn != 0 || u_hr.errors != 0) error("stub: transactions on the pads");
    end else begin
      info_exp = {7'd0, 1'b1, 4'd5, 1'b0, 3'd3, 8'(Mhz), 4'd9, 1'b1, HasLs, 2'(PhyKind)};
      if (v != info_exp) error($sformatf("INFO %08h, expected %08h", v, info_exp));
      reg_rd(RegClkHzOff, v);
      if (v != ClkHz) error($sformatf("CLK_HZ %0d", v));
      reg_rd(RegEmuOff, v);
      if (v != ((PhyKind == 2) ? $clog2(EmuBytes) : 0)) error($sformatf("EMU %08h", v));
      reg_rd(RegCtrlOff, v);
      if (v != CtrlReset) error($sformatf("CTRL reset value %08h", v));
      reg_rd(RegLatOff, v);
      if (v != 32'h0036_5522) error($sformatf("LAT reset value %08h", v));
      reg_rd(RegWbTmoOff, v);
      if (v != 32'd64) error($sformatf("WB_TMO reset value %08h", v));
      reg_rd(RegStatusOff, v);
      if (v[StClkOk]) error("CLK_OK without a HyperRAM clock");

      // ---------------------------------------------- 2 enable, reset
      ck_on = 1'b1;
      reg_rd(RegPsNowOff, v);
      if (32'(v[31:16]) != PsSteps) error($sformatf("PS_NOW steps %0d", v[31:16]));
      hr_config_for(cfg);
      hr_enable(cfg, ok);
      if (!ok) error($sformatf("enable / APPLY failed (STATUS %08h)", st_last));
      reg_rd(RegTim0Off, v);
      if (v != cfg.tim0) error($sformatf("TIM0 %08h, written %08h", v, cfg.tim0));
      hr_cmd(CmdHwReset, ok);
      if (!ok) error($sformatf("HW_RESET failed (STATUS %08h)", st_last));
      reg_rd(RegCr0Off, v);
      if (v[15:0] != Cr0Default) error($sformatf("CR0 shadow after HW_RESET %04h", v[15:0]));

      // ------------------------------- 3 error paths before calibration
      clear_status();
      win_rd(32'h100, v, e);
      if (!e) error("window read before INIT_DONE without a bus error");
      expect_status(sbit(StNotReady), 0, "window before INIT_DONE");
      reg_rd(RegErrAdOff, v);
      if (v != MemBase + 32'h100) error($sformatf("ERR_ADDR %08h after the NOT_READY read", v));
      hr_cmd_raw(sbit(CmdApply) | sbit(CmdRfifoSync), ok);
      if (ok) error("CMD with two bits accepted");
      reg_rd(RegStatusOff, v);
      if (!v[StCmdErr]) error($sformatf("CMD with two bits: STATUS %08h without CMD_ERR", v));
      reg_rd(RegErrCdOff, v);
      info($sformatf("CMD with two bits refused (ERR_CODE %08h)", v));
      clear_status();

      // --------------------------------------------------- 4 init
      t_init = $time;
      hr_init(ok);
      if (!ok) begin
        error("bow_hr_init failed: no further test");
      end else begin
        info($sformatf("init done in %0d us of simulated time", ($time - t_init) / 1_000_000));
        if (Pads && HasLs) begin
          u_hr.wr_relax = 1'b1;                        // the write sweep leaves tIS / tIH on purpose
          hr_calibrate_write(8, ok);
          u_hr.wr_relax = 1'b0;
          if (!ok) error("bow_hr_calibrate_write failed");
          info($sformatf("write phase sweep: %0d capture violations of the device relaxed", u_hr.n_relaxed));
        end
        // calibration leaves RD_ERR (bad phases) and the pattern in the device
        for (int i = 0; i < 32; i++) ref_b[i] = CalPattern[i];
        clear_status();
        reg_rd(RegStatusOff, v);
        if (!v[StReady]) error($sformatf("not READY after init: STATUS %08h", v));

        // ------------------------------------ 5 device registers
        hr_reg_read(0, r16, ok);
        if (!ok || r16 != Id0Val) error($sformatf("REG_RD ID0 %04h", r16));
        hr_reg_read(1, r16, ok);
        if (!ok || r16 != Id1Val) error($sformatf("REG_RD ID1 %04h", r16));
        hr_reg_read(2, r16, ok);
        reg_rd(RegCr0Off, c0);
        if (!ok || r16 != c0[15:0] || (Pads && r16 != u_hr.cr0)) begin
          error($sformatf("CR0: REG_RD %04h, shadow %04h, model %04h", r16, c0[15:0], u_hr.cr0));
        end
        if (cr0_l(c0[15:0]) != cfg.lat || !c0[3]) error($sformatf("CR0 %04h: latency %0d fixed expected", c0, cfg.lat));
        hr_reg_read(3, r16, ok);
        reg_rd(RegCr1Off, c1);
        if (!ok || r16[15:2] != c1[15:2] || (Pads && r16 != u_hr.cr1)) begin
          error($sformatf("CR1: REG_RD %04h, shadow %04h, model %04h", r16, c1[15:0], u_hr.cr1));
        end
        if (r16[1:0] != c1[1:0]) begin
          note($sformatf("CR1 shadow %04h keeps the read-only refresh interval [1:0] of its reset value; the device reads %04h (REG_RD does not update the shadow)",
                         c1[15:0], r16));
        end
        reg_rd(RegTim0Off, v);
        info($sformatf("CR0 %04h CR1 %04h TIM0 %08h LAT %08h", c0[15:0], c1[15:0], v, cfg.lat_reg));

        // --------------------------------------------- 6 window traffic
        for (int m = 0; m < 8; m++) begin
          hr_window(m[0], m[1], m[2]);
          traffic($sformatf("window mode RBUF %0d WRAP %0d WPOST %0d", m[0], m[1], m[2]), n_traf,
                  32'h0001_0000 + 32'(m) * 32'h400, 32'h800);
          block($sformatf("block, mode %0d", m), 32'h0003_0000 + 32'(m) * 32'h100, 24);
        end
        hr_window(1'b1, 1'b1, 1'b1);
        hr_flush(ok);
        if (!ok) error("FLUSH failed");
        model_check("after the window traffic");
        expect_status(0, StBad, "window traffic");
        info($sformatf("window traffic: %0d reads, %0d writes", n_rd, n_wr));
        // RANGE
        clear_status();
        win_rd(MemBytes + 32'h20, v, e);
        if (!e) error("read beyond the device without a bus error");
        expect_status(sbit(StRange), 0, "RANGE");
        reg_rd(RegErrAdOff, v);
        if (v != MemBase + MemBytes + 32'h20) error($sformatf("ERR_ADDR %08h after RANGE", v));
        win_wr(32'h0FFF_FFFC, 32'h1, 4'hF, e);
        if (!e) error("write at the end of the window decode without a bus error");
        clear_status();

        // ----------------------------------------------------- 7 BIST
        hr_bist_burst_max(burst);
        for (int pass = 0; pass < 2; pass++) begin
          int unsigned base_w, words, mode;
          logic [31:0] seed, x;
          logic [15:0] d;
          int          bad;
          base_w = (pass == 0) ? 32'h4_0000 : 32'h4_4000;
          words  = 2048 + 7;
          mode   = (pass == 0) ? 3 : 7;                  // write + read, PRBS / counter
          seed   = (pass == 0) ? 32'h1234_5678 + sd : 32'h0000_A5C3;
          hr_bist(base_w, words, burst, mode, seed, ok, errs);
          reg_rd(RegBCycOff, v);
          info($sformatf("BIST %s: %0d words, bursts of %0d, %0d cycles, %0d errors", pick(pass == 0, "PRBS", "counter"),
                         words, burst, v, errs));
          if (!ok) error($sformatf("BIST pass %0d failed (BIST_ERRS %0d)", pass, errs));
          hr_cmd_must(CmdInval, "INVAL after BIST");
          x   = (seed == 0) ? 32'd1 : seed;
          bad = 0;
          for (int unsigned k = 0; k < words; k++) begin
            int unsigned a;
            a = base_w + k;
            d = ((mode & 4) != 0) ? (16'(a) ^ seed[15:0]) : x[15:0];
            x = xs32(x);
            ref_b[2 * a]     = d[7:0];
            ref_b[2 * a + 1] = d[15:8];
            if (Pads && u_hr.peek(a) !== {d[7:0], d[15:8]}) begin
              bad++;
              if (bad <= 4) error($sformatf("BIST word %06h: device %04h, BIST data %04h (byte A = [7:0])", a,
                                            u_hr.peek(a), d));
            end
          end
          for (int unsigned k = 0; k < 16; k++) begin
            win_read_check(32'(2 * base_w) + 32'(trnd() % (2 * words)), 4'hF, "window read of BIST data");
          end
        end
        // a burst longer than TCSM: refused
        clear_status();
        reg_rd(RegTim0Off, t0v);
        reg_wr(RegTim0Off, (t0v & ~32'hFFF) | 32'd40);
        hr_cmd_must(CmdApply, "APPLY (TCSM 40)");
        bist_tmo_ps = 64'd200_000_000;                 // a refused burst ends the run at once
        hr_bist(32'h5_0000, 256, 100, 3, 32'h1, ok, errs);
        bist_tmo_ps = 64'd2_000_000_000;
        if (ok) error("a BIST burst longer than TCSM was not refused");
        reg_rd(RegStatusOff, st);
        reg_rd(RegErrCdOff, v);
        if (v[15:8] != ErrTcsm) error($sformatf("ERR_CODE %08h after the TCSM refusal", v));
        if (!st[StBistDone] && st[StBistBusy]) begin
          rtl_issue("BIST_REFUSE", $sformatf("a BIST burst refused by the controller (TCSM) never ends the run: STATUS %08h (TCSM_ERR %0d, BIST_BUSY 1, no BIST_DONE). bow_hyperram_ctrl pulses take, bdone and berr in the same cycle (bist_refuse); bow_hyperram_bist takes the burst in BReq and waits in BRun for a bdone that came already",
                              st, st[StTcsmErr]));
          hr_recover(ok);
          if (!ok) error($sformatf("recovery by CORE_RST failed (STATUS %08h)", st_last));
          else     info("recovered by CTRL.CORE_RST, APPLY, RFIFO_SYNC");
        end else begin
          expect_status(sbit(StTcsmErr) | sbit(StBistErr) | sbit(StBistDone), 0, "TCSM refusal");
          info($sformatf("BIST burst longer than TCSM refused: STATUS %08h, ERR_CODE %08h", st, v));
        end
        reg_wr(RegTim0Off, t0v);
        hr_cmd_must(CmdApply, "APPLY (TCSM back)");
        clear_status();

        // ------------------------------- 7b FLUSH / WIN_IDLE race (pads)
        // bow_hr_flush: CMD.FLUSH, then WIN_IDLE. A posted block pushed into
        // the command FIFO must be in the device when WIN_IDLE reads 1
        // (bow_hr_hybrid_sleep / deep_power_down issue a register write next:
        // a host command that reaches the controller's executor before the
        // block is visible on the hr_clk side is served first)
        if (Pads) begin
          int early, n0;
          logic [31:0] w;
          early = 0;
          hr_window(1'b1, 1'b1, 1'b1);
          for (int i = 0; i < 24; i++) begin
            w = 32'h7000 + 32'(64 * i);
            win_write_ref(w, 32'hC0DE_0000 | 32'(i), 4'hF, "flush race");
            repeat (i % 8) @(posedge clk);
            n0 = u_hr.n_words_wr;
            hr_flush(ok);
            if (!ok) error("FLUSH failed");
            if (u_hr.peek_byte(w) !== ref_b[w]) begin
              early++;
              if (early == 1) begin
                rtl_issue("WIN_IDLE", $sformatf("STATUS.WIN_IDLE read 1 after CMD.FLUSH while the posted block (window offset %07h) was still on its way to the device (model: %0d words written since the FLUSH): WIN_IDLE = window idle_o (true once the block is pushed into the command FIFO) && the synchronised chan_idle (wc_empty && !win_txn: the FIFO entry is not visible yet). bow_hr_hybrid_sleep / bow_hr_deep_power_down may then sleep the device before the write (lost, WR_ERR)",
                                    w, u_hr.n_words_wr - n0));
              end
            end
            #(64'd2_000_000);
            if (u_hr.peek_byte(w) !== ref_b[w]) error($sformatf("flush race: posted write %07h never reached the device", w));
          end
          if (early != 0) info($sformatf("flush race: WIN_IDLE before the data in %0d of 24 tries", early));
          else            info("flush race: WIN_IDLE never came before the data (24 tries)");
          // the driver's sleep entry right after a posted write: is the write kept?
          begin
            int lost, wr_err;
            lost   = 0;
            wr_err = 0;
            for (int i = 0; i < 6; i++) begin
              w = 32'h7800 + 32'(64 * i);
              clear_status();
              win_write_ref(w, 32'h5EE0_0000 | 32'(i), 4'hF, "sleep race");
              repeat (i) @(posedge clk);
              hr_hybrid_sleep(ok);                       // bow_hr_hybrid_sleep: FLUSH, REG_WR CR1
              if (!ok) error("sleep race: hybrid sleep not entered");
              #(64'd3_500_000);
              hr_wake(ok);
              if (!ok) error("sleep race: WAKE failed");
              reg_rd(RegStatusOff, v);
              if (v[StWrErr]) wr_err++;
              if (u_hr.peek_byte(w) !== ref_b[w]) begin
                lost++;
                for (int b = 0; b < 4; b++) ref_b.delete(w + 32'(b));   // the device does not have it
              end
            end
            if (lost != 0) begin
              rtl_issue("SLEEP_LOSS", $sformatf("a posted write followed by bow_hr_hybrid_sleep (FLUSH, REG_WR CR1) was lost in %0d of 6 tries (WR_ERR in %0d): the device went to sleep before the write",
                                  lost, wr_err));
            end else begin
              info($sformatf("sleep race: the posted write was kept in 6 of 6 tries (WR_ERR in %0d)", wr_err));
            end
          end
          clear_status();
        end

        // ----------------------------------------- 8 variable latency
        if (VarLat) begin
          cfg.fixed = 1'b0;
          hr_configure(cfg, ok);
          if (!ok) error("configuration with variable latency failed");
          reg_rd(RegCr0Off, c0);
          if (c0[3]) error($sformatf("CR0 %04h: variable latency expected", c0));
          refresh0 = Pads ? u_hr.n_refresh : 0;
          hr_cmd_must(CmdClrStats, "CLR_STATS");
          for (int m = 0; m < 4; m++) begin
            hr_window(1'b1, m[0], m[1]);
            traffic("variable latency", n_traf, 32'h0006_0000 + 32'(m) * 32'h400, 32'h800);
          end
          hr_bist_burst_max(burst);
          hr_bist(32'h6_8000, 1024, burst, 3, 32'h77, ok, errs);
          if (!ok) error($sformatf("BIST with variable latency failed (%0d errors)", errs));
          hr_cmd_must(CmdInval, "INVAL after BIST");
          begin
            logic [31:0] x;
            logic [15:0] d;
            x = 32'h77;
            for (int unsigned k = 0; k < 1024; k++) begin
              d = x[15:0];
              x = xs32(x);
              ref_b[2 * (32'h6_8000 + k)]     = d[7:0];
              ref_b[2 * (32'h6_8000 + k) + 1] = d[15:8];
            end
          end
          hr_cmd_must(CmdSnap, "SNAP");
          reg_rd(RegStOff + 12'(4 * 4), v);
          info($sformatf("variable latency: %0d 2x transactions (ST[4]), model refresh collisions %0d", v,
                         Pads ? u_hr.n_refresh - refresh0 : 0));
          if (v == 0) error("variable latency: no 2x transaction (ST[4] = 0)");
          if (Pads && u_hr.n_refresh == refresh0) error("variable latency: the model drew no refresh collision");
          hr_flush(ok);
          model_check("after the variable latency traffic");
          cfg.fixed = 1'b1;
          hr_configure(cfg, ok);
          if (!ok) error("configuration back to fixed latency failed");
          expect_status(0, StBad, "variable latency");
        end

        // ----------------------------------------------- 9 power, irq
        // hybrid sleep: window refused, WAKE, data kept
        clear_status();
        hr_hybrid_sleep(ok);
        if (!ok) error($sformatf("hybrid sleep not entered (STATUS %08h)", st_last));
        if (Pads && u_hr.pstate != 2) error("hybrid sleep: the device is not asleep");
        win_rd(32'h1_0000, v, e);
        if (!e) error("window read in hybrid sleep without a bus error");
        expect_status(sbit(StNotReady), 0, "window in hybrid sleep");
        clear_status();
        #(64'd3_500_000);                              // tHSIN (3 us): neither the RTL nor the driver waits
        hr_wake(ok);
        if (!ok) error($sformatf("WAKE from hybrid sleep failed (STATUS %08h)", st_last));
        reg_rd(RegCr1Off, c1);
        hr_reg_read(3, r16, ok);
        if (c1[5] || r16[5] || r16[15:2] != c1[15:2] || (Pads && u_hr.cr1 != r16)) begin
          error($sformatf("after hybrid sleep: CR1 shadow %04h, REG_RD %04h, model %04h", c1, r16, u_hr.cr1));
        end
        hr_cmd_must(CmdInval, "INVAL");
        for (int k = 0; k < 24; k++) win_read_check(32'h0001_0000 + 32'(trnd() % 32'h2000), 4'hF, "after hybrid sleep");
        model_check("after hybrid sleep");

        // deep power down: data lost, registers default, reconfigure
        hr_window(1'b1, 1'b1, 1'b1);
        win_read_check(32'h0, 4'hF, "line 0 into the read buffer");   // a hit after the WAKE?
        hr_deep_power_down(ok);
        if (!ok) error($sformatf("deep power down not entered (STATUS %08h)", st_last));
        if (Pads && u_hr.pstate != 1) error("deep power down: the device is not in DPD");
        #(64'd3_500_000);                              // tDPDIN (3 us): neither the RTL nor the driver waits
        hr_wake(ok);
        if (!ok) error($sformatf("WAKE from deep power down failed (STATUS %08h)", st_last));
        reg_rd(RegCr0Off, c0);
        hr_reg_read(2, r16, ok);
        if (c0[15:0] != Cr0Default || r16 != Cr0Default || (Pads && u_hr.cr0 != Cr0Default)) begin
          error($sformatf("after deep power down: CR0 shadow %04h, REG_RD %04h, model %04h", c0, r16, u_hr.cr0));
        end
        if (Pads && u_hr.was_written(32'h0001_0000 / 2)) error("deep power down: the device kept its data");
        // line 0 was in the read buffer before the deep power down: does a
        // read after the WAKE still return the data the device lost?
        begin
          logic [31:0] w0;
          logic [7:0]  b0;
          int          stale;
          stale = 0;
          for (int k = 0; k < 8; k++) begin
            win_rd(32'(4 * k), w0, e);
            for (int b = 0; b < 4; b++) begin
              if (!e && (ref_b.exists(4 * k + b) != 0) && w0[8 * b +: 8] == ref_b[4 * k + b] &&
                  (!Pads || u_hr.peek_byte(4 * k + b) != ref_b[4 * k + b])) stale++;
            end
          end
          b0 = Pads ? u_hr.peek_byte(0) : 8'h00;
          if (stale != 0 && Pads) begin
            error($sformatf("deep power down: the read buffer still served %0d bytes of line 0 that the device lost (device byte 0 = %02h): bow_hyperram_regs sends an INVAL to the window when a WAKE is done",
                            stale, b0));
          end else if (stale != 0) begin
            info($sformatf("deep power down: line 0 reads the data from before (%0d bytes): the loopback emulator keeps its array through DPD, so the INVAL on WAKE cannot be told apart here",
                           stale));
          end else begin
            info("deep power down: no stale line in the read buffer after the WAKE");
          end
        end
        ref_b.delete();
        hr_cmd_must(CmdInval, "INVAL after DPD");
        hr_configure(cfg, ok);
        if (!ok) error("configuration after deep power down failed");
        for (int i = 0; i < 32; i++) ref_b[i] = CalPattern[i];
        write_pattern(ok);
        if (!ok) error("pattern write after deep power down failed");
        traffic("after deep power down", n_traf / 2, 32'h0002_0000, 32'h1000);
        hr_flush(ok);
        model_check("after deep power down");

        // IRQ on CMD_DONE
        reg_wr(RegIrqEnOff, sbit(StCmdDone));
        hr_cmd_must(CmdSnap, "SNAP");
        repeat (4) @(posedge clk);
        if (!irq) error("no interrupt with IRQ_EN.CMD_DONE after a command");
        reg_wr(RegStatusOff, sbit(StCmdDone));
        repeat (4) @(posedge clk);
        if (irq) error("interrupt still high after CMD_DONE was cleared");
        reg_wr(RegIrqEnOff, 32'd0);
        begin
          logic [31:0] s [11];
          for (int i = 0; i < 11; i++) reg_rd(RegStOff + 12'(4 * i), s[i]);
          info($sformatf("ST: rd %0d wr %0d rd words %0d wr words %0d 2x %0d reg %0d failed %0d bist %0d hits %0d misses %0d flushes %0d",
                         s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10]));
        end
      end

      // --------------------------------------------------------- 10 end
      repeat (50) @(posedge clk);
      reg_rd(RegStatusOff, st);
      if ((st & StBad) != 0) error($sformatf("final STATUS %08h: error flags", st));
      reg_rd(RegDbgOff, v);
      if (PhyKind == 2 && (v[31] || v[15:0] != 16'd0)) begin
        error($sformatf("emulator DBG %08h: protocol error code %02h", v, v[23:16]));
      end
      if (PhyKind == 2) info($sformatf("emulator DBG %08h", v));
      if (Pads) begin
        if (u_hr.errors != 0) error($sformatf("the S80KS2562 model counted %0d errors", u_hr.errors));
        if (u_brd.contention != 0) error($sformatf("board contention %0d", u_brd.contention));
        if (u_brd.floats != 0) error($sformatf("board floats %0d", u_brd.floats));
        info($sformatf("model: %0d transactions (%0d / %0d words read / written), 2x %0d, refresh %0d, relaxed %0d; board floats on the HyperRAM side %0d (information)",
                       u_hr.n_txn, u_hr.n_words_rd, u_hr.n_words_wr, u_hr.n_lat2x, u_hr.n_refresh, u_hr.n_relaxed,
                       u_brd.floats_a));
      end
      if (u_clk.ps_ignored != 0 || u_clk.wps_ignored != 0) error("phase steps ignored by the clock model");
    end

    $display("tb_bow_hyperram: %0d notes, %0d RTL issues (%0d waived)", notes, rtl_issues, rtl_waived);
    $display("tb_bow_hyperram: %s (%0d errors: testbench %0d, bus protocol %0d) at %0t ps",
             pick(tb_errs + proto_errs == 0, "PASS", "FAIL"), tb_errs + proto_errs, tb_errs, proto_errs, $time);
    $finish;
  end

endmodule
/* verilator lint_on SYNCASYNCNET */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
