// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Forward path of one 4x4 block, one row of 4 samples per cycle:
//   residual X = orig - pred
//   W = Cf X Cf^T: horizontal transform of every row as it arrives, the
//       vertical one when the 4th row is there (exact integer transform, the
//       order does not matter)
//   level = sign(W) * min((|W| * MF(QP % 6, position) + f) >> (15 + QP / 6), 2063)
//           with f = 2^(15 + QP / 6) / 3 (intra)
// The coefficient (0, 0) is not quantised here: Intra_16x16 luma and chroma
// code it through the DC transform (dc_o, bow_h264_dc); its level is 0.
// Rows arrive back to back (4 per block); the levels come out row by row,
// 7 cycles after the last row of the block.

module bow_h264_fwd import bow_h264_pkg::*; (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic [3:0]                   qk_i,        // QP / 6 (stable during a pass)
  input  logic [2:0]                   qm_i,        // QP % 6

  input  logic                         in_valid_i,
  input  logic [1:0]                   in_row_i,
  input  logic [5:0]                   in_tag_i,    // block id, passed through
  input  logic [3:0][7:0]              in_orig_i,
  input  logic [3:0][7:0]              in_pred_i,

  output logic                         lv_valid_o,
  output logic [1:0]                   lv_row_o,
  output logic [5:0]                   lv_tag_o,
  output logic [3:0][LevelW-1:0]       lv_o,
  output logic                         lv_nz_o,     // a level of this row is not zero

  output logic                         dc_valid_o,
  output logic [5:0]                   dc_tag_o,
  output logic signed [15:0]           dc_o         // W(0, 0)
);

  typedef logic signed [8:0]  r_t;   // residual
  typedef logic signed [11:0] t_t;   // after the horizontal transform
  typedef logic signed [14:0] w_t;   // coefficients

  // ----------------------------------------------------------- A: residual
  logic                     a_valid;
  logic [1:0]               a_row;
  logic [5:0]               a_tag;
  r_t [3:0]                 a_res;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_valid <= 1'b0;
      a_row   <= '0;
      a_tag   <= '0;
      a_res   <= '0;
    end else begin
      a_valid <= in_valid_i;
      a_row   <= in_row_i;
      a_tag   <= in_tag_i;
      for (int k = 0; k < 4; k++) begin
        a_res[k] <= 9'(signed'({1'b0, in_orig_i[k]})) - 9'(signed'({1'b0, in_pred_i[k]}));
      end
    end
  end

  // ------------------------------------------- B: horizontal, then vertical
  t_t [3:0] t_row;
  always_comb begin
    t_t s03, d03, s12, d12;
    s03 = t_t'(a_res[0]) + t_t'(a_res[3]);
    d03 = t_t'(a_res[0]) - t_t'(a_res[3]);
    s12 = t_t'(a_res[1]) + t_t'(a_res[2]);
    d12 = t_t'(a_res[1]) - t_t'(a_res[2]);
    t_row[0] = s03 + s12;
    t_row[1] = (d03 <<< 1) + d12;
    t_row[2] = s03 - s12;
    t_row[3] = d03 - (d12 <<< 1);
  end

  t_t [2:0][3:0] tb_q;          // rows 0..2 of the block
  w_t [3:0][3:0] wb_q;          // coefficients [row][column]
  logic [5:0]    wb_tag_q;
  logic [2:0]    emit_q;        // 0: idle, 1..4: emitting row emit_q - 1

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tb_q       <= '0;
      wb_q       <= '0;
      wb_tag_q   <= '0;
      emit_q     <= '0;
      dc_valid_o <= 1'b0;
      dc_tag_o   <= '0;
      dc_o       <= '0;
    end else begin
      dc_valid_o <= 1'b0;
      if (emit_q != 3'd0) emit_q <= (emit_q == 3'd4) ? 3'd0 : emit_q + 3'd1;
      if (a_valid) begin
        if (a_row != 2'd3) begin
          tb_q[a_row] <= t_row;
        end else begin
          for (int j = 0; j < 4; j++) begin
            w_t t0, t1, t2, t3;
            t0 = w_t'(tb_q[0][j]);
            t1 = w_t'(tb_q[1][j]);
            t2 = w_t'(tb_q[2][j]);
            t3 = w_t'(t_row[j]);
            wb_q[0][j] <= t0 + t1 + t2 + t3;
            wb_q[1][j] <= (t0 <<< 1) + t1 - t2 - (t3 <<< 1);
            wb_q[2][j] <= t0 - t1 - t2 + t3;
            wb_q[3][j] <= t0 - (t1 <<< 1) + (t2 <<< 1) - t3;
          end
          wb_tag_q   <= a_tag;
          emit_q     <= 3'd1;
          dc_valid_o <= 1'b1;
          dc_tag_o   <= a_tag;
          dc_o       <= 16'(w_t'(tb_q[0][0]) + w_t'(tb_q[1][0]) + w_t'(tb_q[2][0]) +
                            w_t'(t_row[0]));
        end
      end
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk_i) begin
    if (rst_ni && a_valid && a_row == 2'd3 && emit_q != 3'd0 && emit_q != 3'd4) begin
      $error("bow_h264_fwd: rows of a block arrived faster than 4 cycles per block");
    end
  end
`endif

  // ------------------------------------------------------- Q: quantisation
  logic [1:0]  e_row;
  assign e_row = 2'(emit_q - 3'd1);

  logic                       q1_valid, q2_valid;
  logic [1:0]                 q1_row, q2_row;
  logic [5:0]                 q1_tag, q2_tag;
  logic [3:0]                 q1_sign, q2_sign;
  logic [3:0][13:0]           q1_abs;
  logic [3:0][13:0]           q1_mf;
  logic [3:0][29:0]           q2_sum;
  logic [21:0]                f;
  logic [4:0]                 shift;

  assign f     = quant_f(qk_i);
  assign shift = 5'd15 + 5'(qk_i);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      q1_valid   <= 1'b0;
      q1_row     <= '0;
      q1_tag     <= '0;
      q1_sign    <= '0;
      q1_abs     <= '0;
      q1_mf      <= '0;
      q2_valid   <= 1'b0;
      q2_row     <= '0;
      q2_tag     <= '0;
      q2_sign    <= '0;
      q2_sum     <= '0;
      lv_valid_o <= 1'b0;
      lv_row_o   <= '0;
      lv_tag_o   <= '0;
      lv_o       <= '0;
      lv_nz_o    <= 1'b0;
    end else begin
      // Q1: magnitude, sign, multiplier
      q1_valid <= (emit_q != 3'd0);
      q1_row   <= e_row;
      q1_tag   <= wb_tag_q;
      for (int j = 0; j < 4; j++) begin
        w_t w;
        w          = wb_q[e_row][j];
        q1_sign[j] <= w[14];
        q1_abs[j]  <= w[14] ? 14'(-w) : 14'(w);
        q1_mf[j]   <= (e_row == 2'd0 && j == 0) ? 14'd0 : quant_mf(qm_i, pos_class(e_row[0], 1'(j)));
      end
      // Q2: product + rounding
      q2_valid <= q1_valid;
      q2_row   <= q1_row;
      q2_tag   <= q1_tag;
      q2_sign  <= q1_sign;
      for (int j = 0; j < 4; j++) begin
        q2_sum[j] <= 30'(q1_abs[j]) * 30'(q1_mf[j]) + 30'(f);
      end
      // Q3: shift, clamp, sign (DC position: 0)
      lv_valid_o <= q2_valid;
      lv_row_o   <= q2_row;
      lv_tag_o   <= q2_tag;
      for (int j = 0; j < 4; j++) begin
        lv_o[j] <= (q2_row == 2'd0 && j == 0) ? '0 : quant_level(q2_sign[j], q2_sum[j], shift);
      end
      lv_nz_o <= 1'b0;
      for (int j = 0; j < 4; j++) begin
        if (!(q2_row == 2'd0 && j == 0) && (q2_sum[j] >> shift) != '0) lv_nz_o <= 1'b1;
      end
    end
  end

endmodule
