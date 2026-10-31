// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 H.264 encoder: shared types and arithmetic helpers. The encoder
// decisions and the arithmetic are specified in docs/ip/h264.md and mirrored
// bit-exactly by tools/h264/h264_model.py.

package bow_h264_pkg;

  localparam int unsigned CoordW   = 12;    // frame size (max 4095)
  localparam int unsigned MbW      = 8;     // macroblock coordinates
  localparam int unsigned LevelW   = 16;    // stored levels (|level| <= 2063)
  localparam int unsigned LevelMax = 2063;  // largest |level| CAVLC codes with suffixLength 0
  localparam int unsigned QpMin    = 10;    // QP range of the encoder (docs/ip/h264.md)
  localparam int unsigned QpMax    = 51;

  localparam logic [7:0] NalHdrIdr = 8'h65;   // nal_ref_idc 3, IDR slice

  // Words of one macroblock in the coefficient buffer (4 levels per word)
  localparam int unsigned WordLumaDc   = 64;    // 64..67: Intra16x16DCLevel matrix, row by row
  localparam int unsigned WordChromaAc = 68;    // 68 + 16 * comp + 4 * blk + row
  localparam int unsigned WordChromaDc = 100;   // 100 + comp: c0..c3

  // Signed element types: the elements of a packed array are only signed when
  // their type is a named signed type.
  typedef logic signed [12:0] s13_t;
  typedef logic signed [14:0] s15_t;
  typedef logic signed [15:0] s16_t;
  typedef logic signed [17:0] s18_t;

  // Parameters of one coded frame, latched at its start of frame
  typedef struct packed {
    logic [5:0] qp;
    logic       deblock;    // slice header: deblocking filter on
    logic       idr_id;     // idr_pic_id
    logic       seq_last;   // last frame of the sequence (STATUS.DONE after it)
  } frame_t;

  // One strip of 16 lines in the strip buffers (input -> macroblock engine)
  typedef struct packed {
    logic [1:0]     slot;
    logic [MbW-1:0] mby;
    logic           first;       // first strip of the frame
    logic           last;        // last strip of the frame
    logic [3:0]     last_line;   // last valid luma line (the lines below repeat it)
    logic [2:0]     last_cline;  // last valid chroma line
    frame_t         frame;
  } strip_t;

  // One coded macroblock (macroblock engine -> CAVLC)
  typedef struct packed {
    logic [MbW-1:0] mbx;
    logic [MbW-1:0] mby;
    logic           first;       // first MB of the frame: NAL + slice header before it
    logic           last;        // last MB of the frame: trailing bits after it
    logic [1:0]     mode;        // Intra16x16PredMode: 0 V, 1 H, 2 DC, 3 plane
    logic [1:0]     cmode;       // intra_chroma_pred_mode: 0 DC, 1 H, 2 V, 3 plane
    logic           cbp_luma;    // CodedBlockPatternLuma = 15
    logic [1:0]     cbp_chroma;  // CodedBlockPatternChroma
    frame_t         frame;
  } mbinfo_t;

  // QP -> {QP / 6, QP % 6}
  function automatic logic [6:0] qp_divmod(logic [5:0] qp);
    logic [3:0] k;
    logic [2:0] m;
    k = 4'(qp / 6'd6);
    m = 3'(qp - 6'(k) * 6'd6);
    return {k, m};
  endfunction

  // QPc for chroma_qp_index_offset = 0 (Table 8-15)
  function automatic logic [5:0] qp_chroma(logic [5:0] qp);
    logic [5:0] r;
    if (qp < 6'd30) begin
      r = qp;
    end else begin
      unique case (qp)
        6'd30: r = 6'd29;
        6'd31: r = 6'd30;
        6'd32: r = 6'd31;
        6'd33, 6'd34: r = 6'd32;
        6'd35: r = 6'd33;
        6'd36, 6'd37: r = 6'd34;
        6'd38, 6'd39: r = 6'd35;
        6'd40, 6'd41: r = 6'd36;
        6'd42, 6'd43, 6'd44: r = 6'd37;
        6'd45, 6'd46, 6'd47: r = 6'd38;
        default: r = 6'd39;
      endcase
    end
    return r;
  endfunction

  // Position class of coefficient (row i, column j) from the parities of i
  // and j: 0 both even, 1 both odd, 2 others
  function automatic logic [1:0] pos_class(logic i0, logic j0);
    if (!i0 && !j0) return 2'd0;
    if (i0 && j0) return 2'd1;
    return 2'd2;
  endfunction

  // Forward quantisation multiplier MF(QP % 6, class)
  function automatic logic [13:0] quant_mf(logic [2:0] m, logic [1:0] cls);
    logic [13:0] r;
    unique case ({m, cls})
      {3'd0, 2'd0}: r = 14'd13107;  {3'd0, 2'd1}: r = 14'd5243;  {3'd0, 2'd2}: r = 14'd8066;
      {3'd1, 2'd0}: r = 14'd11916;  {3'd1, 2'd1}: r = 14'd4660;  {3'd1, 2'd2}: r = 14'd7490;
      {3'd2, 2'd0}: r = 14'd10082;  {3'd2, 2'd1}: r = 14'd4194;  {3'd2, 2'd2}: r = 14'd6554;
      {3'd3, 2'd0}: r = 14'd9362;   {3'd3, 2'd1}: r = 14'd3647;  {3'd3, 2'd2}: r = 14'd5825;
      {3'd4, 2'd0}: r = 14'd8192;   {3'd4, 2'd1}: r = 14'd3355;  {3'd4, 2'd2}: r = 14'd5243;
      {3'd5, 2'd0}: r = 14'd7282;   {3'd5, 2'd1}: r = 14'd2893;  {3'd5, 2'd2}: r = 14'd4559;
      default: r = '0;
    endcase
    return r;
  endfunction

  // Decoder scaling factor V = normAdjust4x4(QP % 6, class)
  function automatic logic [4:0] scale_v(logic [2:0] m, logic [1:0] cls);
    logic [4:0] r;
    unique case ({m, cls})
      {3'd0, 2'd0}: r = 5'd10;  {3'd0, 2'd1}: r = 5'd16;  {3'd0, 2'd2}: r = 5'd13;
      {3'd1, 2'd0}: r = 5'd11;  {3'd1, 2'd1}: r = 5'd18;  {3'd1, 2'd2}: r = 5'd14;
      {3'd2, 2'd0}: r = 5'd13;  {3'd2, 2'd1}: r = 5'd20;  {3'd2, 2'd2}: r = 5'd16;
      {3'd3, 2'd0}: r = 5'd14;  {3'd3, 2'd1}: r = 5'd23;  {3'd3, 2'd2}: r = 5'd18;
      {3'd4, 2'd0}: r = 5'd16;  {3'd4, 2'd1}: r = 5'd25;  {3'd4, 2'd2}: r = 5'd20;
      {3'd5, 2'd0}: r = 5'd18;  {3'd5, 2'd1}: r = 5'd29;  {3'd5, 2'd2}: r = 5'd23;
      default: r = '0;
    endcase
    return r;
  endfunction

  // Rounding offset of the forward quantiser: floor(2^(15 + k) / 3), k = QP / 6
  function automatic logic [21:0] quant_f(logic [3:0] k);
    logic [21:0] r;
    unique case (k)
      4'd0: r = 22'd10922;
      4'd1: r = 22'd21845;
      4'd2: r = 22'd43690;
      4'd3: r = 22'd87381;
      4'd4: r = 22'd174762;
      4'd5: r = 22'd349525;
      4'd6: r = 22'd699050;
      4'd7: r = 22'd1398101;
      default: r = 22'd2796202;
    endcase
    return r;
  endfunction

  // Quantise one coefficient: sign(w) * min((|w| * mf + f) >> shift, LevelMax).
  // Pure combinational helper for the pipelines (they register around it).
  function automatic logic [LevelW-1:0] quant_level(logic sign, logic [29:0] sum, logic [4:0] shift);
    logic [29:0] q;
    logic [11:0] mag;
    q   = sum >> shift;
    mag = (q > 30'(LevelMax)) ? 12'(LevelMax) : q[11:0];
    return sign ? -LevelW'(mag) : LevelW'(mag);
  endfunction

  // Exp-Golomb ue(v) code of v (v < 2^15): {length[4:0], code[15:0]}
  function automatic logic [20:0] ue_code(logic [14:0] v);
    logic [15:0] x;
    logic [4:0]  n;
    x = 16'(v) + 16'd1;
    n = '0;
    for (int i = 0; i < 16; i++) begin
      if (x[i]) n = 5'(i);
    end
    return {5'(2 * n + 1), x};
  endfunction

  // se(v) of a 7 bit signed value
  function automatic logic [20:0] se_code(logic signed [6:0] v);
    logic [14:0] k;
    if (v > 0) k = 15'(2 * v - 1);
    else       k = 15'(-2 * v);
    return ue_code(k);
  endfunction

endpackage
