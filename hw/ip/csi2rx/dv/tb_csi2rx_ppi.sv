// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bench of the CSI-2 controller alone at its PPI (Verilator --binary --timing): step 3 of
// docs/ip/mipi_rx_arch.md, section 10 (since step 4 without the temporary band: the PHY's
// registers, RAW and status are the D-PHY's). The PHY is bow_ppi_bfm, in one of two timings
// (cfg 'ppi'):
//   1  the D-PHY of Bow32: the DUT is bow_csi2rx as in bow_mipi_rx (PPI of bow_ppi_pkg
//      driven by the BFM; INFO[6] = 1, but no D-PHY behind 0xC00: that window reads 0, the
//      D-PHY's interrupt input is 0)
//   2  a standard PHY: the DUT is the flat-port wrapper bow_csi2rx_ppi_flat
// Both DUTs are built (same Lanes, FifoDepth); the one not in use gets no clocks.
//
// Reads a test case of `tools/csi2/csi2_model.py gen DIR --ppi bow|std`:
//   DIR/cfg.txt   settings ('key value': ppi, lanes, byte_ps, ...)
//   DIR/stim.txt  the commands of tb_bow_csi2rx (rd, wr, wrbe, poll, wait, delay, waitbyte,
//                 tready, knob, mark, irqfe) and the PPI lines of the model (ppev, lperr, ppl,
//                 ppb, ppclk, ppon, ppoff, ppidle: see bow_ppi_bfm), played by the BFM;
//                 the TX items they render (pkt, lp, idle, clkon, clkburst, waitphy) and
//                 the model-only lines (nocheck, expect) are skipped
// and writes DIR/out.txt and DIR/regs.txt as tb_bow_csi2rx does (pixels with tuser /
// tlast, rd and poll results, 'fe' records, per segment invariants, burst end times),
// which `csi2_model.py check DIR` compares with the reference model.
//
// Invariants per segment: ppi_overlap = lane programs of the BFM that overlap (a rendering
// error), irq_fe = polls that found IRQ_STATUS.FE with IRQ_EN.FE and irq_o low, irq_stop =
// irqfe lines (test tclkpost: the byte clock stopped behind a frame's FE) at which irq_o was
// still low 2 us later, irq_stop_n = those at which it rose after the last byte clock edge;
// at the end irq_bad (irq_o = |(IRQ_STATUS & IRQ_EN)).
//
// Clocks: CPU 50 MHz, video 200 MHz (PhyClkHz, the lp clock of the D-PHY of Bow32), byte
// clock and the standard PHY's lp clock from the BFM; all unrelated.

`timescale 1ns / 1ps

module tb_csi2rx_ppi;
  import bow_bus_pkg::*;
  import bow_ppi_pkg::*;
  import csi2_tx_pkg::csi2_now;

  parameter int unsigned Lanes     = 2;
  parameter int unsigned FifoDepth = 256;
  localparam int unsigned CpuPs = 20000, VidPs = 5000;    // 50 MHz, 200 MHz
  localparam int unsigned PhyClkHz = 200_000_000;
  localparam int unsigned CpuClkHz = 1_000_000_000 / (CpuPs / 1000);

  logic clk = 1'b0, vclk = 1'b0;
  logic rst_n = 1'b1, vrst_n = 1'b1;
  bit   std = 1'b0;                                       // cfg ppi 2: the flat wrapper
  always #(CpuPs / 2000.0) clk = ~clk;
  always #(VidPs / 2000.0) vclk = ~vclk;

  // the DUT not in use gets no clocks
  logic clk_b, vclk_b, clk_s, vclk_s;
  assign clk_b  = clk & !std;
  assign vclk_b = vclk & !std;
  assign clk_s  = clk & std;
  assign vclk_s = vclk & std;

  bus_req_t req = BUS_REQ_DEFAULT, req_b, req_s;
  bus_rsp_t rsp, rsp_b, rsp_s;
  logic     irq, irq_b, irq_s;
  assign req_b = std ? BUS_REQ_DEFAULT : req;
  assign req_s = std ? req : BUS_REQ_DEFAULT;
  assign rsp   = std ? rsp_s : rsp_b;
  assign irq   = std ? irq_s : irq_b;

  logic       m_tready = 1'b1;
  logic       m_tvalid, m_tlast, mv_b, ml_b, mv_s, ml_s;
  logic [1:0] m_tuser, mu_b, mu_s;
  logic [9:0] m_tdata, md_b, md_s;
  assign m_tvalid = std ? mv_s : mv_b;
  assign m_tlast  = std ? ml_s : ml_b;
  assign m_tuser  = std ? mu_s : mu_b;
  assign m_tdata  = std ? md_s : md_b;

  // ------------------------------------------------------------------- BFM
  logic                  byte_clk, lp_clk;
  ppi_hs_t [Lanes-1:0]   ppi_hs;
  ppi_lp_t [Lanes-1:0]   ppi_lp;
  ppi_lp_clk_t           ppi_lp_clk;
  logic [Lanes-1:0]      enable, enable_b, enable_s;
  logic                  enable_clk, enable_clk_b, enable_clk_s;
  assign enable     = std ? enable_s : enable_b;
  assign enable_clk = std ? enable_clk_s : enable_clk_b;

  bow_ppi_bfm #(.Lanes (Lanes)) u_bfm (
    .vid_clk_i        (vclk),
    .lp_clk_o         (lp_clk),
    .rx_byte_clk_hs_o (byte_clk),
    .ppi_hs_o         (ppi_hs),
    .ppi_lp_o         (ppi_lp),
    .ppi_lp_clk_o     (ppi_lp_clk),
    .enable_i         (enable),
    .enable_clk_i     (enable_clk)
  );

  // ------------------------------------------- DUT 1: the controller, D-PHY of Bow32
  // (the DUT not in use also gets constant PPI inputs: nothing of it is evaluated)
  logic                byte_clk_b, byte_clk_s;
  ppi_hs_t [Lanes-1:0] ppi_hs_b, ppi_hs_s;
  ppi_lp_t [Lanes-1:0] ppi_lp_b, ppi_lp_s;
  ppi_lp_clk_t         ppi_lp_clk_b, ppi_lp_clk_s;
  assign byte_clk_b   = byte_clk & !std;
  assign byte_clk_s   = byte_clk & std;
  assign ppi_hs_b     = std ? '0 : ppi_hs;
  assign ppi_hs_s     = std ? ppi_hs : '0;
  assign ppi_lp_b     = std ? '0 : ppi_lp;
  assign ppi_lp_s     = std ? ppi_lp : '0;
  assign ppi_lp_clk_b = std ? '0 : ppi_lp_clk;
  assign ppi_lp_clk_s = std ? ppi_lp_clk : '0;

  bow_csi2rx #(
    .Lanes      (Lanes),
    .PhyClkHz   (PhyClkHz),
    .CpuClkHz   (CpuClkHz),
    .HasPhy     (1'b1),
    .FifoDepth  (FifoDepth),
    .DphyWin    (1'b1),                    // as in bow_mipi_rx (INFO[6])
    .PpiLpClkHz (PhyClkHz),
    .PpiByteClkHz (180_000_000)            // the BFM's byte clocks: 96 .. 180 MHz
  ) u_dut (
    .clk_i            (clk_b),
    .rst_ni           (rst_n),
    .bus_req_i        (req_b),
    .bus_rsp_o        (rsp_b),
    .irq_o            (irq_b),
    .csi_clk_i        (vclk_b),
    .csi_rst_ni       (vrst_n),
    .m_axis_tvalid_o  (mv_b),
    .m_axis_tready_i  (m_tready),
    .m_axis_tdata_o   (md_b),
    .m_axis_tuser_o   (mu_b),
    .m_axis_tlast_o   (ml_b),
    .rx_byte_clk_hs_i (byte_clk_b),
    .ppi_hs_i         (ppi_hs_b),
    .ppi_lp_i         (ppi_lp_b),
    .ppi_lp_clk_i     (ppi_lp_clk_b),
    .enable_o         (enable_b),
    .enable_clk_o     (enable_clk_b),
    .irq_i            (1'b0)                   // no D-PHY
  );

  // ------------------------------------------- DUT 2: the flat wrapper, standard PHY
  logic [Lanes-1:0][7:0] f_data;
  logic [Lanes-1:0]      f_valid, f_active, f_sync, f_skew, f_sot, f_sot_sync;
  logic [Lanes-1:0]      f_stop, f_ulps_not, f_ulps_esc, f_err, f_esc, f_sync_esc;

  for (genvar l = 0; l < Lanes; l++) begin : g_flat
    assign f_data[l]     = ppi_hs_s[l].rx_data_hs;
    assign f_valid[l]    = ppi_hs_s[l].rx_valid_hs;
    assign f_active[l]   = ppi_hs_s[l].rx_active_hs;
    assign f_sync[l]     = ppi_hs_s[l].rx_sync_hs;
    assign f_skew[l]     = ppi_hs_s[l].rx_skew_cal_hs;
    assign f_sot[l]      = ppi_hs_s[l].err_sot_hs;
    assign f_sot_sync[l] = ppi_hs_s[l].err_sot_sync_hs;
    assign f_stop[l]     = ppi_lp_s[l].stopstate;
    assign f_ulps_not[l] = ppi_lp_s[l].ulps_active_not;
    assign f_ulps_esc[l] = ppi_lp_s[l].rx_ulps_esc;
    assign f_err[l]      = ppi_lp_s[l].err_control[0];
    assign f_esc[l]      = ppi_lp_s[l].err_esc[0];
    assign f_sync_esc[l] = ppi_lp_s[l].err_sync_esc[0];
  end

  bow_csi2rx_ppi_flat #(
    .Lanes     (Lanes),
    .PhyClkHz  (PhyClkHz),
    .CpuClkHz  (CpuClkHz),
    .FifoDepth (FifoDepth),
    .LpClkHz   (25_000_000),                 // the standard PHY's lp clock (lp_ns of the BFM)
    .ByteClkHz (180_000_000)                 // the BFM's byte clocks: 96 .. 180 MHz
  ) u_flat (
    .clk_i                 (clk_s),
    .rst_ni                (rst_n),
    .bus_req_i             (req_s),
    .bus_rsp_o             (rsp_s),
    .irq_o                 (irq_s),
    .csi_clk_i             (vclk_s),
    .csi_rst_ni            (vrst_n),
    .m_axis_tvalid_o       (mv_s),
    .m_axis_tready_i       (m_tready),
    .m_axis_tdata_o        (md_s),
    .m_axis_tuser_o        (mu_s),
    .m_axis_tlast_o        (ml_s),
    .rx_byte_clk_hs_i      (byte_clk_s),
    .rx_data_hs_i          (f_data),
    .rx_valid_hs_i         (f_valid),
    .rx_active_hs_i        (f_active),
    .rx_sync_hs_i          (f_sync),
    .rx_skew_cal_hs_i      (f_skew),
    .err_sot_hs_i          (f_sot),
    .err_sot_sync_hs_i     (f_sot_sync),
    .lp_clk_i              (lp_clk & std),
    .stopstate_i           (f_stop),
    .ulps_active_not_i     (f_ulps_not),
    .rx_ulps_esc_i         (f_ulps_esc),
    .err_control_i         (f_err),
    .err_esc_i             (f_esc),
    .err_sync_esc_i        (f_sync_esc),
    .stopstate_clk_i       (ppi_lp_clk_s.stopstate),
    .rx_clk_active_hs_i    (ppi_lp_clk_s.rx_clk_active_hs),
    .ulps_active_not_clk_i (ppi_lp_clk_s.ulps_active_not),
    .rx_ulps_clk_not_i     (ppi_lp_clk_s.rx_ulps_clk_not),
    .enable_o              (enable_s),
    .enable_clk_o          (enable_clk_s)
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
  int unsigned overlaps0 = 0;
  int unsigned irq_fe_bad = 0, irq_fe_bad0 = 0;      // FE polled with irq_o low (IRQ_EN.FE)
  // irqfe (test tclkpost): irq_o after a frame's FE with the byte clock stopped
  int unsigned irq_stop_bad = 0, irq_stop_bad0 = 0;  // did not rise with the byte clock stopped
  int unsigned irq_stop_n = 0, irq_stop_n0 = 0;      // rose with the byte clock stopped
  int unsigned irq_stop_pre = 0;                     // rose before its last edge
  longint      irq_stop_lat = 0;                     // most ps from the last byte clock edge
  realtime     bclk_t = 0.0;                         // time of the last byte clock edge
  always @(posedge byte_clk) bclk_t = csi2_now();

  function automatic void seg_reset();
    overlaps0   = u_bfm.overlaps;
    irq_fe_bad0 = irq_fe_bad;
    irq_stop_bad0 = irq_stop_bad;
    irq_stop_n0 = irq_stop_n;
  endfunction

  function automatic void seg_dump(int seg);
    $fwrite(regs_fd, "inv %0d ppi_overlap %0d\n", seg, u_bfm.overlaps - overlaps0);
    $fwrite(regs_fd, "inv %0d irq_fe %0d\n", seg, irq_fe_bad - irq_fe_bad0);
    $fwrite(regs_fd, "inv %0d irq_stop %0d\n", seg, irq_stop_bad - irq_stop_bad0);
    $fwrite(regs_fd, "inv %0d irq_stop_n %0d\n", seg, irq_stop_n - irq_stop_n0);
  endfunction

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
  // byte clock stops after its burst. Waits until the BFM is idle (no byte clock edge comes
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
    wait (!u_bfm.busy());
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
    case (key)
      "ppi": begin
        if (v != 1 && v != 2) $fatal(1, "ppi %0d: not a PPI test case (csi2_model.py gen --ppi)", v);
        std     = (v == 2);
        u_bfm.std = std;
      end
      "byte_ps":    u_bfm.byte_ns = v / 1000.0;
      "tready":     tready_pct = v;
      "dut_lanes":  if (v != int'(Lanes)) $fatal(1, "test case for %0d lanes, testbench built with %0d", v, Lanes);
      "vid_ps":     if (v != int'(VidPs)) $fatal(1, "vid_ps %0d", v);
      "cpu_ps":     if (v != int'(CpuPs)) $fatal(1, "cpu_ps %0d", v);
      "fifo_depth": if (v != int'(FifoDepth)) $fatal(1, "fifo_depth %0d, testbench built with %0d", v, FifoDepth);
      default: ;
    endcase
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
    string       line, cmd, key, b;
    int          fd, n, v, seg, a, d, mask, val, us, k, m;
    int          l, pa, pf, ps, pe, pk, pkl, ph;
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
        // PPI lines (bow_ppi_bfm)
        "ppl": begin
          n = $sscanf(line, "ppl %d %d %d %d %d %d %d %d %s", l, pa, pf, ps, pe, pk, pkl, ph, b);
          if (n != 9) $fatal(1, "bad ppl line: %s", line);
          u_bfm.add_lane(l, pa, pf, ps, pe, pk, pkl, ph, b);
        end
        "ppb": begin
          n = $sscanf(line, "ppb %d %d %d %d", k, v, m, d);
          u_bfm.push_burst(k, v, m, d);
        end
        "ppev": begin
          n = $sscanf(line, "ppev %d", v);
          u_bfm.push_ev(v);
        end
        "ppclk": begin
          n = $sscanf(line, "ppclk %d", v);
          u_bfm.push_clk(v);
        end
        "ppidle": begin
          n = $sscanf(line, "ppidle %d", v);
          u_bfm.push_idle(v);
        end
        "ppon":  u_bfm.push_on();
        "ppoff": u_bfm.push_off();
        "lperr": begin
          n = $sscanf(line, "lperr %d", mask);
          wait (!u_bfm.busy());
          u_bfm.push_ev(mask);
          wait (!u_bfm.busy());
        end
        "wait": begin
          while (u_bfm.busy()) service(4);
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
        "irqfe": irq_stop_check();
        "waitbyte": begin
          n = $sscanf(line, "waitbyte %d %d", k, m);
          wait ((u_bfm.cur_burst == k && u_bfm.cur_byte >= m) || u_bfm.bursts_done > k);
        end
        "tready": n = $sscanf(line, "tready %d", tready_pct);
        "knob": wait (!u_bfm.busy());                // TX knobs: the model renders them
        "mark": begin
          n = $sscanf(line, "mark %d", v);
          seg_dump(seg);
          seg = v;
          seg_reset();
          $fwrite(regs_fd, "mark %0d\n", v);
          $fwrite(out_fd, "mark %0d\n", v);
        end
        default: ;                                   // TX items, model-only lines
      endcase
    end
    $fclose(fd);

    // irq_o = |(IRQ_STATUS & IRQ_EN) in the final (static) state
    bus_xfer(1'b0, 32'h014, '0, rd);
    bus_xfer(1'b0, 32'h018, '0, unused);
    $fwrite(regs_fd, "inv %0d irq_bad %0d\n", seg, irq != |(rd & unused));
    seg_dump(seg);
    foreach (u_bfm.t_end[i]) begin
      $fwrite(regs_fd, "tend %0d %0d\n", i, longint'(u_bfm.t_end[i] * 1000.0));
    end
    $fwrite(regs_fd, "end\n");
    $fclose(regs_fd);
    $fclose(out_fd);
    if (irq_stop_n + irq_stop_bad + irq_stop_pre != 0) begin
      $display("tb_csi2rx_ppi: irqfe: irq_o rose %0d times with the byte clock stopped (at most %0d ps after its last edge), %0d misses, %0d rises before it",
               irq_stop_n, irq_stop_lat, irq_stop_bad, irq_stop_pre);
    end
`ifdef BOW_SYNC_JITTER
    // the jitter model of bow_sync and of the FIFO pointer synchronisers (make test sums the
    // late resolutions per build and fails a build without any)
    $display("tb_csi2rx_ppi: BOW_SYNC_JITTER: %0d synchroniser inputs changed inside the window, %0d resolved one cycle late",
             bow_sync_jitter_pkg::n_window, bow_sync_jitter_pkg::n_late);
`endif
    u_bfm.report();
    $display("tb_csi2rx_ppi: %0d bursts, %0d lanes, %s - dumps written", u_bfm.bursts_done, Lanes,
             std ? "standard PHY through bow_csi2rx_ppi_flat" : "D-PHY of Bow32 (bow_csi2rx)");
    $finish;
  end

endmodule
