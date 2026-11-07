// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 H.264 encoder: ISP output (YUV 4:4:4) -> H.264 / AVC byte stream
// (constrained baseline, intra only: one IDR slice of Intra_16x16
// macroblocks per frame, CAVLC). docs/ip/h264.md.
//
//  s_axis --> input (4:2:0, strips) --> strip buffers --> macroblock engine
//  (vid_clk)                                                   |
//                                         coefficient buffer (2 MBs)
//                                                              v
//  m_axis <-- FIFO (2 clocks) <-- bit packer + EP <-- CAVLC coder
//  (clk_i, 32 bit words, tlast = end of a NAL unit / frame)
//
// Two clock domains: registers and the output stream in clk_i, the whole
// encoder in vid_clk_i (200 MHz on the KV260). The input must accept one
// pixel per clock (no back-pressure, like the ISP output); when the encoder
// is slower than the camera, pixels are dropped and STATUS.ERR_OVF is set,
// the bit stream stays valid (FRAME_INFO tells which frame). The output
// stream back-pressures the encoder.
//
// Clock crossings, for any ratio of the two clocks: the control (EN,
// DEBLOCK, QP, START, STOP) as ordered records and the errors as sticky
// flags through bow_cdc_hs; the end of a frame with bow_cdc_pulse (frames
// end at least one macroblock = 392 video cycles apart, the frame
// statistics are held until the next one: the CPU clock must not be more
// than ~100 times slower than the video clock); BUSY / ARMED as levels.
//
// SPS / PPS are written by software (sw/common/src/bow_h264.c), every frame
// is one Annex B NAL unit "00 00 00 01 65 ..." padded with zero bytes to a
// multiple of 4.

module bow_h264 import bow_bus_pkg::*; import bow_h264_pkg::*; #(
  parameter int unsigned MaxWidth  = 2048,   // power of two
  parameter int unsigned NumStrips = 4,      // strip buffer: 2 or 4 strips of 16 lines
  parameter int unsigned OutDepth  = 512     // output FIFO (32 bit words)
) (
  // CPU clock domain
  input  logic        clk_i,
  input  logic        rst_ni,
  input  bus_req_t    reg_req_i,
  output bus_rsp_t    reg_rsp_o,
  output logic        irq_o,

  output logic        m_axis_tvalid_o,     // byte stream, 4 bytes per word, first in [7:0]
  input  logic        m_axis_tready_i,
  output logic [31:0] m_axis_tdata_o,
  output logic        m_axis_tlast_o,      // last word of a frame

  // video clock domain
  input  logic        vid_clk_i,
  input  logic        vid_rst_ni,
  input  logic        s_axis_tvalid_i,     // ISP output: {V, U, Y}
  input  logic [23:0] s_axis_tdata_i,
  input  logic        s_axis_tuser_i,      // start of frame
  input  logic        s_axis_tlast_i       // end of line
);

  localparam int unsigned YAW = $clog2(NumStrips * 2 * MaxWidth);
  localparam int unsigned CAW = $clog2(NumStrips * MaxWidth / 2);

  // ================================================================ resets
  // vrst_n: the video domain. xrst_n: the CPU side of every clock crossing,
  // which must be reset whenever the video side is (bow_cdc_hs,
  // bow_fifo_async: both sides asserted together); the register file then
  // sends the control again.
  /* verilator lint_off SYNCASYNCNET */
  logic vrst_n, xrst_n;
  /* verilator lint_on SYNCASYNCNET */

  bow_rst_sync u_vrst (
    .clk_i  (vid_clk_i),
    .rst_ni (vid_rst_ni & rst_ni),
    .rst_no (vrst_n)
  );

  bow_rst_sync u_xrst (
    .clk_i  (clk_i),
    .rst_ni (vid_rst_ni & rst_ni),
    .rst_no (xrst_n)
  );

  // =========================================================== registers
  logic [CoordW-1:0] width, height;
  logic [15:0]       frames;
  logic [7:0]        skip;
  logic              ctrl_valid_sys, ctrl_ready_sys;
  ctrl_t             ctrl_sys;
  logic              busy_sys, armed_sys, frame_done_sys, err_valid_sys;
  logic [1:0]        err_sys;
  frame_t            frame_info;
  logic [23:0]       frame_bytes;
  logic [31:0]       frame_cycles, mb_cycles;
  logic              out_empty;

  bow_h264_regs #(
    .MaxWidth  (MaxWidth),
    .NumStrips (NumStrips)
  ) u_regs (
    .clk_i,
    .rst_ni,
    .cdc_rst_ni     (xrst_n),
    .bus_req_i      (reg_req_i),
    .bus_rsp_o      (reg_rsp_o),
    .width_o        (width),
    .height_o       (height),
    .frames_o       (frames),
    .skip_o         (skip),
    .ctrl_valid_o   (ctrl_valid_sys),
    .ctrl_ready_i   (ctrl_ready_sys),
    .ctrl_o         (ctrl_sys),
    .busy_i         (busy_sys || !out_empty),
    .armed_i        (armed_sys),
    .frame_done_i   (frame_done_sys),
    .frame_info_i   (frame_info),
    .err_ovf_i      (err_valid_sys && err_sys[0]),
    .err_input_i    (err_valid_sys && err_sys[1]),
    .frame_bytes_i  (frame_bytes),
    .frame_cycles_i (frame_cycles),
    .mb_cycles_i    (mb_cycles),
    .irq_o
  );

  // ===================================================== clock crossings
  // Control: one record per transfer, applied in two cycles. The first one
  // takes QP / DEBLOCK and holds EN low if the record has seen EN low
  // (`dis`: the input aborts a frame and disarms as before); the second one
  // sets EN and issues START / STOP, so a START always finds the EN of its
  // record.
  logic  ctrl_valid, apply_q, en, deblock, start, stop;
  ctrl_t ctrl;
  logic [5:0] qp_q;

  bow_cdc_hs #(
    .Width ($bits(ctrl_t))
  ) u_cdc_ctrl (
    .src_clk_i   (clk_i),
    .src_rst_ni  (xrst_n),
    .src_valid_i (ctrl_valid_sys),
    .src_ready_o (ctrl_ready_sys),
    .src_data_i  (ctrl_sys),
    .dst_clk_i   (vid_clk_i),
    .dst_rst_ni  (vrst_n),
    .dst_valid_o (ctrl_valid),
    .dst_data_o  (ctrl)
  );

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) begin
      apply_q <= 1'b0;
      en      <= 1'b0;
      deblock <= 1'b1;
      qp_q    <= 6'd30;
    end else begin
      apply_q <= ctrl_valid;
      if (ctrl_valid) begin
        en      <= ctrl.en && !ctrl.dis;
        deblock <= ctrl.deblock;
        qp_q    <= ctrl.qp;
      end else if (apply_q) begin
        en      <= ctrl.en;
      end
    end
  end

  assign start = apply_q && ctrl.start;
  assign stop  = apply_q && ctrl.stop;

  logic busy, armed, frame_done, err_ovf, err_in, err_ready;

  bow_sync u_sync_busy (.clk_i, .rst_ni (xrst_n), .d_i (busy), .q_o (busy_sys));
  bow_sync u_sync_armed (.clk_i, .rst_ni (xrst_n), .d_i (armed), .q_o (armed_sys));

  // end of a frame; FRAME_INFO, FRAME_BYTES, FRAME_CYCLES and MB_CYCLES are
  // held until the next one
  bow_cdc_pulse u_cdc_done (
    .src_clk_i (vid_clk_i), .src_rst_ni (vrst_n), .src_pulse_i (frame_done),
    .dst_clk_i (clk_i), .dst_rst_ni (xrst_n), .dst_pulse_o (frame_done_sys));

  // errors can come every cycle: sticky until a transfer takes them
  logic [1:0] err_pend_q;

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) begin
      err_pend_q <= '0;
    end else begin
      err_pend_q <= (err_ready ? '0 : err_pend_q) | {err_in, err_ovf};
    end
  end

  bow_cdc_hs #(
    .Width (2)
  ) u_cdc_err (
    .src_clk_i   (vid_clk_i),
    .src_rst_ni  (vrst_n),
    .src_valid_i (err_pend_q != '0),
    .src_ready_o (err_ready),
    .src_data_i  (err_pend_q),
    .dst_clk_i   (clk_i),
    .dst_rst_ni  (xrst_n),
    .dst_valid_o (err_valid_sys),
    .dst_data_o  (err_sys)
  );

  // ================================================================ input
  logic           y_we, c_we;
  logic [YAW-1:0] y_waddr, y_raddr;
  logic [CAW-1:0] c_waddr, c_raddr;
  logic [63:0]    y_wdata, cb_wdata, cr_wdata, y_rdata, cb_rdata, cr_rdata;
  logic           strip_push, strip_pop, strip_free, strip_empty;
  strip_t         strip_in, strip_out;
  logic           in_active, frame_start;

  bow_h264_input #(
    .MaxWidth  (MaxWidth),
    .NumStrips (NumStrips)
  ) u_input (
    .clk_i         (vid_clk_i),
    .rst_ni        (vrst_n),
    .enable_i      (en),
    .width_i       (width),
    .height_i      (height),
    .start_i       (start),
    .stop_i        (stop),
    .frames_i      (frames),
    .skip_i        (skip),
    .qp_i          (qp_q),
    .deblock_i     (deblock),
    .s_valid_i     (s_axis_tvalid_i),
    .s_data_i      (s_axis_tdata_i),
    .s_sof_i       (s_axis_tuser_i),
    .s_eol_i       (s_axis_tlast_i),
    .y_we_o        (y_we),
    .y_waddr_o     (y_waddr),
    .y_wdata_o     (y_wdata),
    .c_we_o        (c_we),
    .c_waddr_o     (c_waddr),
    .cb_wdata_o    (cb_wdata),
    .cr_wdata_o    (cr_wdata),
    .strip_valid_o (strip_push),
    .strip_o       (strip_in),
    .strip_free_i  (strip_free),
    .armed_o       (armed),
    .active_o      (in_active),
    .frame_start_o (frame_start),
    .err_ovf_o     (err_ovf),
    .err_input_o   (err_in)
  );

  bow_uram_sdp #(.Width (64), .Depth (NumStrips * 2 * MaxWidth)) u_strip_y (
    .clk_i (vid_clk_i), .we_i (y_we), .waddr_i (y_waddr), .wdata_i (y_wdata),
    .raddr_i (y_raddr), .rdata_o (y_rdata));
  bow_uram_sdp #(.Width (64), .Depth (NumStrips * MaxWidth / 2)) u_strip_cb (
    .clk_i (vid_clk_i), .we_i (c_we), .waddr_i (c_waddr), .wdata_i (cb_wdata),
    .raddr_i (c_raddr), .rdata_o (cb_rdata));
  bow_uram_sdp #(.Width (64), .Depth (NumStrips * MaxWidth / 2)) u_strip_cr (
    .clk_i (vid_clk_i), .we_i (c_we), .waddr_i (c_waddr), .wdata_i (cr_wdata),
    .raddr_i (c_raddr), .rdata_o (cr_rdata));

  // every strip in the FIFO owns a slot: it never overflows
  logic                      strip_full;
  logic [$clog2(NumStrips):0] strip_level;

  bow_fifo_sync #(
    .Width ($bits(strip_t)),
    .Depth (NumStrips)
  ) u_strips (
    .clk_i   (vid_clk_i),
    .rst_ni  (vrst_n),
    .clr_i   (1'b0),
    .push_i  (strip_push),
    .wdata_i (strip_in),
    .pop_i   (strip_pop),
    .rdata_o (strip_out),
    .full_o  (strip_full),
    .empty_o (strip_empty),
    .level_o (strip_level)
  );

  // ===================================================== macroblock engine
  logic        cf_we, mb_commit, mb_slot, mb_busy, mb_work, slot_done, slot_idx;
  logic [7:0]  cf_waddr, cf_raddr;
  logic [63:0] cf_wdata, cf_rdata;
  logic [1:0]  slot_full_q;
  mbinfo_t     mb_info;
  mbinfo_t [1:0] slot_info_q;

  bow_h264_mb #(
    .MaxWidth  (MaxWidth),
    .NumStrips (NumStrips)
  ) u_mb (
    .clk_i         (vid_clk_i),
    .rst_ni        (vrst_n),
    .mbw_i         (MbW'(width[CoordW-1:4])),
    .strip_valid_i (!strip_empty),
    .strip_i       (strip_out),
    .strip_pop_o   (strip_pop),
    .strip_free_o  (strip_free),
    .y_raddr_o     (y_raddr),
    .y_rdata_i     (y_rdata),
    .c_raddr_o     (c_raddr),
    .cb_rdata_i    (cb_rdata),
    .cr_rdata_i    (cr_rdata),
    .cf_we_o       (cf_we),
    .cf_waddr_o    (cf_waddr),
    .cf_wdata_o    (cf_wdata),
    .slot_full_i   (slot_full_q),
    .mb_commit_o   (mb_commit),
    .mb_slot_o     (mb_slot),
    .mb_info_o     (mb_info),
    .busy_o        (mb_busy),
    .work_o        (mb_work),
    .rec_valid_o   (),
    .rec_plane_o   (),
    .rec_x_o       (),
    .rec_y_o       (),
    .rec_px_o      ()
  );

  bow_ram_sdp #(.Width (64), .Depth (256)) u_coef (
    .wclk_i (vid_clk_i), .we_i (cf_we), .waddr_i (cf_waddr), .wdata_i (cf_wdata),
    .rclk_i (vid_clk_i), .re_i (1'b1), .raddr_i (cf_raddr), .rdata_o (cf_rdata));

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) begin
      slot_full_q <= '0;
      slot_info_q <= '0;
    end else begin
      if (slot_done) slot_full_q[slot_idx] <= 1'b0;
      if (mb_commit) begin
        slot_full_q[mb_slot] <= 1'b1;
        slot_info_q[mb_slot] <= mb_info;
      end
    end
  end

  // ========================================================= CAVLC + packer
  logic        tk_valid, tk_ready, cavlc_busy;
  logic [1:0]  tk_kind;
  logic [5:0]  tk_len;
  logic [31:0] tk_bits;
  frame_t      tk_frame;

  bow_h264_cavlc #(
    .MaxWidth (MaxWidth)
  ) u_cavlc (
    .clk_i         (vid_clk_i),
    .rst_ni        (vrst_n),
    .cf_raddr_o    (cf_raddr),
    .cf_rdata_i    (cf_rdata),
    .slot_full_i   (slot_full_q),
    .slot_info_i   (slot_info_q),
    .slot_done_o   (slot_done),
    .slot_idx_o    (slot_idx),
    .tk_valid_o    (tk_valid),
    .tk_ready_i    (tk_ready),
    .tk_kind_o     (tk_kind),
    .tk_len_o      (tk_len),
    .tk_bits_o     (tk_bits),
    .tk_frame_o    (tk_frame),
    .busy_o        (cavlc_busy)
  );

  logic        out_push, out_full, out_last, pack_busy;
  logic [31:0] out_data;

  bow_h264_bitpack u_pack (
    .clk_i         (vid_clk_i),
    .rst_ni        (vrst_n),
    .tk_valid_i    (tk_valid),
    .tk_ready_o    (tk_ready),
    .tk_kind_i     (tk_kind),
    .tk_len_i      (tk_len),
    .tk_bits_i     (tk_bits),
    .tk_frame_i    (tk_frame),
    .out_push_o    (out_push),
    .out_full_i    (out_full),
    .out_data_o    (out_data),
    .out_last_o    (out_last),
    .frame_done_o  (frame_done),
    .frame_bytes_o (frame_bytes),
    .frame_o       (frame_info),
    .busy_o        (pack_busy)
  );

  // ========================================================= output FIFO
  // A two word FIFO in front of the dual clock FIFO keeps the full flag of
  // the latter (gray pointer compare) out of the bit packer timing.
  logic [32:0] out_rdata, skid_rdata;
  logic        skid_empty, async_full;
  logic [1:0]  skid_level;

  bow_fifo_sync #(
    .Width (33),
    .Depth (2)
  ) u_skid (
    .clk_i   (vid_clk_i),
    .rst_ni  (vrst_n),
    .clr_i   (1'b0),
    .push_i  (out_push),
    .wdata_i ({out_last, out_data}),
    .pop_i   (!async_full),
    .rdata_o (skid_rdata),
    .full_o  (out_full),
    .empty_o (skid_empty),
    .level_o (skid_level)
  );

  bow_fifo_async #(
    .Width (33),
    .Depth (OutDepth)
  ) u_out (
    .wclk_i  (vid_clk_i),
    .wrst_ni (vrst_n),
    .push_i  (!skid_empty),
    .wdata_i (skid_rdata),
    .full_o  (async_full),
    .rclk_i  (clk_i),
    .rrst_ni (xrst_n),
    .pop_i   (m_axis_tvalid_o && m_axis_tready_i),
    .rdata_o (out_rdata),
    .empty_o (out_empty)
  );

  assign m_axis_tvalid_o = !out_empty;
  assign m_axis_tdata_o  = out_rdata[31:0];
  assign m_axis_tlast_o  = out_rdata[32];

  // ============================================================ statistics
  // FRAME_CYCLES: start of frame -> end of its NAL unit (frames overlap: the
  // start times wait in a small FIFO); MB_CYCLES: cycles the macroblock
  // engine worked since START.
  logic [31:0] now_q, mb_work_q, ts_head;
  logic        ts_empty, ts_full;
  logic [2:0]  ts_level;

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) begin
      now_q        <= '0;
      mb_work_q    <= '0;
      frame_cycles <= '0;
      mb_cycles    <= '0;
    end else begin
      now_q <= now_q + 32'd1;
      if (start) mb_work_q <= '0;
      else if (mb_work) mb_work_q <= mb_work_q + 32'd1;
      if (frame_done) begin
        frame_cycles <= ts_empty ? '0 : now_q - ts_head;
        mb_cycles    <= mb_work_q;
      end
    end
  end

  bow_fifo_sync #(
    .Width (32),
    .Depth (4)
  ) u_ts (
    .clk_i   (vid_clk_i),
    .rst_ni  (vrst_n),
    .clr_i   (start),
    .push_i  (frame_start),
    .wdata_i (now_q),
    .pop_i   (frame_done),
    .rdata_o (ts_head),
    .full_o  (ts_full),
    .empty_o (ts_empty),
    .level_o (ts_level)
  );

  // (an error still on its way to STATUS counts: BUSY low means it is there)
  assign busy = armed || in_active || !strip_empty || mb_busy || (slot_full_q != '0) ||
                cavlc_busy || pack_busy || !skid_empty || (err_pend_q != '0) || !err_ready;

  logic unused;
  assign unused = ^{strip_full, strip_level, ts_full, ts_level, skid_level};

`ifndef SYNTHESIS
  always @(posedge vid_clk_i) begin
    if (vrst_n && strip_push && strip_full) $error("bow_h264: strip FIFO overflow");
    if (vrst_n && mb_commit && slot_full_q[mb_slot]) $error("bow_h264: coefficient slot overwritten");
  end
`endif

endmodule
