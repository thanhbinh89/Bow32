// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// H.264 encoder input: ISP output (YUV 4:4:4, raster, 1 pixel/clock at most)
// -> 4:2:0 -> strip buffers, frame selection and strip hand-over.
//
// * Frame selection: after START, the start of frame (SOF) of every input
//   frame either starts a coded frame or is skipped (SKIP frames between two
//   coded frames, FRAMES coded frames in total, 0 = until STOP). A frame
//   that arrives while the previous one is still being received is not
//   coded (and not counted).
// * Luma goes to the luma strip buffer, 8 pixels per 64 bit word. Chroma is
//   the rounded mean of every 2x2 block: the horizontal pair sums of the even
//   lines wait in a line buffer for the odd lines. 8 chroma samples per word.
// * The strip buffers hold NumStrips strips of 16 lines. Strips get a slot in
//   order; a strip is handed to the macroblock engine (strip_valid_o) once all
//   its lines have been received, the engine releases the slot when it has
//   read it (strip_free_i). Pixels of a strip without a slot are dropped
//   (err_ovf_o: the encoder is slower than the camera); the strip is still
//   coded (with stale samples) so that the bit stream stays valid.
// * A frame that ends early (SOF before `height` lines, or enable_i low) is
//   completed the same way (err_input_o). Shorter lines are flagged too,
//   longer lines and frames are cropped. The last strip of a frame whose
//   height is not a multiple of 16 is completed by the engine, which repeats
//   the last line (strip_t.last_line).
//
// Requirements: width multiple of 16, height even, width <= MaxWidth; the
// source has at least 2 cycles between lines (cameras have hundreds).

module bow_h264_input import bow_h264_pkg::*; #(
  parameter int unsigned MaxWidth  = 2048,    // power of two
  parameter int unsigned NumStrips = 4        // 2 or 4
) (
  input  logic                                         clk_i,
  input  logic                                         rst_ni,

  // configuration (quasi-static: change only while enable_i = 0)
  input  logic                                         enable_i,
  input  logic [CoordW-1:0]                            width_i,
  input  logic [CoordW-1:0]                            height_i,

  // sequence control (pulses) and parameters
  input  logic                                         start_i,
  input  logic                                         stop_i,
  input  logic [15:0]                                  frames_i,   // sampled at start_i
  input  logic [7:0]                                   skip_i,     // sampled at start_i
  input  logic [5:0]                                   qp_i,       // sampled at every frame start
  input  logic                                         deblock_i,

  // ISP output stream
  input  logic                                         s_valid_i,
  input  logic [23:0]                                  s_data_i,   // {V, U, Y}
  input  logic                                         s_sof_i,
  input  logic                                         s_eol_i,

  // strip buffer write ports
  output logic                                         y_we_o,
  output logic [$clog2(NumStrips * 2 * MaxWidth)-1:0]  y_waddr_o,
  output logic [63:0]                                  y_wdata_o,
  output logic                                         c_we_o,
  output logic [$clog2(NumStrips * MaxWidth / 2)-1:0]  c_waddr_o,
  output logic [63:0]                                  cb_wdata_o,
  output logic [63:0]                                  cr_wdata_o,

  // strips to the macroblock engine
  output logic                                         strip_valid_o,
  output strip_t                                       strip_o,
  input  logic                                         strip_free_i,

  // status
  output logic                                         armed_o,
  output logic                                         active_o,
  output logic                                         frame_start_o,
  output logic                                         err_ovf_o,
  output logic                                         err_input_o
);

  localparam int unsigned SW  = $clog2(NumStrips);
  localparam int unsigned WW  = $clog2(MaxWidth / 8);
  localparam int unsigned YAW = $clog2(NumStrips * 2 * MaxWidth);
  localparam int unsigned CAW = $clog2(NumStrips * MaxWidth / 2);
  localparam int unsigned LbAW = $clog2(MaxWidth / 2);

  // ---------------------------------------------------------------- frame size
  logic [MbW-1:0] mbh;
  logic [3:0]     last_line;

  assign mbh       = MbW'(height_i[CoordW-1:4]) + MbW'(height_i[3:0] != 4'd0);
  assign last_line = 4'(height_i - CoordW'(1));

  // --------------------------------------------------------- sequence control
  logic        armed_q, inf_q, idr_q;
  logic [15:0] left_q;
  logic [7:0]  skip_q, skip_cnt_q;

  typedef enum logic [1:0] {StIdle, StActive, StFinish} state_e;
  state_e state_q, state_d;

  logic sof, start_frame, in_frame, abort;

  assign sof         = s_valid_i && s_sof_i;
  assign start_frame = (state_q == StIdle) && sof && enable_i && armed_q && (skip_cnt_q == '0);
  assign in_frame    = (state_q == StActive) && s_valid_i && !s_sof_i && enable_i;
  assign abort       = (state_q == StActive) && (sof || !enable_i);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      armed_q    <= 1'b0;
      inf_q      <= 1'b0;
      idr_q      <= 1'b0;
      left_q     <= '0;
      skip_q     <= '0;
      skip_cnt_q <= '0;
    end else if (start_i) begin
      armed_q    <= 1'b1;
      inf_q      <= (frames_i == '0);
      left_q     <= frames_i;
      skip_q     <= skip_i;
      skip_cnt_q <= '0;
      idr_q      <= 1'b0;
    end else if (stop_i || !enable_i) begin
      armed_q <= 1'b0;
    end else if (start_frame) begin
      skip_cnt_q <= skip_q;
      idr_q      <= ~idr_q;
      if (!inf_q) begin
        left_q <= left_q - 16'd1;
        if (left_q == 16'd1) armed_q <= 1'b0;
      end
    end else if (sof && state_q == StIdle && armed_q && skip_cnt_q != '0) begin
      skip_cnt_q <= skip_cnt_q - 8'd1;
    end
  end

  // ------------------------------------------------------------ frame state
  logic [CoordW-1:0] x_q, y_q, px_x, px_y;
  logic [CoordW-1:0] x_d, y_d;
  logic              px_in;                 // pixel of the coded frame
  logic              line_end, frame_end, short_line;
  frame_t            frame_q;
  logic [MbW-1:0]    done_q, done_d;        // strips whose lines have all been received
  logic [MbW-1:0]    alloc_q, alloc_d;      // strips that own a slot
  logic [MbW-1:0]    push_q;                // strips handed to the engine
  logic [SW-1:0]     base_q;                // slot of strip 0 of the frame
  logic [SW-1:0]     next_slot_q;
  logic [SW:0]       used_q;                // slots allocated and not yet released
  logic              do_alloc, do_push;
  logic [MbW-1:0]    recv;

  assign px_in = start_frame || in_frame;
  assign px_x  = start_frame ? '0 : x_q;
  assign px_y  = start_frame ? '0 : y_q;

  assign line_end   = px_in && s_eol_i;
  assign frame_end  = line_end && (px_y == height_i - CoordW'(1));
  assign short_line = line_end && (px_x < width_i - CoordW'(1));

  always_comb begin
    state_d = state_q;
    x_d     = x_q;
    y_d     = y_q;
    done_d  = done_q;
    if (start_frame) begin
      state_d = StActive;
      done_d  = '0;
    end
    if (px_in) begin
      x_d = s_eol_i ? '0 : px_x + CoordW'(1);
      y_d = s_eol_i ? px_y + CoordW'(1) : px_y;
      if (frame_end) begin
        state_d = StFinish;
        done_d  = mbh;
      end else if (line_end && px_y[3:0] == 4'd15) begin
        done_d = MbW'(px_y[CoordW-1:4]) + MbW'(1);
      end
    end
    if (abort) begin
      state_d = StFinish;
      done_d  = mbh;
    end
    if (state_q == StFinish && push_q == mbh) begin
      state_d = StIdle;
    end
  end

  // Strips get a slot in order, the receiving one at the latest (its first
  // pixel is written one cycle after it arrived, the slot is known by then).
  assign recv     = (state_d == StActive) ? MbW'(y_d[CoordW-1:4]) : mbh;
  assign do_alloc = (state_d != StIdle) && ((start_frame ? '0 : alloc_q) < mbh) &&
                    ((start_frame ? '0 : alloc_q) <= recv) && (used_q < (SW + 1)'(NumStrips));
  assign alloc_d  = (start_frame ? '0 : alloc_q) + MbW'(do_alloc);
  assign do_push  = (state_q != StIdle) && (push_q < alloc_q) && (push_q < done_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= StIdle;
      x_q           <= '0;
      y_q           <= '0;
      frame_q       <= '0;
      done_q        <= '0;
      alloc_q       <= '0;
      push_q        <= '0;
      base_q        <= '0;
      next_slot_q   <= '0;
      used_q        <= '0;
      strip_valid_o <= 1'b0;
      strip_o       <= '0;
    end else begin
      state_q <= state_d;
      x_q     <= x_d;
      y_q     <= y_d;
      done_q  <= done_d;
      alloc_q <= alloc_d;
      if (start_frame) begin
        frame_q.qp       <= qp_i;
        frame_q.deblock  <= deblock_i;
        frame_q.idr_id   <= idr_q;
        frame_q.seq_last <= !inf_q && (left_q == 16'd1);
        base_q           <= next_slot_q;
        push_q           <= '0;
      end
      if (do_alloc) next_slot_q <= next_slot_q + SW'(1);
      used_q <= used_q + (SW + 1)'(do_alloc) - (SW + 1)'(strip_free_i);

      strip_valid_o <= do_push;
      if (do_push) begin
        push_q              <= push_q + MbW'(1);
        strip_o.slot        <= 2'(base_q + SW'(push_q));
        strip_o.mby         <= push_q;
        strip_o.first       <= (push_q == '0);
        strip_o.last        <= (push_q == mbh - MbW'(1));
        strip_o.last_line   <= (push_q == mbh - MbW'(1)) ? last_line : 4'd15;
        strip_o.last_cline  <= (push_q == mbh - MbW'(1)) ? last_line[3:1] : 3'd7;
        strip_o.frame       <= frame_q;
      end
    end
  end

  assign armed_o       = armed_q;
  assign active_o      = (state_q != StIdle);
  assign frame_start_o = start_frame;

  // ------------------------------------------------------ pixel write stage
  logic              p_valid_q;
  logic [CoordW-1:0] p_x_q, p_y_q;
  logic [7:0]        p_y8_q, p_u_q, p_v_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      p_valid_q <= 1'b0;
      p_x_q     <= '0;
      p_y_q     <= '0;
      p_y8_q    <= '0;
      p_u_q     <= '0;
      p_v_q     <= '0;
    end else begin
      p_valid_q <= px_in && (px_x < width_i);
      p_x_q     <= px_x;
      p_y_q     <= px_y;
      p_y8_q    <= s_data_i[7:0];
      p_u_q     <= s_data_i[15:8];
      p_v_q     <= s_data_i[23:16];
    end
  end

  logic          slot_ok;
  logic [SW-1:0] slot;

  assign slot_ok = MbW'(p_y_q[CoordW-1:4]) < alloc_q;
  assign slot    = base_q + SW'(p_y_q[CoordW-1:4]);

  // luma: 8 pixels per word
  logic [6:0][7:0] ybuf_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ybuf_q <= '0;
    end else if (p_valid_q && p_x_q[2:0] != 3'd7) begin
      ybuf_q[p_x_q[2:0]] <= p_y8_q;
    end
  end

  assign y_we_o    = p_valid_q && (p_x_q[2:0] == 3'd7) && slot_ok;
  assign y_waddr_o = YAW'({slot, p_y_q[3:0], p_x_q[WW+2:3]});
  assign y_wdata_o = {p_y8_q, ybuf_q[6], ybuf_q[5], ybuf_q[4], ybuf_q[3], ybuf_q[2], ybuf_q[1],
                      ybuf_q[0]};

  // chroma: pair sums of the even lines in a line buffer, 2x2 mean on the odd lines
  logic [7:0]  u0_q, v0_q;
  logic [8:0]  su, sv;
  logic [17:0] lb_rdata;
  logic        lb_we, lb_re;
  logic [9:0]  cb, cr;
  logic [6:0][7:0] cbbuf_q, crbuf_q;

  assign su    = 9'(u0_q) + 9'(p_u_q);
  assign sv    = 9'(v0_q) + 9'(p_v_q);
  assign lb_we = p_valid_q && p_x_q[0] && !p_y_q[0];
  assign lb_re = p_valid_q && !p_x_q[0] && p_y_q[0];
  assign cb    = 10'(lb_rdata[8:0]) + 10'(su) + 10'd2;
  assign cr    = 10'(lb_rdata[17:9]) + 10'(sv) + 10'd2;

  bow_ram_sdp #(
    .Width (18),
    .Depth (MaxWidth / 2)
  ) u_pair_lb (
    .wclk_i  (clk_i),
    .we_i    (lb_we),
    .waddr_i (LbAW'(p_x_q[CoordW-1:1])),
    .wdata_i ({sv, su}),
    .rclk_i  (clk_i),
    .re_i    (lb_re),
    .raddr_i (LbAW'(p_x_q[CoordW-1:1])),
    .rdata_o (lb_rdata)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      u0_q    <= '0;
      v0_q    <= '0;
      cbbuf_q <= '0;
      crbuf_q <= '0;
    end else if (p_valid_q) begin
      if (!p_x_q[0]) begin
        u0_q <= p_u_q;
        v0_q <= p_v_q;
      end else if (p_y_q[0] && p_x_q[3:1] != 3'd7) begin
        cbbuf_q[p_x_q[3:1]] <= cb[9:2];
        crbuf_q[p_x_q[3:1]] <= cr[9:2];
      end
    end
  end

  assign c_we_o     = p_valid_q && p_y_q[0] && (p_x_q[3:0] == 4'd15) && slot_ok;
  assign c_waddr_o  = CAW'({slot, p_y_q[3:1], p_x_q[WW+2:4]});
  assign cb_wdata_o = {cb[9:2], cbbuf_q[6], cbbuf_q[5], cbbuf_q[4], cbbuf_q[3], cbbuf_q[2],
                       cbbuf_q[1], cbbuf_q[0]};
  assign cr_wdata_o = {cr[9:2], crbuf_q[6], crbuf_q[5], crbuf_q[4], crbuf_q[3], crbuf_q[2],
                       crbuf_q[1], crbuf_q[0]};

  // ------------------------------------------------------------------ errors
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      err_ovf_o   <= 1'b0;
      err_input_o <= 1'b0;
    end else begin
      err_ovf_o   <= p_valid_q && !slot_ok && ((p_x_q[2:0] == 3'd7) ||
                                               (p_y_q[0] && p_x_q[3:0] == 4'd15));
      err_input_o <= abort || short_line;
    end
  end

  logic unused;
  assign unused = ^{p_x_q[CoordW-1:WW+3], cb[1:0], cr[1:0]};

endmodule
