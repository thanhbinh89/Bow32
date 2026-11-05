// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit testbench of the Bow32 DDR2/DDR3 IP bow_ddr (LiteDRAM controller core,
// DFI adapter, Bow32 PHY, bus bridges, registers), Verilator --binary
// --timing, self-checking ("tb_bow_ddr: PASS" / "FAIL"). One Verilator model
// per configuration (the parameters below, see the Makefile).
//
// Board side (PhyKind):
//   2  the MPS4 loopback build: bow_ddr_io_sim (Loopback) + bow_ddr_lb (DRAM
//      emulator, EmuBytes, JEDEC checks; dbg_o -> ddr_dbg_i)
//   1  bow_ddr_io_sim (pads) + ddr_board_model (LevelShift = 1: the FMC card
//      with TXV0108 level shifters, DM ball tied; 0: direct board) +
//      ddr_mem_model (bow_ddr_dev with JEDEC and pin checks, error count on
//      ddr_dbg_i)
// Stub = 1: the DUT is bow_ddr_stub (DdrEn = 0, same ports).
// Clocks: clk_i 50 MHz; ddr_clk_model (ddr_clk, sys_clk = CK / 4 from the
// same process, wclk, wclk90, rd_clk, two MMCM fine phase shift ports), all
// connected straight to the DUT; ddr_rst_ni = MMCM locked.
//
// Bus BFMs (three ports: window, LiteDRAM CSRs, PHY registers): one access at
// a time per port, request held until gnt, the answer taken in the cycle
// after the transfer; a monitor checks on every port that rvalid comes
// exactly one cycle after req && gnt and never otherwise.
//
// Flow (the firmware sequence of docs/ip/ddr.md, register by register):
//   1  link up (LINK, CLK_OK), ID / INFO / EMU / CLK_HZ / reset values
//   2  window access before init_done: bus error, NOT_READY, ERR_ADDR; IRQ
//   3  DFII software control (dfii_control = 0), CTRL = EN | CK_EN | LS_EN |
//      IDLE_DRIVE (+ DDR3 / DM_EN per INFO), APPLY; CKE low / RESET# low for
//      200 us with CK running
//   4  JEDEC init: the generated init.csv (+INIT=<file>) through the CSR port
//      (ctrl: dfii_control; cmd: phase 0 address / baddress / command /
//      command_issue; delay: that many clk_i cycles)
//   5  read calibration (the v1 idea with DFII commands): training pattern P
//      at column 0 and ~P at column 8 (ACT, two WR on phase 2, PRE); sweep the
//      read phase over one CK period (+CAL_POINTS, default 16): per point
//      REF, ACT, CAP_ARM, RD (phase 2) with raw capture, PRE, CAP_DONE, the
//      beat offset p of P in the 32 captured stream cycles; widest (cyclic)
//      run of equal p, its centre; RD_DLY = p / 2 - 4, RD_SLIP = p mod 2,
//      APPLY; verify P / ~P with DFII reads (pi<n>_rddata)
//   6  hand over: dfii_control = SEL | CKE | ODT | RESET_N, init_done = 1,
//      READY
//   7  window traffic against a byte reference model: sequential words,
//      random word / halfword / byte writes (read-modify-write without DM)
//      and reads over several banks and rows; statistics (CLR_STATS, SNAP:
//      ST_RD / ST_WR / ST_RMW exact, ST_ACT / ST_REF > 0); with DM pins
//      (DDR3) also masked byte writes with CTRL.DM_EN (ST_RMW stays 0)
//   8  LiteDRAM BIST: generator + checker (counter and random data), 0
//      errors; a checker with other data must count errors; random data
//      and random addresses (row conflicts; checker count not checked).
//      Throughout: every RD / WR on the DFI has A10 = 0 (no auto-precharge)
//   9  RANGE (offset >= DRAM size); the read budget (RL + RD_DLY + RD_SLIP =
//      32 in time, 33: RD_LATE, the late bursts discarded, no RD_EXTRA; data
//      correct again after restoring LAT); CORE_RST (READY / INIT_DONE low,
//      window and CSR accesses refused, the core restarts in hardware mode,
//      software hand-over again, data kept); window and CSR timeouts by
//      fault injection (native cmd_ready / Wishbone ack forced low):
//      BUS_TIMEOUT, CSR_ERR, BROKEN, accesses refused, recovery by CORE_RST
//  10  end: the emulator / DRAM model reported no JEDEC rule or pin error, no
//      RD_EXTRA / RFIFO_ERR / BUS_TIMEOUT / BROKEN, no protocol error
// Any $error of the RTL or of the models stops the simulation (run with
// +verilator+error+limit+<n> to see more of them).
//
// Plusargs: +INIT=<init.csv> (required unless Stub), +SEED=<n> (random
// traffic), +CAL_POINTS=<n>, +NWIN=<n> (random window accesses, default
// 800), +TIMEOUT_MS=<n> (simulated time limit, default 20), +WAVES
// (waves.fst, needs a model built with --trace-fst: make WAVES=1), and the
// board / DRAM model plusargs (+ddr_board_seed, +ddr_mem_seed, ...).

`timescale 1ps / 1ps

module tb_bow_ddr import bow_bus_pkg::*; import bow_ddr_pkg::*; #(
  parameter int unsigned DdrMem     = 2,          // 2: litedram_ddr2, 3: litedram_ddr3
  parameter int unsigned ClkHz      = 133_333_333,
  parameter int unsigned TckPs      = 7500,
  parameter int unsigned PsSteps    = 504,
  parameter int unsigned PhyKind    = 2,          // 1 pads + board + DRAM, 2 loopback emulator
  parameter int unsigned EmuBytes   = 4 << 20,    // PhyKind 2: emulator storage
  parameter bit          LevelShift = 1'b1,       // PhyKind 1: TXV0108 card, else direct board
  parameter int unsigned TRfcPs     = (DdrMem == 3) ? 110_000 : 105_000,
  // window / CSR timeout (clk_i cycles): short, a hang shows up soon
  parameter int unsigned WinTimeout = 4096,
  parameter bit          Stub       = 1'b0        // DUT = bow_ddr_stub (DdrEn = 0)
);

  localparam bit          Ddr3      = (DdrMem == 3);
  localparam int unsigned DqBits    = Ddr3 ? 16 : 8;
  localparam int unsigned Lanes     = DqBits / 8;
  localparam int unsigned AddrPins  = Ddr3 ? 13 : 14;
  localparam int unsigned BankPins  = Ddr3 ? 3 : 2;
  localparam bit          HasDm     = Ddr3;
  localparam bit          HasResetN = Ddr3;
  localparam int unsigned BankBits  = BankPins;
  localparam int unsigned RowBits   = Ddr3 ? 13 : 14;
  localparam int unsigned ColBits   = 10;
  localparam int unsigned L         = Ddr3 ? 1 : 0;              // log2(lanes)
  localparam int unsigned BB        = 8 * Lanes;                 // burst bytes
  localparam int unsigned MemBytes  = Ddr3 ? (128 << 20) : (64 << 20);
  localparam int unsigned LbRows    = (EmuBytes > 1) ? $clog2(EmuBytes) - L - ColBits - BankBits : RowBits;
  // the DRAM the tests may touch: the emulator's storage or the whole device
  localparam int unsigned TestBytes = (PhyKind == 2 && EmuBytes != 0 && EmuBytes < MemBytes) ?
                                      EmuBytes : MemBytes;
  localparam int unsigned ReadLat   = 12;

  // ------------------------------------------------------------- clocks
  logic clk = 1'b0, rst_n = 1'b0;
  always #10_000 clk = ~clk;                       // clk_i 50 MHz

  logic ck_on = 1'b0;                              // MMCMs running
  logic ddr_clk, sys_clk, wclk, wclk90, rd_clk, locked;
  logic ps_en, ps_inc, ps_done, wps_en, wps_inc, wps_done;

  ddr_clk_model #(
    .TckPs   (TckPs),
    .PsSteps (PsSteps)
  ) u_clk (
    .en_i       (ck_on),
    .ddr_clk_o  (ddr_clk),
    .sys_clk_o  (sys_clk),
    .wclk_o     (wclk),
    .wclk90_o   (wclk90),
    .rd_clk_o   (rd_clk),
    .locked_o   (locked),
    .ps_en_i    (ps_en),
    .ps_inc_i   (ps_inc),
    .ps_done_o  (ps_done),
    .wps_en_i   (wps_en),
    .wps_inc_i  (wps_inc),
    .wps_done_o (wps_done)
  );

  // ---------------------------------------------------------------- DUT
  logic        hang_win = 1'b0, hang_csr = 1'b0;    // fault injection (g_ip)
  bus_req_t    mem_req = '0, csr_req = '0, reg_req = '0;
  bus_rsp_t    mem_rsp, csr_rsp, reg_rsp;
  logic        irq;
  ddr_io_out_t io_o;
  ddr_io_in_t  io_i;
  logic [31:0] dbg;

  if (Stub) begin : g_stub
    bow_ddr_stub #(
      .DdrMem     (DdrMem),
      .ClkHz      (ClkHz),
      .PsSteps    (PsSteps),
      .PhyKind    (PhyKind),
      .EmuBytes   (EmuBytes),
      .WinTimeout (WinTimeout)
    ) dut (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .mem_req_i      (mem_req),
      .mem_rsp_o      (mem_rsp),
      .csr_req_i      (csr_req),
      .csr_rsp_o      (csr_rsp),
      .reg_req_i      (reg_req),
      .reg_rsp_o      (reg_rsp),
      .irq_o          (irq),
      .ddr_sys_clk_i  (sys_clk),
      .ddr_clk_i      (ddr_clk),
      .ddr_rst_ni     (locked),
      .ddr_rd_clk_i   (rd_clk),
      .ddr_ps_en_o    (ps_en),
      .ddr_ps_inc_o   (ps_inc),
      .ddr_ps_done_i  (ps_done),
      .ddr_wps_en_o   (wps_en),
      .ddr_wps_inc_o  (wps_inc),
      .ddr_wps_done_i (wps_done),
      .ddr_io_o       (io_o),
      .ddr_io_i       (io_i),
      .ddr_dbg_i      (dbg)
    );
  end else begin : g_ip
    bow_ddr #(
      .DdrMem     (DdrMem),
      .ClkHz      (ClkHz),
      .PsSteps    (PsSteps),
      .PhyKind    (PhyKind),
      .EmuBytes   (EmuBytes),
      .WinTimeout (WinTimeout)
    ) dut (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .mem_req_i      (mem_req),
      .mem_rsp_o      (mem_rsp),
      .csr_req_i      (csr_req),
      .csr_rsp_o      (csr_rsp),
      .reg_req_i      (reg_req),
      .reg_rsp_o      (reg_rsp),
      .irq_o          (irq),
      .ddr_sys_clk_i  (sys_clk),
      .ddr_clk_i      (ddr_clk),
      .ddr_rst_ni     (locked),
      .ddr_rd_clk_i   (rd_clk),
      .ddr_ps_en_o    (ps_en),
      .ddr_ps_inc_o   (ps_inc),
      .ddr_ps_done_i  (ps_done),
      .ddr_wps_en_o   (wps_en),
      .ddr_wps_inc_o  (wps_inc),
      .ddr_wps_done_i (wps_done),
      .ddr_io_o       (io_o),
      .ddr_io_i       (io_i),
      .ddr_dbg_i      (dbg)
    );

    // fault injection (timeout tests): the native port never takes a
    // command / the LiteDRAM Wishbone port never answers
    initial begin
      forever begin
        @(posedge hang_win);
        force dut.nat_cmd_ready = 1'b0;
        @(negedge hang_win);
        release dut.nat_cmd_ready;
      end
    end
    initial begin
      forever begin
        @(posedge hang_csr);
        force dut.wb_ack = 1'b0;
        @(negedge hang_csr);
        release dut.wb_ack;
      end
    end

    // every RD / WR on the DFI has A10 = 0: the cores are generated without
    // auto-precharge, which bow_ddr_dev and the DRAM models do not model (the
    // random-address BIST pass of step 8 makes the bank machines see row
    // conflicts, where LiteDRAM would otherwise use it)
    int unsigned n_cas = 0;
    always @(posedge sys_clk) begin
      for (int n = 0; n < 4; n++) begin
        if (!dut.dfi[n].cs_n && dut.dfi[n].ras_n && !dut.dfi[n].cas_n) begin
          n_cas++;
          if (dut.dfi[n].address[10]) begin
            error($sformatf("%s with A10 = 1 (auto-precharge) on DFI phase %0d",
                            dut.dfi[n].we_n ? "RD" : "WR", n));
          end
        end
      end
    end
  end

  // ------------------------------------------------------- board side
  int unsigned dram_errs = 0, contention = 0, floats = 0;
  logic        dram_init_done;

  if (PhyKind == 2) begin : g_lb
    logic                     lb_en, lb_rst_n;
    logic [1:0][MaxDq-1:0]    lb_dq;
    logic [MaxLanes-1:0][1:0] lb_dqs;

    bow_ddr_io_sim #(
      .DqBits   (DqBits),
      .Lanes    (Lanes),
      .AddrPins (AddrPins),
      .BankPins (BankPins),
      .Loopback (1'b1)
    ) u_io (
      .clk_i        (ddr_clk),
      .wclk_i       (wclk),
      .wclk90_i     (wclk90),
      .rd_clk_i     (rd_clk),
      .io_o_i       (io_o),
      .io_i_o       (io_i),
      .lb_en_i      (lb_en),
      .lb_dq_i      (lb_dq),
      .lb_dqs_i     (lb_dqs),
      .ck_p_o       (),
      .ck_n_o       (),
      .cke_o        (),
      .rst_n_o      (),
      .odt_o        (),
      .cs_n_o       (),
      .ras_n_o      (),
      .cas_n_o      (),
      .we_n_o       (),
      .ba_o         (),
      .a_o          (),
      .dq_o         (),
      .dq_oe_o      (),
      .dq_i         ('0),
      .dqs_p_o      (),
      .dqs_n_o      (),
      .dqs_oe_o     (),
      .dqs_p_i      ('0),
      .dqs_n_i      ('1),
      .dm_o         (),
      .ls_oe_n_o    (),
      .ls_dir_dq_o  (),
      .ls_dir_dqs_o ()
    );

    // like the MPS4 top: the emulator resets with the MMCM lock only
    bow_rst_sync u_lb_rst (
      .clk_i  (ddr_clk),
      .rst_ni (locked),
      .rst_no (lb_rst_n)
    );

    bow_ddr_lb #(
      .Ddr3     (Ddr3),
      .DqBits   (DqBits),
      .BankBits (BankBits),
      .RowBits  (LbRows),
      .ColBits  (ColBits),
      .MemBytes (EmuBytes),
      .UseUram  (1'b0)
    ) u_lb (
      .clk_i    (ddr_clk),
      .rst_ni   (lb_rst_n),
      .io_i     (io_o),
      .lb_en_o  (lb_en),
      .lb_dq_o  (lb_dq),
      .lb_dqs_o (lb_dqs),
      .dbg_o    (dbg)
    );

    always @(posedge clk) begin
      dram_errs      = 32'(dbg[15:0]);
      dram_init_done = dbg[30];
    end

  end else begin : g_pads
    logic                ck_p, ck_n, cke, rst_n_p, odt, cs_n, ras_n, cas_n, we_n;
    logic [BankPins-1:0] ba;
    logic [AddrPins-1:0] a;
    logic [DqBits-1:0]   dq_f, dq_pin;
    logic                dq_oe;
    logic [Lanes-1:0]    dqs_p_f, dqs_n_f, dqs_oe, dqs_p_pin, dqs_n_pin, dm;
    logic                ls_oe_n, ls_dir_dq, ls_dir_dqs;
    // DRAM side
    logic                m_ck_p, m_ck_n, m_cke, m_rst_n, m_odt, m_cs_n, m_ras_n, m_cas_n, m_we_n;
    logic [BankPins-1:0] m_ba;
    logic [AddrPins-1:0] m_a;
    logic [DqBits-1:0]   m_dq, m_dq_out;
    logic                m_dq_oe;
    logic [Lanes-1:0]    m_dq_drv, m_dqs_p, m_dqs_n, m_dqs_drv, m_dqs_p_out, m_dqs_n_out;
    logic [Lanes-1:0]    m_dqs_oe, m_dm;
    logic [15:0]         m_err_count;
    logic                m_init_done;

    bow_ddr_io_sim #(
      .DqBits   (DqBits),
      .Lanes    (Lanes),
      .AddrPins (AddrPins),
      .BankPins (BankPins),
      .Loopback (1'b0)
    ) u_io (
      .clk_i        (ddr_clk),
      .wclk_i       (wclk),
      .wclk90_i     (wclk90),
      .rd_clk_i     (rd_clk),
      .io_o_i       (io_o),
      .io_i_o       (io_i),
      .lb_en_i      (1'b0),
      .lb_dq_i      ('0),
      .lb_dqs_i     ('0),
      .ck_p_o       (ck_p),
      .ck_n_o       (ck_n),
      .cke_o        (cke),
      .rst_n_o      (rst_n_p),
      .odt_o        (odt),
      .cs_n_o       (cs_n),
      .ras_n_o      (ras_n),
      .cas_n_o      (cas_n),
      .we_n_o       (we_n),
      .ba_o         (ba),
      .a_o          (a),
      .dq_o         (dq_f),
      .dq_oe_o      (dq_oe),
      .dq_i         (dq_pin),
      .dqs_p_o      (dqs_p_f),
      .dqs_n_o      (dqs_n_f),
      .dqs_oe_o     (dqs_oe),
      .dqs_p_i      (dqs_p_pin),
      .dqs_n_i      (dqs_n_pin),
      .dm_o         (dm),
      .ls_oe_n_o    (ls_oe_n),
      .ls_dir_dq_o  (ls_dir_dq),
      .ls_dir_dqs_o (ls_dir_dqs)
    );

    ddr_board_model #(
      .DqBits     (DqBits),
      .Lanes      (Lanes),
      .AddrPins   (AddrPins),
      .BankPins   (BankPins),
      .LevelShift (LevelShift),
      .DmTied     (!HasDm),
      .Verbose    (1'b1)
    ) u_board (
      .ck_p_i        (ck_p),
      .ck_n_i        (ck_n),
      .cke_i         (cke),
      .rst_n_i       (rst_n_p),
      .odt_i         (odt),
      .cs_n_i        (cs_n),
      .ras_n_i       (ras_n),
      .cas_n_i       (cas_n),
      .we_n_i        (we_n),
      .ba_i          (ba),
      .a_i           (a),
      .dq_i          (dq_f),
      .dq_oe_i       (dq_oe),
      .dq_o          (dq_pin),
      .dqs_p_i       (dqs_p_f),
      .dqs_n_i       (dqs_n_f),
      .dqs_oe_i      (dqs_oe),
      .dqs_p_o       (dqs_p_pin),
      .dqs_n_o       (dqs_n_pin),
      .dm_i          (dm),
      .ls_oe_n_i     (ls_oe_n),
      .ls_dir_dq_i   (ls_dir_dq),
      .ls_dir_dqs_i  (ls_dir_dqs),
      .mem_ck_p_o    (m_ck_p),
      .mem_ck_n_o    (m_ck_n),
      .mem_cke_o     (m_cke),
      .mem_rst_n_o   (m_rst_n),
      .mem_odt_o     (m_odt),
      .mem_cs_n_o    (m_cs_n),
      .mem_ras_n_o   (m_ras_n),
      .mem_cas_n_o   (m_cas_n),
      .mem_we_n_o    (m_we_n),
      .mem_ba_o      (m_ba),
      .mem_a_o       (m_a),
      .mem_dq_o      (m_dq),
      .mem_dq_drv_o  (m_dq_drv),
      .mem_dq_i      (m_dq_out),
      .mem_dq_oe_i   (m_dq_oe),
      .mem_dqs_p_o   (m_dqs_p),
      .mem_dqs_n_o   (m_dqs_n),
      .mem_dqs_drv_o (m_dqs_drv),
      .mem_dqs_p_i   (m_dqs_p_out),
      .mem_dqs_n_i   (m_dqs_n_out),
      .mem_dqs_oe_i  (m_dqs_oe),
      .mem_dm_o      (m_dm)
    );

    ddr_mem_model #(
      .Ddr3     (Ddr3),
      .DqBits   (DqBits),
      .Lanes    (Lanes),
      .BankBits (BankBits),
      .RowBits  (RowBits),
      .ColBits  (ColBits),
      .AddrPins (AddrPins),
      .BankPins (BankPins),
      .TckPs    (TckPs),
      .TRfcPs   (TRfcPs)
    ) u_mem (
      .ck_p_i      (m_ck_p),
      .ck_n_i      (m_ck_n),
      .cke_i       (m_cke),
      .rst_n_i     (m_rst_n),
      .odt_i       (m_odt),
      .cs_n_i      (m_cs_n),
      .ras_n_i     (m_ras_n),
      .cas_n_i     (m_cas_n),
      .we_n_i      (m_we_n),
      .ba_i        (m_ba),
      .a_i         (m_a),
      .dq_i        (m_dq),
      .dq_drv_i    (m_dq_drv),
      .dq_o        (m_dq_out),
      .dq_oe_o     (m_dq_oe),
      .dqs_p_i     (m_dqs_p),
      .dqs_n_i     (m_dqs_n),
      .dqs_drv_i   (m_dqs_drv),
      .dqs_p_o     (m_dqs_p_out),
      .dqs_n_o     (m_dqs_n_out),
      .dqs_oe_o    (m_dqs_oe),
      .dm_i        (m_dm),
      .wr_relax_i  (1'b0),
      .dbg_o       (dbg),
      .err_code_o  (),
      .err_count_o (m_err_count),
      .init_done_o (m_init_done)
    );

    always @(posedge clk) begin
      dram_errs      = 32'(m_err_count);
      dram_init_done = m_init_done;
      contention     = u_board.contention;
      floats         = u_board.floats;
    end
  end

  // ============================================================ bus BFMs
  int unsigned tb_errs = 0, proto_errs = 0;

  task automatic error(string msg);
    tb_errs++;
    $display("%0t ps: tb_bow_ddr: ERROR: %s", $time, msg);
  endtask

  task automatic expect_eq(string what, logic [31:0] got, logic [31:0] exp);
    if (got !== exp) error($sformatf("%s = %08h, expected %08h", what, got, exp));
  endtask

  localparam int unsigned PMem = 0, PCsr = 1, PReg = 2;

  // one access: request held until gnt, answer in the cycle after the transfer
  task automatic bus_xfer(input int unsigned port, input bit we, input logic [31:0] addr,
                          input logic [31:0] wdata, input logic [3:0] be,
                          output logic [31:0] rdata, output bit err);
    bus_req_t    r;
    bit          g;
    int unsigned wait_cyc;
    r       = '0;
    r.req   = 1'b1;
    r.we    = we;
    r.be    = be;
    r.addr  = addr;
    r.wdata = wdata;
    @(posedge clk);
    #1;
    unique case (port)
      PMem:    mem_req = r;
      PCsr:    csr_req = r;
      default: reg_req = r;
    endcase
    wait_cyc = 0;
    do begin
      @(negedge clk);
      unique case (port)
        PMem:    g = mem_rsp.gnt;
        PCsr:    g = csr_rsp.gnt;
        default: g = reg_rsp.gnt;
      endcase
      @(posedge clk);
      #1;
      if (++wait_cyc > WinTimeout + 256) begin
        $fatal(1, "tb_bow_ddr: port %0d access %08h: no gnt for %0d cycles", port, addr,
               wait_cyc);
      end
    end while (!g);
    unique case (port)
      PMem:    mem_req = '0;
      PCsr:    csr_req = '0;
      default: reg_req = '0;
    endcase
    @(negedge clk);
    unique case (port)
      PMem:    begin rdata = mem_rsp.rdata; err = mem_rsp.err; end
      PCsr:    begin rdata = csr_rsp.rdata; err = csr_rsp.err; end
      default: begin rdata = reg_rsp.rdata; err = reg_rsp.err; end
    endcase
  endtask

  // rvalid exactly one cycle after req && gnt, on every port
  logic [2:0] xfer_q = '0;
  always @(posedge clk) begin
    if (rst_n) begin
      if (mem_rsp.rvalid !== xfer_q[PMem]) begin
        proto_errs++;
        $display("%0t ps: tb_bow_ddr: ERROR: window rvalid %b, transfer in the previous cycle %b",
                 $time, mem_rsp.rvalid, xfer_q[PMem]);
      end
      if (csr_rsp.rvalid !== xfer_q[PCsr]) begin
        proto_errs++;
        $display("%0t ps: tb_bow_ddr: ERROR: CSR rvalid %b, transfer in the previous cycle %b",
                 $time, csr_rsp.rvalid, xfer_q[PCsr]);
      end
      if (reg_rsp.rvalid !== xfer_q[PReg]) begin
        proto_errs++;
        $display("%0t ps: tb_bow_ddr: ERROR: register rvalid %b, transfer in the previous cycle %b",
                 $time, reg_rsp.rvalid, xfer_q[PReg]);
      end
    end
    xfer_q[PMem] <= mem_req.req && mem_rsp.gnt;
    xfer_q[PCsr] <= csr_req.req && csr_rsp.gnt;
    xfer_q[PReg] <= reg_req.req && reg_rsp.gnt;
  end

  localparam logic [31:0] RegBase = 32'h4000_E000, CsrBase = 32'h4000_C000,
                          MemBase = 32'h8000_0000;

  task automatic reg_wr(input logic [11:0] off, input logic [31:0] v);
    logic [31:0] d;
    bit          e;
    bus_xfer(PReg, 1'b1, RegBase | 32'(off), v, 4'hF, d, e);
    if (e) error($sformatf("register write %03x answered with a bus error", off));
  endtask

  task automatic reg_rd(input logic [11:0] off, output logic [31:0] v);
    bit e;
    bus_xfer(PReg, 1'b0, RegBase | 32'(off), '0, 4'hF, v, e);
    if (e) error($sformatf("register read %03x answered with a bus error", off));
  endtask

  task automatic csr_wr(input logic [12:0] off, input logic [31:0] v);
    logic [31:0] d;
    bit          e;
    bus_xfer(PCsr, 1'b1, CsrBase | 32'(off), v, 4'hF, d, e);
    if (e) error($sformatf("CSR write %04x answered with a bus error", off));
  endtask

  task automatic csr_rd(input logic [12:0] off, output logic [31:0] v);
    bit e;
    bus_xfer(PCsr, 1'b0, CsrBase | 32'(off), '0, 4'hF, v, e);
    if (e) error($sformatf("CSR read %04x answered with a bus error", off));
  endtask

  int unsigned n_mem = 0;

  task automatic mem_wr(input logic [31:0] off, input logic [31:0] v, input logic [3:0] be,
                        output bit e);
    logic [31:0] d;
    bus_xfer(PMem, 1'b1, MemBase + off, v, be, d, e);
    n_mem++;
  endtask

  task automatic mem_rd(input logic [31:0] off, output logic [31:0] v, output bit e);
    bus_xfer(PMem, 1'b0, MemBase + off, '0, 4'hF, v, e);
    n_mem++;
  endtask

  // ======================================================= register map
  localparam logic [11:0] RId = 12'h000, RInfo = 12'h004, RCtrl = 12'h008, RCmd = 12'h00C,
                          RStatus = 12'h010, RIrqEn = 12'h014, RLat = 12'h01C,
                          RPsTarget = 12'h030, RPsNow = 12'h034, REmu = 12'h098,
                          RClkHz = 12'h09C, RStRd = 12'h0A0, RStWr = 12'h0A4, RStAct = 12'h0A8,
                          RStRef = 12'h0AC, RStRmw = 12'h0B0, RDbg = 12'h0B4,
                          RErrAddr = 12'h0B8, RCap = 12'h100;
  localparam logic [31:0] StBusy = 32'h1, StReady = 32'h2, StClkOk = 32'h4, StApplied = 32'h8,
                          StPsDone = 32'h20, StCapDone = 32'h40, StCmdErr = 32'h200,
                          StRfifoErr = 32'h400, StBusTimeout = 32'h800, StLink = 32'h2000,
                          StPsErr = 32'h4000, StRfifoBroken = 32'h8000, StInitDone = 32'h1_0000,
                          StInitError = 32'h2_0000, StRdLate = 32'h4_0000,
                          StRdExtra = 32'h8_0000, StNotReady = 32'h10_0000,
                          StRange = 32'h20_0000, StCsrErr = 32'h40_0000,
                          StBroken = 32'h80_0000;
  localparam logic [31:0] W1cAll = 32'h007C_4E68;
  localparam logic [31:0] CmdApply = 32'h1, CmdPsGo = 32'h2, CmdRfifoSync = 32'h10,
                          CmdSnap = 32'h20, CmdClrStats = 32'h40, CmdCapArm = 32'h100;
  localparam logic [31:0] CtrlEn = 32'h1, CtrlDmEn = 32'h10, CtrlDdr3 = 32'h20,
                          CtrlIdleDrive = 32'h40, CtrlLsEn = 32'h80, CtrlCkEn = 32'h800,
                          CtrlCoreRst = 32'h1000;
  localparam logic [31:0] LatReset = 32'h2224_0083;

  // LiteDRAM CSRs (generated/ddr<2|3>/csr.csv)
  localparam logic [12:0] CInitDone = 13'h0000, CInitError = 13'h0004, CDfiiCtrl = 13'h0800,
                          CChkReset = 13'h1000, CChkStart = 13'h1004, CChkDone = 13'h1008,
                          CChkBase = 13'h100C, CChkEnd = 13'h1010, CChkLength = 13'h1014,
                          CChkRandom = 13'h1018, CChkTicks = 13'h101C, CChkErrors = 13'h1020,
                          CGenReset = 13'h1800, CGenStart = 13'h1804, CGenDone = 13'h1808,
                          CGenBase = 13'h180C, CGenEnd = 13'h1810, CGenLength = 13'h1814,
                          CGenRandom = 13'h1818, CGenTicks = 13'h181C;
  function automatic logic [12:0] c_pi(int unsigned n, int unsigned reg_ix);
    // reg_ix: 0 command, 1 command_issue, 2 address, 3 baddress, 4 wrdata, 5 rddata
    return 13'h0804 + 13'(24 * n) + 13'(4 * reg_ix);
  endfunction
  localparam logic [31:0] DfiiSel = 32'h1, DfiiCke = 32'h2, DfiiOdt = 32'h4, DfiiResetN = 32'h8;
  localparam logic [31:0] DCs = 32'h01, DWe = 32'h02, DCas = 32'h04, DRas = 32'h08,
                          DWrdata = 32'h10, DRddata = 32'h20;
  localparam logic [31:0] OpPre = DRas | DWe | DCs, OpAct = DRas | DCs,
                          OpRef = DRas | DCas | DCs, OpWr = DCas | DWe | DCs | DWrdata,
                          OpRd = DCas | DCs | DRddata;

  // ============================================================ helpers
  localparam longint CmdTimeoutPs = 64'd200_000_000;      // 200 us

  task automatic wait_cycles(input int unsigned n);
    repeat (n) @(posedge clk);
  endtask

  // poll STATUS until (st & mask) == want; error on timeout
  task automatic poll_status(input logic [31:0] mask, input logic [31:0] want,
                             input longint timeout_ps, input string what,
                             output logic [31:0] st);
    longint t0;
    t0 = longint'($time);
    forever begin
      reg_rd(RStatus, st);
      if ((st & mask) == want) break;
      if (longint'($time) - t0 > timeout_ps) begin
        error($sformatf("%s: STATUS %08h, timeout", what, st));
        break;
      end
    end
  endtask

  // one channel command (CMD bit), wait for BUSY = 0; ok = no CMD_ERR (and
  // APPLIED / PS_DONE for APPLY / PS_GO)
  task automatic cmd(input logic [31:0] c, output bit ok);
    logic [31:0] st, flag;
    flag = (c == CmdApply) ? StApplied : (c == CmdPsGo) ? StPsDone : 32'h0;
    reg_wr(RStatus, StCmdErr | StApplied | StPsDone | StPsErr);
    reg_wr(RCmd, c);
    poll_status(StBusy, 32'h0, CmdTimeoutPs, "command", st);
    ok = (st & (StBusy | StCmdErr | StPsErr)) == 0 && (st & flag) == flag;
  endtask

  task automatic cmd_ok(input logic [31:0] c, input string what);
    bit ok;
    cmd(c, ok);
    if (!ok) error($sformatf("command %s failed", what));
  endtask

  // ------------------------------------------------------------- DFII
  task automatic dfii_cmd(input int unsigned ph, input logic [31:0] op, input logic [15:0] a,
                          input logic [2:0] ba);
    csr_wr(c_pi(ph, 2), 32'(a));
    csr_wr(c_pi(ph, 3), 32'(ba));
    csr_wr(c_pi(ph, 0), op);
    csr_wr(c_pi(ph, 1), 32'h1);
  endtask

  // burst bytes <-> pi<n>_wrdata / rddata: phase n = bytes 2n*Lanes .. (2n+2)*Lanes-1
  task automatic dfii_write(input logic [2:0] ba, input logic [15:0] col, input burst_t d);
    for (int unsigned n = 0; n < 4; n++) begin
      logic [31:0] v;
      v = '0;
      for (int unsigned b = 0; b < 2 * Lanes; b++) v[8 * b +: 8] = d[2 * Lanes * n + b];
      csr_wr(c_pi(n, 4), v);
    end
    dfii_cmd(2, OpWr, col, ba);
  endtask

  task automatic dfii_read(input logic [2:0] ba, input logic [15:0] col, input bit cap,
                           output burst_t d);
    if (cap) cmd_ok(CmdCapArm, "CAP_ARM");
    dfii_cmd(2, OpRd, col, ba);
    // the data reach the phase injectors ReadLatency (12) controller cycles
    // after the RD: faster than the next CSR access (LiteX firmware: cdelay)
    wait_cycles(64);
    d = '0;
    for (int unsigned n = 0; n < 4; n++) begin
      logic [31:0] v;
      csr_rd(c_pi(n, 5), v);
      for (int unsigned b = 0; b < 2 * Lanes; b++) d[2 * Lanes * n + b] = v[8 * b +: 8];
    end
  endtask

  // ====================================================== calibration
  localparam logic [7:0] CalP [8] = '{8'hA5, 8'h5A, 8'hF0, 8'h0F, 8'hC3, 8'h3C, 8'h96, 8'h69};
  localparam int unsigned CalMaxPoints = 64;

  // training burst: x8 P, x16 lanes P / ~P; inv: ~ of that (column 8)
  function automatic burst_t cal_burst(bit inv);
    burst_t d;
    d = '0;
    for (int i = 0; i < 8; i++) begin
      logic [7:0] v;
      v = inv ? ~CalP[i] : CalP[i];
      if (L != 0) begin
        d[2 * i]     = v;
        d[2 * i + 1] = ~v;
      end else begin
        d[i] = v;
      end
    end
    return d;
  endfunction

  // beat offset of P in the raw capture: smallest p in 0..56, -1 if absent
  task automatic cal_find(output int p);
    logic [15:0] b [64];
    logic [31:0] c;
    p = -1;
    for (int i = 0; i < 32; i++) begin
      reg_rd(RCap + 12'(4 * i), c);
      b[2 * i]     = (L != 0) ? c[15:0] : {8'h0, c[7:0]};
      b[2 * i + 1] = (L != 0) ? c[31:16] : {8'h0, c[15:8]};
    end
    for (int q = 0; q <= 56 && p < 0; q++) begin
      bit m;
      m = 1'b1;
      for (int j = 0; j < 8; j++) begin
        logic [15:0] want;
        want = {8'h0, CalP[j]};
        if (L != 0) want[15:8] = ~CalP[j];
        if (b[q + j] != want) m = 1'b0;
      end
      if (m) p = q;
    end
  endtask

  // REF, ACT, RD with raw capture, PRE of bank 0 row 0; p (-1: not found)
  task automatic cal_measure(output int p);
    burst_t      d;
    logic [31:0] st;
    dfii_cmd(0, OpRef, 16'h0, 3'd0);
    dfii_cmd(0, OpAct, 16'h0, 3'd0);
    reg_wr(RStatus, StCapDone);
    dfii_read(3'd0, 16'h0, 1'b1, d);
    dfii_cmd(0, OpPre, 16'h0, 3'd0);
    poll_status(StCapDone, StCapDone, CmdTimeoutPs, "CAP_DONE", st);
    cal_find(p);
  endtask

  // (a long phase move takes up to ~50 us: refresh first, all banks closed)
  task automatic phase_go(input int target);
    dfii_cmd(0, OpRef, 16'h0, 3'd0);
    reg_wr(RPsTarget, 32'(target) & 32'hFFFF);
    cmd_ok(CmdPsGo, "PS_GO");
  endtask

  int cal_map [CalMaxPoints];
  int cal_phase = 0, cal_p = -1, cal_width = 0;

  task automatic calibrate(input int npts_in, output bit ok);
    int          step, npts, best, best_len, p;
    logic [31:0] lat;
    burst_t      got;
    ok   = 1'b0;
    npts = (npts_in < 4) ? 4 : (npts_in > int'(CalMaxPoints)) ? int'(CalMaxPoints) : npts_in;
    step = int'(PsSteps) / npts;
    // 1 read phase 0 (reset value), FIFO synchronised there
    cmd_ok(CmdRfifoSync, "RFIFO_SYNC");
    wait_cycles(100);
    // 2 P at column 0, ~P at column 8 of bank 0 row 0
    dfii_cmd(0, OpAct, 16'h0, 3'd0);
    dfii_write(3'd0, 16'd0, cal_burst(1'b0));
    dfii_write(3'd0, 16'd8, cal_burst(1'b1));
    dfii_cmd(0, OpPre, 16'h0, 3'd0);
    // 3 sweep one CK period
    for (int i = 0; i < npts; i++) begin
      phase_go(i * step);
      cal_measure(cal_map[i]);
    end
    begin
      string s;
      s = "";
      for (int i = 0; i < npts; i++) s = {s, $sformatf(" %0d", cal_map[i])};
      $display("%0t ps: tb_bow_ddr: cal sweep (step %0d):%s", $time, step, s);
    end
    // 4 widest run of points with the same p; cyclic: one CK period later the
    // stream delivers the data one cycle (2 beats) earlier
    best     = 0;
    best_len = 0;
    for (int s = 0; s < npts; s++) begin
      int ps, prev, len;
      ps = cal_map[s];
      if (ps < 0) continue;
      prev = (s != 0) ? cal_map[s - 1] : cal_map[npts - 1] + 2;
      if (cal_map[(s != 0) ? s - 1 : npts - 1] >= 0 && prev == ps) continue;   // not a run start
      len = 1;
      while (len < npts) begin
        int j, vv;
        j  = s + len;
        vv = cal_map[j % npts];
        if (vv < 0 || vv - 2 * (j / npts) != ps) break;
        len++;
      end
      if (len > best_len) begin
        best     = s;
        best_len = len;
      end
    end
    cal_width = best_len * step;
    if (best_len == 0 || 5 * cal_width < int'(PsSteps)) begin
      error($sformatf("calibration: no eye of 20 %% of a CK period (best %0d points)", best_len));
      return;
    end
    begin
      int last, ka, kb, kc;
      last = best + best_len - 1;
      ka   = best * step;
      kb   = (last % npts) * step + (last / npts) * int'(PsSteps);
      kc   = (ka + kb) / 2;
      if (kc >= int'(PsSteps)) kc -= int'(PsSteps);
      cal_phase = kc;
    end
    // 5 centre of the eye, RD_DLY / RD_SLIP from the beat offset there
    phase_go(cal_phase);
    cal_measure(p);
    cal_p = p;
    if (p < 0 || (p >> 1) < 4 || (p >> 1) - 4 > 31) begin
      error($sformatf("calibration: pattern not found at the eye centre (p %0d)", p));
      return;
    end
    reg_rd(RLat, lat);
    lat = (lat & ~32'h0003_F000) | (32'((p >> 1) - 4) << 12) | (32'(p & 1) << 17);
    reg_wr(RLat, lat);
    cmd_ok(CmdApply, "APPLY of RD_DLY");
    if (32'(lat[5:0]) + 32'(lat[16:12]) + 32'(lat[17]) > 32'(4 * ReadLat - 16)) begin
      error($sformatf("calibration: RL + RD_DLY + RD_SLIP = %0d beyond the DFI read budget",
                      lat[5:0] + lat[16:12] + lat[17]));
    end
    // verify: col 0 = P, col 8 = ~P through the DFII read data
    dfii_cmd(0, OpRef, 16'h0, 3'd0);
    dfii_cmd(0, OpAct, 16'h0, 3'd0);
    ok = 1'b1;
    for (int c = 0; c < 2; c++) begin
      burst_t want;
      want = cal_burst(c != 0);
      dfii_read(3'd0, 16'(8 * c), 1'b0, got);
      for (int i = 0; i < int'(BB); i++) begin
        if (got[i] != want[i]) begin
          ok = 1'b0;
          error($sformatf("calibration verify: column %0d byte %0d = %02h, expected %02h",
                          8 * c, i, got[i], want[i]));
        end
      end
    end
    dfii_cmd(0, OpPre, 16'h0, 3'd0);
    $display("%0t ps: tb_bow_ddr: cal %s: read phase %0d, p %0d (RD_DLY %0d SLIP %0d), eye %0d of %0d steps, LAT %08h",
             $time, ok ? "OK" : "FAIL", cal_phase, p, (p >> 1) - 4, p & 1, cal_width, PsSteps, lat);
  endtask

  // CTRL.CORE_RST is set: release it, wait until the core answers (it comes
  // back in hardware mode, dfii_control = SEL: refresh runs, CKE high), then
  // the software hand-over again without dropping CKE: dfii_control = CKE |
  // ODT | RESET_N, PREA, SEL | CKE | ODT | RESET_N, init_done = 1, READY
  task automatic core_restart(input logic [31:0] ctrl, input string what);
    logic [31:0] v, st;
    bit          e;
    longint      t0;
    reg_wr(RCtrl, ctrl);
    t0 = longint'($time);
    forever begin
      bus_xfer(PCsr, 1'b0, CsrBase | 32'(CDfiiCtrl), '0, 4'hF, v, e);
      if (!e) break;
      if (longint'($time) - t0 > 64'd2_000_000) begin
        error($sformatf("%s: the CSRs do not answer after CORE_RST", what));
        break;
      end
    end
    expect_eq({what, ": dfii_control after CORE_RST"}, v, DfiiSel);
    reg_wr(RStatus, W1cAll);                     // flags of the test, refused polls
    csr_rd(CInitDone, v);
    expect_eq({what, ": init_done after CORE_RST"}, v, 32'h0);
    csr_wr(CDfiiCtrl, DfiiCke | DfiiOdt | DfiiResetN);
    dfii_cmd(0, OpPre, 16'h0400, 3'd0);
    csr_wr(CDfiiCtrl, DfiiSel | DfiiCke | DfiiOdt | DfiiResetN);
    csr_wr(CInitDone, 32'h1);
    poll_status(StReady | StBroken, StReady, 64'd10_000_000, {what, ": READY after CORE_RST"}, st);
  endtask

  // ============================================================ init.csv
  task automatic run_init(input string fn);
    int          fd, n, nl;
    string       line, kind;
    logic [31:0] addr, bank, val, dly;
    fd = $fopen(fn, "r");
    if (fd == 0) $fatal(1, "tb_bow_ddr: cannot open %s (+INIT)", fn);
    nl = 0;
    while (!$feof(fd)) begin
      line = "";
      void'($fgets(line, fd));
      if (line.len() < 4 || line[0] == "#" || line.substr(0, 3) == "kind") continue;
      // kind,address,bank,value,delay,comment
      for (int i = 0; i < line.len(); i++) if (line.getc(i) == ",") line.putc(i, " ");
      n = $sscanf(line, "%s %h %d %h %d", kind, addr, bank, val, dly);
      if (n != 5) $fatal(1, "tb_bow_ddr: %s: bad line '%s'", fn, line);
      if (kind == "ctrl") begin
        csr_wr(CDfiiCtrl, val);
      end else if (kind == "cmd") begin
        dfii_cmd(0, val, addr[15:0], bank[2:0]);
      end else begin
        $fatal(1, "tb_bow_ddr: %s: unknown kind '%s'", fn, kind);
      end
      wait_cycles(dly);                          // cdelay(n): n clk_i cycles
      nl++;
    end
    $fclose(fd);
    $display("%0t ps: tb_bow_ddr: init sequence %s: %0d steps", $time, fn, nl);
  endtask

  // ====================================================== window traffic
  logic [7:0] ref_mem [int unsigned];
  int unsigned exp_rd = 0, exp_wr = 0, exp_rmw = 0;
  bit          masked_mode = 1'b0;     // CTRL.DM_EN applied (HasDm only)

  // window write through the reference model (counts the expected statistics)
  task automatic win_write(input logic [31:0] off, input logic [31:0] v, input logic [3:0] be);
    bit e;
    mem_wr(off, v, be, e);
    if (e) error($sformatf("window write %08h answered with a bus error", off));
    for (int b = 0; b < 4; b++) if (be[b]) ref_mem[off + 32'(b)] = v[8 * b +: 8];
    if (be != 4'h0) begin
      exp_wr++;
      if (!masked_mode) begin          // no DM (or DM_EN = 0): read-modify-write
        exp_rd++;
        exp_rmw++;
      end
    end
  endtask

  task automatic win_check(input logic [31:0] off);
    logic [31:0] v, want;
    bit          e, known;
    mem_rd(off, v, e);
    exp_rd++;
    if (e) error($sformatf("window read %08h answered with a bus error", off));
    want  = '0;
    known = 1'b1;
    for (int b = 0; b < 4; b++) begin
      if (ref_mem.exists(off + 32'(b))) want[8 * b +: 8] = ref_mem[off + 32'(b)];
      else                              known = 1'b0;
    end
    if (known && v !== want) error($sformatf("window read %08h = %08h, expected %08h", off, v, want));
  endtask

  // ============================================================== main
  initial begin : watchdog
    int timeout_ms;
    timeout_ms = 20;
    void'($value$plusargs("TIMEOUT_MS=%d", timeout_ms));
    #(longint'(timeout_ms) * 1_000_000_000);
    $fatal(1, "tb_bow_ddr: simulated time limit of %0d ms reached (+TIMEOUT_MS)", timeout_ms);
  end

  logic [31:0] info_exp;
  assign info_exp = {5'(ReadLat), Ddr3, HasResetN, 1'b1, 8'((ClkHz + 500_000) / 1_000_000),
                     2'(PhyKind), HasDm, 2'(BankPins - 1), 4'(AddrPins - 1), 2'(Lanes - 1),
                     5'(DqBits)};

  initial begin
    int          seed, npts, nwin;
    string       init_fn;
    logic [31:0] v, st, ctrl, lat_ok;
    bit          e, ok;
    int unsigned total;

    seed = 1;
    void'($value$plusargs("SEED=%d", seed));
    void'($urandom(seed));
    npts = 16;
    void'($value$plusargs("CAL_POINTS=%d", npts));
    nwin = 800;
    void'($value$plusargs("NWIN=%d", nwin));
    if ($test$plusargs("WAVES")) begin
      $dumpfile("waves.fst");
      $dumpvars(0, tb_bow_ddr);
    end
    $display("tb_bow_ddr: DDR%0d x%0d (litedram_ddr%0d), %0d MHz, PHY kind %0d%s%s", Ddr3 ? 3 : 2,
             DqBits, DdrMem, (ClkHz + 500_000) / 1_000_000, PhyKind,
             (PhyKind == 2) ? " (loopback emulator)" : LevelShift ? " (TXV0108 card)" : " (direct board)",
             Stub ? ", STUB" : "");

    // power up: MMCMs, then the SoC reset
    #100_000;
    ck_on = 1'b1;
    repeat (8) @(posedge clk);
    #1;
    rst_n = 1'b1;
    wait_cycles(4);

    if (Stub) begin
      // ------------------------------------------------- DdrEn = 0
      reg_rd(RId, v);
      expect_eq("ID", v, IdValue);
      reg_rd(RInfo, v);
      expect_eq("INFO (stub)", v, 32'h0);
      reg_rd(RStatus, v);
      expect_eq("STATUS (stub)", v, 32'h0);
      mem_rd(32'h0, v, e);
      if (!e) error("stub: window read without bus error");
      mem_wr(32'h10, 32'h1234_5678, 4'hF, e);
      if (!e) error("stub: window write without bus error");
      bus_xfer(PCsr, 1'b0, CsrBase | 32'h800, '0, 4'hF, v, e);
      if (!e) error("stub: CSR read without bus error");
      bus_xfer(PCsr, 1'b1, CsrBase, 32'h1, 4'hF, v, e);
      if (!e) error("stub: CSR write without bus error");
      expect_eq("irq_o (stub)", 32'(irq), 32'h0);
    end else begin
      if (!$value$plusargs("INIT=%s", init_fn)) $fatal(1, "tb_bow_ddr: +INIT=<init.csv> missing");

      // ------------------------------------------- 1 link, identification
      poll_status(StLink | StClkOk, StLink | StClkOk, 64'd20_000_000, "link up", st);
      reg_rd(RId, v);
      expect_eq("ID", v, IdValue);
      reg_rd(RInfo, v);
      expect_eq("INFO", v, info_exp);
      reg_rd(REmu, v);
      expect_eq("EMU", v, (EmuBytes == 0) ? 32'h0 : 32'($clog2(EmuBytes)));
      reg_rd(RClkHz, v);
      expect_eq("CLK_HZ", v, ClkHz);
      reg_rd(RPsNow, v);
      expect_eq("PS_NOW", v, {16'(PsSteps), 16'h0});
      reg_rd(RCtrl, v);
      expect_eq("CTRL reset", v, 32'h40);
      reg_rd(RLat, v);
      expect_eq("LAT reset", v, LatReset);
      reg_rd(RStatus, v);
      expect_eq("STATUS after link up", v & ~StLink & ~StClkOk, 32'h0);

      // ------------------------------- 2 window before init_done, IRQ
      reg_wr(RIrqEn, StNotReady);
      mem_rd(32'h100, v, e);
      if (!e) error("window read before init_done: no bus error");
      reg_rd(RStatus, st);
      if (!st[20]) error("window read before init_done: NOT_READY not set");
      reg_rd(RErrAddr, v);
      expect_eq("ERR_ADDR", v, MemBase + 32'h100);
      wait_cycles(2);
      if (irq !== 1'b1) error("irq_o not set by NOT_READY with IRQ_EN");
      reg_wr(RStatus, StNotReady);
      wait_cycles(2);
      if (irq !== 1'b0) error("irq_o still set after clearing NOT_READY");
      reg_wr(RIrqEn, 32'h0);

      // ------------------------------------------ 3 DFII, CTRL, APPLY
      csr_rd(CDfiiCtrl, v);
      expect_eq("dfii_control reset", v, DfiiSel);
      csr_wr(CDfiiCtrl, 32'h0);                  // software control: CKE / RESET# low
      csr_rd(CDfiiCtrl, v);
      expect_eq("dfii_control", v, 32'h0);
      csr_rd(CInitDone, v);
      expect_eq("ddrctrl init_done", v, 32'h0);
      ctrl = CtrlEn | CtrlCkEn | CtrlLsEn | CtrlIdleDrive | (Ddr3 ? CtrlDdr3 : 32'h0);
      reg_wr(RCtrl, ctrl);
      // LAT: DDR2 CL3 = the reset value (RL 3, WL 2); DDR3 DLL-off RL 6, WL 6
      if (Ddr3) reg_wr(RLat, (LatReset & ~32'hFFF) | 32'd6 | (32'd6 << 6));
      cmd_ok(CmdApply, "APPLY");
      // DDR2: 200 us of clock with CKE low; DDR3: RESET# low 200 us
      #(201_000_000);

      // ---------------------------------------------- 4 JEDEC init
      run_init(init_fn);
      wait_cycles(200);
      if (dram_errs != 0) error($sformatf("DRAM model: %0d errors after the init", dram_errs));
      if (dram_init_done !== 1'b1) error("DRAM model: init sequence not complete");

      // ------------------------------------------------ 5 calibration
      calibrate(npts, ok);
      reg_rd(RLat, lat_ok);

      // -------------------------------------------------- 6 hand over
      dfii_cmd(0, OpPre, 16'h0400, 3'd0);        // PREA
      csr_wr(CDfiiCtrl, DfiiSel | DfiiCke | DfiiOdt | DfiiResetN);
      csr_wr(CInitDone, 32'h1);
      poll_status(StReady | StInitDone, StReady | StInitDone, 64'd10_000_000, "READY", st);

      // ---------------------------------------------- 7 window traffic
      cmd_ok(CmdClrStats, "CLR_STATS");
      exp_rd  = 0;
      exp_wr  = 0;
      exp_rmw = 0;
      // sequential words across two pages of every bank
      for (int unsigned i = 0; i < 128; i++) begin
        logic [31:0] off;
        off = 32'h1000 + 32'(i) * 32'd36;          // crosses lanes, bursts, banks
        off = off & ~32'h3;
        win_write(off, 32'hC0DE_0000 ^ (off * 32'h9E37_79B9), 4'hF);
      end
      for (int unsigned i = 0; i < 128; i++) begin
        logic [31:0] off;
        off = (32'h1000 + 32'(i) * 32'd36) & ~32'h3;
        win_check(off);
      end
      // random traffic in a 4 KiB region (all words written first) and
      // across the test range
      for (int unsigned w = 0; w < 4096; w += 4) win_write(32'h0010_0000 + 32'(w), $urandom, 4'hF);
      for (int i = 0; i < nwin; i++) begin
        logic [31:0] off, d;
        logic [3:0]  be;
        int          kind, sel, sub;
        kind = $urandom_range(9);
        if (kind < 8) off = 32'h0010_0000 + ($urandom_range(4095) & ~32'h3);
        else          off = ($urandom_range(TestBytes - 1) & ~32'h3);
        d   = $urandom;
        sel = $urandom_range(5);
        sub = $urandom_range(14);
        unique case (sel)
          0:       be = 4'hF;
          1:       be = 4'h3 << (2 * (sub & 1));
          2, 3:    be = 4'h1 << (sub & 3);
          4:       be = 4'(sub + 1);
          default: be = 4'h0;          // read
        endcase
        if (be == 4'h0 || kind == 9) begin
          win_check(off);
        end else begin
          win_write(off, d, be);
        end
      end
      // read back the whole region
      for (int unsigned w = 0; w < 4096; w += 4) win_check(32'h0010_0000 + 32'(w));
      cmd_ok(CmdSnap, "SNAP");
      reg_rd(RStRd, v);
      expect_eq("ST_RD", v, exp_rd);
      reg_rd(RStWr, v);
      expect_eq("ST_WR", v, exp_wr);
      reg_rd(RStRmw, v);
      expect_eq("ST_RMW", v, exp_rmw);
      reg_rd(RStAct, v);
      if (v == 0) error("ST_ACT = 0 after window traffic");
      reg_rd(RStRef, v);
      if (v == 0) error("ST_REF = 0 in hardware mode");
      $display("%0t ps: tb_bow_ddr: window traffic: %0d accesses, ST_RD %0d ST_WR %0d ST_RMW %0d",
               $time, n_mem, exp_rd, exp_wr, exp_rmw);

      // masked writes (DM pins, CTRL.DM_EN): no read-modify-write
      if (HasDm) begin
        reg_wr(RCtrl, ctrl | CtrlDmEn);
        cmd_ok(CmdApply, "APPLY (DM_EN)");
        masked_mode = 1'b1;
        cmd_ok(CmdClrStats, "CLR_STATS");
        exp_rd  = 0;
        exp_wr  = 0;
        exp_rmw = 0;
        for (int i = 0; i < 200; i++) begin
          logic [31:0] off;
          off = 32'h0010_0000 + ($urandom_range(4095) & ~32'h3);
          if ($urandom_range(1) != 0) win_write(off, $urandom, 4'(32'h1 << $urandom_range(3)));
          else                        win_check(off);
        end
        for (int unsigned w = 0; w < 4096; w += 4) win_check(32'h0010_0000 + 32'(w));
        cmd_ok(CmdSnap, "SNAP");
        reg_rd(RStRmw, v);
        expect_eq("ST_RMW with DM_EN", v, 32'h0);
        reg_rd(RStWr, v);
        expect_eq("ST_WR with DM_EN", v, exp_wr);
        reg_rd(RStRd, v);
        expect_eq("ST_RD with DM_EN", v, exp_rd);
        reg_wr(RCtrl, ctrl);
        cmd_ok(CmdApply, "APPLY (DM_EN off)");
        masked_mode = 1'b0;
      end

      // ------------------------------------------------- 8 LiteDRAM BIST
      for (int pass = 0; pass < 4; pass++) begin
        logic [31:0] base, len, ticks, errs;
        base = 32'h0020_0000;
        len  = 32'h0000_8000;                    // 32 KiB
        // generator (pass 0 counter data, 1 random data), checker with the
        // same data (pass 2: checker with the other data must fail); pass 3:
        // random data AND random addresses (row conflicts in the bank
        // machines; LiteDRAM's addresses repeat and its mask, given in bytes,
        // is applied to word addresses: up to 8 x len above base, away from
        // the window data; the checker count is not meaningful then)
        csr_wr(CGenReset, 32'h1);
        csr_wr(CGenReset, 32'h0);
        csr_wr(CGenBase, base);
        csr_wr(CGenEnd, base + len);
        csr_wr(CGenLength, len);
        csr_wr(CGenRandom, (pass == 1) ? 32'h1 : (pass == 3) ? 32'h3 : 32'h0);
        csr_wr(CGenStart, 32'h1);
        begin
          longint t0;
          t0 = longint'($time);
          do begin
            csr_rd(CGenDone, v);
            if (longint'($time) - t0 > 64'd3_000_000_000) begin
              error("BIST generator: no done");
              break;
            end
          end while (v[0] != 1'b1);
        end
        csr_rd(CGenTicks, ticks);
        csr_wr(CChkReset, 32'h1);
        csr_wr(CChkReset, 32'h0);
        csr_wr(CChkBase, base);
        csr_wr(CChkEnd, base + len);
        csr_wr(CChkLength, len);
        csr_wr(CChkRandom, (pass == 0) ? 32'h0 : (pass == 3) ? 32'h3 : 32'h1);
        csr_wr(CChkStart, 32'h1);
        begin
          longint t0;
          t0 = longint'($time);
          do begin
            csr_rd(CChkDone, v);
            if (longint'($time) - t0 > 64'd3_000_000_000) begin
              error("BIST checker: no done");
              break;
            end
          end while (v[0] != 1'b1);
        end
        csr_rd(CChkErrors, errs);
        $display("%0t ps: tb_bow_ddr: BIST pass %0d (%s): %0d bytes, generator %0d ticks, checker errors %0d",
                 $time, pass, (pass == 1) ? "random data" : (pass == 3) ? "random data and addresses" :
                 "counter data", len, ticks, errs);
        if (pass < 2 && errs != 0) error($sformatf("BIST pass %0d: %0d errors", pass, errs));
        if (pass == 2 && errs == 0) error("BIST checker with other data: no errors counted");
      end
      // the window data are still there
      for (int unsigned w = 0; w < 4096; w += 64) win_check(32'h0010_0000 + 32'(w));

      // ---------------------------------------------------- 9 RANGE
      reg_wr(RStatus, W1cAll);
      mem_rd(MemBytes, v, e);
      if (!e) error("window read at the DRAM size: no bus error");
      reg_rd(RStatus, st);
      if (!st[21]) error("window read at the DRAM size: RANGE not set");
      reg_rd(RErrAddr, v);
      expect_eq("ERR_ADDR (RANGE)", v, MemBase + MemBytes);
      mem_wr(32'h1FFF_FFFC, 32'h0, 4'hF, e);
      if (!e) error("window write at the end of the decode: no bus error");
      reg_wr(RStatus, StRange);

      // ------------------------------------------- RD budget, RD_LATE
      // window reads (LiteDRAM RD phase 2): RL + RD_DLY + RD_SLIP = 4 *
      // ReadLatency - 16 (32) is in time, one more is late (the data are
      // garbage either way: only the flags are checked)
      for (int over = 0; over < 2; over++) begin
        int dly;
        dly = int'(4 * ReadLat - 16) - int'(lat_ok[5:0]) - 1 + over;   // RD_SLIP = 1
        reg_wr(RLat, (lat_ok & ~32'h0003_F000) | (32'(dly) << 12) | (32'd1 << 17));
        cmd_ok(CmdApply, "APPLY (RD_DLY budget)");
        reg_wr(RStatus, StRdLate | StRdExtra);
        mem_rd(32'h0010_0000, v, e);
        if (e) error("RD budget read answered with a bus error");
        mem_rd(32'h0010_0040, v, e);
        reg_rd(RStatus, st);
        if (over == 0 && st[18]) error($sformatf("RL + RD_DLY + RD_SLIP = %0d: RD_LATE set", 4 * ReadLat - 16));
        if (over == 1 && !st[18]) error($sformatf("RL + RD_DLY + RD_SLIP = %0d: RD_LATE not set", 4 * ReadLat - 15));
        if (st[19]) error("RD budget: RD_EXTRA set (late bursts not discarded)");
      end
      reg_wr(RLat, lat_ok);
      cmd_ok(CmdApply, "APPLY (calibrated LAT)");
      reg_wr(RStatus, StRdLate | StRdExtra);
      for (int unsigned w = 0; w < 1024; w += 128) win_check(32'h0010_0000 + 32'(w));
      reg_rd(RStatus, st);
      if (st[18] || st[19]) error($sformatf("RD_LATE / RD_EXTRA after restoring LAT: STATUS %08h", st));

      // ---------------------------------------------------- CORE_RST
      reg_wr(RCtrl, ctrl | CtrlCoreRst);
      wait_cycles(8);
      reg_rd(RStatus, st);
      if (st[1] || st[16]) error($sformatf("CORE_RST: READY / INIT_DONE still set (STATUS %08h)", st));
      if (st[23]) error("CORE_RST: BROKEN set");
      mem_rd(32'h0010_0000, v, e);
      if (!e) error("CORE_RST: window read without bus error");
      bus_xfer(PCsr, 1'b0, CsrBase | 32'h800, '0, 4'hF, v, e);
      if (!e) error("CORE_RST: CSR read without bus error");
      reg_rd(RStatus, st);
      if (!st[20] || !st[22]) error($sformatf("CORE_RST: NOT_READY / CSR_ERR not set (STATUS %08h)", st));
      reg_rd(RCtrl, v);
      expect_eq("CTRL with CORE_RST", v, ctrl | CtrlCoreRst);
      core_restart(ctrl, "CORE_RST");
      for (int unsigned w = 0; w < 4096; w += 128) win_check(32'h0010_0000 + 32'(w));
      win_write(32'h0010_0004, 32'h5555_AAAA, 4'h6);
      win_check(32'h0010_0004);

      // ---------------------------------- window timeout, BROKEN, recovery
      hang_win = 1'b1;
      mem_rd(32'h0010_0008, v, e);
      if (!e) error("window timeout: no bus error");
      reg_rd(RStatus, st);
      if (!st[11] || !st[23] || st[1]) error($sformatf("window timeout: STATUS %08h (BUS_TIMEOUT, BROKEN, !READY)", st));
      reg_rd(RErrAddr, v);
      expect_eq("ERR_ADDR (timeout)", v, MemBase + 32'h0010_0008);
      mem_rd(32'h0010_0008, v, e);
      if (!e) error("window access while BROKEN: no bus error");
      csr_rd(CInitDone, v);                      // the CSR bridge still works
      expect_eq("init_done while the window is BROKEN", v, 32'h1);
      reg_wr(RCtrl, ctrl | CtrlCoreRst);         // the stuck access is cleared ...
      wait_cycles(8);
      hang_win = 1'b0;                           // ... before the port moves again
      reg_rd(RStatus, st);
      if (st[23]) error("CORE_RST did not clear BROKEN");
      core_restart(ctrl, "window timeout");
      for (int unsigned w = 0; w < 4096; w += 256) win_check(32'h0010_0000 + 32'(w));

      // ------------------------------------- CSR timeout, BROKEN, recovery
      hang_csr = 1'b1;
      bus_xfer(PCsr, 1'b0, CsrBase | 32'(CInitDone), '0, 4'hF, v, e);
      if (!e) error("CSR timeout: no bus error");
      reg_rd(RStatus, st);
      if (!st[11] || !st[22] || !st[23]) error($sformatf("CSR timeout: STATUS %08h (BUS_TIMEOUT, CSR_ERR, BROKEN)", st));
      reg_wr(RStatus, StCsrErr);
      bus_xfer(PCsr, 1'b0, CsrBase | 32'(CInitDone), '0, 4'hF, v, e);
      if (!e) error("CSR access while the CSR bridge is dead: no bus error");
      mem_rd(32'h0010_0000, v, e);
      if (!e) error("window access while BROKEN (CSR bridge): no bus error");
      reg_wr(RCtrl, ctrl | CtrlCoreRst);
      wait_cycles(8);
      hang_csr = 1'b0;
      core_restart(ctrl, "CSR timeout");
      for (int unsigned w = 0; w < 4096; w += 256) win_check(32'h0010_0000 + 32'(w));

      // ------------------------------------- command channel corner cases
      reg_wr(RStatus, StCmdErr);
      reg_wr(RCmd, CmdApply | CmdSnap);          // two bits: refused
      reg_rd(RStatus, st);
      if (!st[9] || st[0]) error($sformatf("CMD with two bits: STATUS %08h (CMD_ERR, !BUSY)", st));
      reg_wr(RStatus, StCmdErr);
      reg_wr(RPsTarget + 12'h024, 32'd10);       // WPS_TARGET: write phase +10 steps
      cmd(32'h80, ok);
      reg_rd(RPsNow + 12'h024, v);               // WPS_NOW
      if (!ok || v[15:0] != 16'd10) error($sformatf("WPS_GO +10: ok %0d, WPS_NOW %08h", ok, v));
      reg_wr(RPsTarget + 12'h024, 32'(PsSteps / 4 + 1));
      cmd(32'h80, ok);
      reg_rd(RStatus, st);
      if (ok || !st[5] || !st[14]) error($sformatf("WPS_GO beyond PsSteps / 4: STATUS %08h", st));
      reg_wr(RPsTarget + 12'h024, 32'd0);
      cmd(32'h80, ok);
      if (!ok) error("WPS_GO back to 0 failed");
      reg_wr(RPsTarget, 32'(cal_phase + 2 * int'(PsSteps) + 1));   // > 2 * PsSteps from the sync
      cmd(CmdPsGo, ok);
      reg_rd(RPsNow, v);
      if (ok || v[15:0] != 16'(cal_phase)) error($sformatf("PS_GO beyond 2 * PsSteps: ok %0d, PS_NOW %08h", ok, v));
      reg_wr(RStatus, W1cAll);
      for (int unsigned w = 0; w < 4096; w += 512) win_check(32'h0010_0000 + 32'(w));

      // ---------------------------------------------------------- 10 end
      wait_cycles(500);
      reg_rd(RStatus, st);
      reg_rd(RCtrl, v);
      if (st & (StRdExtra | StRfifoErr | StBusTimeout | StBroken | StRfifoBroken | StCmdErr |
                StInitError | StCsrErr | StNotReady | StRange | StRdLate)) begin
        error($sformatf("final STATUS %08h: unexpected error flags", st));
      end
      reg_rd(RDbg, v);
      if (PhyKind == 2 && (v[31] || v[15:0] != 16'h0)) begin
        error($sformatf("emulator DBG %08h: JEDEC rule error code %02h", v, v[23:16]));
      end
      if (PhyKind == 2 && !v[30]) error($sformatf("emulator DBG %08h: init not done", v));
      $display("%0t ps: tb_bow_ddr: DBG %08h, cal phase %0d p %0d LAT %08h", $time, v, cal_phase,
               cal_p, lat_ok);
    end

    total = tb_errs + proto_errs + dram_errs + contention + floats;
    $display("tb_bow_ddr: %0d window accesses; errors: testbench %0d, bus protocol %0d, DRAM model %0d, board contention %0d / floats %0d",
             n_mem, tb_errs, proto_errs, dram_errs, contention, floats);
    $display("tb_bow_ddr: %s (%0d errors) at %0t ps", (total == 0) ? "PASS" : "FAIL", total, $time);
    $finish;
  end

endmodule
