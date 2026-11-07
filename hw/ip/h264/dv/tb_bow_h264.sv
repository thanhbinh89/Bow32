// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit testbench of the Bow32 H.264 encoder (Verilator --binary --timing).
//
// Reads a test case written by `tools/h264/h264_model.py gen DIR`:
//   case.txt   "<w> <h> <frames> <skip> <count> <deblock> <hblank> <vblank> <gap> <bp> <seed>
//              <restart>" then one QP per input frame
//   input.hex  the input frames, {V, U, Y} per pixel (ISP output order)
// programs the encoder through its register bus, streams the frames (QP
// written before each start of frame, random gaps inside the lines), reads
// the output stream with random back-pressure and writes
//   DIR/out.hex     output words "<8 hex digits> <last>"
//   DIR/rec.txt     reconstructed rows of the macroblock engine (debug)
//   DIR/status.txt  "OK frames <n> bytes <b>" or "ERR <flags>"
// which `h264_model.py check DIR` compares with the bit-exact model.
//
// Register checks on the way (a failure stops the simulation):
//   * SIZE is clamped to the encoder limits; START while EN = 0 is ignored
//   * EN and START written back to back, two QP writes back to back before
//     every frame (the second one must be used): the control crossing keeps
//     the order and the newest value for any clock ratio
//   * while the frames go in, STATUS is polled and written all the time
//     (W1C of FRAME_DONE, of nothing): no FRAME_DONE may get lost, FRAME_CNT
//     counts them; FRAME_INFO of every frame (QP, idr_pic_id, LAST, no error)
//   * FRAMES > 0: DONE comes with FRAME_CNT = FRAMES; restart = 1: a second
//     START with FRAMES = 1 (idr_pic_id goes on, TOTAL_BYTES starts again)
//
// Clocks: +CLK_HALF / +VCLK_HALF (ns, half periods, default 10 / 3.5: CPU
// 50 MHz, video ~143 MHz, unrelated); +BP=<percent> overrides the output
// back-pressure of the case (a slow CPU clock drains the output slowly).

`timescale 1ns / 1ps

module tb_bow_h264;
  import bow_bus_pkg::*;

  real  clk_half = 10.0, vclk_half = 3.5;
  logic clk = 1'b0, vclk = 1'b0;
  logic rst_n = 1'b1;

  initial begin
    void'($value$plusargs("CLK_HALF=%f", clk_half));
    void'($value$plusargs("VCLK_HALF=%f", vclk_half));
  end
  always #(clk_half) clk = ~clk;
  always #(vclk_half) vclk = ~vclk;

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
  int unsigned restart;
  int unsigned qps [64];
  localparam int unsigned MaxPixels = 1 << 20;
  logic [23:0] image [MaxPixels];

  // expected FRAME_INFO of every coded frame since reset
  int unsigned exp_n;
  int unsigned exp_qp [64];
  bit          exp_last [64];

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
    #0.1;
    reg_req = r;
    @(posedge clk);
    #0.1;
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
                          RegSkip = 32'h020, RegFrameCnt = 32'h024, RegTotal = 32'h038,
                          RegFrameInfo = 32'h03C;
  localparam int unsigned StBusy = 0, StFrameDone = 1, StDone = 2, StArmed = 5;

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
  // The pixels change 0.1 ns after a clock edge (as the bus requests): the
  // encoder takes every one at the next edge, wherever the task starts.
  task automatic vclk_step();
    @(posedge vclk);
    #0.1;
  endtask

  task automatic send_frame(int unsigned f);
    int unsigned base, hb;
    base = f * width * height;
    // blanking long enough for the encoder (the test checks bits, not speed)
    hb = hblank + 64 * (width / 16);
    vclk_step();
    for (int unsigned y = 0; y < height; y++) begin
      for (int unsigned x = 0; x < width; x++) begin
        while ($urandom_range(99) < gap) vclk_step();
        s_tvalid = 1'b1;
        s_tdata  = image[base + y * width + x];
        s_tuser  = (x == 0 && y == 0);
        s_tlast  = (x == width - 1);
        vclk_step();
        s_tvalid = 1'b0;
        s_tuser  = 1'b0;
        s_tlast  = 1'b0;
      end
      repeat (hb) vclk_step();
    end
    repeat (vblank * (width + hb)) vclk_step();
  endtask

  // ---------------------------------------------------------- STATUS monitor
  int unsigned fd_seq, fd_total;   // FRAME_DONE seen in this sequence / since reset
  int unsigned seq_frames;         // FRAMES of this sequence
  bit          done_seen, sending;

  // One look at STATUS: a FRAME_DONE is taken (FRAME_INFO checked, W1C),
  // DONE checked; then a W1C write of nothing, which must not hide an event
  // that comes in the same cycle.
  task automatic poll_status();
    logic [31:0] st, info, cnt;
    int unsigned g;
    rd(RegStatus, st);
    if (st[StFrameDone]) begin
      rd(RegFrameInfo, info);
      rd(RegFrameCnt, cnt);
      wr(RegStatus, 32'h1 << StFrameDone);
      g = fd_total;
      if (cnt != fd_seq + 1) begin
        $fatal(1, "FRAME_DONE lost: FRAME_CNT %0d at FRAME_DONE %0d of the sequence", cnt,
               fd_seq + 1);
      end
      if (g >= exp_n) $fatal(1, "FRAME_DONE %0d, only %0d frames expected", g + 1, exp_n);
      if (info[5:0] != exp_qp[g] || info[8] != deblock[0] || info[9] != g[0] ||
          info[13:12] != 2'b00 || info[14] != exp_last[g]) begin
        $fatal(1, "frame %0d: FRAME_INFO %08x, expected QP %0d deblock %0d idr %0d last %0d",
               g, info, exp_qp[g], deblock, g & 1, exp_last[g]);
      end
      fd_seq++;
      fd_total++;
    end
    if (st[StDone] && !done_seen) begin
      rd(RegFrameCnt, cnt);
      if (seq_frames == 0) $fatal(1, "DONE with FRAMES = 0");
      if (cnt != seq_frames || fd_seq != seq_frames) begin
        $fatal(1, "DONE with FRAME_CNT %0d after %0d FRAME_DONE, FRAMES %0d", cnt, fd_seq,
               seq_frames);
      end
      done_seen = 1'b1;
    end
    wr(RegStatus, 32'h0);
  endtask

  task automatic send_polled(int unsigned f);
    sending = 1'b1;
    fork
      begin
        send_frame(f);
        sending = 1'b0;
      end
      while (sending) poll_status();
    join
  endtask

  task automatic wait_armed();
    logic [31:0] st;
    longint      t0;
    t0 = $time;
    do begin
      rd(RegStatus, st);
      if ($time - t0 > 100_000) $fatal(1, "START did not arm the encoder (STATUS %02x)", st);
    end while (!st[StArmed]);
  endtask

  // the control record of the last writes has reached the video domain
  task automatic settle();
    repeat (8) @(posedge clk);
    repeat (30) @(posedge vclk);
  endtask

  task automatic wait_idle();
    logic [31:0] st;
    longint      t0;
    t0 = $time;
    do begin
      poll_status();
      repeat (20) @(posedge clk);
      rd(RegStatus, st);
      if ($time - t0 > 200_000_000) $fatal(1, "timeout: encoder still busy (STATUS %02x)", st);
    end while (st[StBusy]);
    poll_status();
  endtask

  // ------------------------------------------------------------------- main
  initial begin
    int          fd, n, bp_arg;
    int unsigned junk, nsel;
    logic [31:0] st, cnt, total, total1, mbc, d;

    if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR=<test case> required");
    fd = $fopen({dir, "/case.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/case.txt", dir);
    n = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d", width, height, nframes, skip, count,
                deblock, hblank, vblank, gap, bp, seed, restart);
    if (n != 12) $fatal(1, "bad case.txt");
    for (int i = 0; i < nframes; i++) begin
      if ($fscanf(fd, "%d", qps[i]) != 1) $fatal(1, "missing QP of frame %0d", i);
    end
    $fclose(fd);
    if ($value$plusargs("BP=%d", bp_arg)) bp = bp_arg;
    if (nframes * width * height > MaxPixels) $fatal(1, "test case larger than %0d pixels", MaxPixels);
    $readmemh({dir, "/input.hex"}, image, 0, nframes * width * height - 1);
    void'($urandom(seed));
    fout = $fopen({dir, "/out.hex"}, "w");
    frec = $fopen({dir, "/rec.txt"}, "w");

    // FRAME_INFO of the coded frames (h264_model.py selected_frames)
    nsel = 0;
    for (int unsigned i = 0; i < nframes; i++) begin
      if (i % (skip + 1) == 0 && (count == 0 || nsel < count)) begin
        exp_qp[nsel]   = qps[i];
        exp_last[nsel] = (count != 0) && (nsel == count - 1);
        nsel++;
      end
    end
    exp_n = nsel;
    if (restart != 0) begin
      exp_qp[exp_n]   = qps[0];
      exp_last[exp_n] = 1'b1;
      exp_n++;
    end

    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // SIZE limits: 16..MaxWidth (2048) x 16..4080
    wr(RegSize, 32'h0000_0000);
    rd(RegSize, d);
    if (d != 32'h0010_0010) $fatal(1, "SIZE 0 reads %08x, expected 16 x 16", d);
    wr(RegSize, 32'h0FFF_0FFF);
    rd(RegSize, d);
    if (d != 32'h0FF0_0800) $fatal(1, "SIZE 0x0fff_0fff reads %08x, expected 2048 x 4080", d);
    wr(RegSize, (height << 16) | width);
    rd(RegSize, d);
    if (d != ((height << 16) | width)) $fatal(1, "SIZE %0dx%0d reads %08x", width, height, d);

    wr(RegFrames, count);
    wr(RegSkip, skip);
    wr(RegQp, qps[0]);
    // START while EN = 0 is ignored
    wr(RegCmd, 32'h1);
    settle();
    rd(RegStatus, st);
    if (st[StArmed]) $fatal(1, "START armed the encoder while CTRL.EN = 0");
    // EN and START back to back: START must find EN
    wr(RegCtrl, 32'h1 | (deblock << 1));
    wr(RegCmd, 32'h1);
    wait_armed();

    fd_seq     = 0;
    fd_total   = 0;
    done_seen  = 1'b0;
    seq_frames = count;
    for (int unsigned f = 0; f < nframes; f++) begin
      // two writes back to back: the second QP is the one of this frame
      junk = 10 + (qps[f] + 17) % 42;
      wr(RegQp, junk);
      wr(RegQp, qps[f]);
      settle();
      send_polled(f);
    end
    wr(RegCmd, 32'h2);                          // STOP (the last frame has started)
    wait_idle();
    if (count != 0 && !done_seen) $fatal(1, "no DONE after FRAMES = %0d", count);
    rd(RegFrameCnt, cnt);
    rd(RegTotal, total1);

    // second sequence: FRAMES = 1, input frame 0 with its QP
    if (restart != 0) begin
      wr(RegFrames, 1);
      wr(RegQp, qps[0]);
      wr(RegCmd, 32'h1);
      wait_armed();
      fd_seq     = 0;
      done_seen  = 1'b0;
      seq_frames = 1;
      send_polled(0);
      wait_idle();
      if (!done_seen) $fatal(1, "no DONE after the second START");
      rd(RegFrameCnt, cnt);
      rd(RegTotal, total);
      total = total + total1;
    end else begin
      total = total1;
    end

    if (fd_total != exp_n) $fatal(1, "%0d FRAME_DONE seen, %0d frames expected", fd_total, exp_n);
    repeat (50) @(posedge clk);
    rd(RegStatus, st);
    rd(32'h030, mbc);
    $display("tb_bow_h264: MB_CYCLES %0d = %0d cycles per macroblock", mbc,
             mbc / (cnt * (width / 16) * ((height + 15) / 16)));
    $fclose(fout);
    $fclose(frec);
    fd = $fopen({dir, "/status.txt"}, "w");
    if (st[3] || st[4]) $fdisplay(fd, "ERR status %02x frames %0d bytes %0d", st, fd_total, total);
    else                $fdisplay(fd, "OK frames %0d bytes %0d", fd_total, total);
    $fclose(fd);
    if (total != 4 * words) $fatal(1, "TOTAL_BYTES %0d but %0d words received", total, words);
    $display("tb_bow_h264: %0d frames, %0d bytes, status %02x", fd_total, total, st);
    $finish;
  end

endmodule
