// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Intra prediction of one row of 4 samples of a 4x4 block, all four modes at
// once (ITU-T H.264 clauses 8.3.3 and 8.3.4):
//   v   p[x, -1]                       (vertical)
//   h   p[-1, y]                       (horizontal)
//   dc  dc_i                           (DC of the macroblock / chroma 4x4 block)
//   p   Clip1((a + b (x - c0) + c (y - c0) + 16) >> 5),  c0 = 7 luma, 3 chroma
// The DC value and the plane parameters a, b, c are computed once per
// macroblock (bow_h264_mb). Latency 3 cycles, one row per cycle.

module bow_h264_pred (
  input  logic               clk_i,
  input  logic               chroma_i,   // 0: 16x16 luma, 1: 8x8 chroma
  input  logic [1:0]         bx_i,       // block column: x of the row = 4 * bx_i .. + 3
  input  logic [3:0]         y_i,        // line inside the macroblock
  input  logic [15:0][7:0]   top_i,      // p[x, -1]
  input  logic [15:0][7:0]   left_i,     // p[-1, y]
  input  logic [7:0]         dc_i,
  input  logic signed [14:0] pa_i,
  input  logic signed [12:0] pb_i,
  input  logic signed [12:0] pc_i,
  output logic [3:0][7:0]    v_o,
  output logic [3:0][7:0]    h_o,
  output logic [3:0][7:0]    dc_o,
  output logic [3:0][7:0]    p_o
);

  // stage 1: sample selection, plane products
  logic [3:0][7:0]    v1, v2;
  logic [7:0]         h1, h2, dc1, dc2;
  logic signed [17:0] bdx1, cdy1, a1;
  logic signed [14:0] b1, b3;
  logic signed [4:0]  dx, dy;

  assign dx = chroma_i ? (5'(signed'({1'b0, bx_i, 2'b00})) - 5'sd3)
                       : (5'(signed'({1'b0, bx_i, 2'b00})) - 5'sd7);
  assign dy = chroma_i ? (5'(signed'({1'b0, y_i})) - 5'sd3) : (5'(signed'({1'b0, y_i})) - 5'sd7);

  always_ff @(posedge clk_i) begin
    for (int k = 0; k < 4; k++) begin
      v1[k] <= top_i[{bx_i, 2'(k)}];
    end
    h1   <= left_i[y_i];
    dc1  <= dc_i;
    bdx1 <= 18'(pb_i) * 18'(dx);
    cdy1 <= 18'(pc_i) * 18'(dy);
    a1   <= 18'(pa_i) + 18'sd16;
    b1   <= 15'(pb_i);
    b3   <= 15'(pb_i) + 15'(pb_i) + 15'(pb_i);
  end

  // stage 2: plane value of the first sample of the row
  logic signed [17:0] base2;
  logic signed [14:0] b2, b32;

  always_ff @(posedge clk_i) begin
    v2    <= v1;
    h2    <= h1;
    dc2   <= dc1;
    base2 <= a1 + bdx1 + cdy1;
    b2    <= b1;
    b32   <= b3;
  end

  // stage 3: the four samples
  function automatic logic [7:0] clip_shift(logic signed [17:0] v);
    logic signed [12:0] s;
    s = 13'(v >>> 5);
    if (s < 0) return 8'd0;
    if (s > 13'sd255) return 8'd255;
    return s[7:0];
  endfunction

  always_ff @(posedge clk_i) begin
    v_o     <= v2;
    h_o     <= {4{h2}};
    dc_o    <= {4{dc2}};
    p_o[0]  <= clip_shift(base2);
    p_o[1]  <= clip_shift(base2 + 18'(b2));
    p_o[2]  <= clip_shift(base2 + 18'(b2) + 18'(b2));
    p_o[3]  <= clip_shift(base2 + 18'(b32));
  end

endmodule
