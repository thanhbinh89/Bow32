// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit testbench of the Bow32 H.264 encoder (Verilator --binary --timing).
//
// Reads a test case written by `tools/h264/h264_model.py gen DIR`:
//   case.txt   "<w> <h> <frames> <skip> <count> <deblock> <hblank> <vblank> <gap> <bp> <seed>"
//              then one QP per input frame
//   input.hex  the input frames, {V, U, Y} per pixel (ISP output order)
// programs the encoder through its register bus, streams the frames (QP
// written before each start of frame, random gaps inside the lines), reads
// the output stream with random back-pressure and writes
//   DIR/out.hex     output words "<8 hex digits> <last>"
//   DIR/rec.txt     reconstructed rows of the macroblock engine (debug)
//   DIR/status.txt  "OK frames <n> bytes <b>" or "ERR <flags>"
// which `h264_model.py check DIR` compares with the bit-exact model.
// The CPU and video clocks are unrelated (50 MHz / ~143 MHz).

`timescale 1ns / 1ps

module tb_bow_h264;
  import bow_bus_pkg::*;

  logic clk = 1'b0, vclk = 1'b0;
  logic rst_n = 1'b1;
  always #10.0 clk = ~clk;
  always #3.5 vclk = ~vclk;

  bus_req_t reg_req = BUS_REQ_DEFAULT;
  bus_rsp_t reg_rsp;
  logic     irq;

  logic        m_tvalid, m_tlast;
  logic        m_tready = 1'b0;
  logic [31:0] m_tdata;
  logic        s_tvalid = 1'b0, s_tuser = 1'b0, s_tlast = 1'b0;
  logic [23:0] s_tdata = '0;

  bow_h264 #(
    .MaxWidth  (2048),
    .NumStrips (4)
  ) dut (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .reg_req_i       (reg_req),
    .reg_rsp_o       (reg_rsp),
    .irq_o           (irq),
    .m_axis_tvalid_o (m_tvalid),
    .m_axis_tready_i (m_tready),
    .m_axis_tdata_o  (m_tdata),
    .m_axis_tlast_o  (m_tlast),
    .vid_clk_i       (vclk),
    .vid_rst_ni      (rst_n),
    .s_axis_tvalid_i (s_tvalid),
    .s_axis_tdata_i  (s_tdata),
    .s_axis_tuser_i  (s_tuser),
    .s_axis_tlast_i  (s_tlast)
  );

  // --------------------------------------------------------------- test case
  string       dir;
  int unsigned width, height, nframes, skip, count, deblock, hblank, vblank, gap, bp, seed;
  int unsigned qps [64];
  localparam int unsigned MaxPixels = 1 << 20;
  logic [23:0] image [MaxPixels];

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
    reg_req = r;
    @(posedge clk);
    #1;
    reg_req = BUS_REQ_DEFAULT;
    rdata   = reg_rsp.rdata;
  endtask

  task automatic wr(input logic [31:0] addr, input logic [31:0] data);
    logic [31:0] d;
    bus_xfer(1'b1, addr, data, d);
  endtask

  task automatic rd(input logic [31:0] addr, output logic [31:0] data);
    bus_xfer(1'b0, addr, '0, data);
  endtask

  localparam logic [31:0] RegCtrl = 32'h004, RegCmd = 32'h008, RegStatus = 32'h00C,
                          RegSize = 32'h014, RegQp = 32'h018, RegFrames = 32'h01C,
                          RegSkip = 32'h020, RegFrameCnt = 32'h024, RegTotal = 32'h038;

  // ------------------------------------------------------------ output side
  int          fout, frec;
  int unsigned words = 0;

  always @(posedge clk) begin
    if (rst_n && m_tvalid && m_tready) begin
      $fdisplay(fout, "%08x %0d", m_tdata, m_tlast);
      words++;
    end
  end

  always @(posedge clk) begin
    m_tready <= ($urandom_range(99) >= bp);
  end

  // reconstructed rows (debug)
  always @(posedge vclk) begin
    if (dut.u_mb.rec_valid_o) begin
      $fdisplay(frec, "%0d %0d %0d %02x %02x %02x %02x", dut.u_mb.rec_plane_o, dut.u_mb.rec_x_o,
                dut.u_mb.rec_y_o, dut.u_mb.rec_px_o[0], dut.u_mb.rec_px_o[1],
                dut.u_mb.rec_px_o[2], dut.u_mb.rec_px_o[3]);
    end
  end

  // ------------------------------------------------------------ video side
  task automatic send_frame(int unsigned f);
    int unsigned base, hb;
    base = f * width * height;
    // blanking long enough for the encoder (the test checks bits, not speed)
    hb = hblank + 64 * (width / 16);
    for (int unsigned y = 0; y < height; y++) begin
      for (int unsigned x = 0; x < width; x++) begin
        while ($urandom_range(99) < gap) @(posedge vclk);
        s_tvalid <= 1'b1;
        s_tdata  <= image[base + y * width + x];
        s_tuser  <= (x == 0 && y == 0);
        s_tlast  <= (x == width - 1);
        @(posedge vclk);
        s_tvalid <= 1'b0;
        s_tuser  <= 1'b0;
        s_tlast  <= 1'b0;
      end
      repeat (hb) @(posedge vclk);
    end
    repeat (vblank * (width + hb)) @(posedge vclk);
  endtask

  // ------------------------------------------------------------------- main
  initial begin
    int          fd, n;
    logic [31:0] st, cnt, total, mbc;
    longint      t0;

    if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR=<test case> required");
    fd = $fopen({dir, "/case.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/case.txt", dir);
    n = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d", width, height, nframes, skip, count,
                deblock, hblank, vblank, gap, bp, seed);
    if (n != 11) $fatal(1, "bad case.txt");
    for (int i = 0; i < nframes; i++) begin
      if ($fscanf(fd, "%d", qps[i]) != 1) $fatal(1, "missing QP of frame %0d", i);
    end
    $fclose(fd);
    if (nframes * width * height > MaxPixels) $fatal(1, "test case larger than %0d pixels", MaxPixels);
    $readmemh({dir, "/input.hex"}, image, 0, nframes * width * height - 1);
    void'($urandom(seed));
    fout = $fopen({dir, "/out.hex"}, "w");
    frec = $fopen({dir, "/rec.txt"}, "w");

    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    wr(RegSize, (height << 16) | width);
    wr(RegFrames, count);
    wr(RegSkip, skip);
    wr(RegQp, qps[0]);
    wr(RegCtrl, 32'h1 | (deblock << 1));
    repeat (4) @(posedge clk);
    wr(RegCmd, 32'h1);                          // START
    repeat (4) @(posedge clk);

    for (int unsigned f = 0; f < nframes; f++) begin
      wr(RegQp, qps[f]);
      repeat (30) @(posedge vclk);              // the QP pulse reaches the video domain
      send_frame(f);
    end
    wr(RegCmd, 32'h2);                          // STOP (the last frame has started)

    t0 = $time;
    do begin
      repeat (50) @(posedge clk);
      rd(RegStatus, st);
      if ($time - t0 > 200_000_000) $fatal(1, "timeout: encoder still busy (STATUS %02x)", st);
    end while (st[0]);
    repeat (50) @(posedge clk);
    rd(RegStatus, st);
    rd(RegFrameCnt, cnt);
    rd(RegTotal, total);
    rd(32'h030, mbc);
    $display("tb_bow_h264: MB_CYCLES %0d = %0d cycles per macroblock", mbc,
             mbc / (cnt * (width / 16) * ((height + 15) / 16)));
    $fclose(fout);
    $fclose(frec);
    fd = $fopen({dir, "/status.txt"}, "w");
    if (st[3] || st[4]) $fdisplay(fd, "ERR status %02x frames %0d bytes %0d", st, cnt, total);
    else                $fdisplay(fd, "OK frames %0d bytes %0d", cnt, total);
    $fclose(fd);
    if (total != 4 * words) $fatal(1, "TOTAL_BYTES %0d but %0d words received", total, words);
    $display("tb_bow_h264: %0d frames, %0d bytes, status %02x", cnt, total, st);
    $finish;
  end

endmodule
