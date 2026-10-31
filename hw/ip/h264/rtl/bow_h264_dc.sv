// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// DC transforms of a macroblock (one call for luma, one for chroma).
//
// Luma (Intra_16x16): D(by, bx) = W(0, 0) of the 16 blocks
//   forward  Y = (H D H) >> 1, level = sign * ((|Y| MF(QP%6, 0) + 2f) >> (16 + QP/6))
//   inverse  F = H c H,  dcY = (F LS + 2^(5 - QP/6)) >> (6 - QP/6)   QP < 36
//                        dcY = (F LS) << (QP/6 - 6)                  QP >= 36
//   (clause 8.5.10), LS = 16 V(QP%6, 0), H = 4x4 Hadamard.
// Chroma (4:2:0, per component): D = 2x2 matrix of the W(0, 0)
//   forward  Y = H2 D H2 (no shift), same quantiser
//   inverse  F = H2 c H2, dcC = ((F LS) << (QPc/6)) >> 5   (clause 8.5.11)
// Index of raw_i / dq_o: luma 4 * by + bx, chroma 4 * comp + blk.
// The levels leave as rows (wr_*): luma matrix rows 0..3, chroma comp 0..1.

module bow_h264_dc import bow_h264_pkg::*; (
  input  logic                          clk_i,
  input  logic                          rst_ni,

  input  logic                          start_i,     // inputs stable until done_o
  input  logic                          chroma_i,
  input  logic [3:0]                    qk_i,
  input  logic [2:0]                    qm_i,
  input  s16_t [15:0]                   raw_i,

  output logic                          wr_valid_o,
  output logic [1:0]                    wr_idx_o,
  output logic [3:0][LevelW-1:0]        wr_lv_o,

  output s18_t [15:0]                   dq_o,
  output logic                          nz_o,        // a level is not zero
  output logic                          done_o       // pulse, dq_o / nz_o valid
);

  typedef logic signed [17:0] v_t;
  typedef enum logic [3:0] {
    StIdle, StH1, StH2, StQ, StQWait, StI1, StI2, StDq, StDqWait, StDone
  } state_e;

  state_e     state_q;
  logic [2:0] cnt_q;
  logic [1:0] nrows;
  logic       chroma_q;    // chroma_i, sampled at the start

  assign nrows = chroma_q ? 2'd1 : 2'd3;   // last row index

  v_t [15:0] m_q;      // working matrix (E, Y, then F)
  v_t [15:0] cl_q;     // levels

  function automatic v_t h4(v_t a, v_t b, v_t c, v_t d, logic [1:0] k);
    unique case (k)
      2'd0: return a + b + c + d;
      2'd1: return a + b - c - d;
      2'd2: return a - b - c + d;
      default: return a - b + c - d;
    endcase
  endfunction

  // ------------------------------------------------------------ quantiser
  logic [21:0] f;
  logic [4:0]  shift;
  logic [13:0] mf0;
  logic [8:0]  ls0;

  assign f     = quant_f(qk_i);
  assign shift = 5'd16 + 5'(qk_i);
  assign mf0   = quant_mf(qm_i, 2'd0);
  assign ls0   = {scale_v(qm_i, 2'd0), 4'b0000};

  logic               q1_valid, q2_valid;
  logic [1:0]         q1_row, q2_row;
  logic [3:0]         q1_sign, q2_sign;
  logic [3:0][16:0]   q1_abs;
  logic [3:0][29:0]   q2_sum;
  logic [1:0]         qrow;

  assign qrow = cnt_q[1:0];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      q1_valid   <= 1'b0;
      q1_row     <= '0;
      q1_sign    <= '0;
      q1_abs     <= '0;
      q2_valid   <= 1'b0;
      q2_row     <= '0;
      q2_sign    <= '0;
      q2_sum     <= '0;
      wr_valid_o <= 1'b0;
      wr_idx_o   <= '0;
      wr_lv_o    <= '0;
    end else begin
      q1_valid <= (state_q == StQ);
      q1_row   <= qrow;
      for (int j = 0; j < 4; j++) begin
        v_t y;
        y = m_q[4 * qrow + j];
        q1_sign[j] <= y[17];
        q1_abs[j]  <= y[17] ? 17'(-y) : 17'(y);
      end
      q2_valid <= q1_valid;
      q2_row   <= q1_row;
      q2_sign  <= q1_sign;
      for (int j = 0; j < 4; j++) begin
        q2_sum[j] <= 30'(q1_abs[j]) * 30'(mf0) + 30'({f, 1'b0});
      end
      wr_valid_o <= q2_valid;
      wr_idx_o   <= q2_row;
      for (int j = 0; j < 4; j++) begin
        wr_lv_o[j] <= quant_level(q2_sign[j], q2_sum[j], shift);
      end
    end
  end

  // -------------------------------------------------------- dequantiser
  // product, then the shift (two register stages)
  logic                d1_valid, d2_valid;
  logic [1:0]          d1_row, d2_row;
  logic [3:0][26:0]    d1_prod;     // signed F * LS
  v_t [3:0]            d2_dq;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      d1_valid <= 1'b0;
      d1_row   <= '0;
      d1_prod  <= '0;
      d2_valid <= 1'b0;
      d2_row   <= '0;
      d2_dq    <= '0;
      chroma_q <= 1'b0;
    end else begin
      if (state_q == StIdle && start_i) chroma_q <= chroma_i;
      d1_valid <= (state_q == StDq);
      d1_row   <= qrow;
      for (int j = 0; j < 4; j++) begin
        d1_prod[j] <= 27'(27'(signed'(m_q[4 * qrow + j])) * 27'(signed'({1'b0, ls0})));
      end
      d2_valid <= d1_valid;
      d2_row   <= d1_row;
      for (int j = 0; j < 4; j++) begin
        d2_dq[j] <= dequant(d1_prod[j], chroma_q, qk_i);
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic v_t dequant(logic [26:0] p, logic chroma, logic [3:0] k);
    logic signed [26:0] s;
    logic signed [30:0] x;
    s = signed'(p);
    if (chroma) begin
      x = (31'(s) <<< k) >>> 5;
    end else if (k >= 4'd6) begin
      x = 31'(s) <<< (k - 4'd6);
    end else begin
      x = (31'(s) + (31'sd1 <<< (4'd5 - k))) >>> (4'd6 - k);
    end
    return 18'(x);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ------------------------------------------------------------- control
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StIdle;
      cnt_q   <= '0;
      m_q     <= '0;
      cl_q    <= '0;
      dq_o    <= '0;
      nz_o    <= 1'b0;
      done_o  <= 1'b0;
    end else begin
      done_o <= 1'b0;
      if (wr_valid_o) begin
        for (int j = 0; j < 4; j++) begin
          cl_q[4 * wr_idx_o + j] <= v_t'(signed'(wr_lv_o[j]));
          if (wr_lv_o[j] != '0) nz_o <= 1'b1;
        end
      end
      if (d2_valid) begin
        for (int j = 0; j < 4; j++) begin
          dq_o[4 * d2_row + j] <= d2_dq[j];
        end
      end
      unique case (state_q)
        StIdle: if (start_i) begin
          state_q <= StH1;
          nz_o    <= 1'b0;
        end
        // E = D H (rows), or the whole 2x2 transform of both components
        StH1: begin
          for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
              if (chroma_q) begin
                m_q[4 * i + j] <= h4(v_t'(raw_i[4 * i]), v_t'(raw_i[4 * i + 1]) * ((j == 0 || j == 2) ? 1 : -1),
                                     v_t'(raw_i[4 * i + 2]) * ((j < 2) ? 1 : -1),
                                     v_t'(raw_i[4 * i + 3]) * ((j == 0 || j == 3) ? 1 : -1), 2'd0);
              end else begin
                m_q[4 * i + j] <= h4(v_t'(raw_i[4 * i]), v_t'(raw_i[4 * i + 1]),
                                     v_t'(raw_i[4 * i + 2]), v_t'(raw_i[4 * i + 3]), 2'(j));
              end
            end
          end
          state_q <= chroma_q ? StQ : StH2;
          cnt_q   <= '0;
        end
        // Y = H E (columns), >> 1
        StH2: begin
          for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
              m_q[4 * i + j] <= h4(m_q[j], m_q[4 + j], m_q[8 + j], m_q[12 + j], 2'(i)) >>> 1;
            end
          end
          state_q <= StQ;
          cnt_q   <= '0;
        end
        StQ: begin
          cnt_q <= cnt_q + 3'd1;
          if (cnt_q[1:0] == nrows) begin
            state_q <= StQWait;
            cnt_q   <= '0;
          end
        end
        StQWait: begin
          cnt_q <= cnt_q + 3'd1;
          if (cnt_q == 3'd3) state_q <= StI1;   // the last row of levels is in cl_q
        end
        // F = H c (columns first: H c H is symmetric in the order)
        StI1: begin
          for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
              if (chroma_q) begin
                m_q[4 * i + j] <= h4(cl_q[4 * i], cl_q[4 * i + 1] * ((j == 0 || j == 2) ? 1 : -1),
                                     cl_q[4 * i + 2] * ((j < 2) ? 1 : -1),
                                     cl_q[4 * i + 3] * ((j == 0 || j == 3) ? 1 : -1), 2'd0);
              end else begin
                m_q[4 * i + j] <= h4(cl_q[j], cl_q[4 + j], cl_q[8 + j], cl_q[12 + j], 2'(i));
              end
            end
          end
          state_q <= chroma_q ? StDq : StI2;
          cnt_q   <= '0;
        end
        StI2: begin
          for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
              m_q[4 * i + j] <= h4(m_q[4 * i], m_q[4 * i + 1], m_q[4 * i + 2], m_q[4 * i + 3], 2'(j));
            end
          end
          state_q <= StDq;
          cnt_q   <= '0;
        end
        StDq: begin
          cnt_q <= cnt_q + 3'd1;
          if (cnt_q[1:0] == nrows) begin
            state_q <= StDqWait;
            cnt_q   <= '0;
          end
        end
        StDqWait: begin
          cnt_q <= cnt_q + 3'd1;
          if (cnt_q == 3'd1) state_q <= StDone;   // the last row is in dq_o
        end
        StDone: begin
          state_q <= StIdle;
          done_o  <= 1'b1;
        end
        default: state_q <= StIdle;
      endcase
    end
  end

endmodule
