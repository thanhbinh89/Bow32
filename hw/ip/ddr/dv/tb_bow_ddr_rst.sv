// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Reset and clock-domain-crossing corner cases of bow_ddr (DDR2 x8 core,
// 133.33 MHz, 504 phase steps). No DRAM model: the read data at the pads are
// the constant A5 on every edge, which is all the bridges need. Parts:
//   A  short CTRL.CORE_RST pulses (1..6 clk_i cycles, several clock phases)
//      followed at once by a CSR read or a window read: the access is refused
//      within a few cycles, never left to the bridge timeout (BUS_TIMEOUT,
//      BROKEN).
//   B  window byte stores (read-modify-write) on a running controller with
//      CORE_RST at a sweep of times during the access: every WR burst that
//      reaches the PHY is the merged word (A5 bytes, the stored 0x11 in its
//      lane), never the cleared payload (zeros) of a bridge already in reset
//      while the core still issues the write it had accepted.
//   A2 a CSR read presented in the same cycle as, or the cycle after, the
//      CTRL write that clears CORE_RST: refused at once as well.
//   C  a SoC reset (rst_ni) with the MMCMs running, in the middle of a write
//      phase move: the steppers finish the move, WPS_NOW / PS_NOW equal the
//      phases of the clock model, a read phase command right after the reset
//      waits for the write phase move, and the +-PsSteps / 4 limit of the
//      write phase still counts from the real phase 0.
//   D  init_done cleared over the CSR port (as firmware does before DFII
//      sections) while a window read or byte store is in flight: the access
//      is answered (refused before its launch, or completed), never left to
//      the bridge timeout.
//   E  the DDR clocks stop (MMCMs still locked) while a window read or a CSR
//      read is in flight: bus error with BUS_TIMEOUT and BROKEN (CSR: and
//      CSR_ERR), not NOT_READY; an MMCM restart (link reset) clears it.
// Prints "tb_bow_ddr_rst: PASS" or "tb_bow_ddr_rst: FAIL (<n> errors)".
`timescale 1ps / 1ps

module tb_bow_ddr_rst import bow_bus_pkg::*; import bow_ddr_pkg::*;;

  localparam int unsigned PsSteps = 504;

  logic clk = 1'b0, rst_n = 1'b0;
  always #10_000 clk = ~clk;                       // clk_i 50 MHz

  logic ck_on = 1'b0;
  logic ddr_clk, sys_clk, wclk, wclk90, rd_clk, locked;
  logic ps_en, ps_inc, ps_done, wps_en, wps_inc, wps_done;

  ddr_clk_model #(.TckPs(7500), .PsSteps(PsSteps)) u_clk (
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

  bus_req_t    mem_req = '0, csr_req = '0, reg_req = '0;
  bus_rsp_t    mem_rsp, csr_rsp, reg_rsp;
  logic        irq;
  ddr_io_out_t io_o;
  ddr_io_in_t  io_i;

  always_comb begin
    io_i = '0;
    io_i.dq[0][7:0] = 8'hA5;
    io_i.dq[1][7:0] = 8'hA5;
  end

  bow_ddr #(
    .DdrMem     (2),
    .ClkHz      (133_333_333),
    .PsSteps    (PsSteps),
    .PhyKind    (2),
    .EmuBytes   (0),
    .WinTimeout (4096)
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
    .ddr_dbg_i      (32'h0)
  );

  localparam logic [31:0] Phy = 32'h4000_E000, Ctrlr = 32'h4000_C000, Win = 32'h8000_0000;
  localparam logic [31:0] RCtrl = Phy + 32'h008, RCmd = Phy + 32'h00C, RStatus = Phy + 32'h010,
                          RPsTarget = Phy + 32'h030, RPsNow = Phy + 32'h034,
                          RWpsTarget = Phy + 32'h054, RWpsNow = Phy + 32'h058;
  localparam logic [31:0] CtrlIdle = 32'h0000_0040;    // IDLE_DRIVE (reset value)
  localparam logic [31:0] CtrlRun  = 32'h0000_0841;    // EN | IDLE_DRIVE | CK_EN
  localparam logic [31:0] CtrlRst  = 32'h0000_1000;    // CORE_RST
  localparam logic [31:0] CInitDone = Ctrlr + 32'h000, CDfiiControl = Ctrlr + 32'h800;
  localparam int unsigned StBusy = 0, StReady = 1, StClkOk = 2, StPsErr = 14, StBusTimeout = 11,
                          StNotReady = 20, StCsrErr = 22, StBroken = 23;

  int errors = 0;

  task automatic error(input string msg);
    errors++;
    $display("%0t ps: ERROR %s", $time, msg);
  endtask

  // ---------------------------------------------------------------- BFMs
  // drive after the clock edge, sample at the edge
  task automatic reg_wr(input logic [31:0] a, input logic [31:0] d);
    @(posedge clk); #1;
    reg_req = '{req: 1'b1, we: 1'b1, be: 4'hF, addr: a, wdata: d};
    @(posedge clk); #1;
    reg_req = '0;
  endtask

  task automatic reg_rd(input logic [31:0] a, output logic [31:0] d);
    @(posedge clk); #1;
    reg_req = '{req: 1'b1, we: 1'b0, be: 4'hF, addr: a, wdata: '0};
    @(posedge clk); #1;
    reg_req = '0;
    @(posedge clk);
    d = reg_rsp.rdata;
  endtask

  // one access on a stalling port (window or CSR): cycles from req to rvalid
  task automatic access(input bit is_mem, input bit we, input logic [3:0] be,
                        input logic [31:0] a, input logic [31:0] wd,
                        output logic [31:0] d, output logic e, output int cyc);
    bus_req_t r;
    r = '{req: 1'b1, we: we, be: be, addr: a, wdata: wd};
    @(posedge clk); #1;
    if (is_mem) mem_req = r; else csr_req = r;
    finish_access(is_mem, d, e, cyc);
  endtask

  // the rest of an access whose request is already on the port
  task automatic finish_access(input bit is_mem, output logic [31:0] d, output logic e,
                               output int cyc);
    cyc = 0;
    forever begin
      @(posedge clk);
      cyc++;
      if (is_mem ? mem_rsp.gnt : csr_rsp.gnt) break;
      if (cyc > 100_000) $fatal(1, "tb_bow_ddr_rst: no gnt");
    end
    #1;
    if (is_mem) mem_req = '0; else csr_req = '0;
    @(posedge clk);
    cyc++;
    d = is_mem ? mem_rsp.rdata : csr_rsp.rdata;
    e = is_mem ? mem_rsp.err : csr_rsp.err;
  endtask

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  // CORE_RST = 1 for w cycles (back-to-back register writes), then ctrl
  task automatic core_rst_pulse(input logic [31:0] ctrl, input int w);
    @(posedge clk); #1;
    reg_req = '{req: 1'b1, we: 1'b1, be: 4'hF, addr: RCtrl, wdata: ctrl | CtrlRst};
    repeat (w) @(posedge clk);
    #1;
    reg_req = '{req: 1'b1, we: 1'b1, be: 4'hF, addr: RCtrl, wdata: ctrl};
    @(posedge clk); #1;
    reg_req = '0;
  endtask

  // a long CORE_RST pulse (clears BROKEN), the CSRs answer again
  task automatic core_restart(input logic [31:0] ctrl);
    reg_wr(RCtrl, ctrl | CtrlRst);
    wait_cycles(40);
    reg_wr(RCtrl, ctrl);
    wait_cycles(60);
    reg_wr(RStatus, 32'h00FF_FFFF);
  endtask

  task automatic wait_idle(input string what);
    logic [31:0] st;
    int          n;
    n = 0;
    do begin
      reg_rd(RStatus, st);
      n++;
    end while (st[StBusy] && n < 2000);
    if (st[StBusy]) error({what, ": BUSY stays 1"});
  endtask

  task automatic phase_cmd(input bit write, input int target, input string what);
    reg_wr(write ? RWpsTarget : RPsTarget, 32'(target));
    reg_wr(RCmd, write ? 32'h80 : 32'h02);
    wait_idle(what);
  endtask

  // ------------------------------------- every WR command into the PHY (B)
  bit in_b = 1'b0;
  int wr_total = 0, wr_bad = 0;

  always @(posedge ddr_clk) begin
    if (in_b && dut.phy_cmd_v && dut.phy_cmd_code == CmdWr) begin
      bit bad;
      bad = 1'b0;
      for (int b = 0; b < 8; b++) begin
        if (dut.phy_wr_bytes[b] != 8'hA5 && dut.phy_wr_bytes[b] != 8'h11) bad = 1'b1;
      end
      wr_total++;
      if (bad) begin
        wr_bad++;
        error($sformatf("B: WR burst %h to the DRAM (bank %0d a %h): not the merged word",
                        dut.phy_wr_bytes[7:0], dut.phy_cmd_ba, dut.phy_cmd_a));
      end
    end
  end

  // ---------------------------------------------------------------- tests
  initial begin
    logic [31:0] st, d;
    logic        e;
    int          cyc, slow;

    #100_000 ck_on = 1'b1;
    #200_000 rst_n = 1'b1;
    do reg_rd(RStatus, st); while (!st[StClkOk]);
    wait_cycles(20);

    // ------------------------------------------------ A short CORE_RST
    slow = 0;
    for (int ph = 0; ph < 6; ph++) begin
      for (int w = 1; w <= 4; w++) begin
        wait_cycles(ph);
        core_rst_pulse(CtrlIdle, w);
        access(1'b0, 1'b0, 4'hF, CDfiiControl, '0, d, e, cyc);
        reg_rd(RStatus, st);
        if (cyc > 100 || st[StBusTimeout] || st[StBroken]) begin
          slow++;
          error($sformatf("A: CSR read after a %0d-cycle CORE_RST (phase %0d): %0d cycles, STATUS %08h",
                          w, ph, cyc, st));
        end
        core_restart(CtrlIdle);
      end
    end
    for (int ph = 0; ph < 6; ph++) begin
      for (int w = 1; w <= 6; w++) begin
        for (int g = 0; g <= 2; g++) begin
          access(1'b0, 1'b1, 4'hF, CInitDone, 32'h1, d, e, cyc);   // hand over (no DRAM)
          wait_cycles(10 + ph);
          reg_rd(RStatus, st);
          if (!st[StReady]) error($sformatf("A: READY not set before the pulse (STATUS %08h)", st));
          core_rst_pulse(CtrlIdle, w);
          wait_cycles(g);
          access(1'b1, 1'b0, 4'hF, Win + 32'h40, '0, d, e, cyc);
          reg_rd(RStatus, st);
          // the core reset clears init_done: the read is refused at once
          if (cyc > 100 || st[StBusTimeout] || st[StBroken]) begin
            slow++;
            error($sformatf("A: window read %0d cycles after a %0d-cycle CORE_RST (phase %0d): %0d cycles, STATUS %08h",
                            g, w, ph, cyc, st));
          end else if (!e || !st[StNotReady]) begin
            error($sformatf("A: window read after CORE_RST: err %0d, STATUS %08h (NOT_READY)", e, st));
          end
          core_restart(CtrlIdle);
        end
      end
    end
    // A2: the CSR read in the same cycle as / the cycle after the write that
    // clears CORE_RST
    for (int g = 0; g <= 1; g++) begin
      for (int w = 1; w <= 3; w++) begin
        for (int ph = 0; ph < 4; ph++) begin
          wait_cycles(ph);
          @(posedge clk); #1;
          reg_req = '{req: 1'b1, we: 1'b1, be: 4'hF, addr: RCtrl, wdata: CtrlIdle | CtrlRst};
          repeat (w) @(posedge clk);
          #1;
          reg_req = '{req: 1'b1, we: 1'b1, be: 4'hF, addr: RCtrl, wdata: CtrlIdle};
          if (g == 0) csr_req = '{req: 1'b1, we: 1'b0, be: 4'hF, addr: CDfiiControl, wdata: '0};
          @(posedge clk); #1;
          reg_req = '0;
          if (g == 1) csr_req = '{req: 1'b1, we: 1'b0, be: 4'hF, addr: CDfiiControl, wdata: '0};
          finish_access(1'b0, d, e, cyc);
          reg_rd(RStatus, st);
          if (cyc > 100 || st[StBusTimeout] || st[StBroken]) begin
            slow++;
            error($sformatf("A2: CSR read %0d cycle(s) after the CORE_RST clear (%0d-cycle pulse, phase %0d): %0d cycles, STATUS %08h",
                            g, w, ph, cyc, st));
          end
          core_restart(CtrlIdle);
        end
      end
    end
    $display("%0t ps: A: short CORE_RST pulses, %0d accesses left to the timeout", $time, slow);

    // ------------------------------------- B CORE_RST during byte stores
    reg_wr(RCtrl, CtrlRun);
    reg_wr(RCmd, 32'h1);                                          // APPLY
    wait_idle("B: APPLY");
    access(1'b0, 1'b1, 4'hF, CInitDone, 32'h1, d, e, cyc);
    wait_cycles(20);
    in_b = 1'b1;
    access(1'b1, 1'b1, 4'h1, Win + 32'h100, 32'h11, d, e, cyc);
    if (e || wr_total != 1) error($sformatf("B: plain byte store: err %0d, %0d WR", e, wr_total));
    for (int k = 0; k < 120; k++) begin
      fork
        access(1'b1, 1'b1, 4'h1 << (k % 4), Win + 32'h200 + 32'(8 * k), 32'h1111_1111, d, e, cyc);
        begin
          wait_cycles(25 + (k % 40));
          core_rst_pulse(CtrlRun, 1);
        end
      join
      wait_cycles(40);
      access(1'b0, 1'b1, 4'hF, CInitDone, 32'h1, d, e, cyc);    // hand over again
      wait_cycles(20);
      reg_wr(RStatus, 32'h00FF_FFFF);
    end
    $display("%0t ps: B: %0d WR bursts, %0d not the merged word", $time, wr_total, wr_bad);
    if (wr_total < 30) error($sformatf("B: only %0d WR bursts (the sweep missed the writes)", wr_total));

    // ---------------------- D init_done cleared with a window access in flight
    slow = 0;
    for (int k = 0; k < 48; k++) begin
      logic [31:0] d2;
      logic        e2;
      int          cyc2;
      fork
        access(1'b1, k[0], k[0] ? (4'h1 << (k % 4)) : 4'hF, Win + 32'h800 + 32'(8 * k),
               32'h1111_1111, d, e, cyc);
        access(1'b0, 1'b1, 4'hF, CInitDone, 32'h0, d2, e2, cyc2);
      join
      reg_rd(RStatus, st);
      if (cyc > 200 || st[StBusTimeout] || st[StBroken] || (e && !st[StNotReady])) begin
        slow++;
        error($sformatf("D: window %s with init_done cleared: err %0d after %0d cycles, STATUS %08h",
                        k[0] ? "store" : "read", e, cyc, st));
      end
      access(1'b0, 1'b1, 4'hF, CInitDone, 32'h1, d, e, cyc);   // hand over again
      wait_cycles(20 + (k % 7));
      reg_wr(RStatus, 32'h00FF_FFFF);
    end
    in_b = 1'b0;
    $display("%0t ps: D: init_done cleared during window accesses, %0d left to the timeout", $time, slow);

    // ------------------------------------ C SoC reset during a phase move
    phase_cmd(1'b1, 20, "C: WPS_GO +20");
    reg_wr(RWpsTarget, 32'd100);
    reg_wr(RCmd, 32'h80);
    wait_cycles(150);
    if (u_clk.wps_phase <= 20 || u_clk.wps_phase >= 100) begin
      error($sformatf("C: write phase %0d at the reset: not in the middle of the move",
                      u_clk.wps_phase));
    end
    @(posedge clk); #1 rst_n = 1'b0;
    wait_cycles(10);
    #1 rst_n = 1'b1;
    do reg_rd(RStatus, st); while (!st[StClkOk]);
    phase_cmd(1'b0, 40, "C: PS_GO 40 after the reset");
    reg_rd(RStatus, st);
    if (st[StPsErr]) error($sformatf("C: PS_GO 40 after the reset refused (STATUS %08h)", st));
    reg_rd(RWpsNow, d);
    if ($signed(d[15:0]) != 100 || u_clk.wps_phase != 100) begin
      error($sformatf("C: after the reset WPS_NOW %0d, write phase %0d (want 100)",
                      $signed(d[15:0]), u_clk.wps_phase));
    end
    reg_rd(RPsNow, d);
    if ($signed(d[15:0]) != 40 || u_clk.ps_phase != 40) begin
      error($sformatf("C: after the reset PS_NOW %0d, read phase %0d (want 40)",
                      $signed(d[15:0]), u_clk.ps_phase));
    end
    phase_cmd(1'b1, PsSteps / 4, "C: WPS_GO +T/4");
    if (u_clk.wps_phase != PsSteps / 4) begin
      error($sformatf("C: WPS_GO +%0d gives write phase %0d", PsSteps / 4, u_clk.wps_phase));
    end
    reg_wr(RStatus, 32'h00FF_FFFF);
    phase_cmd(1'b1, PsSteps / 4 + 1, "C: WPS_GO beyond T/4");
    reg_rd(RStatus, st);
    if (!st[StPsErr] || u_clk.wps_phase != PsSteps / 4) begin
      error($sformatf("C: WPS_GO +%0d not refused (STATUS %08h, write phase %0d)", PsSteps / 4 + 1,
                      st, u_clk.wps_phase));
    end
    phase_cmd(1'b1, 0, "C: WPS_GO 0");
    phase_cmd(1'b0, 0, "C: PS_GO 0");
    reg_rd(RWpsNow, d);
    if (d[15:0] != 16'd0 || u_clk.wps_phase != 0 || u_clk.ps_phase != 0) begin
      error($sformatf("C: back to 0: WPS_NOW %0d, phases %0d / %0d", $signed(d[15:0]),
                      u_clk.wps_phase, u_clk.ps_phase));
    end

    // ------------------- E DDR clocks lost (MMCMs locked) during an access
    for (int port = 0; port < 2; port++) begin
      reg_wr(RCtrl, CtrlRun);
      reg_wr(RCmd, 32'h1);
      wait_idle("E: APPLY");
      access(1'b0, 1'b1, 4'hF, CInitDone, 32'h1, d, e, cyc);
      wait_cycles(20);
      reg_wr(RStatus, 32'h00FF_FFFF);
      fork
        access(port == 0, 1'b0, 4'hF, (port == 0) ? Win + 32'h80 : CDfiiControl, '0, d, e, cyc);
        begin
          wait_cycles(3);                      // the access runs in the ddr_sys domain
          u_clk.freeze = 1'b1;                 // CK and CK / 4 stop, MMCMs still locked
        end
      join
      reg_rd(RStatus, st);
      $display("%0t ps: E: %s with the DDR clocks stopped: err %0d after %0d cycles, STATUS %08h", $time,
               port ? "CSR read" : "window read", e, cyc, st);
      if (!e || !st[StBusTimeout] || !st[StBroken] || st[StNotReady] || (port == 1 && !st[StCsrErr])) begin
        error($sformatf("E: %s with the DDR clocks stopped: err %0d after %0d cycles, STATUS %08h (want BUS_TIMEOUT, BROKEN%s, no NOT_READY)",
                        port ? "CSR read" : "window read", e, cyc, st, port ? ", CSR_ERR" : ""));
      end
      // MMCM restart: the link reset clears the dead bridge
      ck_on = 1'b0;
      wait (locked === 1'b0);
      wait_cycles(10);
      u_clk.freeze = 1'b0;
      ck_on = 1'b1;
      do reg_rd(RStatus, st); while (!st[StClkOk]);
      wait_cycles(64);
      reg_rd(RStatus, st);
      if (st[StBroken]) error($sformatf("E: BROKEN after the MMCM restart (STATUS %08h)", st));
      reg_wr(RStatus, 32'h00FF_FFFF);
    end

    $display("tb_bow_ddr_rst: %s (%0d errors) at %0t ps", errors ? "FAIL" : "PASS", errors, $time);
    $finish;
  end

  initial begin
    #3_000_000_000;
    $display("tb_bow_ddr_rst: FAIL (global timeout)");
    $finish;
  end

endmodule
