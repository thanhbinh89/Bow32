// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit testbench of the Bow32 CSI-2 receiver (Verilator --binary --timing).
//
// Reads a test case written by `tools/csi2/csi2_model.py gen DIR`:
//   DIR/cfg.txt   settings ('key value': lanes, clock mode, D-PHY timing, eye, ...)
//   DIR/stim.txt  commands, executed in order by the main process:
//     rd A / wr A D / poll A MASK VALUE US    register access (hex)
//     pkt ...                                 one burst for csi2_tx_model (see Burst in the model)
//     lp MASK LP NS / idle NS / clkon         LP states, idle time, continuous clock start
//     clkburst NS                             clock lane only burst (deferred work)
//     wait / delay NS / waitbyte BURST BYTE   wait for the TX model to finish / time / burst progress
//     tready PCT / knob NAME V / mark N       m_axis tready duty, TX knob, segment marker
//   and writes
//   DIR/out.txt   one line per m_axis transfer: pixel tuser tlast, and 'mark N'
//   DIR/regs.txt  rd/poll results, 'fe FRAME_INFO FRAME_SUM' for every frame end
//                 (IRQ_STATUS.FE polled during wait/delay/poll and cleared),
//                 per segment invariants ('inv SEG NAME VALUE'), burst end
//                 times ('tend BURST PS') and 'end'
// which `csi2_model.py check DIR` compares with the reference model.
//
// Invariants measured on every burst: LP-01 -> LP-00 at the pins to hs_en
// (data and clock lanes) and LP-11 to hs_en low, CE open while the clock lane
// is in an LP state or opened while it toggles (csi2_tx_model counters); at
// the end irq_o = |(IRQ_STATUS & IRQ_EN).
//
// Clocks: CPU 50 MHz, video 200 MHz (PhyClkHz), byte clock from the TX model;
// all unrelated.

`timescale 1ns / 1ps

module tb_bow_csi2rx;
  import bow_bus_pkg::*;
  import csi2_tx_pkg::*;

  parameter int unsigned Lanes = 2;
  localparam int unsigned FifoDepth = 256;
  localparam int unsigned CpuPs = 20000, VidPs = 5000;    // 50 MHz, 200 MHz
  localparam int unsigned PhyClkHz = 200_000_000;

  logic clk = 1'b0, vclk = 1'b0;
  logic rst_n = 1'b1, vrst_n = 1'b1;
  always #(CpuPs / 2000.0) clk = ~clk;
  always #(VidPs / 2000.0) vclk = ~vclk;

  bus_req_t req = BUS_REQ_DEFAULT;
  bus_rsp_t rsp;
  logic     irq;

  logic                  m_tvalid, m_tuser, m_tlast;
  logic                  m_tready = 1'b1;
  logic [9:0]            m_tdata;
  logic                  byte_clk, byte_ce, byte_rst, clk_hs_en;
  logic [1:0]            clk_lp;
  logic [Lanes-1:0][1:0] lp;
  logic [Lanes-1:0]      hs_en, dly_load;
  logic [Lanes-1:0][7:0] rx_data;
  logic [Lanes-1:0][8:0] dly_tap, dly_tap_rb;

  bow_csi2rx #(
    .Lanes     (Lanes),
    .PhyClkHz  (PhyClkHz),
    .HasPhy    (1'b1),
    .FifoDepth (FifoDepth)
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
    .byte_clk_i      (byte_clk),
    .byte_ce_o       (byte_ce),
    .byte_rst_o      (byte_rst),
    .clk_lp_i        (clk_lp),
    .clk_hs_en_o     (clk_hs_en),
    .lp_i            (lp),
    .hs_en_o         (hs_en),
    .rx_data_i       (rx_data),
    .dly_tap_o       (dly_tap),
    .dly_load_o      (dly_load),
    .dly_tap_i       (dly_tap_rb)
  );

  csi2_tx_model #(.Lanes(Lanes)) u_tx (
    .byte_clk_o  (byte_clk),
    .byte_ce_i   (byte_ce),
    .byte_rst_i  (byte_rst),
    .clk_lp_o    (clk_lp),
    .clk_hs_en_i (clk_hs_en),
    .lp_o        (lp),
    .hs_en_i     (hs_en),
    .rx_data_o   (rx_data),
    .dly_tap_i   (dly_tap),
    .dly_load_i  (dly_load),
    .dly_tap_o   (dly_tap_rb)
  );

  string dir;
  int    out_fd, regs_fd;

  // ------------------------------------------------------------ m_axis sink
  int unsigned tready_pct = 100;

  always @(posedge vclk) begin
    if (m_tvalid && m_tready) $fwrite(out_fd, "%03x %0d %0d\n", m_tdata, m_tuser, m_tlast);
    #0.5;
    m_tready = ($urandom_range(99) < tready_pct);
  end

  // -------------------------------------------------------------- invariants
  // Maxima of this segment in ps (-1: none), CE counters at the segment start
  longint lat_max [3], off_max [2];
  int unsigned ce_bad0 = 0, ce_rise0 = 0, runts0 = 0, flips0 = 0;

  function automatic void seg_reset();
    for (int i = 0; i < 3; i++) lat_max[i] = -1;
    for (int i = 0; i < 2; i++) off_max[i] = -1;
    ce_bad0  = u_tx.ce_bad;
    ce_rise0 = u_tx.ce_rise_toggle;
    runts0   = u_tx.runts;
    flips0   = u_tx.flips;
  endfunction

  function automatic void seg_dump(int seg);
    $fwrite(regs_fd, "inv %0d lat0 %0d\n", seg, lat_max[0]);
    if (Lanes > 1) $fwrite(regs_fd, "inv %0d lat1 %0d\n", seg, lat_max[1]);
    $fwrite(regs_fd, "inv %0d latclk %0d\n", seg, lat_max[2]);
    $fwrite(regs_fd, "inv %0d off0 %0d\n", seg, off_max[0]);
    if (Lanes > 1) $fwrite(regs_fd, "inv %0d off1 %0d\n", seg, off_max[1]);
    $fwrite(regs_fd, "inv %0d ce_bad %0d\n", seg, u_tx.ce_bad - ce_bad0);
    $fwrite(regs_fd, "inv %0d ce_rise_toggle %0d\n", seg, u_tx.ce_rise_toggle - ce_rise0);
    $fwrite(regs_fd, "inv %0d runts %0d\n", seg, u_tx.runts - runts0);
    $fwrite(regs_fd, "inv %0d flips %0d\n", seg, u_tx.flips - flips0);
  endfunction

  // LP-01 -> LP-00 at the pin -> hs_en (only HS requests of the last 1 us)
  function automatic void hs_on(int i);
    longint d;
    d = longint'((csi2_now() - u_tx.t_lp00[i]) * 1000.0);
    if (d >= 0 && d < 1_000_000 && d > lat_max[i]) lat_max[i] = d;
  endfunction

  // LP-11 at the pin -> hs_en low (only if the lane went LP-11 in the last 200 ns)
  function automatic void hs_off(int i);
    longint d;
    d = longint'((csi2_now() - u_tx.t_lp11[i]) * 1000.0);
    if (lp[i] == 2'b11 && d >= 0 && d < 200_000 && d > off_max[i]) off_max[i] = d;
  endfunction

  for (genvar l = 0; l < int'(Lanes); l++) begin : g_lane_mon
    always @(posedge hs_en[l]) hs_on(l);
    always @(negedge hs_en[l]) hs_off(l);
  end
  always @(posedge clk_hs_en) hs_on(2);

  // ---------------------------------------------------------------- bus BFM
  task automatic bus_xfer(input bit we, input logic [31:0] addr, input logic [31:0] wdata,
                          output logic [31:0] rdata);
    bus_req_t r;
    r       = BUS_REQ_DEFAULT;
    r.req   = 1'b1;
    r.we    = we;
    r.be    = 4'hF;
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

  // One poll of IRQ_STATUS.FE (frame end records), then `cycles` CPU cycles
  task automatic service(input int unsigned cycles);
    logic [31:0] st, info, fsum, unused;
    bus_xfer(1'b0, 32'h014, '0, st);
    if (st[1]) begin
      bus_xfer(1'b0, 32'h050, '0, info);
      bus_xfer(1'b0, 32'h058, '0, fsum);
      bus_xfer(1'b1, 32'h014, 32'h2, unused);
      $fwrite(regs_fd, "fe %08x %08x\n", info, fsum);
    end
    repeat (cycles) @(posedge clk);
  endtask

  // ------------------------------------------------------------------ setup
  function automatic void set_knob(string key, int v);
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
      "eye0_lo":       u_tx.eye_lo[0] = v;
      "eye0_hi":       u_tx.eye_hi[0] = v;
      "eye1_lo":       u_tx.eye_lo[1] = v;
      "eye1_hi":       u_tx.eye_hi[1] = v;
      "tready":        tready_pct = v;
      "dut_lanes":     if (v != int'(Lanes)) $fatal(1, "test case for %0d lanes, testbench built with %0d", v, Lanes);
      "vid_ps":        if (v != int'(VidPs)) $fatal(1, "vid_ps %0d", v);
      "cpu_ps":        if (v != int'(CpuPs)) $fatal(1, "cpu_ps %0d", v);
      "fifo_depth":    if (v != int'(FifoDepth)) $fatal(1, "fifo_depth %0d", v);
      default: ;
    endcase
  endfunction

  // 'pkt VC DT WC HFLIP_A HFLIP_B PFLIP TRUNC SYNC0 SYNC1 ZEROS0 ZEROS1 PHASE0 PHASE1 ZERO_NS PAYLOAD'
  function automatic void push_pkt(string line);
    int          vc, dt, wc, hf0, hf1, pf, tr, s0, s1, z0, z1, p0, p1, zns, n;
    string       pay;
    csi2_flags_t f;
    csi2_bytes_t b;
    pay = "";
    n = $sscanf(line, "pkt %d %h %h %d %d %d %d %h %h %d %d %d %d %d %s", vc, dt, wc, hf0, hf1, pf,
                tr, s0, s1, z0, z1, p0, p1, zns, pay);
    if (n != 15) $fatal(1, "bad pkt line: %s", line);
    f = csi2_flags();
    f.hdr_flip_a = 8'(hf0);
    f.hdr_flip_b = 8'(hf1);
    f.pay_flip   = pf;
    f.trunc      = tr;
    f.sync       = {8'(s1), 8'(s0)};
    f.zeros      = {8'(z1), 8'(z0)};
    f.phase      = {4'(p1), 4'(p0)};
    f.zero_ns    = 16'(zns);
    if (dt < 'h10) begin
      u_tx.push_short(vc, dt, wc, f);
    end else begin
      b.delete();
      if (pay != "-") begin
        for (int i = 0; i + 1 < pay.len(); i += 2) b.push_back(8'(pay.substr(i, i + 1).atohex()));
      end
      u_tx.push_long(vc, dt, b, f);
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
        "poll": begin
          n = $sscanf(line, "poll %h %h %h %d", a, mask, val, us);
          t0 = csi2_now();
          do begin
            service(10);
            bus_xfer(1'b0, a, '0, rd);
          end while ((rd & mask) != val && csi2_now() - t0 < us * 1000.0);
          $fwrite(regs_fd, "poll %03x %08x\n", a, rd);
        end
        "pkt": push_pkt(line);
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
    $display("tb_bow_csi2rx: %0d bursts, %0d lanes - dumps written", u_tx.bursts_done, Lanes);
    $finish;
  end

endmodule
