// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// H.264 CAVLC coder: turns the macroblocks of the coefficient buffer into
// syntax elements ("tokens" of up to 32 bits for bow_h264_bitpack):
//
//   first MB of a frame   NAL start (0x65), IDR I slice header (frame_t)
//   every MB              mb_type, intra_chroma_pred_mode, mb_qp_delta = 0,
//                         residual blocks (clause 7.3.5.3): Intra16x16DCLevel,
//                         16 x AC if CodedBlockPatternLuma, 2 x chroma DC if
//                         CodedBlockPatternChroma > 0, 8 x chroma AC if 2
//   last MB of a frame    rbsp_slice_trailing_bits, end of the NAL unit
//
// Two stages:
//   F  reads the 4 (chroma DC: 1) words of the next block, puts the levels in
//      coding order (zig-zag), counts TotalCoeff / TrailingOnes, finds nC
//      from the TotalCoeff of the left / top blocks (current macroblock,
//      left macroblock, line buffer of the macroblock row above)
//   E  emits coeff_token + trailing one signs, the levels (suffixLength
//      adaptation), total_zeros and the run_before of the block, one token
//      per cycle; a last stage turns them into codes (bow_h264_tables_pkg)
// F works on the next block while E emits the current one. The slot of a
// macroblock is released as soon as F has read it.

module bow_h264_cavlc import bow_h264_pkg::*; import bow_h264_tables_pkg::*; #(
  parameter int unsigned MaxWidth = 2048
) (
  input  logic          clk_i,
  input  logic          rst_ni,

  // coefficient buffer read port (latency 1)
  output logic [7:0]    cf_raddr_o,
  input  logic [63:0]   cf_rdata_i,

  // macroblocks committed by bow_h264_mb
  input  logic [1:0]    slot_full_i,
  input  mbinfo_t [1:0] slot_info_i,
  output logic          slot_done_o,      // pulse: slot slot_idx_o read
  output logic          slot_idx_o,

  // tokens to bow_h264_bitpack: kind 0 = len bits of tk_bits_o (right
  // aligned), 1 = NAL start (header byte in tk_bits_o[7:0]), 2 = trailing
  // bits and end of the NAL unit (frame done)
  output logic          tk_valid_o,
  input  logic          tk_ready_i,
  output logic [1:0]    tk_kind_o,
  output logic [5:0]    tk_len_o,
  output logic [31:0]   tk_bits_o,
  output logic          tk_seq_last_o,    // with kind 2: last frame of the sequence

  output logic          busy_o
);

  localparam int unsigned LbAW = $clog2(MaxWidth / 16);

  // block kinds
  localparam logic [1:0] KLdc = 2'd0, KLac = 2'd1, KCdc = 2'd2, KCac = 2'd3;

  // zig-zag: scan index -> raster index
  function automatic logic [3:0] zz(int s);
    unique case (s)
      0: return 4'd0;   1: return 4'd1;   2: return 4'd4;   3: return 4'd8;
      4: return 4'd5;   5: return 4'd2;   6: return 4'd3;   7: return 4'd6;
      8: return 4'd9;   9: return 4'd12;  10: return 4'd13; 11: return 4'd10;
      12: return 4'd7;  13: return 4'd11; 14: return 4'd14; default: return 4'd15;
    endcase
  endfunction

  function automatic logic [3:0] msb16(logic [15:0] m);
    logic [3:0] r;
    r = '0;
    for (int i = 0; i < 16; i++) begin
      if (m[i]) r = 4'(i);
    end
    return r;
  endfunction

  function automatic logic [4:0] popcount16(logic [15:0] m);
    logic [4:0] r;
    r = '0;
    for (int i = 0; i < 16; i++) r = r + 5'(m[i]);
    return r;
  endfunction

  // ===================================================================== F
  typedef enum logic [2:0] {FIdle, FTop, FRead, FA1, FA2, FA3, FA4, FHold} fstate_e;

  fstate_e    fst_q;
  logic       fslot_q;            // slot being read
  mbinfo_t    finfo_q;
  logic [4:0] fidx_q;             // block of the MB: 0 LDC, 1..16 LAC, 17..18 CDC, 19..26 CAC
  logic [2:0] fword_q;            // words requested
  logic [3:0][3:0][15:0] fw_q;    // the words of the block
  logic       fmb_first_q;        // the next block is the first of its macroblock

  // TotalCoeff of the 4x4 blocks: current MB (luma [4 by + bx], chroma
  // [comp][2 by + bx]), left MB right column, top MB bottom row
  logic [15:0][4:0]     tcl_q;
  logic [1:0][3:0][4:0] tcc_q;
  logic [3:0][4:0]      tcl_left_q, tcl_top_q;
  logic [1:0][1:0][4:0] tcc_left_q, tcc_top_q;
  logic [39:0]          tclb_rdata;
  logic                 tclb_we;
  logic [39:0]          tclb_wdata;

  bow_ram_sdp #(.Width (40), .Depth (MaxWidth / 16)) u_tc_lb (
    .wclk_i (clk_i), .we_i (tclb_we), .waddr_i (LbAW'(finfo_q.mbx)), .wdata_i (tclb_wdata),
    .rclk_i (clk_i), .re_i (fst_q == FIdle), .raddr_i (LbAW'(slot_info_i[fslot_q].mbx)),
    .rdata_o (tclb_rdata));

  // block of the current index
  logic [1:0] fkind;
  logic       fcomp;
  logic [3:0] fblk;
  logic [6:0] fbase;
  logic [2:0] fnwords;

  always_comb begin
    fcomp = 1'b0;
    fblk  = '0;
    if (fidx_q == 5'd0) begin
      fkind = KLdc;
      fbase = 7'(WordLumaDc);
    end else if (fidx_q <= 5'd16) begin
      fkind = KLac;
      fblk  = 4'(fidx_q - 5'd1);
      fbase = {1'b0, fblk, 2'b00};
    end else if (fidx_q <= 5'd18) begin
      fkind = KCdc;
      fcomp = (fidx_q == 5'd18);
      fbase = 7'(WordChromaDc) + 7'(fcomp);
    end else begin
      fkind = KCac;
      fcomp = (fidx_q >= 5'd23);
      fblk  = {2'b00, 2'(fidx_q - 5'd19)};
      fbase = 7'(WordChromaAc) + {2'b00, fcomp, fblk[1:0], 2'b00};
    end
    fnwords = (fkind == KCdc) ? 3'd1 : 3'd4;
  end

  // next block index after fidx_q (27 = end of the macroblock)
  function automatic logic [4:0] next_idx(logic [4:0] i, logic cbp_luma, logic [1:0] cbp_chroma);
    logic [4:0] n;
    n = i + 5'd1;
    if (n >= 5'd1 && n <= 5'd16 && !cbp_luma) n = 5'd17;
    if (n >= 5'd17 && n <= 5'd18 && cbp_chroma == 2'd0) n = 5'd27;
    if (n >= 5'd19 && n <= 5'd26 && cbp_chroma != 2'd2) n = 5'd27;
    return n;
  endfunction

  assign cf_raddr_o = {fslot_q, fbase + 7'(fword_q)};

  // highest set bit, one-hot
  function automatic logic [15:0] hsb(logic [15:0] m);
    logic [15:0] r;
    logic        seen;
    r    = '0;
    seen = 1'b0;
    for (int i = 15; i >= 0; i--) begin
      r[i] = m[i] && !seen;
      seen = seen || m[i];
    end
    return r;
  endfunction

  function automatic logic [3:0] index16(logic [15:0] oh);
    logic [3:0] r;
    r = '0;
    for (int i = 0; i < 16; i++) begin
      if (oh[i]) r = r | 4'(i);
    end
    return r;
  endfunction

  // Analysis in four cycles:
  //   A1  coding order, non zero / +-1 maps
  //   A2  TotalCoeff, highest non zero coefficient
  //   A3  the second highest
  //   A4  the third, TrailingOnes and their signs, nC; into the block buffer
  logic [15:0][15:0] a1_c;        // levels in coding order
  logic [15:0]       a1_nz, a1_one;
  logic [4:0]        a2_tc;
  logic [15:0]       a2_oh0, a2_m1, a3_oh1, a3_m2;
  logic [1:0]        a1_kind;
  logic              a1_comp;
  logic [3:0]        a1_blk;

  // block buffer F -> E
  logic              bb_valid_q;
  logic [15:0][15:0] bb_c_q;
  logic [15:0]       bb_nz_q;
  logic [4:0]        bb_tc_q;
  logic [1:0]        bb_t1_q;
  logic [3:0]        bb_p0_q;
  logic [3:0]        bb_tz_q;
  logic [4:0]        bb_max_q;
  logic [2:0]        bb_tab_q;
  logic [2:0]        bb_signs_q;
  logic              bb_mb_first_q, bb_mb_last_q;
  mbinfo_t           bb_info_q;
  logic              e_take;      // E copies the block buffer

  // nC of block (kind, comp, blk)
  function automatic logic [2:0] nc_table(logic [4:0] na, logic [4:0] nb, logic ha, logic hb);
    logic [5:0] nc;
    if (ha && hb)  nc = (6'(na) + 6'(nb) + 6'd1) >> 1;
    else if (ha)   nc = 6'(na);
    else if (hb)   nc = 6'(nb);
    else           nc = '0;
    if (nc < 6'd2) return 3'd0;
    if (nc < 6'd4) return 3'd1;
    if (nc < 6'd8) return 3'd2;
    return 3'd3;
  endfunction

  logic [2:0] a1_tab;
  always_comb begin
    logic [1:0] bx, by;
    logic [4:0] na, nb;
    logic       ha, hb;
    bx = '0;
    by = '0;
    na = '0;
    nb = '0;
    ha = 1'b0;
    hb = 1'b0;
    if (a1_kind == KLdc || a1_kind == KLac) begin
      bx = (a1_kind == KLdc) ? 2'd0 : {a1_blk[2], a1_blk[0]};
      by = (a1_kind == KLdc) ? 2'd0 : {a1_blk[3], a1_blk[1]};
      if (bx != 2'd0) begin
        na = tcl_q[{by, 2'(bx - 2'd1)}];
        ha = 1'b1;
      end else if (finfo_q.mbx != '0) begin
        na = tcl_left_q[by];
        ha = 1'b1;
      end
      if (by != 2'd0) begin
        nb = tcl_q[{2'(by - 2'd1), bx}];
        hb = 1'b1;
      end else if (finfo_q.mby != '0) begin
        nb = tcl_top_q[bx];
        hb = 1'b1;
      end
      a1_tab = nc_table(na, nb, ha, hb);
    end else if (a1_kind == KCac) begin
      bx = {1'b0, a1_blk[0]};
      by = {1'b0, a1_blk[1]};
      if (bx[0]) begin
        na = tcc_q[a1_comp][{by[0], 1'b0}];
        ha = 1'b1;
      end else if (finfo_q.mbx != '0) begin
        na = tcc_left_q[a1_comp][by[0]];
        ha = 1'b1;
      end
      if (by[0]) begin
        nb = tcc_q[a1_comp][{1'b0, bx[0]}];
        hb = 1'b1;
      end else if (finfo_q.mby != '0) begin
        nb = tcc_top_q[a1_comp][bx[0]];
        hb = 1'b1;
      end
      a1_tab = nc_table(na, nb, ha, hb);
    end else begin
      a1_tab = 3'd4;           // chroma DC: nC = -1
    end
  end

  logic       f_mb_done;       // F finished the blocks of its macroblock (this cycle)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fst_q         <= FIdle;
      fslot_q       <= 1'b0;
      finfo_q       <= '0;
      fidx_q        <= '0;
      fword_q       <= '0;
      fw_q          <= '0;
      fmb_first_q   <= 1'b0;
      a1_c          <= '0;
      a1_nz         <= '0;
      a1_one        <= '0;
      a2_tc         <= '0;
      a2_oh0        <= '0;
      a2_m1         <= '0;
      a3_oh1        <= '0;
      a3_m2         <= '0;
      a1_kind       <= '0;
      a1_comp       <= 1'b0;
      a1_blk        <= '0;
      tcl_q         <= '0;
      tcc_q         <= '0;
      tcl_left_q    <= '0;
      tcl_top_q     <= '0;
      tcc_left_q    <= '0;
      tcc_top_q     <= '0;
      bb_valid_q    <= 1'b0;
      bb_c_q        <= '0;
      bb_nz_q       <= '0;
      bb_tc_q       <= '0;
      bb_t1_q       <= '0;
      bb_p0_q       <= '0;
      bb_tz_q       <= '0;
      bb_max_q      <= '0;
      bb_tab_q      <= '0;
      bb_signs_q    <= '0;
      bb_mb_first_q <= 1'b0;
      bb_mb_last_q  <= 1'b0;
      bb_info_q     <= '0;
    end else begin
      if (e_take) bb_valid_q <= 1'b0;
      unique case (fst_q)
        // wait for a committed macroblock (the line buffer read of its top
        // TotalCoeff runs in this state)
        FIdle: if (slot_full_i[fslot_q]) begin
          finfo_q     <= slot_info_i[fslot_q];
          fidx_q      <= '0;
          fword_q     <= '0;
          fmb_first_q <= 1'b1;
          tcl_q       <= '0;
          tcc_q       <= '0;
          fst_q       <= FTop;
        end
        FTop: begin
          tcl_top_q <= tclb_rdata[19:0];
          tcc_top_q <= tclb_rdata[39:20];
          fst_q     <= FRead;
        end
        // read the words of the block (data one cycle later)
        FRead: begin
          if (fword_q != '0) fw_q[2'(fword_q - 3'd1)] <= cf_rdata_i;
          if (fword_q == fnwords) begin
            fst_q <= FA1;
          end else begin
            fword_q <= fword_q + 3'd1;
          end
        end
        FA1: begin
          logic [15:0][15:0] r;     // raster
          logic [15:0][15:0] c;     // coding order
          for (int i = 0; i < 16; i++) r[i] = fw_q[i / 4][i % 4];
          for (int s = 0; s < 16; s++) begin
            unique case (fkind)
              KLdc:    c[s] = r[zz(s)];
              KCdc:    c[s] = (s < 4) ? fw_q[0][s % 4] : 16'd0;
              default: c[s] = (s < 15) ? r[zz(s + 1)] : 16'd0;
            endcase
            a1_nz[s]  <= (c[s] != '0);
            a1_one[s] <= (c[s] == 16'd1) || (c[s] == 16'hFFFF);
          end
          a1_c    <= c;
          a1_kind <= fkind;
          a1_comp <= fcomp;
          a1_blk  <= fblk;
          fst_q   <= FA2;
        end
        FA2: begin
          a2_tc  <= popcount16(a1_nz);
          a2_oh0 <= hsb(a1_nz);
          a2_m1  <= a1_nz & ~hsb(a1_nz);
          fst_q  <= FA3;
        end
        FA3: begin
          a3_oh1 <= hsb(a2_m1);
          a3_m2  <= a2_m1 & ~hsb(a2_m1);
          fst_q  <= FA4;
        end
        // TrailingOnes, nC, block buffer, update of the TotalCoeff map
        FA4: if (!bb_valid_q || e_take) begin
          logic [15:0] oh2;
          logic [4:0]  tc;
          logic [3:0]  p0;
          logic [1:0]  t1;
          logic [2:0]  sg;
          oh2 = hsb(a3_m2);
          tc  = a2_tc;
          p0  = index16(a2_oh0);
          t1  = 2'd0;
          if (tc >= 5'd1 && |(a2_oh0 & a1_one)) begin
            t1 = 2'd1;
            if (tc >= 5'd2 && |(a3_oh1 & a1_one)) begin
              t1 = 2'd2;
              if (tc >= 5'd3 && |(oh2 & a1_one)) t1 = 2'd3;
            end
          end
          sg = '0;
          for (int i = 0; i < 16; i++) begin
            if (a2_oh0[i]) sg[2] = a1_c[i][15];
            if (a3_oh1[i]) sg[1] = a1_c[i][15];
            if (oh2[i])    sg[0] = a1_c[i][15];
          end
          bb_valid_q    <= 1'b1;
          bb_c_q        <= a1_c;
          bb_nz_q       <= a1_nz;
          bb_tc_q       <= tc;
          bb_t1_q       <= t1;
          bb_p0_q       <= p0;
          bb_tz_q       <= (tc == '0) ? 4'd0 : 4'(5'(p0) + 5'd1 - tc);
          bb_max_q      <= (a1_kind == KLdc) ? 5'd16 : (a1_kind == KCdc) ? 5'd4 : 5'd15;
          bb_tab_q      <= a1_tab;
          bb_signs_q    <= sg;
          bb_mb_first_q <= fmb_first_q;
          bb_mb_last_q  <= (next_idx(fidx_q, finfo_q.cbp_luma, finfo_q.cbp_chroma) == 5'd27);
          bb_info_q     <= finfo_q;
          fmb_first_q   <= 1'b0;
          if (a1_kind == KLac) tcl_q[{a1_blk[3], a1_blk[1], a1_blk[2], a1_blk[0]}] <= tc;
          if (a1_kind == KCac) tcc_q[a1_comp][a1_blk[1:0]] <= tc;
          if (next_idx(fidx_q, finfo_q.cbp_luma, finfo_q.cbp_chroma) == 5'd27) begin
            fst_q <= FHold;
          end else begin
            fidx_q  <= next_idx(fidx_q, finfo_q.cbp_luma, finfo_q.cbp_chroma);
            fword_q <= '0;
            fst_q   <= FRead;
          end
        end
        // macroblock read: TotalCoeff to the line buffer / left column, next slot
        FHold: begin
          tcl_left_q    <= {tcl_q[15], tcl_q[11], tcl_q[7], tcl_q[3]};
          tcc_left_q[0] <= {tcc_q[0][3], tcc_q[0][1]};
          tcc_left_q[1] <= {tcc_q[1][3], tcc_q[1][1]};
          fslot_q       <= ~fslot_q;
          fst_q         <= FIdle;
        end
        default: fst_q <= FIdle;
      endcase
    end
  end

  assign f_mb_done   = (fst_q == FHold);
  assign tclb_we     = f_mb_done;
  assign tclb_wdata  = {tcc_q[1][3], tcc_q[1][2], tcc_q[0][3], tcc_q[0][2],
                        tcl_q[15], tcl_q[14], tcl_q[13], tcl_q[12]};
  assign slot_done_o = f_mb_done;
  assign slot_idx_o  = fslot_q;

  // ===================================================================== E
  typedef enum logic [3:0] {
    EIdle, ENal, ESh0, ESh1, ESh2, EMbh, ECt, ELv, ETz, ERb, ETrail
  } estate_e;

  // token requests (E1) -> codes (E2)
  typedef enum logic [2:0] {RRaw, RNal, RTrail, RCt, RLv, RTz, RRb} rkind_e;

  estate_e           est_q;
  logic [15:0][15:0] ec_q;
  logic [15:0]       emask_q;
  logic [4:0]        etc_q;
  logic [1:0]        et1_q;
  logic [3:0]        ep0_q, eprev_q;
  logic [3:0]        etz_q, ezl_q;
  logic [4:0]        emax_q;
  logic [2:0]        etab_q, esigns_q, esl_q;
  logic              efirst_lv_q, emb_last_q;
  mbinfo_t           einfo_q;

  logic              adv;           // the token pipeline moves
  logic              rq_valid_q;
  rkind_e            rq_kind_q;
  logic [5:0]        rq_len_q;
  logic [31:0]       rq_bits_q;     // raw bits / NAL header
  logic [2:0]        rq_tab_q;      // coeff_token: table, tc, t1, signs
  logic [4:0]        rq_tc_q;
  logic [1:0]        rq_t1_q;
  logic [2:0]        rq_signs_q;
  logic [15:0]       rq_lv_q;       // level, suffixLength, first after the trailing ones
  logic [2:0]        rq_sl_q;
  logic              rq_first_q;
  logic              rq_dc_q;       // total_zeros: chroma DC table
  logic [3:0]        rq_tz_q;
  logic [2:0]        rq_zl_q;       // run_before
  logic [3:0]        rq_run_q;
  logic              rq_seq_last_q;

  assign adv    = !tk_valid_o || tk_ready_i;
  assign e_take = adv && bb_valid_q &&
                  ((est_q == EIdle && !bb_mb_first_q) || est_q == EMbh);

  // next level / run position
  logic [3:0]  lv_pos, rb_pos;
  logic [15:0] lv_val;
  logic [11:0] lv_abs;
  logic [2:0]  sl_new;

  assign lv_pos = msb16(emask_q);
  assign rb_pos = msb16(emask_q);
  assign lv_val = ec_q[lv_pos];
  assign lv_abs = lv_val[15] ? 12'(-lv_val) : 12'(lv_val);

  always_comb begin
    logic [2:0] s;
    s = (esl_q == 3'd0) ? 3'd1 : esl_q;
    if (s < 3'd6 && 13'(lv_abs) > (13'd3 << (s - 3'd1))) s = s + 3'd1;
    sl_new = s;
  end

  // run before the coefficient at eprev_q, zeros left after it
  logic [3:0] run;
  assign run = eprev_q - rb_pos - 4'd1;

  logic [20:0] ue_mbt, ue_cm, se_qp;
  assign ue_mbt = ue_code(15'd1 + 15'(einfo_q.mode) + 15'(einfo_q.cbp_chroma) * 15'd4 +
                          (einfo_q.cbp_luma ? 15'd12 : 15'd0));
  assign ue_cm  = ue_code(15'(einfo_q.cmode));
  assign se_qp  = se_code(7'(signed'({1'b0, einfo_q.frame.qp})) - 7'sd26);

  // the block of the buffer starts in E (copy)
  task automatic start_block();
    ec_q        <= bb_c_q;
    emask_q     <= bb_nz_q;
    etc_q       <= bb_tc_q;
    et1_q       <= bb_t1_q;
    ep0_q       <= bb_p0_q;
    etz_q       <= bb_tz_q;
    emax_q      <= bb_max_q;
    etab_q      <= bb_tab_q;
    esigns_q    <= bb_signs_q;
    emb_last_q  <= bb_mb_last_q;
    einfo_q     <= bb_info_q;
  endtask

  logic [15:0] ec_nz;
  always_comb begin
    for (int s = 0; s < 16; s++) ec_nz[s] = (ec_q[s] != '0);
  end

  estate_e blk_end;
  assign blk_end = (emb_last_q && einfo_q.last) ? ETrail : EIdle;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      est_q         <= EIdle;
      ec_q          <= '0;
      emask_q       <= '0;
      etc_q         <= '0;
      et1_q         <= '0;
      ep0_q         <= '0;
      eprev_q       <= '0;
      etz_q         <= '0;
      ezl_q         <= '0;
      emax_q        <= '0;
      etab_q        <= '0;
      esigns_q      <= '0;
      esl_q         <= '0;
      efirst_lv_q   <= 1'b0;
      emb_last_q    <= 1'b0;
      einfo_q       <= '0;
      rq_valid_q    <= 1'b0;
      rq_kind_q     <= RRaw;
      rq_len_q      <= '0;
      rq_bits_q     <= '0;
      rq_tab_q      <= '0;
      rq_tc_q       <= '0;
      rq_t1_q       <= '0;
      rq_signs_q    <= '0;
      rq_lv_q       <= '0;
      rq_sl_q       <= '0;
      rq_first_q    <= 1'b0;
      rq_dc_q       <= 1'b0;
      rq_tz_q       <= '0;
      rq_zl_q       <= '0;
      rq_run_q      <= '0;
      rq_seq_last_q <= 1'b0;
    end else if (adv) begin
      rq_valid_q <= 1'b0;
      unique case (est_q)
        EIdle: if (bb_valid_q) begin
          einfo_q <= bb_info_q;
          if (bb_mb_first_q) begin
            est_q <= bb_info_q.first ? ENal : EMbh;
          end else begin
            start_block();
            est_q <= ECt;
          end
        end
        ENal: begin
          rq_valid_q <= 1'b1;
          rq_kind_q  <= RNal;
          rq_bits_q  <= 32'(NalHdrIdr);
          est_q      <= ESh0;
        end
        // first_mb_in_slice 0, slice_type 7, pic_parameter_set_id 0, frame_num 0
        ESh0: begin
          rq_valid_q <= 1'b1;
          rq_kind_q  <= RRaw;
          rq_len_q   <= 6'd13;
          rq_bits_q  <= 32'h1110;
          est_q      <= ESh1;
        end
        // idr_pic_id, no_output_of_prior_pics_flag 0, long_term_reference_flag 0
        ESh1: begin
          rq_valid_q <= 1'b1;
          rq_kind_q  <= RRaw;
          rq_len_q   <= einfo_q.frame.idr_id ? 6'd5 : 6'd3;
          rq_bits_q  <= einfo_q.frame.idr_id ? 32'b01000 : 32'b100;
          est_q      <= ESh2;
        end
        // slice_qp_delta, disable_deblocking_filter_idc (0 + two offsets 0, or 1)
        ESh2: begin
          rq_valid_q <= 1'b1;
          rq_kind_q  <= RRaw;
          rq_len_q   <= 6'(se_qp[20:16]) + 6'd3;
          rq_bits_q  <= {13'h0, se_qp[15:0], einfo_q.frame.deblock ? 3'b111 : 3'b010};
          est_q      <= EMbh;
        end
        // mb_type, intra_chroma_pred_mode, mb_qp_delta 0; the first block starts
        EMbh: if (bb_valid_q) begin
          rq_valid_q <= 1'b1;
          rq_kind_q  <= RRaw;
          rq_len_q   <= 6'(ue_mbt[20:16]) + 6'(ue_cm[20:16]) + 6'd1;
          rq_bits_q  <= (32'(ue_mbt[15:0]) << (ue_cm[20:16] + 5'd1)) |
                        (32'(ue_cm[15:0]) << 1) | 32'd1;
          start_block();
          est_q <= ECt;
        end
        // coeff_token + trailing_ones_sign_flags; the levels follow
        ECt: begin
          logic [15:0] m;
          rq_valid_q <= 1'b1;
          rq_kind_q  <= RCt;
          rq_tab_q   <= etab_q;
          rq_tc_q    <= etc_q;
          rq_t1_q    <= et1_q;
          rq_signs_q <= esigns_q;
          m = emask_q;
          for (int i = 0; i < 3; i++) begin
            if (2'(i) < et1_q) m = m & ~(16'd1 << msb16(m));
          end
          emask_q     <= m;
          esl_q       <= (etc_q > 5'd10 && et1_q < 2'd3) ? 3'd1 : 3'd0;
          efirst_lv_q <= (et1_q < 2'd3);
          if (etc_q == '0)            est_q <= blk_end;
          else if (m != '0)           est_q <= ELv;
          else if (etc_q < emax_q)    est_q <= ETz;
          else                        est_q <= blk_end;
        end
        // levels, highest frequency first
        ELv: begin
          rq_valid_q  <= 1'b1;
          rq_kind_q   <= RLv;
          rq_lv_q     <= lv_val;
          rq_sl_q     <= esl_q;
          rq_first_q  <= efirst_lv_q;
          efirst_lv_q <= 1'b0;
          esl_q       <= sl_new;
          emask_q     <= emask_q & ~(16'd1 << lv_pos);
          if ((emask_q & ~(16'd1 << lv_pos)) == '0) begin
            est_q <= (etc_q < emax_q) ? ETz : blk_end;
          end
        end
        // total_zeros; then run_before over the coefficients below p0
        ETz: begin
          rq_valid_q <= 1'b1;
          rq_kind_q  <= RTz;
          rq_dc_q    <= (emax_q == 5'd4);
          rq_tc_q    <= etc_q;
          rq_tz_q    <= etz_q;
          emask_q    <= ec_nz & ((16'd1 << ep0_q) - 16'd1);
          eprev_q    <= ep0_q;
          ezl_q      <= etz_q;
          est_q      <= ERb;
        end
        ERb: begin
          if (ezl_q == '0 || emask_q == '0) begin
            est_q <= blk_end;
          end else begin
            rq_valid_q <= 1'b1;
            rq_kind_q  <= RRb;
            rq_zl_q    <= (ezl_q > 4'd7) ? 3'd7 : 3'(ezl_q);
            rq_run_q   <= run;
            ezl_q      <= ezl_q - run;
            eprev_q    <= rb_pos;
            emask_q    <= emask_q & ~(16'd1 << rb_pos);
          end
        end
        ETrail: begin
          rq_valid_q    <= 1'b1;
          rq_kind_q     <= RTrail;
          rq_seq_last_q <= einfo_q.frame.seq_last;
          est_q         <= EIdle;
        end
        default: est_q <= EIdle;
      endcase
    end
  end

  // ========================================================= E2: the codes
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tk_valid_o    <= 1'b0;
      tk_kind_o     <= '0;
      tk_len_o      <= '0;
      tk_bits_o     <= '0;
      tk_seq_last_o <= 1'b0;
    end else if (adv) begin
      tk_valid_o    <= rq_valid_q;
      tk_kind_o     <= 2'd0;
      tk_seq_last_o <= rq_seq_last_q;
      unique case (rq_kind_q)
        RNal: begin
          tk_kind_o <= 2'd1;
          tk_len_o  <= 6'd8;
          tk_bits_o <= rq_bits_q;
        end
        RTrail: begin
          tk_kind_o <= 2'd2;
          tk_len_o  <= '0;
          tk_bits_o <= '0;
        end
        RCt: begin
          logic [20:0] ct;
          logic [2:0]  sg;
          ct = coeff_token(rq_tab_q, rq_tc_q, rq_t1_q);
          sg = rq_signs_q >> (2'd3 - rq_t1_q);
          tk_len_o  <= 6'(ct[20:16]) + 6'(rq_t1_q);
          tk_bits_o <= (32'(ct[15:0]) << rq_t1_q) | 32'(sg);
        end
        RLv: begin
          logic [12:0] code, sfx, mask;
          logic [11:0] mag;
          mag  = rq_lv_q[15] ? 12'(-rq_lv_q) : 12'(rq_lv_q);
          code = rq_lv_q[15] ? (13'(mag) * 13'd2 - 13'd1) : (13'(mag) * 13'd2 - 13'd2);
          if (rq_first_q) code = code - 13'd2;
          if (rq_sl_q == 3'd0) begin
            if (code < 13'd14) begin
              tk_len_o  <= 6'(code) + 6'd1;
              tk_bits_o <= 32'd1;
            end else if (code < 13'd30) begin
              sfx = code - 13'd14;
              tk_len_o  <= 6'd19;
              tk_bits_o <= 32'h10 | 32'(sfx);
            end else begin
              sfx = code - 13'd30;
              tk_len_o  <= 6'd28;
              tk_bits_o <= 32'h1000 | 32'(sfx);
            end
          end else if (code < (13'd15 << rq_sl_q)) begin
            mask = (13'd1 << rq_sl_q) - 13'd1;
            sfx  = code & mask;
            tk_len_o  <= 6'(code >> rq_sl_q) + 6'd1 + 6'(rq_sl_q);
            tk_bits_o <= (32'd1 << rq_sl_q) | 32'(sfx);
          end else begin
            sfx = code - (13'd15 << rq_sl_q);
            tk_len_o  <= 6'd28;
            tk_bits_o <= 32'h1000 | 32'(sfx);
          end
        end
        RTz: begin
          logic [12:0] t;
          t = total_zeros(rq_dc_q, rq_tc_q[3:0], rq_tz_q);
          tk_len_o  <= 6'(t[12:9]);
          tk_bits_o <= 32'(t[8:0]);
        end
        RRb: begin
          logic [14:0] t;
          t = run_before(rq_zl_q, rq_run_q);
          tk_len_o  <= 6'(t[14:11]);
          tk_bits_o <= 32'(t[10:0]);
        end
        default: begin
          tk_len_o  <= rq_len_q;
          tk_bits_o <= rq_bits_q;
        end
      endcase
    end
  end

  assign busy_o = (fst_q != FIdle) || bb_valid_q || (est_q != EIdle) || rq_valid_q || tk_valid_o;

  logic unused;
  assign unused = ^{emax_q[4:3], einfo_q};

endmodule
