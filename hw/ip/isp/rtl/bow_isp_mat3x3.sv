// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// 3 x 3 colour matrix with offsets, used for colour correction (CCM) and for
// RGB -> YCbCr conversion (CSC):
//
//   out_i = clamp((sum_j c_ij * in_j + (off_i << 8) + 128) >>> 8, 0, 2^W - 1)
//
// c_ij: signed 3.8 fixed point (12 bit, -8.0 .. +7.996), off_i: signed, in
// output units. When disabled the input is passed through with the same
// latency. Latency: 5 cycles (registers around the multipliers so they map
// onto DSP slices at 200 MHz).

module bow_isp_mat3x3 import bow_isp_pkg::*; #(
  parameter int unsigned W    = PixW,   // input and output component width
  parameter int unsigned OffW = 11      // offset width (signed)
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic                         abort_i,
  input  logic                         enable_i,
  input  logic [8:0][CoefW-1:0]        coef_i,    // [3*i+j] = c_ij
  input  logic [2:0][OffW-1:0]         off_i,

  input  logic                         valid_i,
  input  logic [2:0][W-1:0]            in_i,
  input  logic [CoordW-1:0]            x_i,
  input  logic [CoordW-1:0]            y_i,
  input  logic                         sof_i,
  input  logic                         eof_i,

  output logic                         valid_o,
  output logic [2:0][W-1:0]            out_o,
  output logic [CoordW-1:0]            x_o,
  output logic [CoordW-1:0]            y_o,
  output logic                         sof_o,
  output logic                         eof_o
);

  localparam int unsigned Lat   = 5;
  localparam int unsigned ProdW = CoefW + W + 1;
  localparam int unsigned AccW  = ProdW + 3;

  // Side band and bypass data
  logic [Lat-1:0]              v_q, sof_q, eof_q;
  logic [Lat-1:0][CoordW-1:0]  x_q, y_q;
  logic [Lat-1:0][2:0][W-1:0]  in_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      v_q   <= '0;
      sof_q <= '0;
      eof_q <= '0;
      x_q   <= '0;
      y_q   <= '0;
      in_q  <= '0;
    end else begin
      v_q   <= abort_i ? '0 : {v_q[Lat-2:0], valid_i};
      sof_q <= {sof_q[Lat-2:0], sof_i};
      eof_q <= {eof_q[Lat-2:0], eof_i};
      x_q   <= {x_q[Lat-2:0], x_i};
      y_q   <= {y_q[Lat-2:0], y_i};
      in_q  <= {in_q[Lat-2:0], in_i};
    end
  end

  // Stage 1: register operands; stage 2: products
  logic signed [8:0][CoefW-1:0] c1_q;
  logic signed [2:0][W:0]       a1_q;
  logic signed [8:0][ProdW-1:0] p2_q;
  logic signed [2:0][AccW-1:0]  s3a_q, s3b_q, acc4_q;

  always_ff @(posedge clk_i) begin
    c1_q <= coef_i;
    for (int unsigned j = 0; j < 3; j++) begin
      a1_q[j] <= {1'b0, in_i[j]};
    end
    for (int unsigned i = 0; i < 3; i++) begin
      for (int unsigned j = 0; j < 3; j++) begin
        p2_q[3 * i + j] <= ProdW'($signed(c1_q[3 * i + j]) * $signed(a1_q[j]));
      end
    end
    // Stage 3: partial sums; stage 4: total
    for (int unsigned i = 0; i < 3; i++) begin
      s3a_q[i] <= AccW'($signed(p2_q[3 * i])) + AccW'($signed(p2_q[3 * i + 1]));
      s3b_q[i] <= AccW'($signed(p2_q[3 * i + 2])) +
                  (AccW'($signed(off_i[i])) <<< 8) + AccW'(128);
      acc4_q[i] <= s3a_q[i] + s3b_q[i];
    end
  end

  // Stage 5: scale, clamp, or bypass
  logic signed [AccW-1:0] shifted [3];

  always_comb begin
    for (int unsigned i = 0; i < 3; i++) begin
      shifted[i] = $signed(acc4_q[i]) >>> 8;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_o <= '0;
    end else begin
      for (int unsigned i = 0; i < 3; i++) begin
        if (!enable_i) begin
          out_o[i] <= in_q[Lat-2][i];
        end else if (shifted[i] < 0) begin
          out_o[i] <= '0;
        end else if (shifted[i] > $signed(AccW'((1 << W) - 1))) begin
          out_o[i] <= '1;
        end else begin
          out_o[i] <= shifted[i][W-1:0];
        end
      end
    end
  end

  assign valid_o = v_q[Lat-1];
  assign sof_o   = sof_q[Lat-1];
  assign eof_o   = eof_q[Lat-1];
  assign x_o     = x_q[Lat-1];
  assign y_o     = y_q[Lat-1];

endmodule
