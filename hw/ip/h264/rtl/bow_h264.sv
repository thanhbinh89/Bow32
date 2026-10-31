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
// the bit stream stays valid. The output stream back-pressures the encoder.
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

  // =========================================================== registers
  logic              en_sys, deblock_sys, qp_upd_sys, start_sys, stop_sys;
  logic [CoordW-1:0] width, height;
  logic [5:0]        qp_sys;
  logic [15:0]       frames;
  logic [7:0]        skip;
  logic              busy_sys, armed_sys, frame_done_sys, seq_done_sys, err_ovf_sys, err_in_sys;
  logic [23:0]       frame_bytes;
  logic [31:0]       frame_cycles, mb_cycles;
  logic              out_empty;

  bow_h264_regs #(
    .MaxWidth  (MaxWidth),
    .NumStrips (NumStrips)
  ) u_regs (
    .clk_i,
    .rst_ni,
    .bus_req_i      (reg_req_i),
    .bus_rsp_o      (reg_rsp_o),
    .enable_o       (en_sys),
    .deblock_o      (deblock_sys),
    .width_o        (width),
    .height_o       (height),
    .qp_o           (qp_sys),
    .qp_upd_o       (qp_upd_sys),
    .frames_o       (frames),
    .skip_o         (skip),
    .start_o        (start_sys),
    .stop_o         (stop_sys),
    .busy_i         (busy_sys || !out_empty),
    .armed_i        (armed_sys),
    .frame_done_i   (frame_done_sys),
    .seq_done_i     (seq_done_sys),
    .err_ovf_i      (err_ovf_sys),
    .err_input_i    (err_in_sys),
    .frame_bytes_i  (frame_bytes),
    .frame_cycles_i (frame_cycles),
    .mb_cycles_i    (mb_cycles),
    .irq_o
  );

  // ===================================================== clock crossings
  /* verilator lint_off SYNCASYNCNET */
  logic vrst_n;
  /* verilator lint_on SYNCASYNCNET */

  bow_rst_sync u_vrst (
    .clk_i  (vid_clk_i),
    .rst_ni (vid_rst_ni & rst_ni),
    .rst_no (vrst_n)
  );

  logic en, deblock, qp_upd, start, stop;

  bow_sync u_sync_en (.clk_i (vid_clk_i), .rst_ni (vrst_n), .d_i (en_sys), .q_o (en));
  bow_sync u_sync_db (.clk_i (vid_clk_i), .rst_ni (vrst_n), .d_i (deblock_sys), .q_o (deblock));

  bow_cdc_pulse u_cdc_qp (
    .src_clk_i (clk_i), .src_rst_ni (rst_ni), .src_pulse_i (qp_upd_sys),
    .dst_clk_i (vid_clk_i), .dst_rst_ni (vrst_n), .dst_pulse_o (qp_upd));
  bow_cdc_pulse u_cdc_start (
    .src_clk_i (clk_i), .src_rst_ni (rst_ni), .src_pulse_i (start_sys),
    .dst_clk_i (vid_clk_i), .dst_rst_ni (vrst_n), .dst_pulse_o (start));
  bow_cdc_pulse u_cdc_stop (
    .src_clk_i (clk_i), .src_rst_ni (rst_ni), .src_pulse_i (stop_sys),
    .dst_clk_i (vid_clk_i), .dst_rst_ni (vrst_n), .dst_pulse_o (stop));

  // QP: captured when its pulse arrives (the register is stable by then)
  logic [5:0] qp_q;
  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n)      qp_q <= 6'd30;
    else if (qp_upd)  qp_q <= qp_sys;
  end

  logic busy, armed, frame_done, seq_done, err_ovf, err_in;

  bow_sync u_sync_busy (.clk_i, .rst_ni, .d_i (busy), .q_o (busy_sys));
  bow_sync u_sync_armed (.clk_i, .rst_ni, .d_i (armed), .q_o (armed_sys));

  bow_cdc_pulse u_cdc_done (
    .src_clk_i (vid_clk_i), .src_rst_ni (vrst_n), .src_pulse_i (frame_done),
    .dst_clk_i (clk_i), .dst_rst_ni (rst_ni), .dst_pulse_o (frame_done_sys));
  bow_cdc_pulse u_cdc_seq (
    .src_clk_i (vid_clk_i), .src_rst_ni (vrst_n), .src_pulse_i (seq_done),
    .dst_clk_i (clk_i), .dst_rst_ni (rst_ni), .dst_pulse_o (seq_done_sys));

  // errors can come every cycle: at most one pulse per 16 video cycles
  logic [1:0] err_pend_q, err_pulse;
  logic [3:0] err_div_q;

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) begin
      err_pend_q <= '0;
      err_div_q  <= '0;
    end else begin
      err_div_q  <= err_div_q + 4'd1;
      err_pend_q <= (err_pend_q | {err_in, err_ovf}) & ~err_pulse;
    end
  end
  assign err_pulse = (err_div_q == '0) ? err_pend_q : '0;

  bow_cdc_pulse u_cdc_ovf (
    .src_clk_i (vid_clk_i), .src_rst_ni (vrst_n), .src_pulse_i (err_pulse[0]),
    .dst_clk_i (clk_i), .dst_rst_ni (rst_ni), .dst_pulse_o (err_ovf_sys));
  bow_cdc_pulse u_cdc_in (
    .src_clk_i (vid_clk_i), .src_rst_ni (vrst_n), .src_pulse_i (err_pulse[1]),
    .dst_clk_i (clk_i), .dst_rst_ni (rst_ni), .dst_pulse_o (err_in_sys));

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
  logic        tk_valid, tk_ready, tk_seq_last, cavlc_busy;
  logic [1:0]  tk_kind;
  logic [5:0]  tk_len;
  logic [31:0] tk_bits;

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
    .tk_seq_last_o (tk_seq_last),
    .busy_o        (cavlc_busy)
  );

  logic        out_push, out_full, out_last, pack_busy, pack_seq_last;
  logic [31:0] out_data;

  bow_h264_bitpack u_pack (
    .clk_i         (vid_clk_i),
    .rst_ni        (vrst_n),
    .tk_valid_i    (tk_valid),
    .tk_ready_o    (tk_ready),
    .tk_kind_i     (tk_kind),
    .tk_len_i      (tk_len),
    .tk_bits_i     (tk_bits),
    .tk_seq_last_i (tk_seq_last),
    .out_push_o    (out_push),
    .out_full_i    (out_full),
    .out_data_o    (out_data),
    .out_last_o    (out_last),
    .frame_done_o  (frame_done),
    .frame_bytes_o (frame_bytes),
    .seq_last_o    (pack_seq_last),
    .busy_o        (pack_busy)
  );

  assign seq_done = frame_done && pack_seq_last;

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
    .rrst_ni (rst_ni),
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

  assign busy = armed || in_active || !strip_empty || mb_busy || (slot_full_q != '0) ||
                cavlc_busy || pack_busy || !skid_empty;

  logic unused;
  assign unused = ^{strip_full, strip_level, ts_full, ts_level, skid_level};

`ifndef SYNTHESIS
  always @(posedge vid_clk_i) begin
    if (vrst_n && strip_push && strip_full) $error("bow_h264: strip FIFO overflow");
    if (vrst_n && mb_commit && slot_full_q[mb_slot]) $error("bow_h264: coefficient slot overwritten");
  end
`endif

endmodule
