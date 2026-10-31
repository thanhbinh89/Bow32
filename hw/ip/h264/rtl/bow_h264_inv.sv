// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Inverse path of one 4x4 block, one row of 4 levels per cycle, exactly as
// the decoder does it (ITU-T H.264 clause 8.5.12):
//   d(i, j) = (level * V(QP % 6, position)) << (QP / 6)   (flat scaling lists)
//   d(0, 0) = in_dc_i (dequantised DC from bow_h264_dc)
//   rows first (e, f), then columns (g, h), r = (h + 32) >> 6
// The residual rows come out back to back (out_res_o), 3 cycles after the
// last level row of the block.

module bow_h264_inv import bow_h264_pkg::*; (
  input  logic                          clk_i,
  input  logic                          rst_ni,

  input  logic [3:0]                    qk_i,
  input  logic [2:0]                    qm_i,

  input  logic                          in_valid_i,
  input  logic [1:0]                    in_row_i,
  input  logic [5:0]                    in_tag_i,
  input  logic [3:0][LevelW-1:0]        in_lv_i,
  input  logic signed [17:0]            in_dc_i,     // used with row 0

  output logic                          out_valid_o,
  output logic [1:0]                    out_row_o,
  output logic [5:0]                    out_tag_o,
  output s16_t [3:0]                    out_res_o
);

  typedef logic signed [21:0] d_t;
  typedef logic signed [23:0] f_t;

  // ---------------------------------------------------------- A: dequantise
  logic           a_valid;
  logic [1:0]     a_row;
  logic [5:0]     a_tag;
  d_t [3:0]       a_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_valid <= 1'b0;
      a_row   <= '0;
      a_tag   <= '0;
      a_d     <= '0;
    end else begin
      a_valid <= in_valid_i;
      a_row   <= in_row_i;
      a_tag   <= in_tag_i;
      for (int j = 0; j < 4; j++) begin
        if (in_row_i == 2'd0 && j == 0) begin
          a_d[j] <= d_t'(in_dc_i);
        end else begin
          a_d[j] <= (d_t'(signed'(in_lv_i[j])) *
                     d_t'(signed'({1'b0, scale_v(qm_i, pos_class(in_row_i[0], 1'(j)))}))) <<< qk_i;
        end
      end
    end
  end

  // ------------------------------------------------- B: row transform, then g
  f_t [3:0] f_row;
  always_comb begin
    f_t e0, e1, e2, e3;
    e0 = f_t'(a_d[0]) + f_t'(a_d[2]);
    e1 = f_t'(a_d[0]) - f_t'(a_d[2]);
    e2 = (f_t'(a_d[1]) >>> 1) - f_t'(a_d[3]);
    e3 = f_t'(a_d[1]) + (f_t'(a_d[3]) >>> 1);
    f_row[0] = e0 + e3;
    f_row[1] = e1 + e2;
    f_row[2] = e1 - e2;
    f_row[3] = e0 - e3;
  end

  f_t [2:0][3:0] fb_q;        // rows 0..2
  f_t [3:0][3:0] gb_q;        // [g index][column]
  logic [5:0]    gb_tag_q;
  logic          gb_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fb_q       <= '0;
      gb_q       <= '0;
      gb_tag_q   <= '0;
      gb_valid_q <= 1'b0;
    end else begin
      gb_valid_q <= 1'b0;
      if (a_valid) begin
        if (a_row != 2'd3) begin
          fb_q[a_row] <= f_row;
        end else begin
          for (int j = 0; j < 4; j++) begin
            gb_q[0][j] <= fb_q[0][j] + fb_q[2][j];
            gb_q[1][j] <= fb_q[0][j] - fb_q[2][j];
            gb_q[2][j] <= (fb_q[1][j] >>> 1) - f_row[j];
            gb_q[3][j] <= fb_q[1][j] + (f_row[j] >>> 1);
          end
          gb_tag_q   <= a_tag;
          gb_valid_q <= 1'b1;
        end
      end
    end
  end

  // ----------------------------------------------- C: h and r for all rows
  s16_t [3:0][3:0]              rb_q;   // [row][column]
  logic [5:0]                   rb_tag_q;
  logic [2:0]                   emit_q;  // 0 idle, 1..4: row emit_q - 1

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic signed [15:0] round6(f_t h);
    f_t r;
    r = (h + f_t'(32)) >>> 6;
    return 16'(r);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rb_q     <= '0;
      rb_tag_q <= '0;
      emit_q   <= '0;
    end else begin
      if (emit_q != 3'd0) emit_q <= (emit_q == 3'd4) ? 3'd0 : emit_q + 3'd1;
      if (gb_valid_q) begin
        for (int j = 0; j < 4; j++) begin
          rb_q[0][j] <= round6(gb_q[0][j] + gb_q[3][j]);
          rb_q[1][j] <= round6(gb_q[1][j] + gb_q[2][j]);
          rb_q[2][j] <= round6(gb_q[1][j] - gb_q[2][j]);
          rb_q[3][j] <= round6(gb_q[0][j] - gb_q[3][j]);
        end
        rb_tag_q <= gb_tag_q;
        emit_q   <= 3'd1;
      end
    end
  end

  assign out_valid_o = (emit_q != 3'd0);
  assign out_row_o   = 2'(emit_q - 3'd1);
  assign out_tag_o   = rb_tag_q;
  assign out_res_o   = rb_q[2'(emit_q - 3'd1)];

`ifndef SYNTHESIS
  always @(posedge clk_i) begin
    if (rst_ni && a_valid) begin
      for (int j = 0; j < 4; j++) begin
        if (a_d[j] > 22'sd131071 || a_d[j] < -22'sd131072) begin
          $error("bow_h264_inv: dequantised coefficient %0d out of range", a_d[j]);
        end
      end
    end
  end
`endif

endmodule
