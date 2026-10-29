// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Gamma / tone curve: one 1024 x 8 bit look-up table per colour channel,
// out = LUT_c[in] (10 bit linear -> 8 bit display referred).
// When disabled, out = in >> 2. The tables reset to that identity curve.
//
// The tables are written by the CPU on its own clock (lut_clk_i) and read
// in the video clock domain (dual clock block RAM). Writing while video runs
// changes the curve in the middle of a frame, which is harmless.
// Latency: 2 cycles.

module bow_isp_gamma import bow_isp_pkg::*; (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    abort_i,
  input  logic                    enable_i,

  input  logic                    lut_clk_i,
  input  logic [2:0]              lut_we_i,     // one bit per channel
  input  logic [PixW-1:0]         lut_addr_i,
  input  logic [OutW-1:0]         lut_data_i,

  input  logic                    valid_i,
  input  logic [2:0][PixW-1:0]    in_i,
  input  logic [CoordW-1:0]       x_i,
  input  logic [CoordW-1:0]       y_i,
  input  logic                    sof_i,
  input  logic                    eof_i,

  output logic                    valid_o,
  output logic [2:0][OutW-1:0]    out_o,
  output logic [CoordW-1:0]       x_o,
  output logic [CoordW-1:0]       y_o,
  output logic                    sof_o,
  output logic                    eof_o
);

  logic [2:0][OutW-1:0] lut_q;
  logic [2:0][OutW-1:0] bypass_q;
  logic                 v1_q, sof1_q, eof1_q;
  logic [CoordW-1:0]    x1_q, y1_q;

  for (genvar c = 0; c < 3; c++) begin : g_lut
    logic [OutW-1:0] mem [1 << PixW];

    initial begin
      for (int unsigned i = 0; i < (1 << PixW); i++) begin
        mem[i] = OutW'(i >> (PixW - OutW));
      end
    end

    always_ff @(posedge lut_clk_i) begin
      if (lut_we_i[c]) begin
        mem[lut_addr_i] <= lut_data_i;
      end
    end

    always_ff @(posedge clk_i) begin
      lut_q[c] <= mem[in_i[c]];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bypass_q <= '0;
      v1_q     <= 1'b0;
      sof1_q   <= 1'b0;
      eof1_q   <= 1'b0;
      x1_q     <= '0;
      y1_q     <= '0;
      valid_o  <= 1'b0;
      out_o    <= '0;
      x_o      <= '0;
      y_o      <= '0;
      sof_o    <= 1'b0;
      eof_o    <= 1'b0;
    end else begin
      for (int unsigned c = 0; c < 3; c++) begin
        bypass_q[c] <= in_i[c][PixW-1:PixW-OutW];
      end
      v1_q    <= valid_i && !abort_i;
      sof1_q  <= sof_i;
      eof1_q  <= eof_i;
      x1_q    <= x_i;
      y1_q    <= y_i;

      valid_o <= v1_q && !abort_i;
      out_o   <= enable_i ? lut_q : bypass_q;
      x_o     <= x1_q;
      y_o     <= y1_q;
      sof_o   <= sof1_q;
      eof_o   <= eof1_q;
    end
  end

endmodule
