// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit testbench of the Bow32 ISP (Verilator --binary --timing).
//
// Reads a test case written by `tools/isp/isp_model.py gen DIR` (register
// writes, frame size, input image), programs the ISP through its register
// bus, streams two frames (or runs the internal TPG), and dumps
//   DIR/out.hex    first output frame (AXI4-Stream tdata per pixel)
//   DIR/stats.hex  statistics registers + histogram
//   DIR/cap.hex    capture buffer
// which `isp_model.py check DIR` compares with the bit-exact model.
//
// The CPU and video clocks are unrelated (50 MHz / ~143 MHz) to exercise the
// clock domain crossings; the input has random gaps inside lines.

`timescale 1ns / 1ps

module tb_bow_isp;
  import bow_bus_pkg::*;

  logic clk = 1'b0, vclk = 1'b0;
  logic rst_n = 1'b1, vrst_n = 1'b1;
  always #10.0 clk = ~clk;
  always #3.5 vclk = ~vclk;

  bus_req_t reg_req = BUS_REQ_DEFAULT, buf_req = BUS_REQ_DEFAULT;
  bus_rsp_t reg_rsp, buf_rsp;
  logic     irq;

  logic        s_tvalid = 1'b0, s_tready, s_tuser = 1'b0, s_tlast = 1'b0;
  logic [9:0]  s_tdata = '0;
  logic        m_tvalid, m_tuser, m_tlast;
  logic [23:0] m_tdata;

  bow_isp #(
    .MaxWidth (2048),
    .BufWords (32768)
  ) dut (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .reg_req_i       (reg_req),
    .reg_rsp_o       (reg_rsp),
    .buf_req_i       (buf_req),
    .buf_rsp_o       (buf_rsp),
    .irq_o           (irq),
    .vid_clk_i       (vclk),
    .vid_rst_ni      (vrst_n),
    .s_axis_tvalid_i (s_tvalid),
    .s_axis_tready_o (s_tready),
    .s_axis_tdata_i  (s_tdata),
    .s_axis_tuser_i  (s_tuser),
    .s_axis_tlast_i  (s_tlast),
    .m_axis_tvalid_o (m_tvalid),
    .m_axis_tready_i (1'b1),
    .m_axis_tdata_o  (m_tdata),
    .m_axis_tuser_o  (m_tuser),
    .m_axis_tlast_o  (m_tlast)
  );

  // --------------------------------------------------------------- test case
  string       dir;
  int unsigned width, height, use_tpg;
  logic [9:0]  image [65536];

  // ---------------------------------------------------------------- bus BFM
  // One transfer on the register (port 0) or buffer (port 1) bus. Both ports
  // grant in the same cycle and answer in the next one.
  task automatic bus_xfer(input int port, input bit we, input logic [31:0] addr,
                          input logic [31:0] wdata, output logic [31:0] rdata);
    bus_req_t r;
    r       = BUS_REQ_DEFAULT;
    r.req   = 1'b1;
    r.we    = we;
    r.be    = 4'hF;
    r.addr  = addr;
    r.wdata = wdata;
    @(posedge clk);
    #1;
    if (port == 0) reg_req = r; else buf_req = r;
    @(posedge clk);
    #1;
    rdata = (port == 0) ? reg_rsp.rdata : buf_rsp.rdata;
    if (port == 0) reg_req = BUS_REQ_DEFAULT; else buf_req = BUS_REQ_DEFAULT;
  endtask

  // ------------------------------------------------------------ stream driver
  bit          stream_go = 1'b0;
  int unsigned stream_frames = 2;

  initial begin : driver
    int unsigned f, x, y, gap;
    wait (stream_go);
    f = 0;
    while (f < stream_frames) begin
      y = 0;
      while (y < height) begin
        x = 0;
        while (x < width) begin
          @(posedge vclk);
          #0.5;
          s_tvalid = 1'b1;
          s_tdata  = image[y * width + x];
          s_tuser  = (x == 0) && (y == 0);
          s_tlast  = (x == width - 1);
          do @(posedge vclk); while (!s_tready);
          #0.5;
          s_tvalid = 1'b0;
          gap = ($urandom % 4 == 0) ? $urandom % 3 : 0;
          repeat (gap) @(posedge vclk);
          x++;
        end
        repeat (24) @(posedge vclk);        // horizontal blanking
        y++;
      end
      repeat (200) @(posedge vclk);         // vertical blanking
      f++;
    end
  end

  // ----------------------------------------------------------- output monitor
  int unsigned out_n = 0;
  bit          out_started = 1'b0, out_done = 1'b0;
  int          out_fd;

  always @(posedge vclk) begin
    if (m_tvalid && !out_done) begin
      if (m_tuser && !out_started) begin
        out_started = 1'b1;
        out_fd = $fopen({dir, "/out.hex"}, "w");
      end
      if (out_started) begin
        if (m_tlast != ((out_n % width) == width - 1)) begin
          $fatal(1, "tlast wrong at output pixel %0d", out_n);
        end
        if ((out_n != 0) && m_tuser) $fatal(1, "unexpected tuser at output pixel %0d", out_n);
        $fwrite(out_fd, "%06x\n", m_tdata);
        out_n++;
        if (out_n == width * height) begin
          $fclose(out_fd);
          out_done = 1'b1;
        end
      end
    end
  end

  // ---------------------------------------------------------------- watchdog
  longint unsigned vcycles = 0;
  always @(posedge vclk) vcycles <= vcycles + 1;
  always @(posedge vclk) if (vcycles == 4_000_000) $fatal(1, "TIMEOUT");

  // ------------------------------------------------------------------- main
  initial begin : main
    int          fd, n;
    logic [31:0] a, d, rd, status;
    int unsigned cap_w, cap_h;

    if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR=<test case> required");
    fd = $fopen({dir, "/meta.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/meta.txt", dir);
    n = $fscanf(fd, "%d %d %d", width, height, use_tpg);
    $fclose(fd);
    for (int i = 0; i < 65536; i++) image[i] = '0;
    $readmemh({dir, "/input.hex"}, image);

    // reset with real edges (two-state simulator)
    #1;
    rst_n  = 1'b0;
    vrst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n  = 1'b1;
    vrst_n = 1'b1;
    repeat (5) @(posedge clk);

    bus_xfer(0, 0, 32'h000, 0, rd);
    if (rd != 32'h4953_5001) $fatal(1, "bad ID %08x", rd);

    // program the configuration
    cap_w = 0;
    cap_h = 0;
    fd = $fopen({dir, "/regs.txt"}, "r");
    while ($fscanf(fd, "%h %h", a, d) == 2) begin
      bus_xfer(0, 1, a, d, rd);
      if (a == 32'h0F8) begin
        cap_w = d[11:0];
        cap_h = d[27:16];
      end
    end
    $fclose(fd);

    bus_xfer(0, 1, 32'h008, 1, rd);               // UPDATE
    do bus_xfer(0, 0, 32'h00C, 0, status); while (status[0]);
    bus_xfer(0, 1, 32'h0F0, 1, rd);               // CAP_CTRL.START
    bus_xfer(0, 1, 32'h004, use_tpg ? 3 : 1, rd); // CTRL: EN (+ TPG)
    if (!use_tpg) stream_go = 1'b1;

    // wait for capture and statistics of the first frame
    do bus_xfer(0, 0, 32'h00C, 0, status); while (status[2:1] != 2'b11);
    wait (out_done);

    fd = $fopen({dir, "/stats.hex"}, "w");
    for (int i = 0; i < 7; i++) begin
      bus_xfer(0, 0, 32'h100 + 4 * i, 0, rd);
      $fwrite(fd, "%08x\n", rd);
    end
    for (int i = 0; i < 64; i++) begin
      bus_xfer(0, 0, 32'h200 + 4 * i, 0, rd);
      $fwrite(fd, "%08x\n", rd);
    end
    $fclose(fd);

    fd = $fopen({dir, "/cap.hex"}, "w");
    for (int i = 0; i < cap_w * cap_h; i++) begin
      bus_xfer(1, 0, 32'h3000_0000 + 4 * i, 0, rd);
      $fwrite(fd, "%06x\n", rd[23:0]);
    end
    $fclose(fd);

    bus_xfer(0, 0, 32'h00C, 0, status);
    if (status[7:4] != 0) $fatal(1, "ISP error flags set: STATUS = %08x", status);
    bus_xfer(0, 0, 32'h018, 0, rd);
    $display("tb_bow_isp: %0dx%0d %s, measured input %0dx%0d, STATUS %02x - dumps written",
             width, height, use_tpg ? "TPG" : "stream", rd[11:0], rd[27:16], status[7:0]);
    $finish;
  end

endmodule
