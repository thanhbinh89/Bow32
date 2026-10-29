// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// White balance on the Bayer mosaic: one gain per CFA colour (R, Gr, Gb, B),
// unsigned 4.8 fixed point (0x100 = 1.0, max 15.996):
//
//   p' = min((p * gain[colour] + 128) >> 8, 1023)      (gain = 1.0 when disabled)
//
// The gains also scale the range back to full scale after black level
// subtraction. Latency: 3 cycles (select, multiply, round/saturate).

module bow_isp_wb import bow_isp_pkg::*; (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  logic                  enable_i,
  input  logic [1:0]            bayer_i,
  input  logic [3:0][GainW-1:0] gain_i,

  input  logic                  valid_i,
  input  logic [PixW-1:0]       data_i,
  input  logic [CoordW-1:0]     x_i,
  input  logic [CoordW-1:0]     y_i,
  input  logic                  sof_i,

  output logic                  valid_o,
  output logic [PixW-1:0]       data_o,
  output logic                  sof_o
);

  localparam int unsigned ProdW = PixW + GainW;

  logic             v1_q, v2_q, sof1_q, sof2_q;
  logic [PixW-1:0]  p1_q;
  logic [GainW-1:0] g1_q;
  logic [ProdW-1:0] prod_q, scaled;

  assign scaled = (prod_q + ProdW'(128)) >> 8;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      v1_q    <= 1'b0;
      v2_q    <= 1'b0;
      sof1_q  <= 1'b0;
      sof2_q  <= 1'b0;
      p1_q    <= '0;
      g1_q    <= '0;
      prod_q  <= '0;
      valid_o <= 1'b0;
      data_o  <= '0;
      sof_o   <= 1'b0;
    end else begin
      // Stage 1: gain of this pixel's colour
      v1_q   <= valid_i;
      sof1_q <= sof_i;
      p1_q   <= data_i;
      g1_q   <= enable_i ? gain_i[cfa_color(bayer_i, x_i[0], y_i[0])] : GainW'(256);
      // Stage 2: multiply
      v2_q   <= v1_q;
      sof2_q <= sof1_q;
      prod_q <= p1_q * g1_q;
      // Stage 3: round and saturate
      valid_o <= v2_q;
      sof_o   <= sof2_q;
      data_o  <= (scaled > ProdW'(1023)) ? PixW'(1023) : scaled[PixW-1:0];
    end
  end

  logic unused_xy;
  assign unused_xy = ^{x_i[CoordW-1:1], y_i[CoordW-1:1]};

endmodule
