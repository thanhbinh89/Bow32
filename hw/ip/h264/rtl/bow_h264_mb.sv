// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// H.264 macroblock engine: Intra_16x16 prediction, mode decision, transform,
// quantisation and reconstruction of one macroblock after the other, in
// raster order, from the strip buffers (docs/ip/h264.md):
//
//   neighbours  top row (line buffer, reconstructed), left column (previous
//               macroblock), top-left; DC value and plane parameters
//   luma        mode decision: SAD of V, H, DC, plane over the 16x16 block
//               (the lowest mode number wins a tie), forward pass (residual,
//               4x4 transform, AC quantisation), DC transform, inverse pass
//               (dequantisation, inverse transform, reconstruction)
//   chroma      the same for Cb + Cr (4:2:0, modes DC, H, V, plane)
//   end         levels + macroblock info to the CAVLC coder (coefficient
//               buffer slot), bottom row to the line buffer, right column
//               kept as the next left column
//
// Every pass streams one row of 4 samples per cycle through the shared
// prediction unit (bow_h264_pred) and bow_h264_fwd / bow_h264_inv. About
// 392 cycles per macroblock.
//
// Coefficient buffer words (4 levels, level j in bits [16 j +: 16]):
//   0..63    luma block blk (z-order) row r: 4 * blk + r
//   64..67   Intra16x16DCLevel matrix rows
//   68..99   chroma: 68 + 16 * comp + 4 * blk + r
//   100,101  chroma DC c0..c3 of Cb, Cr

module bow_h264_mb import bow_h264_pkg::*; #(
  parameter int unsigned MaxWidth  = 2048,
  parameter int unsigned NumStrips = 4
) (
  input  logic                                         clk_i,
  input  logic                                         rst_ni,
  input  logic [MbW-1:0]                               mbw_i,        // width in macroblocks

  // strips from bow_h264_input (FIFO head)
  input  logic                                         strip_valid_i,
  input  strip_t                                       strip_i,
  output logic                                         strip_pop_o,
  output logic                                         strip_free_o,

  // strip buffer read ports (latency 2)
  output logic [$clog2(NumStrips * 2 * MaxWidth)-1:0]  y_raddr_o,
  input  logic [63:0]                                  y_rdata_i,
  output logic [$clog2(NumStrips * MaxWidth / 2)-1:0]  c_raddr_o,
  input  logic [63:0]                                  cb_rdata_i,
  input  logic [63:0]                                  cr_rdata_i,

  // coefficient buffer (2 slots) and macroblock hand-over to the CAVLC coder
  output logic                                         cf_we_o,
  output logic [7:0]                                   cf_waddr_o,   // {slot, word}
  output logic [63:0]                                  cf_wdata_o,
  input  logic [1:0]                                   slot_full_i,
  output logic                                         mb_commit_o,
  output logic                                         mb_slot_o,
  output mbinfo_t                                      mb_info_o,

  output logic                                         busy_o,       // a strip is being coded
  output logic                                         work_o,       // working on a macroblock

  // reconstructed samples (debug / test): plane 0 Y, 1 Cb, 2 Cr
  output logic                                         rec_valid_o,
  output logic [1:0]                                   rec_plane_o,
  output logic [CoordW-1:0]                            rec_x_o,
  output logic [CoordW-1:0]                            rec_y_o,
  output logic [3:0][7:0]                              rec_px_o
);

  localparam int unsigned SW  = $clog2(NumStrips);
  localparam int unsigned WW  = $clog2(MaxWidth / 8);
  localparam int unsigned YAW = $clog2(NumStrips * 2 * MaxWidth);
  localparam int unsigned CAW = $clog2(NumStrips * MaxWidth / 2);
  localparam int unsigned LbAW = $clog2(MaxWidth / 16);

  typedef enum logic [4:0] {
    StIdle, StNb0, StNb1, StSet0, StSet1, StSet2,
    StLMd, StLMdW, StLSel, StLSel2, StLFwd, StLFwdW, StLDc, StLInv, StLInvW,
    StCMd, StCMdW, StCSel, StCSel2, StCFwd, StCFwdW, StCDc, StCInv, StCInvW, StEnd
  } state_e;

  state_e         state_q;
  logic           have_strip_q;
  strip_t         strip_q;
  logic [MbW-1:0] mbx_q;
  logic           wslot_q;
  logic           top_av, left_av;
  logic [6:0]     qkm_l_q, qkm_c_q;    // {QP / 6, QP % 6} of luma and chroma

  assign top_av  = (strip_q.mby != '0);
  assign left_av = (mbx_q != '0);

  // ------------------------------------------------------------ neighbours
  logic [15:0][7:0]      top_q, left_q, right_q, bot_q;
  logic [1:0][7:0][7:0]  topc_q, leftc_q, rightc_q, botc_q;
  logic [7:0]            tl_q, tl_next_q;
  logic [1:0][7:0]       tlc_q, tlc_next_q;
  logic [127:0]          lby_rdata;
  logic [63:0]           lbcb_rdata, lbcr_rdata;
  logic                  lb_we;

  assign lb_we = (state_q == StEnd);

  bow_ram_sdp #(.Width (128), .Depth (MaxWidth / 16)) u_lb_y (
    .wclk_i (clk_i), .we_i (lb_we), .waddr_i (LbAW'(mbx_q)), .wdata_i (bot_q),
    .rclk_i (clk_i), .re_i (state_q == StNb0), .raddr_i (LbAW'(mbx_q)), .rdata_o (lby_rdata));
  bow_ram_sdp #(.Width (64), .Depth (MaxWidth / 16)) u_lb_cb (
    .wclk_i (clk_i), .we_i (lb_we), .waddr_i (LbAW'(mbx_q)), .wdata_i (botc_q[0]),
    .rclk_i (clk_i), .re_i (state_q == StNb0), .raddr_i (LbAW'(mbx_q)), .rdata_o (lbcb_rdata));
  bow_ram_sdp #(.Width (64), .Depth (MaxWidth / 16)) u_lb_cr (
    .wclk_i (clk_i), .we_i (lb_we), .waddr_i (LbAW'(mbx_q)), .wdata_i (botc_q[1]),
    .rclk_i (clk_i), .re_i (state_q == StNb0), .raddr_i (LbAW'(mbx_q)), .rdata_o (lbcr_rdata));

  // --------------------------------------------- DC values, plane parameters
  // Three cycles: sums and differences of the neighbours, the weighted sums
  // H and V of the plane prediction, then DC values and a, b, c.
  typedef logic signed [9:0] d_t;

  logic [11:0]        sum_t_q, sum_l_q;
  d_t [7:0]           dt_q, dl_q;             // p[8+k, -1] - p[6-k, -1], same for the left column
  d_t [1:0][3:0]      dct_q, dcl_q;           // chroma: p[4+k, -1] - p[2-k, -1]
  logic signed [15:0] ph_q, pv_q;
  logic [1:0][9:0]    cst0_q, cst1_q, csl0_q, csl1_q;
  s13_t [1:0]         cph_q, cpv_q;

  logic [7:0]                dc_l_q;
  logic signed [14:0]        pa_l_q;
  logic signed [12:0]        pb_l_q, pc_l_q;
  logic [1:0][3:0][7:0]      dc_c_q;
  s15_t [1:0]                pa_c_q;
  s13_t [1:0]                pb_c_q, pc_c_q;

  function automatic d_t diff8(logic [7:0] a, logic [7:0] b);
    return 10'(signed'({1'b0, a})) - 10'(signed'({1'b0, b}));
  endfunction

  always_ff @(posedge clk_i) begin
    if (state_q == StSet0) begin
      logic [11:0] st, sl;
      st = '0;
      sl = '0;
      for (int k = 0; k < 16; k++) begin
        st = st + 12'(top_q[k]);
        sl = sl + 12'(left_q[k]);
      end
      sum_t_q <= st;
      sum_l_q <= sl;
      for (int k = 0; k < 8; k++) begin
        dt_q[k] <= diff8(top_q[8 + k], (k == 7) ? tl_q : top_q[6 - k]);
        dl_q[k] <= diff8(left_q[8 + k], (k == 7) ? tl_q : left_q[6 - k]);
      end
      for (int c = 0; c < 2; c++) begin
        for (int k = 0; k < 4; k++) begin
          dct_q[c][k] <= diff8(topc_q[c][4 + k], (k == 3) ? tlc_q[c] : topc_q[c][2 - k]);
          dcl_q[c][k] <= diff8(leftc_q[c][4 + k], (k == 3) ? tlc_q[c] : leftc_q[c][2 - k]);
        end
        cst0_q[c] <= 10'(topc_q[c][0]) + 10'(topc_q[c][1]) + 10'(topc_q[c][2]) + 10'(topc_q[c][3]);
        cst1_q[c] <= 10'(topc_q[c][4]) + 10'(topc_q[c][5]) + 10'(topc_q[c][6]) + 10'(topc_q[c][7]);
        csl0_q[c] <= 10'(leftc_q[c][0]) + 10'(leftc_q[c][1]) + 10'(leftc_q[c][2]) + 10'(leftc_q[c][3]);
        csl1_q[c] <= 10'(leftc_q[c][4]) + 10'(leftc_q[c][5]) + 10'(leftc_q[c][6]) + 10'(leftc_q[c][7]);
      end
    end
    if (state_q == StSet1) begin
      logic signed [15:0] h, v;
      h = '0;
      v = '0;
      for (int k = 0; k < 8; k++) begin
        h = h + 16'(k + 1) * 16'(dt_q[k]);
        v = v + 16'(k + 1) * 16'(dl_q[k]);
      end
      ph_q <= h;
      pv_q <= v;
      for (int c = 0; c < 2; c++) begin
        logic signed [12:0] hc, vc;
        hc = '0;
        vc = '0;
        for (int k = 0; k < 4; k++) begin
          hc = hc + 13'(k + 1) * 13'(dct_q[c][k]);
          vc = vc + 13'(k + 1) * 13'(dcl_q[c][k]);
        end
        cph_q[c] <= hc;
        cpv_q[c] <= vc;
      end
    end
    if (state_q == StSet2) begin
      if (top_av && left_av) dc_l_q <= 8'((13'(sum_t_q) + 13'(sum_l_q) + 13'd16) >> 5);
      else if (left_av)      dc_l_q <= 8'((sum_l_q + 12'd8) >> 4);
      else if (top_av)       dc_l_q <= 8'((sum_t_q + 12'd8) >> 4);
      else                   dc_l_q <= 8'd128;
      pa_l_q <= 15'(16 * (int'(left_q[15]) + int'(top_q[15])));
      pb_l_q <= 13'((22'(ph_q) * 22'sd5 + 22'sd32) >>> 6);
      pc_l_q <= 13'((22'(pv_q) * 22'sd5 + 22'sd32) >>> 6);
      for (int c = 0; c < 2; c++) begin
        // block 0 (top-left) and 3 (bottom-right): top + left
        if (top_av && left_av) begin
          dc_c_q[c][0] <= 8'((11'(cst0_q[c]) + 11'(csl0_q[c]) + 11'd4) >> 3);
          dc_c_q[c][3] <= 8'((11'(cst1_q[c]) + 11'(csl1_q[c]) + 11'd4) >> 3);
        end else if (left_av) begin
          dc_c_q[c][0] <= 8'((csl0_q[c] + 10'd2) >> 2);
          dc_c_q[c][3] <= 8'((csl1_q[c] + 10'd2) >> 2);
        end else if (top_av) begin
          dc_c_q[c][0] <= 8'((cst0_q[c] + 10'd2) >> 2);
          dc_c_q[c][3] <= 8'((cst1_q[c] + 10'd2) >> 2);
        end else begin
          dc_c_q[c][0] <= 8'd128;
          dc_c_q[c][3] <= 8'd128;
        end
        // block 1 (top-right): top first
        if (top_av)       dc_c_q[c][1] <= 8'((cst1_q[c] + 10'd2) >> 2);
        else if (left_av) dc_c_q[c][1] <= 8'((csl0_q[c] + 10'd2) >> 2);
        else              dc_c_q[c][1] <= 8'd128;
        // block 2 (bottom-left): left first
        if (left_av)      dc_c_q[c][2] <= 8'((csl1_q[c] + 10'd2) >> 2);
        else if (top_av)  dc_c_q[c][2] <= 8'((cst0_q[c] + 10'd2) >> 2);
        else              dc_c_q[c][2] <= 8'd128;
        pa_c_q[c] <= 15'(16 * (int'(leftc_q[c][7]) + int'(topc_q[c][7])));
        pb_c_q[c] <= 13'((20'(cph_q[c]) * 20'sd34 + 20'sd32) >>> 6);
        pc_c_q[c] <= 13'((20'(cpv_q[c]) * 20'sd34 + 20'sd32) >>> 6);
      end
    end
  end

  // ------------------------------------------------------------- sequencer
  logic [5:0] seq_q;
  logic       seq_run, seq_last, pass_chroma, pass_md, pass_fwd, pass_inv;

  assign pass_md     = (state_q == StLMd)  || (state_q == StCMd);
  assign pass_fwd    = (state_q == StLFwd) || (state_q == StCFwd);
  assign pass_inv    = (state_q == StLInv) || (state_q == StCInv);
  assign seq_run     = pass_md || pass_fwd || pass_inv;
  assign pass_chroma = (state_q == StCMd) || (state_q == StCFwd) || (state_q == StCInv);
  assign seq_last    = pass_chroma ? (seq_q == 6'd31) : (seq_q == 6'd63);

  // step -> {chroma, comp, blk, row} (tag = {chroma, comp, blk})
  logic [5:0] s0_tag;
  logic [1:0] s0_row;
  assign s0_tag = pass_chroma ? {1'b1, seq_q[4], 2'b00, seq_q[3:2]} : {2'b00, seq_q[5:2]};
  assign s0_row = seq_q[1:0];

  // block column / row of a tag
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [1:0] tag_bx(logic [5:0] tag);
    return tag[5] ? {1'b0, tag[0]} : {tag[2], tag[0]};
  endfunction
  function automatic logic [1:0] tag_by(logic [5:0] tag);
    return tag[5] ? {1'b0, tag[1]} : {tag[3], tag[1]};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------- strip buffer read address
  logic [1:0] s0_bx, s0_by;
  logic [3:0] s0_line, s0_line_c;
  logic [2:0] s0_cline, s0_cline_c;

  assign s0_bx      = tag_bx(s0_tag);
  assign s0_by      = tag_by(s0_tag);
  assign s0_line    = {s0_by, s0_row};
  assign s0_line_c  = (s0_line > strip_q.last_line) ? strip_q.last_line : s0_line;
  assign s0_cline   = {s0_by[0], s0_row};
  assign s0_cline_c = (s0_cline > strip_q.last_cline) ? strip_q.last_cline : s0_cline;

  assign y_raddr_o = YAW'({strip_q.slot[SW-1:0], s0_line_c, mbx_q[WW-2:0], s0_bx[1]});
  assign c_raddr_o = CAW'({strip_q.slot[SW-1:0], s0_cline_c, mbx_q[WW-2:0]});

  // pipeline S1..S3 (strip buffer latency 2, prediction latency 3)
  logic [3:1] sp_valid;
  logic [3:1][5:0] sp_tag;
  logic [3:1][1:0] sp_row;
  logic [3:1] sp_last;
  logic [3:0][7:0] s3_orig;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sp_valid <= '0;
      sp_tag   <= '0;
      sp_row   <= '0;
      sp_last  <= '0;
      s3_orig  <= '0;
    end else begin
      sp_valid <= {sp_valid[2:1], (pass_md || pass_fwd)};
      sp_tag   <= {sp_tag[2:1], s0_tag};
      sp_row   <= {sp_row[2:1], s0_row};
      sp_last  <= {sp_last[2:1], seq_last};
      // S2 -> S3: the samples of the row
      begin
        logic [63:0] w;
        logic        half;
        w    = !sp_tag[2][5] ? y_rdata_i : (sp_tag[2][4] ? cr_rdata_i : cb_rdata_i);
        half = sp_tag[2][0];       // bx[0] for luma and chroma
        s3_orig <= half ? w[63:32] : w[31:0];
      end
    end
  end

  // ------------------------------------------------------------ prediction
  logic             pr_chroma, pr_comp;
  logic [1:0]       pr_bx;
  logic [3:0]       pr_y;
  logic [1:0]       pr_blk;
  logic [3:0][7:0]  pr_v, pr_h, pr_dc, pr_p;
  logic [5:0]       inv_tag;
  logic [1:0]       inv_row;
  logic             inv_valid;
  s16_t [3:0]       inv_res;

  // MD / forward passes: the sequencer; inverse passes: the rows leaving bow_h264_inv
  always_comb begin
    logic [5:0] tag;
    logic [1:0] row;
    tag       = pass_md || pass_fwd ? s0_tag : inv_tag;
    row       = pass_md || pass_fwd ? s0_row : inv_row;
    pr_chroma = tag[5];
    pr_comp   = tag[4];
    pr_blk    = tag[1:0];
    pr_bx     = tag_bx(tag);
    pr_y      = tag[5] ? {1'b0, tag[1], row} : {tag[3], tag[1], row};
  end

  bow_h264_pred u_pred (
    .clk_i,
    .chroma_i (pr_chroma),
    .bx_i     (pr_bx),
    .y_i      (pr_y),
    .top_i    (pr_chroma ? {64'h0, topc_q[pr_comp]} : top_q),
    .left_i   (pr_chroma ? {64'h0, leftc_q[pr_comp]} : left_q),
    .dc_i     (pr_chroma ? dc_c_q[pr_comp][pr_blk] : dc_l_q),
    .pa_i     (pr_chroma ? pa_c_q[pr_comp] : pa_l_q),
    .pb_i     (pr_chroma ? pb_c_q[pr_comp] : pb_l_q),
    .pc_i     (pr_chroma ? pc_c_q[pr_comp] : pc_l_q),
    .v_o      (pr_v),
    .h_o      (pr_h),
    .dc_o     (pr_dc),
    .p_o      (pr_p)
  );

  logic [1:0] mode_l_q, mode_c_q;
  logic [3:0][7:0] pred_sel;
  logic       sel_chroma;

  // the prediction of the chosen mode (luma: 0 V 1 H 2 DC 3 P, chroma: 0 DC 1 H 2 V 3 P)
  assign sel_chroma = (state_q >= StCMd);
  always_comb begin
    unique case (sel_chroma ? mode_c_q : mode_l_q)
      2'd0: pred_sel = sel_chroma ? pr_dc : pr_v;
      2'd1: pred_sel = pr_h;
      2'd2: pred_sel = sel_chroma ? pr_v : pr_dc;
      default: pred_sel = pr_p;
    endcase
  end

  // --------------------------------------------------------- mode decision
  function automatic logic [9:0] sad4(logic [3:0][7:0] a, logic [3:0][7:0] b);
    logic [9:0] s;
    s = '0;
    for (int k = 0; k < 4; k++) begin
      logic [7:0] d;
      d = (a[k] > b[k]) ? (a[k] - b[k]) : (b[k] - a[k]);
      s = s + 10'(d);
    end
    return s;
  endfunction

  logic             md4_valid;
  logic [3:0][9:0]  md4_row;     // V H DC P of one row
  logic [3:0][15:0] sad_q;       // V H DC P
  logic [6:0]       md_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      md4_valid <= 1'b0;
      md4_row   <= '0;
      sad_q     <= '0;
      md_cnt_q  <= '0;
    end else begin
      md4_valid  <= sp_valid[3] && (state_q == StLMd || state_q == StLMdW ||
                                    state_q == StCMd || state_q == StCMdW);
      md4_row[0] <= sad4(s3_orig, pr_v);
      md4_row[1] <= sad4(s3_orig, pr_h);
      md4_row[2] <= sad4(s3_orig, pr_dc);
      md4_row[3] <= sad4(s3_orig, pr_p);
      if (state_q == StLSel2 || state_q == StCSel2 || state_q == StSet0) begin
        sad_q    <= '0;
        md_cnt_q <= '0;
      end else if (md4_valid) begin
        for (int m = 0; m < 4; m++) sad_q[m] <= sad_q[m] + 16'(md4_row[m]);
        md_cnt_q <= md_cnt_q + 7'd1;
      end
    end
  end

  // Mode choice in two cycles: the six comparisons of the four SADs (in the
  // order of the modes: luma V H DC P, chroma DC H V P), then the winner.
  // Mode i wins when it is available, strictly better than every available
  // mode before it and not worse than every available mode after it (the
  // lowest mode number wins a tie).
  logic [3:0][3:0] beats_q;     // beats_q[j][i]: mode j strictly better than mode i
  logic [1:0] best_l, best_c;

  always_ff @(posedge clk_i) begin
    if (state_q == StLSel || state_q == StCSel) begin
      for (int i = 0; i < 4; i++) begin
        for (int j = 0; j < 4; j++) begin
          // slot of a mode in sad_q: luma = mode, chroma {DC, H, V, P} = {2, 1, 0, 3}
          int si, sj;
          si = (state_q == StLSel) ? i : (i == 0) ? 2 : (i == 2) ? 0 : i;
          sj = (state_q == StLSel) ? j : (j == 0) ? 2 : (j == 2) ? 0 : j;
          beats_q[j][i] <= sad_q[sj] < sad_q[si];
        end
      end
    end
  end

  function automatic logic [1:0] pick(logic [3:0][3:0] beats, logic [3:0] avail);
    logic [1:0] r;
    r = 2'd0;
    for (int i = 3; i >= 0; i--) begin
      logic win;
      win = avail[i];
      for (int j = 0; j < 4; j++) begin
        if (j < i && avail[j] && !beats[i][j]) win = 1'b0;
        if (j > i && avail[j] && beats[j][i]) win = 1'b0;
      end
      if (win) r = 2'(i);
    end
    return r;
  endfunction

  assign best_l = pick(beats_q, {top_av && left_av, 1'b1, left_av, top_av});   // P DC H V
  assign best_c = pick(beats_q, {top_av && left_av, top_av, left_av, 1'b1});   // P V H DC

  // ---------------------------------------------------------- forward path
  logic [3:0] fqk, iqk;
  logic [2:0] fqm, iqm;
  logic       fwd_lv_valid, fwd_lv_nz, fwd_dc_valid;
  logic [1:0] fwd_lv_row;
  logic [5:0] fwd_lv_tag, fwd_dc_tag;
  logic [3:0][LevelW-1:0] fwd_lv;
  logic signed [15:0] fwd_dc;

  assign {fqk, fqm} = sel_chroma ? qkm_c_q : qkm_l_q;
  assign {iqk, iqm} = sel_chroma ? qkm_c_q : qkm_l_q;

  bow_h264_fwd u_fwd (
    .clk_i,
    .rst_ni,
    .qk_i       (fqk),
    .qm_i       (fqm),
    .in_valid_i (sp_valid[3] && (state_q == StLFwd || state_q == StLFwdW ||
                                 state_q == StCFwd || state_q == StCFwdW)),
    .in_row_i   (sp_row[3]),
    .in_tag_i   (sp_tag[3]),
    .in_orig_i  (s3_orig),
    .in_pred_i  (pred_sel),
    .lv_valid_o (fwd_lv_valid),
    .lv_row_o   (fwd_lv_row),
    .lv_tag_o   (fwd_lv_tag),
    .lv_o       (fwd_lv),
    .lv_nz_o    (fwd_lv_nz),
    .dc_valid_o (fwd_dc_valid),
    .dc_tag_o   (fwd_dc_tag),
    .dc_o       (fwd_dc)
  );

  s16_t [15:0]              dc_raw_q;     // luma [4 by + bx], chroma [4 comp + blk]
  logic [6:0]               lv_cnt_q;
  logic                     nz_luma_q, nz_cac_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dc_raw_q  <= '0;
      lv_cnt_q  <= '0;
      nz_luma_q <= 1'b0;
      nz_cac_q  <= 1'b0;
    end else begin
      if (state_q == StLSel2 || state_q == StCSel2) begin
        lv_cnt_q <= '0;
        dc_raw_q <= '0;
      end else if (fwd_lv_valid) begin
        lv_cnt_q <= lv_cnt_q + 7'd1;
      end
      if (state_q == StSet0) begin
        nz_luma_q <= 1'b0;
        nz_cac_q  <= 1'b0;
      end else if (fwd_lv_valid && fwd_lv_nz) begin
        if (fwd_lv_tag[5]) nz_cac_q  <= 1'b1;
        else               nz_luma_q <= 1'b1;
      end
      if (fwd_dc_valid) begin
        if (fwd_dc_tag[5]) dc_raw_q[{1'b0, fwd_dc_tag[4], fwd_dc_tag[1:0]}] <= fwd_dc;
        else               dc_raw_q[{tag_by(fwd_dc_tag), tag_bx(fwd_dc_tag)}] <= fwd_dc;
      end
    end
  end

  // -------------------------------------------------------- DC transforms
  logic                      dc_start, dc_done, dc_nz, dc_wr_valid;
  logic [1:0]                dc_wr_idx;
  logic [3:0][LevelW-1:0]    dc_wr_lv;
  s18_t [15:0]               dc_dq;
  logic                      dc_started_q;

  assign dc_start = ((state_q == StLDc) || (state_q == StCDc)) && !dc_started_q;

  bow_h264_dc u_dc (
    .clk_i,
    .rst_ni,
    .start_i    (dc_start),
    .chroma_i   (state_q == StCDc),
    .qk_i       (fqk),
    .qm_i       (fqm),
    .raw_i      (dc_raw_q),
    .wr_valid_o (dc_wr_valid),
    .wr_idx_o   (dc_wr_idx),
    .wr_lv_o    (dc_wr_lv),
    .dq_o       (dc_dq),
    .nz_o       (dc_nz),
    .done_o     (dc_done)
  );

  s18_t [15:0]              dq_l_q, dq_c_q;
  logic                     nz_cdc_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dc_started_q <= 1'b0;
      dq_l_q       <= '0;
      dq_c_q       <= '0;
      nz_cdc_q     <= 1'b0;
    end else begin
      if (dc_start) dc_started_q <= 1'b1;
      if (dc_done) begin
        dc_started_q <= 1'b0;
        if (state_q == StCDc) begin
          dq_c_q   <= dc_dq;
          nz_cdc_q <= dc_nz;
        end else begin
          dq_l_q <= dc_dq;
        end
      end
    end
  end

  // -------------------------------------------- coefficient / level buffers
  logic [6:0]  word_w;
  logic        lvb_we;
  logic [63:0] lvb_wdata;

  always_comb begin
    if (dc_wr_valid) begin
      word_w    = (state_q == StCDc) ? 7'(WordChromaDc + 32'(dc_wr_idx))
                                     : 7'(WordLumaDc + 32'(dc_wr_idx));
      lvb_wdata = dc_wr_lv;
    end else if (fwd_lv_tag[5]) begin
      word_w    = 7'(WordChromaAc) + {2'b00, fwd_lv_tag[4], fwd_lv_tag[1:0], fwd_lv_row};
      lvb_wdata = fwd_lv;
    end else begin
      word_w    = {1'b0, fwd_lv_tag[3:0], fwd_lv_row};
      lvb_wdata = fwd_lv;
    end
  end

  assign lvb_we     = dc_wr_valid || fwd_lv_valid;
  assign cf_we_o    = lvb_we;
  assign cf_waddr_o = {wslot_q, word_w};
  assign cf_wdata_o = lvb_wdata;

  // private copy of the levels for the inverse pass
  logic [6:0]  word_r;
  logic [63:0] lvb_rdata;

  assign word_r = pass_chroma ? 7'(WordChromaAc) + {2'b00, seq_q[4], seq_q[3:2], seq_q[1:0]}
                              : {1'b0, seq_q[5:2], seq_q[1:0]};

  bow_ram_sdp #(.Width (64), .Depth (128)) u_lvb (
    .wclk_i (clk_i), .we_i (lvb_we), .waddr_i (word_w), .wdata_i (lvb_wdata),
    .rclk_i (clk_i), .re_i (pass_inv), .raddr_i (word_r), .rdata_o (lvb_rdata));

  // ---------------------------------------------------------- inverse path
  // level buffer read at S0, data at S1, registered at S2 (timing)
  logic       iv1_valid, iv2_valid;
  logic [5:0] iv1_tag, iv2_tag;
  logic [1:0] iv1_row, iv2_row;
  logic [63:0] lvb_q;
  logic signed [17:0] iv2_dc;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      iv1_valid <= 1'b0;
      iv1_tag   <= '0;
      iv1_row   <= '0;
      iv2_valid <= 1'b0;
      iv2_tag   <= '0;
      iv2_row   <= '0;
      lvb_q     <= '0;
    end else begin
      iv1_valid <= pass_inv;
      iv1_tag   <= s0_tag;
      iv1_row   <= s0_row;
      iv2_valid <= iv1_valid;
      iv2_tag   <= iv1_tag;
      iv2_row   <= iv1_row;
      lvb_q     <= lvb_rdata;
    end
  end

  assign iv2_dc = iv2_tag[5] ? dq_c_q[{1'b0, iv2_tag[4], iv2_tag[1:0]}]
                             : dq_l_q[{tag_by(iv2_tag), tag_bx(iv2_tag)}];

  bow_h264_inv u_inv (
    .clk_i,
    .rst_ni,
    .qk_i        (iqk),
    .qm_i        (iqm),
    .in_valid_i  (iv2_valid),
    .in_row_i    (iv2_row),
    .in_tag_i    (iv2_tag),
    .in_lv_i     (lvb_q),
    .in_dc_i     (iv2_dc),
    .out_valid_o (inv_valid),
    .out_row_o   (inv_row),
    .out_tag_o   (inv_tag),
    .out_res_o   (inv_res)
  );

  // residual waits for the prediction (3 cycles)
  logic [3:1]                    rp_valid;
  logic [3:1][5:0]               rp_tag;
  logic [3:1][1:0]               rp_row;
  s16_t [3:1][3:0]               rp_res;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rp_valid <= '0;
      rp_tag   <= '0;
      rp_row   <= '0;
      rp_res   <= '0;
    end else begin
      rp_valid <= {rp_valid[2:1], inv_valid};
      rp_tag   <= {rp_tag[2:1], inv_tag};
      rp_row   <= {rp_row[2:1], inv_row};
      rp_res   <= {rp_res[2:1], inv_res};
    end
  end

  logic [3:0][7:0] recon;
  always_comb begin
    for (int k = 0; k < 4; k++) begin
      logic signed [16:0] s;
      s = 17'(signed'({1'b0, pred_sel[k]})) + 17'(rp_res[3][k]);
      recon[k] = (s < 0) ? 8'd0 : (s > 17'sd255) ? 8'd255 : s[7:0];
    end
  end

  logic [6:0] rec_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rec_cnt_q   <= '0;
      right_q     <= '0;
      bot_q       <= '0;
      rightc_q    <= '0;
      botc_q      <= '0;
      rec_valid_o <= 1'b0;
      rec_plane_o <= '0;
      rec_x_o     <= '0;
      rec_y_o     <= '0;
      rec_px_o    <= '0;
    end else begin
      rec_valid_o <= rp_valid[3];
      rec_px_o    <= recon;
      if (state_q == StLDc || state_q == StCDc) begin
        rec_cnt_q <= '0;
      end else if (rp_valid[3]) begin
        logic [1:0] bx, by;
        bx = tag_bx(rp_tag[3]);
        by = tag_by(rp_tag[3]);
        rec_cnt_q <= rec_cnt_q + 7'd1;
        if (!rp_tag[3][5]) begin
          rec_plane_o <= 2'd0;
          rec_x_o     <= CoordW'({mbx_q, bx, 2'b00});
          rec_y_o     <= CoordW'({strip_q.mby, by, rp_row[3]});
          if (bx == 2'd3) right_q[{by, rp_row[3]}] <= recon[3];
          if (by == 2'd3 && rp_row[3] == 2'd3) begin
            for (int k = 0; k < 4; k++) bot_q[{bx, 2'(k)}] <= recon[k];
          end
        end else begin
          rec_plane_o <= rp_tag[3][4] ? 2'd2 : 2'd1;
          rec_x_o     <= CoordW'({mbx_q, bx[0], 2'b00});
          rec_y_o     <= CoordW'({strip_q.mby, by[0], rp_row[3]});
          if (bx[0]) rightc_q[rp_tag[3][4]][{by[0], rp_row[3]}] <= recon[3];
          if (by[0] && rp_row[3] == 2'd3) begin
            for (int k = 0; k < 4; k++) botc_q[rp_tag[3][4]][{bx[0], 2'(k)}] <= recon[k];
          end
        end
      end
    end
  end

  // --------------------------------------------------------- control FSM
  logic last_mb;
  assign last_mb = (mbx_q == mbw_i - MbW'(1));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= StIdle;
      have_strip_q <= 1'b0;
      strip_q      <= '0;
      mbx_q        <= '0;
      wslot_q      <= 1'b0;
      seq_q        <= '0;
      qkm_l_q      <= '0;
      qkm_c_q      <= '0;
      mode_l_q     <= '0;
      mode_c_q     <= '0;
      top_q        <= '0;
      topc_q       <= '0;
      left_q       <= '0;
      leftc_q      <= '0;
      tl_q         <= '0;
      tlc_q        <= '0;
      tl_next_q    <= '0;
      tlc_next_q   <= '0;
    end else begin
      if (seq_run) seq_q <= seq_q + 6'd1;
      unique case (state_q)
        StIdle: begin
          if (!have_strip_q) begin
            if (strip_valid_i) begin
              have_strip_q <= 1'b1;
              strip_q      <= strip_i;
              mbx_q        <= '0;
              qkm_l_q      <= qp_divmod(strip_i.frame.qp);
              qkm_c_q      <= qp_divmod(qp_chroma(strip_i.frame.qp));
            end
          end else if (!slot_full_i[wslot_q]) begin
            state_q <= StNb0;
          end
        end
        StNb0: state_q <= StNb1;
        StNb1: begin
          top_q      <= lby_rdata;
          topc_q     <= {lbcr_rdata, lbcb_rdata};
          tl_q       <= tl_next_q;
          tlc_q      <= tlc_next_q;
          tl_next_q  <= lby_rdata[127:120];
          tlc_next_q <= {lbcr_rdata[63:56], lbcb_rdata[63:56]};
          state_q    <= StSet0;
        end
        StSet0: state_q <= StSet1;
        StSet1: state_q <= StSet2;
        StSet2: begin
          state_q <= StLMd;
          seq_q   <= '0;
        end
        StLMd:  if (seq_last) state_q <= StLMdW;
        StLMdW: if (md_cnt_q == 7'd64) state_q <= StLSel;
        StLSel: state_q <= StLSel2;
        StLSel2: begin
          mode_l_q <= best_l;
          state_q  <= StLFwd;
          seq_q    <= '0;
        end
        StLFwd:  if (seq_last) state_q <= StLFwdW;
        StLFwdW: if (lv_cnt_q == 7'd64) state_q <= StLDc;
        StLDc: if (dc_done) begin
          state_q <= StLInv;
          seq_q   <= '0;
        end
        StLInv:  if (seq_last) state_q <= StLInvW;
        StLInvW: if (rec_cnt_q == 7'd64) begin
          state_q <= StCMd;
          seq_q   <= '0;
        end
        StCMd:  if (seq_last) state_q <= StCMdW;
        StCMdW: if (md_cnt_q == 7'd32) state_q <= StCSel;
        StCSel: state_q <= StCSel2;
        StCSel2: begin
          mode_c_q <= best_c;
          state_q  <= StCFwd;
          seq_q    <= '0;
        end
        StCFwd:  if (seq_last) state_q <= StCFwdW;
        StCFwdW: if (lv_cnt_q == 7'd32) state_q <= StCDc;
        StCDc: if (dc_done) begin
          state_q <= StCInv;
          seq_q   <= '0;
        end
        StCInv:  if (seq_last) state_q <= StCInvW;
        StCInvW: if (rec_cnt_q == 7'd32) state_q <= StEnd;
        StEnd: begin
          left_q  <= right_q;
          leftc_q <= rightc_q;
          wslot_q <= ~wslot_q;
          mbx_q   <= mbx_q + MbW'(1);
          if (last_mb) have_strip_q <= 1'b0;
          state_q <= StIdle;
        end
        default: state_q <= StIdle;
      endcase
    end
  end

  assign strip_pop_o  = (state_q == StIdle) && !have_strip_q && strip_valid_i;
  assign strip_free_o = (state_q == StEnd) && last_mb;
  assign busy_o       = (state_q != StIdle) || have_strip_q;
  assign work_o       = (state_q != StIdle);

  // macroblock hand-over
  always_comb begin
    mb_info_o            = '0;
    mb_info_o.mbx        = mbx_q;
    mb_info_o.mby        = strip_q.mby;
    mb_info_o.first      = strip_q.first && (mbx_q == '0);
    mb_info_o.last       = strip_q.last && last_mb;
    mb_info_o.mode       = mode_l_q;
    mb_info_o.cmode      = mode_c_q;
    mb_info_o.cbp_luma   = nz_luma_q;
    mb_info_o.cbp_chroma = nz_cac_q ? 2'd2 : (nz_cdc_q ? 2'd1 : 2'd0);
    mb_info_o.frame      = strip_q.frame;
  end

  assign mb_commit_o = (state_q == StEnd);
  assign mb_slot_o   = wslot_q;

  logic unused;
  assign unused = ^{sp_last, pr_blk, strip_q.slot, mbx_q[MbW-1:WW-1], s0_bx[0]};

endmodule
