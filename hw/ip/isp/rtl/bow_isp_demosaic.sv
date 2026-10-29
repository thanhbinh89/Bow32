// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bilinear demosaic (3 x 3 window): every pixel gets the two missing colours
// as the average of its nearest neighbours of that colour.
//
//   centre R : G = (N+S+E+W+2)>>2,   B = (NE+NW+SE+SW+2)>>2
//   centre B : G = (N+S+E+W+2)>>2,   R = (NE+NW+SE+SW+2)>>2
//   centre Gr: R = (E+W+1)>>1,       B = (N+S+1)>>1      (G on a red row)
//   centre Gb: B = (E+W+1)>>1,       R = (N+S+1)>>1      (G on a blue row)
//
// Simple and cheap, but it produces colour fringes ("zipper") on sharp
// edges; a gradient corrected 5 x 5 kernel (Malvar-He-Cutler) is a good
// next step (docs/ip/isp.md). Latency: 2 cycles.

module bow_isp_demosaic import bow_isp_pkg::*; (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  logic                      abort_i,
  input  logic [1:0]                bayer_i,

  input  logic                      valid_i,
  input  logic [2:0][2:0][PixW-1:0] win_i,     // [row][column]
  input  logic [CoordW-1:0]         x_i,
  input  logic [CoordW-1:0]         y_i,
  input  logic                      sof_i,
  input  logic                      eof_i,

  output logic                      valid_o,
  output logic [2:0][PixW-1:0]      rgb_o,     // [0] R, [1] G, [2] B
  output logic [CoordW-1:0]         x_o,
  output logic [CoordW-1:0]         y_o,
  output logic                      sof_o,
  output logic                      eof_o
);

  logic              v1_q, sof1_q, eof1_q;
  logic [CoordW-1:0] x1_q, y1_q;
  cfa_e              col1_q;
  logic [PixW-1:0]   c1_q;
  logic [PixW+1:0]   cross1_q, diag1_q;
  logic [PixW:0]     h1_q, v1sum_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      v1_q     <= 1'b0;
      sof1_q   <= 1'b0;
      eof1_q   <= 1'b0;
      x1_q     <= '0;
      y1_q     <= '0;
      col1_q   <= CfaR;
      c1_q     <= '0;
      cross1_q <= '0;
      diag1_q  <= '0;
      h1_q     <= '0;
      v1sum_q  <= '0;
    end else begin
      // Stage 1: neighbour sums
      v1_q     <= valid_i && !abort_i;
      sof1_q   <= sof_i;
      eof1_q   <= eof_i;
      x1_q     <= x_i;
      y1_q     <= y_i;
      col1_q   <= cfa_color(bayer_i, x_i[0], y_i[0]);
      c1_q     <= win_i[1][1];
      h1_q     <= {1'b0, win_i[1][0]} + {1'b0, win_i[1][2]};
      v1sum_q  <= {1'b0, win_i[0][1]} + {1'b0, win_i[2][1]};
      cross1_q <= {2'b0, win_i[0][1]} + {2'b0, win_i[2][1]} +
                  {2'b0, win_i[1][0]} + {2'b0, win_i[1][2]};
      diag1_q  <= {2'b0, win_i[0][0]} + {2'b0, win_i[0][2]} +
                  {2'b0, win_i[2][0]} + {2'b0, win_i[2][2]};
    end
  end

  logic [PixW-1:0] cross_avg, diag_avg, h_avg, v_avg;

  assign cross_avg = PixW'((cross1_q + (PixW + 2)'(2)) >> 2);
  assign diag_avg  = PixW'((diag1_q + (PixW + 2)'(2)) >> 2);
  assign h_avg     = PixW'((h1_q + (PixW + 1)'(1)) >> 1);
  assign v_avg     = PixW'((v1sum_q + (PixW + 1)'(1)) >> 1);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_o <= 1'b0;
      rgb_o   <= '0;
      x_o     <= '0;
      y_o     <= '0;
      sof_o   <= 1'b0;
      eof_o   <= 1'b0;
    end else begin
      // Stage 2: pick the interpolation for this pixel's colour
      valid_o <= v1_q && !abort_i;
      x_o     <= x1_q;
      y_o     <= y1_q;
      sof_o   <= sof1_q;
      eof_o   <= eof1_q;
      unique case (col1_q)
        CfaR:    rgb_o <= {diag_avg, cross_avg, c1_q};
        CfaB:    rgb_o <= {c1_q, cross_avg, diag_avg};
        CfaGr:   rgb_o <= {v_avg, c1_q, h_avg};
        default: rgb_o <= {h_avg, c1_q, v_avg};   // CfaGb
      endcase
    end
  end

endmodule
