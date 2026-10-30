// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 ISP (image signal processor) for RAW10 Bayer sensors, 1 pixel/clock.
//
//  sensor --+                                                       +--> m_axis (RGB888/YUV444)
//           +-> input -> BLC -> [5x5] -> DPC -> WB -> [3x3] -> demosaic -> CCM -> gamma -> CSC
//  TPG -----+                                                  |                           +--> capture -> buffer
//                                                              +--> statistics (AE/AWB/AF)
//
// Two clock domains:
//   clk_i      CPU / bus clock: registers (bow_isp_regs), capture buffer read
//   vid_clk_i  video clock: the whole pixel pipeline (200 MHz on the KV260)
//
// The pixel pipeline has no internal back-pressure. Window generators
// insert border pixels in the blanking (they stall the input), two small
// FIFOs decouple them, and the output must accept 1 pixel/clock (m_axis
// tready low with valid high is reported as an output error). See
// docs/ip/isp.md for the stage arithmetic and the register map.

module bow_isp import bow_bus_pkg::*; import bow_isp_pkg::*; #(
  parameter int unsigned MaxWidth = 2048,     // line buffer depth (>= frame width)
  parameter int unsigned BufWords = 32768     // capture buffer (24 bit words)
) (
  // CPU clock domain
  input  logic                clk_i,
  input  logic                rst_ni,
  input  bus_req_t            reg_req_i,     // registers (peripheral bus)
  output bus_rsp_t            reg_rsp_o,
  input  bus_req_t            buf_req_i,     // capture buffer (main bus), read only
  output bus_rsp_t            buf_rsp_o,
  output logic                irq_o,

  // Video clock domain
  input  logic                vid_clk_i,
  input  logic                vid_rst_ni,

  input  logic                s_axis_tvalid_i,   // RAW10 from the camera receiver
  output logic                s_axis_tready_o,
  input  logic [PixW-1:0]     s_axis_tdata_i,
  input  logic                s_axis_tuser_i,    // start of frame
  input  logic                s_axis_tlast_i,    // end of line

  output logic                m_axis_tvalid_o,   // processed video, UG934 component order:
  input  logic                m_axis_tready_i,   //   RGB: {R, B, G}, YUV444: {V, U, Y}
  output logic [3*OutW-1:0]   m_axis_tdata_o,
  output logic                m_axis_tuser_o,
  output logic                m_axis_tlast_o
);

  localparam int unsigned BufAW = $clog2(BufWords);

  // =========================================================================
  // CPU domain: registers
  // =========================================================================
  isp_cfg_t     cfg_stage;
  isp_cap_cfg_t cap_cfg;
  isp_stats_t   vid_stats;
  logic         en_sys, tpg_sys;
  logic         upd_req_sys, upd_ack_sys, cap_start_sys, cap_done_sys, snap_sys;
  logic         err_in_sys, err_fifo_sys, err_out_sys, err_cap_sys;
  logic [2:0]   lut_we;
  logic [PixW-1:0] lut_addr;
  logic [OutW-1:0] lut_data;
  logic [CoordW-1:0] meas_w, meas_h;

  bow_isp_regs #(
    .MaxWidth (MaxWidth),
    .BufWords (BufWords)
  ) u_regs (
    .clk_i,
    .rst_ni,
    .bus_req_i     (reg_req_i),
    .bus_rsp_o     (reg_rsp_o),
    .enable_o      (en_sys),
    .src_tpg_o     (tpg_sys),
    .cfg_o         (cfg_stage),
    .upd_req_o     (upd_req_sys),
    .upd_ack_i     (upd_ack_sys),
    .cap_cfg_o     (cap_cfg),
    .cap_start_o   (cap_start_sys),
    .cap_done_i    (cap_done_sys),
    .lut_we_o      (lut_we),
    .lut_addr_o    (lut_addr),
    .lut_data_o    (lut_data),
    .snap_i        (snap_sys),
    .stats_i       (vid_stats),
    .meas_width_i  (meas_w),
    .meas_height_i (meas_h),
    .err_input_i   (err_in_sys),
    .err_fifo_i    (err_fifo_sys),
    .err_output_i  (err_out_sys),
    .err_cap_i     (err_cap_sys),
    .irq_o
  );

  // =========================================================================
  // Clock domain crossing
  // =========================================================================
  // vrst_n is the asynchronous reset of the video domain and also loads the
  // configuration synchronously (see "active configuration" below).
  /* verilator lint_off SYNCASYNCNET */
  logic vrst_n;
  /* verilator lint_on SYNCASYNCNET */

  bow_rst_sync u_vrst (
    .clk_i  (vid_clk_i),
    .rst_ni (vid_rst_ni & rst_ni),
    .rst_no (vrst_n)
  );

  logic en, src_tpg;

  bow_sync u_sync_en (
    .clk_i  (vid_clk_i),
    .rst_ni (vrst_n),
    .d_i    (en_sys),
    .q_o    (en)
  );

  bow_sync u_sync_tpg (
    .clk_i  (vid_clk_i),
    .rst_ni (vrst_n),
    .d_i    (tpg_sys),
    .q_o    (src_tpg)
  );

  logic upd_req, upd_ack, cap_start, cap_done, snap;
  logic err_in, err_fifo, err_out, err_cap;

  bow_cdc_pulse u_cdc_upd_req (
    .src_clk_i (clk_i), .src_rst_ni (rst_ni), .src_pulse_i (upd_req_sys),
    .dst_clk_i (vid_clk_i), .dst_rst_ni (vrst_n), .dst_pulse_o (upd_req));
  bow_cdc_pulse u_cdc_upd_ack (
    .src_clk_i (vid_clk_i), .src_rst_ni (vrst_n), .src_pulse_i (upd_ack),
    .dst_clk_i (clk_i), .dst_rst_ni (rst_ni), .dst_pulse_o (upd_ack_sys));
  bow_cdc_pulse u_cdc_cap_start (
    .src_clk_i (clk_i), .src_rst_ni (rst_ni), .src_pulse_i (cap_start_sys),
    .dst_clk_i (vid_clk_i), .dst_rst_ni (vrst_n), .dst_pulse_o (cap_start));
  bow_cdc_pulse u_cdc_cap_done (
    .src_clk_i (vid_clk_i), .src_rst_ni (vrst_n), .src_pulse_i (cap_done),
    .dst_clk_i (clk_i), .dst_rst_ni (rst_ni), .dst_pulse_o (cap_done_sys));
  bow_cdc_pulse u_cdc_snap (
    .src_clk_i (vid_clk_i), .src_rst_ni (vrst_n), .src_pulse_i (snap),
    .dst_clk_i (clk_i), .dst_rst_ni (rst_ni), .dst_pulse_o (snap_sys));

  // Error events can come every cycle: report each kind at most every 16
  // video cycles so that the pulse synchroniser never merges two pulses.
  logic [3:0] err_pend_q, err_evt, err_pulse;
  logic [3:0] err_div_q;

  assign err_evt = {err_cap, err_out, err_fifo, err_in};

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) begin
      err_pend_q <= '0;
      err_div_q  <= '0;
    end else begin
      err_div_q  <= err_div_q + 4'd1;
      err_pend_q <= (err_pend_q | err_evt) & ~err_pulse;
    end
  end

  assign err_pulse = (err_div_q == '0) ? err_pend_q : '0;

  for (genvar i = 0; i < 4; i++) begin : g_cdc_err
    logic err_dst;
    bow_cdc_pulse u_cdc (
      .src_clk_i (vid_clk_i), .src_rst_ni (vrst_n), .src_pulse_i (err_pulse[i]),
      .dst_clk_i (clk_i), .dst_rst_ni (rst_ni), .dst_pulse_o (err_dst));
    if (i == 0) begin : g_in
      assign err_in_sys = err_dst;
    end else if (i == 1) begin : g_fifo
      assign err_fifo_sys = err_dst;
    end else if (i == 2) begin : g_out
      assign err_out_sys = err_dst;
    end else begin : g_cap
      assign err_cap_sys = err_dst;
    end
  end

  // =========================================================================
  // Video domain: active configuration, updated between frames
  // =========================================================================
  isp_cfg_t cfg;
  logic     upd_pend_q, busy, in_active;

  logic upd_apply;
  assign upd_apply = upd_pend_q && !busy;

  // No asynchronous reset: during reset the configuration is loaded from the
  // (reset) staging registers, afterwards only between two frames.
  always_ff @(posedge vid_clk_i) begin
    if (!vrst_n || upd_apply) cfg <= cfg_stage;
  end

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) begin
      upd_pend_q <= 1'b0;
      upd_ack    <= 1'b0;
    end else begin
      upd_ack <= upd_apply;
      if (upd_req) upd_pend_q <= 1'b1;
      else if (upd_apply) upd_pend_q <= 1'b0;
    end
  end

  // =========================================================================
  // Source selection
  // =========================================================================
  logic            tpg_valid, tpg_user, tpg_last, src_ready;
  logic [PixW-1:0] tpg_data;

  bow_isp_tpg u_tpg (
    .clk_i    (vid_clk_i),
    .rst_ni   (vrst_n),
    .enable_i (en && src_tpg),
    .cfg_i    (cfg),
    .tvalid_o (tpg_valid),
    .tready_i (src_ready),
    .tdata_o  (tpg_data),
    .tuser_o  (tpg_user),
    .tlast_o  (tpg_last)
  );

  // The camera stream is dropped (tready = 1) while the TPG is selected.
  assign s_axis_tready_o = src_tpg ? 1'b1 : src_ready;

  // =========================================================================
  // Front: input -> BLC -> FIFO A -> 5x5 -> DPC -> WB -> FIFO B
  // =========================================================================
  logic            in_valid, in_sof, abort, front_ready;
  logic [PixW-1:0] in_data;

  bow_isp_input u_input (
    .clk_i         (vid_clk_i),
    .rst_ni        (vrst_n),
    .enable_i      (en),
    .width_i       (cfg.width),
    .height_i      (cfg.height),
    .hold_i        (upd_pend_q && !in_active),
    .ready_i       (front_ready),
    .s_tvalid_i    (src_tpg ? tpg_valid : s_axis_tvalid_i),
    .s_tready_o    (src_ready),
    .s_tdata_i     (src_tpg ? tpg_data  : s_axis_tdata_i),
    .s_tuser_i     (src_tpg ? tpg_user  : s_axis_tuser_i),
    .s_tlast_i     (src_tpg ? tpg_last  : s_axis_tlast_i),
    .valid_o       (in_valid),
    .data_o        (in_data),
    .sof_o         (in_sof),
    .abort_o       (abort),
    .err_o         (err_in),
    .active_o      (in_active),
    .meas_width_o  (meas_w),
    .meas_height_o (meas_h)
  );

  logic            blc_valid, blc_sof;
  logic [PixW-1:0] blc_data;

  bow_isp_blc u_blc (
    .clk_i    (vid_clk_i),
    .rst_ni   (vrst_n),
    .enable_i (cfg.blc_en),
    .black_i  (cfg.blc),
    .valid_i  (in_valid),
    .data_i   (in_data),
    .sof_i    (in_sof),
    .valid_o  (blc_valid),
    .data_o   (blc_data),
    .sof_o    (blc_sof)
  );

  // FIFO A: absorbs the pixels in flight while the 5x5 generator inserts
  // border pixels.
  logic          fa_empty, fa_full, w5_ready;
  logic [3:0]    fa_level;
  logic [PixW:0] fa_rdata;

  bow_fifo_sync #(
    .Width (PixW + 1),
    .Depth (8)
  ) u_fifo_a (
    .clk_i   (vid_clk_i),
    .rst_ni  (vrst_n),
    .clr_i   (abort),
    .push_i  (blc_valid),
    .wdata_i ({blc_sof, blc_data}),
    .pop_i   (w5_ready && !fa_empty),
    .rdata_o (fa_rdata),
    .full_o  (fa_full),
    .empty_o (fa_empty),
    .level_o (fa_level)
  );

  logic                      w5_valid, w5_sof, w5_eof, w5_eol, w5_busy;
  logic [4:0][4:0][PixW-1:0] w5_win;
  logic [CoordW-1:0]         w5_x, w5_y;

  bow_isp_window #(
    .N        (5),
    .DataW    (PixW),
    .MaxWidth (MaxWidth)
  ) u_win5 (
    .clk_i       (vid_clk_i),
    .rst_ni      (vrst_n),
    .abort_i     (abort),
    .width_i     (cfg.width),
    .height_i    (cfg.height),
    .in_valid_i  (!fa_empty),
    .in_ready_o  (w5_ready),
    .in_data_i   (fa_rdata[PixW-1:0]),
    .in_sof_i    (fa_rdata[PixW]),
    .busy_o      (w5_busy),
    .out_valid_o (w5_valid),
    .out_win_o   (w5_win),
    .out_x_o     (w5_x),
    .out_y_o     (w5_y),
    .out_sof_o   (w5_sof),
    .out_eol_o   (w5_eol),
    .out_eof_o   (w5_eof)
  );

  logic              dpc_valid, dpc_sof, dpc_eof, dpc_hit;
  logic [PixW-1:0]   dpc_data;
  logic [CoordW-1:0] dpc_x, dpc_y;

  bow_isp_dpc u_dpc (
    .clk_i    (vid_clk_i),
    .rst_ni   (vrst_n),
    .abort_i  (abort),
    .enable_i (cfg.dpc_en),
    .th_i     (cfg.dpc_th),
    .valid_i  (w5_valid),
    .win_i    (w5_win),
    .x_i      (w5_x),
    .y_i      (w5_y),
    .sof_i    (w5_sof),
    .eof_i    (w5_eof),
    .valid_o  (dpc_valid),
    .data_o   (dpc_data),
    .x_o      (dpc_x),
    .y_o      (dpc_y),
    .sof_o    (dpc_sof),
    .eof_o    (dpc_eof),
    .hit_o    (dpc_hit)
  );

  logic            wb_valid, wb_sof;
  logic [PixW-1:0] wb_data;

  bow_isp_wb u_wb (
    .clk_i    (vid_clk_i),
    .rst_ni   (vrst_n),
    .enable_i (cfg.wb_en),
    .bayer_i  (cfg.bayer),
    .gain_i   (cfg.wb_gain),
    .valid_i  (dpc_valid),
    .data_i   (dpc_data),
    .x_i      (dpc_x),
    .y_i      (dpc_y),
    .sof_i    (dpc_sof),
    .valid_o  (wb_valid),
    .data_o   (wb_data),
    .sof_o    (wb_sof)
  );

  // FIFO B: decouples the two window generators.
  logic          fb_empty, fb_full, w3_ready;
  logic [5:0]    fb_level;
  logic [PixW:0] fb_rdata;

  bow_fifo_sync #(
    .Width (PixW + 1),
    .Depth (32)
  ) u_fifo_b (
    .clk_i   (vid_clk_i),
    .rst_ni  (vrst_n),
    .clr_i   (abort),
    .push_i  (wb_valid),
    .wdata_i ({wb_sof, wb_data}),
    .pop_i   (w3_ready && !fb_empty),
    .rdata_o (fb_rdata),
    .full_o  (fb_full),
    .empty_o (fb_empty),
    .level_o (fb_level)
  );

  // Input flow control: room for everything that may still be in flight
  // between the input and each FIFO.
  assign front_ready = (fa_level < 4'd4) && (fb_level < 6'd12);
  assign err_fifo    = (blc_valid && fa_full) || (wb_valid && fb_full);

  // =========================================================================
  // Back: 3x3 -> demosaic -> CCM -> gamma -> CSC -> output / capture
  // =========================================================================
  logic                      w3_valid, w3_sof, w3_eof, w3_eol, w3_busy;
  logic [2:0][2:0][PixW-1:0] w3_win;
  logic [CoordW-1:0]         w3_x, w3_y;

  bow_isp_window #(
    .N        (3),
    .DataW    (PixW),
    .MaxWidth (MaxWidth)
  ) u_win3 (
    .clk_i       (vid_clk_i),
    .rst_ni      (vrst_n),
    .abort_i     (abort),
    .width_i     (cfg.width),
    .height_i    (cfg.height),
    .in_valid_i  (!fb_empty),
    .in_ready_o  (w3_ready),
    .in_data_i   (fb_rdata[PixW-1:0]),
    .in_sof_i    (fb_rdata[PixW]),
    .busy_o      (w3_busy),
    .out_valid_o (w3_valid),
    .out_win_o   (w3_win),
    .out_x_o     (w3_x),
    .out_y_o     (w3_y),
    .out_sof_o   (w3_sof),
    .out_eol_o   (w3_eol),
    .out_eof_o   (w3_eof)
  );

  logic                 dm_valid, dm_sof, dm_eof;
  logic [2:0][PixW-1:0] dm_rgb;
  logic [CoordW-1:0]    dm_x, dm_y;

  bow_isp_demosaic u_demosaic (
    .clk_i   (vid_clk_i),
    .rst_ni  (vrst_n),
    .abort_i (abort),
    .bayer_i (cfg.bayer),
    .valid_i (w3_valid),
    .win_i   (w3_win),
    .x_i     (w3_x),
    .y_i     (w3_y),
    .sof_i   (w3_sof),
    .eof_i   (w3_eof),
    .valid_o (dm_valid),
    .rgb_o   (dm_rgb),
    .x_o     (dm_x),
    .y_o     (dm_y),
    .sof_o   (dm_sof),
    .eof_o   (dm_eof)
  );

  bow_isp_stats u_stats (
    .clk_i       (vid_clk_i),
    .rst_ni      (vrst_n),
    .abort_i     (abort),
    .x0_i        (cfg.st_x0),
    .x1_i        (cfg.st_x1),
    .y0_i        (cfg.st_y0),
    .y1_i        (cfg.st_y1),
    .sat_i       (cfg.st_sat),
    .valid_i     (dm_valid),
    .rgb_i       (dm_rgb),
    .x_i         (dm_x),
    .y_i         (dm_y),
    .eof_i       (dm_eof),
    .dpc_valid_i (dpc_valid),
    .dpc_hit_i   (dpc_hit),
    .dpc_eof_i   (dpc_eof),
    .stats_o     (vid_stats),
    .snap_o      (snap)
  );

  logic                 ccm_valid, ccm_sof, ccm_eof;
  logic [2:0][PixW-1:0] ccm_rgb;
  logic [CoordW-1:0]    ccm_x, ccm_y;

  bow_isp_mat3x3 #(
    .W    (PixW),
    .OffW (11)
  ) u_ccm (
    .clk_i    (vid_clk_i),
    .rst_ni   (vrst_n),
    .abort_i  (abort),
    .enable_i (cfg.ccm_en),
    .coef_i   (cfg.ccm),
    .off_i    (cfg.ccm_off),
    .valid_i  (dm_valid),
    .in_i     (dm_rgb),
    .x_i      (dm_x),
    .y_i      (dm_y),
    .sof_i    (dm_sof),
    .eof_i    (dm_eof),
    .valid_o  (ccm_valid),
    .out_o    (ccm_rgb),
    .x_o      (ccm_x),
    .y_o      (ccm_y),
    .sof_o    (ccm_sof),
    .eof_o    (ccm_eof)
  );

  logic                 gm_valid, gm_sof, gm_eof;
  logic [2:0][OutW-1:0] gm_rgb;
  logic [CoordW-1:0]    gm_x, gm_y;

  bow_isp_gamma u_gamma (
    .clk_i      (vid_clk_i),
    .rst_ni     (vrst_n),
    .abort_i    (abort),
    .enable_i   (cfg.gamma_en),
    .lut_clk_i  (clk_i),
    .lut_we_i   (lut_we),
    .lut_addr_i (lut_addr),
    .lut_data_i (lut_data),
    .valid_i    (ccm_valid),
    .in_i       (ccm_rgb),
    .x_i        (ccm_x),
    .y_i        (ccm_y),
    .sof_i      (ccm_sof),
    .eof_i      (ccm_eof),
    .valid_o    (gm_valid),
    .out_o      (gm_rgb),
    .x_o        (gm_x),
    .y_o        (gm_y),
    .sof_o      (gm_sof),
    .eof_o      (gm_eof)
  );

  logic                 cs_valid, cs_sof, cs_eof;
  logic [2:0][OutW-1:0] cs_out;
  logic [CoordW-1:0]    cs_x, cs_y;

  bow_isp_mat3x3 #(
    .W    (OutW),
    .OffW (9)
  ) u_csc (
    .clk_i    (vid_clk_i),
    .rst_ni   (vrst_n),
    .abort_i  (abort),
    .enable_i (cfg.csc_en),
    .coef_i   (cfg.csc),
    .off_i    (cfg.csc_off),
    .valid_i  (gm_valid),
    .in_i     (gm_rgb),
    .x_i      (gm_x),
    .y_i      (gm_y),
    .sof_i    (gm_sof),
    .eof_i    (gm_eof),
    .valid_o  (cs_valid),
    .out_o    (cs_out),
    .x_o      (cs_x),
    .y_o      (cs_y),
    .sof_o    (cs_sof),
    .eof_o    (cs_eof)
  );

  // Output stream (UG934 order: component 0 in the LSBs).
  // An abort can cut a frame in the middle of an output line. The rest of
  // that line is then sent as zero pixels, so that every output line has
  // `width` pixels; the frame itself just ends early. The next frame cannot
  // reach the output before: the window generators need 3 of its lines first.
  logic              line_open_q, pad_q;
  logic [CoordW-1:0] out_x_q;          // x of the next pixel of an open line
  logic [CoordW-1:0] last_x;
  logic              cs_eol;

  assign last_x = cfg.width - CoordW'(1);
  assign cs_eol = (cs_x == last_x);

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) begin
      m_axis_tvalid_o <= 1'b0;
      m_axis_tdata_o  <= '0;
      m_axis_tuser_o  <= 1'b0;
      m_axis_tlast_o  <= 1'b0;
      line_open_q     <= 1'b0;
      pad_q           <= 1'b0;
      out_x_q         <= '0;
    end else if (cs_valid) begin
      m_axis_tvalid_o <= 1'b1;
      m_axis_tuser_o  <= cs_sof;
      m_axis_tlast_o  <= cs_eol;
      m_axis_tdata_o  <= cfg.csc_en ? {cs_out[2], cs_out[1], cs_out[0]}    // V U Y
                                    : {cs_out[0], cs_out[2], cs_out[1]};   // R B G
      line_open_q     <= !cs_eol;
      out_x_q         <= cs_x + CoordW'(1);
      pad_q           <= abort && !cs_eol;
    end else if (pad_q || (abort && line_open_q)) begin
      m_axis_tvalid_o <= 1'b1;
      m_axis_tuser_o  <= 1'b0;
      m_axis_tlast_o  <= (out_x_q == last_x);
      m_axis_tdata_o  <= '0;
      line_open_q     <= (out_x_q != last_x);
      out_x_q         <= out_x_q + CoordW'(1);
      pad_q           <= (out_x_q != last_x);
    end else begin
      m_axis_tvalid_o <= 1'b0;
    end
  end

  assign err_out = m_axis_tvalid_o && !m_axis_tready_i;

`ifndef SYNTHESIS
  always @(posedge vid_clk_i) begin
    if (vrst_n && pad_q && cs_valid) begin
      $error("bow_isp: a frame reached the output while an aborted line was completed");
    end
  end
`endif

  // =========================================================================
  // Capture into the buffer
  // =========================================================================
  logic                 cap_we, cap_busy;
  logic [BufAW-1:0]     cap_waddr;
  logic [3*OutW-1:0]    cap_wdata;

  bow_isp_capture #(
    .BufWords   (BufWords),
    .MaxColumns (MaxWidth / 2)
  ) u_capture (
    .clk_i   (vid_clk_i),
    .rst_ni  (vrst_n),
    .abort_i (abort),
    .start_i (cap_start),
    .cfg_i   (cap_cfg),
    .busy_o  (cap_busy),
    .done_o  (cap_done),
    .ovf_o   (err_cap),
    .valid_i (cs_valid),
    .comp_i  (cs_out),
    .x_i     (cs_x),
    .y_i     (cs_y),
    .sof_i   (cs_sof),
    .eof_i   (cs_eof),
    .we_o    (cap_we),
    .waddr_o (cap_waddr),
    .wdata_o (cap_wdata)
  );

  logic [3*OutW-1:0] buf_rdata;
  logic              buf_rvalid_q, buf_err_q;

  bow_ram_sdp #(
    .Width (3 * OutW),
    .Depth (BufWords)
  ) u_buffer (
    .wclk_i  (vid_clk_i),
    .we_i    (cap_we),
    .waddr_i (cap_waddr),
    .wdata_i (cap_wdata),
    .rclk_i  (clk_i),
    .re_i    (buf_req_i.req && !buf_req_i.we),
    .raddr_i (buf_req_i.addr[BufAW+1:2]),
    .rdata_o (buf_rdata)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      buf_rvalid_q <= 1'b0;
      buf_err_q    <= 1'b0;
    end else begin
      buf_rvalid_q <= buf_req_i.req;
      buf_err_q    <= buf_req_i.req && buf_req_i.we;
    end
  end

  assign buf_rsp_o.gnt    = 1'b1;
  assign buf_rsp_o.rvalid = buf_rvalid_q;
  assign buf_rsp_o.err    = buf_err_q;
  assign buf_rsp_o.rdata  = {8'h00, buf_rdata};

  // =========================================================================
  // Pipeline busy (configuration updates wait until it is empty)
  // =========================================================================
  logic [5:0] tail_q;

  always_ff @(posedge vid_clk_i or negedge vrst_n) begin
    if (!vrst_n) begin
      tail_q <= '0;
    end else if (w5_valid || w3_valid || blc_valid || in_valid) begin
      tail_q <= 6'd40;          // > latency of DPC + WB and demosaic .. capture
    end else if (tail_q != '0) begin
      tail_q <= tail_q - 6'd1;
    end
  end

  assign busy = in_active || !fa_empty || w5_busy || !fb_empty || w3_busy || (tail_q != '0) ||
                pad_q;

  logic unused;
  assign unused = ^{w5_eol, w3_eol, cap_busy, buf_req_i.addr[31:BufAW+2], buf_req_i.addr[1:0],
                    buf_req_i.be, buf_req_i.wdata};

endmodule
