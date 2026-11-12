// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bench of the CSI-2 controller alone at its PPI (Verilator --binary --timing): step 3 of
// docs/ip/mipi_rx_arch.md, section 10. The PHY is bow_ppi_bfm, in one of two timings (cfg
// 'ppi'):
//   1  the D-PHY of Bow32: the DUT is bow_csi2rx (PPI of bow_ppi_pkg and the temporary
//      band of v1, both driven by the BFM)
//   2  a standard PHY: the DUT is the flat-port wrapper bow_csi2rx_ppi_flat
// Both DUTs are built (same Lanes, FifoDepth); the one not in use gets no clocks.
//
// Reads a test case of `tools/csi2/csi2_model.py gen DIR --ppi bow|std`:
//   DIR/cfg.txt   settings ('key value': ppi, lanes, byte_ps, ...)
//   DIR/stim.txt  the commands of tb_bow_csi2rx (rd, wr, wrbe, poll, wait, delay, waitbyte,
//                 tready, knob, mark) and the PPI lines of the model (ppev, lperr, ppl,
//                 ppb, ppclk, ppon, ppoff, ppidle: see bow_ppi_bfm), played by the BFM;
//                 the TX items they render (pkt, lp, idle, clkon, clkburst, waitphy) and
//                 the model-only lines (nocheck, expect) are skipped
// and writes DIR/out.txt and DIR/regs.txt as tb_bow_csi2rx does (pixels with tuser /
// tlast, rd and poll results, 'fe' records, per segment invariants, burst end times),
// which `csi2_model.py check DIR` compares with the reference model.
//
// Invariants per segment: ppi_ce_bad = STATUS reads whose CE differs from RxClkActiveHS,
// read when it was stable for 5 CPU clocks (band of the BFM; flat wrapper: 2 flops);
// ppi_overlap = lane programs of the BFM that overlap (a rendering error); at the end
// irq_bad (irq_o = |(IRQ_STATUS & IRQ_EN)).
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
  parameter bit          DlyVid    = 1'b0;
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

  logic                  band_lp_rst_n, band_brst_n, band_drst_n, band_rst_src_n, band_clk_force;
  logic [7:0]            band_settle, band_clk_settle, band_clk_miss;
  logic [3:0]            band_lp_filter;
  logic [Lanes-1:0][8:0] band_dly, band_dly_sys;
  logic [Lanes-1:0][1:0] band_dly_req;
  logic [Lanes:0][1:0]   band_lp_sys;
  logic [Lanes:0]        band_hs_en_sys, band_ev_hs;
  logic                  band_ce_sys, band_phy_rdy_sys, band_clk_force_lp;
  logic [19:0]           band_meter_sys;
  logic [Lanes-1:0]      band_lane_en_lp, band_raw_valid;
  logic [Lanes-1:0][7:0] band_raw_data;

  bow_ppi_bfm #(.Lanes (Lanes)) u_bfm (
    .clk_i               (clk),
    .vid_clk_i           (vclk),
    .lp_clk_o            (lp_clk),
    .rx_byte_clk_hs_o    (byte_clk),
    .ppi_hs_o            (ppi_hs),
    .ppi_lp_o            (ppi_lp),
    .ppi_lp_clk_o        (ppi_lp_clk),
    .enable_i            (enable),
    .enable_clk_i        (enable_clk),
    .band_lp_rst_ni      (std ? vrst_n : band_lp_rst_n),
    .band_clk_force_i    (std ? 1'b0 : band_clk_force),
    .band_lp_sys_o       (band_lp_sys),
    .band_hs_en_sys_o    (band_hs_en_sys),
    .band_ce_sys_o       (band_ce_sys),
    .band_phy_rdy_sys_o  (band_phy_rdy_sys),
    .band_meter_sys_o    (band_meter_sys),
    .band_dly_sys_o      (band_dly_sys),
    .band_ev_hs_o        (band_ev_hs),
    .band_lane_en_lp_o   (band_lane_en_lp),
    .band_clk_force_lp_o (band_clk_force_lp),
    .band_raw_data_o     (band_raw_data),
    .band_raw_valid_o    (band_raw_valid)
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
    .DlyVid     (DlyVid),
    .PpiLpClkHz (PhyClkHz)
  ) u_dut (
    .clk_i               (clk_b),
    .rst_ni              (rst_n),
    .bus_req_i           (req_b),
    .bus_rsp_o           (rsp_b),
    .irq_o               (irq_b),
    .vid_clk_i           (vclk_b),
    .vid_rst_ni          (vrst_n),
    .m_axis_tvalid_o     (mv_b),
    .m_axis_tready_i     (m_tready),
    .m_axis_tdata_o      (md_b),
    .m_axis_tuser_o      (mu_b),
    .m_axis_tlast_o      (ml_b),
    .rx_byte_clk_hs_i    (byte_clk_b),
    .ppi_hs_i            (ppi_hs_b),
    .ppi_lp_i            (ppi_lp_b),
    .ppi_lp_clk_i        (ppi_lp_clk_b),
    .enable_o            (enable_b),
    .enable_clk_o        (enable_clk_b),
    .band_lp_rst_no      (band_lp_rst_n),
    .band_brst_no        (band_brst_n),
    .band_drst_no        (band_drst_n),
    .band_rst_src_no     (band_rst_src_n),
    .band_clk_force_o    (band_clk_force),
    .band_settle_o       (band_settle),
    .band_lp_filter_o    (band_lp_filter),
    .band_clk_settle_o   (band_clk_settle),
    .band_clk_miss_o     (band_clk_miss),
    .band_dly_o          (band_dly),
    .band_dly_req_o      (band_dly_req),
    .band_lp_sys_i       (band_lp_sys),
    .band_hs_en_sys_i    (band_hs_en_sys),
    .band_ce_sys_i       (band_ce_sys),
    .band_phy_rdy_sys_i  (band_phy_rdy_sys),
    .band_meter_sys_i    (band_meter_sys),
    .band_dly_sys_i      (band_dly_sys),
    .band_ev_hs_i        (band_ev_hs),
    .band_lane_en_lp_i   (band_lane_en_lp),
    .band_clk_force_lp_i (band_clk_force_lp),
    .band_raw_data_i     (band_raw_data),
    .band_raw_valid_i    (band_raw_valid)
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
    .FifoDepth (FifoDepth)
  ) u_flat (
    .clk_i                 (clk_s),
    .rst_ni                (rst_n),
    .bus_req_i             (req_s),
    .bus_rsp_o             (rsp_s),
    .irq_o                 (irq_s),
    .vid_clk_i             (vclk_s),
    .vid_rst_ni            (vrst_n),
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
    .enable_clk_o          (enable_clk_s),
    .phy_ready_i           (1'b1)                    // no PhyReady
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
  // STATUS.CE against RxClkActiveHS (stable for 5 CPU clocks before the read)
  realtime     t_act = 0.0;
  int unsigned ce_bad = 0, ce_bad0 = 0, overlaps0 = 0;
  always @(u_bfm.rx_clk_active) t_act = csi2_now();

  function automatic void status_read(logic [31:0] v, realtime t0);
    if (t0 - t_act >= 5 * CpuPs / 1000.0 && v[11] != u_bfm.rx_clk_active) ce_bad++;
  endfunction

  function automatic void seg_reset();
    ce_bad0   = ce_bad;
    overlaps0 = u_bfm.overlaps;
  endfunction

  function automatic void seg_dump(int seg);
    $fwrite(regs_fd, "inv %0d ppi_ce_bad %0d\n", seg, ce_bad - ce_bad0);
    $fwrite(regs_fd, "inv %0d ppi_overlap %0d\n", seg, u_bfm.overlaps - overlaps0);
  endfunction

  // ---------------------------------------------------------------- bus BFM
  task automatic bus_xfer(input bit we, input logic [31:0] addr, input logic [31:0] wdata,
                          output logic [31:0] rdata, input logic [3:0] be = 4'hF);
    bus_req_t r;
    realtime  t0;
    r       = BUS_REQ_DEFAULT;
    r.req   = 1'b1;
    r.we    = we;
    r.be    = be;
    r.addr  = addr;
    r.wdata = wdata;
    @(posedge clk);
    #1;
    t0  = csi2_now();
    req = r;
    @(posedge clk);
    #1;
    rdata = rsp.rdata;
    req   = BUS_REQ_DEFAULT;
    if (!we && addr == 32'h010) status_read(rdata, t0);
  endtask

  // One poll of IRQ_STATUS.FE (frame end records), then `cycles` CPU cycles
  task automatic service(input int unsigned cycles);
    logic [31:0] st, info, fsum, ferr, unused;
    bus_xfer(1'b0, 32'h014, '0, st);
    if (st[1]) begin
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
    int          fd, n, v, seg, a, d, mask, val, us, k, m, dv;
    int          l, pa, pf, ps, pe, pk, pkl, ph;
    logic [31:0] rd, unused;
    realtime     t0;

    if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR=<test case> required");
    fd = $fopen({dir, "/cfg.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/cfg.txt", dir);
    dv = 0;
    while ($fgets(line, fd)) begin
      if ($sscanf(line, "%s %d", key, v) == 2) begin
        set_knob(key, v);
        if (key == "dly_vid") dv = v;
      end
    end
    $fclose(fd);
    // INFO.DLY_VID of the DUT in use: the controller's parameter, 0 behind the flat wrapper
    if (dv != (std ? 0 : int'(DlyVid))) $fatal(1, "dly_vid %0d, the DUT in use has %0d", dv, std ? 0 : DlyVid);
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
          n = $sscanf(line, "ppev %d %d", v, m);
          u_bfm.push_ev(v, m);
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
          n = $sscanf(line, "lperr %d %d", mask, v);
          wait (!u_bfm.busy());
          @(negedge vclk);
          u_bfm.lp_error(mask, v);
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
    u_bfm.report();
    $display("tb_csi2rx_ppi: %0d bursts, %0d lanes, %s - dumps written", u_bfm.bursts_done, Lanes,
             std ? "standard PHY through bow_csi2rx_ppi_flat" : "D-PHY of Bow32 (bow_csi2rx and its band)");
    $finish;
  end

endmodule
