// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// HyperRAM PHY, technology independent part (hr_clk domain, except the write
// side of the read FIFO in hr_rd_clk). docs/ip/hyperram.md, "PHY".
//
// Pins: pin_d_i is the pin intent that bow_hyperram_ctrl computes for
//   transaction cycle t in the cycle its counter is at t; this module
//   registers it (io_o = "PHY cycle", bow_hyperram_pkg contract), so the pins
//   show it two hr_clk cycles after the controller cycle. Reset (link reset)
//   = HR_IO_OUT_IDLE: CS# high at once, shifters isolated.
//
// Read stream: io_i is registered once on hr_rd_clk and pushed every hr_rd_clk
//   cycle into bow_fifo_async (Depth 16, {rwds fall, rwds rise, dq fall, dq
//   rise}); the hr side pops every cycle from the 5th cycle after empty_o is
//   first seen low (both clocks have the same frequency, so the latency stays
//   constant until the read phase moves by a whole period). The popped head
//   is registered into st_q: "stream cycle" = the cycle it is in st_q. A pop
//   while empty or a push while full: rfifo_err_o (pulse) and rfifo_broken_o
//   until rfifo_sync_i, which flushes both FIFO sides for 8 cycles (ORed into
//   their resets) and restarts.
//
// Read aligner (one read at a time; bow_hyperram_ctrl starts a read only when
// rd_busy_o = 0): arm_i (one pulse per read, with arm_n_i = words, 1..255)
//   is delayed by cfg.rd_dly cycles (stream delay, calibrated); then the
//   samples of each stream cycle are taken in time order (rise, fall):
//   Wait  : count consecutive RWDS = 0 samples (saturating at 2); a sample
//           with RWDS = 1 after at least two low ones is byte A of word 0 (a
//           high sample after fewer lows, e.g. the 2x latency indication of
//           the CA phase, restarts the count).
//   GetB  : RWDS = 0 -> byte B, the word {A, B} is out (rd_v_o); RWDS = 1 ->
//           strict: error ErrRwds; else that sample is a new byte A.
//   GetA  : RWDS = 1 -> byte A of the next word; RWDS = 0 -> strict: error
//           ErrRwds; else a stall (allowed by the HyperBus specification,
//           never done by the S80KS2562), waiting.
//   The first byte A must come within cfg.arm_lead + cfg.rd_tmo stream cycles
//   of the delayed arm, and (non-strict) every next word within 16 cycles:
//   else ErrRdTmo. After arm_n words, or an error: rd_done_o (one pulse, with
//   rd_err_o and rd_code_o). A read FIFO already broken when the read is
//   armed: ErrRfifo at once.
//   Arm early by up to arm_lead - 1 cycles or late by up to (arm_lead - 2)
//   cycles of a mis-set rd_dly still returns the right words; later than that
//   the stream shows a toggling RWDS without two low samples (strict) or no
//   start at all, and the read fails instead of returning shifted data.
//
// Raw capture: cap_arm_i (pulse) arms it, txn_start_i (the controller cycle
//   of t = 0 of the next transaction) starts it: 64 stream cycles from that
//   cycle into cap_o[0..63] = {rwds fall, rwds rise, dq fall[7:0], dq
//   rise[7:0]}; cap_done_o pulses when the 64th is in. Quasi-static outside a
//   capture. Capture index c of the first byte A of a read with first data
//   cycle t_D gives rd_dly = c - t_D.
//
// rwds_lvl_o: the RWDS pad level (asynchronous) through bow_sync (latency
// indication of the CA phase, taken by the controller at t = cfg.lat_smp).

module bow_hyperram_phy import bow_hyperram_pkg::*; (
  input  logic              clk_i,          // hr_clk
  input  logic              rst_ni,         // link reset, hr_clk side
  input  logic              rd_clk_i,       // hr_rd_clk
  input  logic              rd_rst_ni,      // link reset, hr_rd_clk side
  input  cfg_t              cfg_i,

  input  hr_io_out_t        pin_d_i,        // controller pin intent (registered here)
  input  logic              txn_start_i,    // controller at t = 0
  input  logic              arm_i,          // read: controller at t = t_D - arm_lead
  input  logic [7:0]        arm_n_i,        // read: words (1..255)
  output logic              rd_busy_o,      // a read is armed or running
  output logic              rd_v_o,         // one word
  output logic [7:0]        rd_a_o,         // byte A (first byte)
  output logic [7:0]        rd_b_o,         // byte B
  output logic              rd_done_o,      // the armed read finished (one pulse)
  output logic              rd_err_o,       // with rd_done_o
  output logic [7:0]        rd_code_o,      // with rd_done_o: ErrNone / ErrRdTmo / ErrRwds / ErrRfifo

  input  logic              rfifo_sync_i,   // one pulse
  output logic              rfifo_err_o,    // one pulse
  output logic              rfifo_broken_o, // level

  input  logic              cap_arm_i,      // one pulse
  output logic              cap_done_o,     // one pulse
  output logic [63:0][17:0] cap_o,

  output logic              rwds_lvl_o,     // synchronised RWDS pad level

  output hr_io_out_t        io_o,           // to the pad wrapper
  input  hr_io_in_t         io_i,           // hr_rd_clk domain
  input  logic              rwds_pad_i      // asynchronous
);

  localparam int unsigned FifoW = 18;    // {rwds f, rwds r, dq f, dq r}

  // =========================================================================
  // Pins
  // =========================================================================
  hr_io_out_t io_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      io_q <= HR_IO_OUT_IDLE;
    end else begin
      io_q <= pin_d_i;
    end
  end

  assign io_o = io_q;

  bow_sync u_rwds_sync (
    .clk_i,
    .rst_ni,
    .d_i    (rwds_pad_i),
    .q_o    (rwds_lvl_o)
  );

  // =========================================================================
  // Read FIFO (hr_rd_clk -> hr_clk)
  // =========================================================================
  logic [2:0] flush_cnt_q;
  logic       flush_q;      // RFIFO_SYNC flush, 8 cycles (a flop: reset source)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      flush_q     <= 1'b0;
      flush_cnt_q <= 3'd0;
    end else if (rfifo_sync_i) begin
      flush_q     <= 1'b1;
      flush_cnt_q <= 3'd7;
    end else if (flush_cnt_q != 3'd0) begin
      flush_cnt_q <= flush_cnt_q - 3'd1;
    end else begin
      flush_q <= 1'b0;
    end
  end

  // both FIFO sides reset by the link reset or the flush (asserted together),
  // each released synchronously to its own clock
  logic wrst_n, rrst_n;

  bow_rst_sync u_wrst (
    .clk_i  (rd_clk_i),
    .rst_ni (rd_rst_ni & ~flush_q),
    .rst_no (wrst_n)
  );

  bow_rst_sync u_rrst (
    .clk_i,
    .rst_ni (rst_ni & ~flush_q),
    .rst_no (rrst_n)
  );

  // ---- write side (hr_rd_clk): one register, push every cycle
  logic [FifoW-1:0] in_q;
  logic             rf_full, ovf_q;

  always_ff @(posedge rd_clk_i) begin
    in_q <= {io_i.rwds[1], io_i.rwds[0], io_i.dq[1], io_i.dq[0]};
  end

  always_ff @(posedge rd_clk_i or negedge wrst_n) begin
    if (!wrst_n) begin
      ovf_q <= 1'b0;
    end else if (rf_full) begin
      ovf_q <= 1'b1;        // pushed while full: the stream lost a cycle
    end
  end

  // ---- read side (hr_clk)
  logic             rf_empty, rf_pop, ovf_s;
  logic [FifoW-1:0] rf_rdata;

  bow_fifo_async #(
    .Width (FifoW),
    .Depth (16)
  ) u_rfifo (
    .wclk_i  (rd_clk_i),
    .wrst_ni (wrst_n),
    .push_i  (1'b1),
    .wdata_i (in_q),
    .full_o  (rf_full),
    .rclk_i  (clk_i),
    .rrst_ni (rrst_n),
    .pop_i   (rf_pop),
    .rdata_o (rf_rdata),
    .empty_o (rf_empty)
  );

  bow_sync u_ovf_sync (
    .clk_i,
    .rst_ni (rrst_n),
    .d_i    (ovf_q),
    .q_o    (ovf_s)
  );

  logic [2:0] strt_q;       // cycles since empty_o was first seen low
  logic       run_q, broken_q, rferr_q, rf_bad;

  assign rf_pop = run_q;
  assign rf_bad = (run_q && rf_empty) || ovf_s;

  always_ff @(posedge clk_i or negedge rrst_n) begin
    if (!rrst_n) begin
      strt_q   <= 3'd0;
      run_q    <= 1'b0;
      broken_q <= 1'b0;
      rferr_q  <= 1'b0;
    end else begin
      if (!run_q && (strt_q != 3'd0 || !rf_empty)) strt_q <= strt_q + 3'd1;
      if (!run_q && strt_q == 3'd3) run_q <= 1'b1;   // first pop: 5th cycle
      rferr_q <= rf_bad && !broken_q;
      if (rf_bad) broken_q <= 1'b1;
    end
  end

  assign rfifo_err_o    = rferr_q;
  assign rfifo_broken_o = broken_q;

  // the stream register takes the FIFO RAM read data (written in hr_rd_clk):
  // a flop for the CDC tools
  logic [FifoW-1:0] st_q;

  always_ff @(posedge clk_i) begin
    st_q <= rf_rdata;
  end

  logic [7:0] st_dr, st_df;
  logic       st_wr, st_wf;
  assign {st_wf, st_wr, st_df, st_dr} = st_q;

  // =========================================================================
  // Read aligner
  // =========================================================================
  typedef enum logic [1:0] {
    AIdle,
    AWait,     // armed: two low RWDS samples, then the first byte A
    AGetB,     // byte A in a_q, waiting for byte B
    AGetA      // waiting for the next byte A
  } astate_e;

  // arm delay line: arm_go = arm_i delayed by cfg.rd_dly (0..31) cycles
  logic [30:0] arm_sr_q;
  logic        arm_go;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      arm_sr_q <= '0;
    end else begin
      arm_sr_q <= {arm_sr_q[29:0], arm_i};
    end
  end

  assign arm_go = (cfg_i.rd_dly == 5'd0) ? arm_i : arm_sr_q[cfg_i.rd_dly - 5'd1];

  astate_e    ast_q;
  logic [1:0] low_q;        // consecutive low RWDS samples (Wait)
  logic [7:0] a_q;          // byte A of the word in progress
  logic [7:0] need_q;       // words still expected
  logic [7:0] tmo_q;        // cycles without progress
  logic       pend_q;       // armed, the delayed token not yet arrived
  logic [7:0] n_pend_q;

  // one sample step
  typedef struct packed {
    astate_e    st;
    logic [1:0] low;
    logic [7:0] a;
    logic       word;      // a word completed in this step
    logic [7:0] wa, wb;
    logic       err;
  } astep_t;

  function automatic astep_t step(astep_t s, logic rw, logic [7:0] d, logic strict);
    astep_t r;
    r      = s;
    r.word = 1'b0;
    unique case (s.st)
      AWait: begin
        if (!rw) begin
          r.low = (s.low == 2'd2) ? 2'd2 : s.low + 2'd1;
        end else if (s.low == 2'd2) begin
          r.a  = d;
          r.st = AGetB;
        end else begin
          r.low = 2'd0;
        end
      end
      AGetB: begin
        if (!rw) begin
          r.word = 1'b1;
          r.wa   = s.a;
          r.wb   = d;
          r.st   = AGetA;
        end else if (strict) begin
          r.err = 1'b1;
        end else begin
          r.a = d;
        end
      end
      AGetA: begin
        if (rw) begin
          r.a  = d;
          r.st = AGetB;
        end else if (strict) begin
          r.err = 1'b1;
        end
      end
      default: ;
    endcase
    return r;
  endfunction

  astep_t s0, s1, s2;
  logic   active;

  assign active = (ast_q != AIdle);

  always_comb begin
    s0     = '{st: ast_q, low: low_q, a: a_q, word: 1'b0, wa: '0, wb: '0, err: 1'b0};
    s1     = step(s0, st_wr, st_dr, cfg_i.strict);
    // a word completed by the rise sample is reported, the fall sample may
    // only start the next one (one word per cycle at most); after the last
    // word (or an error) the fall sample is not looked at
    s2     = (s1.err || (s1.word && need_q == 8'd1)) ? s1 : step(s1, st_wf, st_df, cfg_i.strict);
    s2.word = s1.word || s2.word;
    if (s1.word) begin
      s2.wa = s1.wa;
      s2.wb = s1.wb;
    end
  end

  logic       rd_v_q, done_q, err_q;
  logic [7:0] ra_q, rb_q, code_q;
  logic [7:0] tmo_lim;

  // first byte A: arm_lead + rd_tmo cycles; next words (non-strict): 16
  assign tmo_lim = (ast_q == AWait) ? 8'(cfg_i.arm_lead) + 8'(cfg_i.rd_tmo) : 8'd16;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ast_q    <= AIdle;
      low_q    <= 2'd0;
      a_q      <= '0;
      need_q   <= '0;
      tmo_q    <= '0;
      pend_q   <= 1'b0;
      n_pend_q <= '0;
      rd_v_q   <= 1'b0;
      ra_q     <= '0;
      rb_q     <= '0;
      done_q   <= 1'b0;
      err_q    <= 1'b0;
      code_q   <= ErrNone;
    end else begin
      rd_v_q <= 1'b0;
      done_q <= 1'b0;
      err_q  <= 1'b0;
      if (arm_i) begin
        pend_q   <= 1'b1;
        n_pend_q <= (arm_n_i == 8'd0) ? 8'd1 : arm_n_i;
      end
      if (arm_go) begin
        pend_q <= 1'b0;
        if (broken_q) begin
          done_q <= 1'b1;
          err_q  <= 1'b1;
          code_q <= ErrRfifo;
          ast_q  <= AIdle;
        end else begin
          ast_q  <= AWait;
          low_q  <= 2'd0;
          need_q <= arm_i ? ((arm_n_i == 8'd0) ? 8'd1 : arm_n_i) : n_pend_q;
          tmo_q  <= '0;
        end
      end else if (active) begin
        ast_q <= s2.st;
        low_q <= s2.low;
        a_q   <= s2.a;
        if (s2.err) begin
          ast_q  <= AIdle;
          done_q <= 1'b1;
          err_q  <= 1'b1;
          code_q <= ErrRwds;
        end else if (s2.word) begin
          rd_v_q <= 1'b1;
          ra_q   <= s2.wa;
          rb_q   <= s2.wb;
          tmo_q  <= '0;
          need_q <= need_q - 8'd1;
          if (need_q == 8'd1) begin
            ast_q  <= AIdle;
            done_q <= 1'b1;
            code_q <= ErrNone;
          end
        end else if (tmo_q == tmo_lim) begin
          ast_q  <= AIdle;
          done_q <= 1'b1;
          err_q  <= 1'b1;
          code_q <= ErrRdTmo;
        end else begin
          tmo_q <= tmo_q + 8'd1;
        end
      end
    end
  end

  assign rd_busy_o = active || pend_q || (arm_sr_q != '0) || arm_i;
  assign rd_v_o    = rd_v_q;
  assign rd_a_o    = ra_q;
  assign rd_b_o    = rb_q;
  assign rd_done_o = done_q;
  assign rd_err_o  = err_q;
  assign rd_code_o = code_q;

  // =========================================================================
  // Raw capture: 64 stream cycles from the controller cycle of t = 0
  // =========================================================================
  logic       cap_pend_q, cap_act_q, cap_done_q;
  logic [5:0] cap_idx_q;
  logic [63:0][FifoW-1:0] cap_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cap_pend_q <= 1'b0;
      cap_act_q  <= 1'b0;
      cap_idx_q  <= '0;
      cap_done_q <= 1'b0;
    end else begin
      cap_done_q <= 1'b0;
      if (cap_arm_i) begin
        cap_pend_q <= 1'b1;
      end else if (cap_pend_q && txn_start_i) begin
        cap_pend_q <= 1'b0;
        cap_act_q  <= 1'b1;
        cap_idx_q  <= 6'd1;
      end else if (cap_act_q) begin
        cap_idx_q <= cap_idx_q + 6'd1;
        if (cap_idx_q == 6'd63) begin
          cap_act_q  <= 1'b0;
          cap_done_q <= 1'b1;
        end
      end
    end
  end

  logic cap_first;
  assign cap_first = cap_pend_q && txn_start_i && !cap_arm_i;

  // capture words: no reset (quasi-static data for the register block)
  always_ff @(posedge clk_i) begin
    for (int unsigned i = 0; i < 64; i++) begin
      if ((cap_first && i == 0) || (cap_act_q && cap_idx_q == 6'(i))) cap_q[i] <= st_q;
    end
  end

  assign cap_done_o = cap_done_q;
  assign cap_o      = cap_q;

  // the PHY uses strict, arm_lead, rd_tmo and rd_dly of the configuration
  logic unused;
  assign unused = ^cfg_i;

endmodule
