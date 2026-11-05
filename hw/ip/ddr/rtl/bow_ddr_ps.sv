// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// MMCM fine phase-shift stepper of the DDR IP (ddr_clk domain, which is also
// the PSCLK of the MMCMs). bow_ddr_dfi has two: the read phase
// (rd_clk, ddr_ps_*) and the write phase (wclk / wclk90, ddr_wps_*).
//
// go_i takes target_i (signed fine steps) and ref_i:
//   * |target_i - ref_i| > Limit: refused, done_o + err_o, no step (read
//     phase: ref_i = phase at the last RFIFO_SYNC, Limit = 2 * PsSteps, the
//     read FIFO occupancy moves by one entry per CK period of shift; write
//     phase: ref_i = 0, Limit = PsSteps / 4: static timing of the pad
//     wrapper covers the PHY -> ODDR paths for +-T/4 only);
//   * target_i == now_o: done_o at once;
//   * otherwise one PSEN at a time (MMCME4: a one-cycle pulse, PSINCDEC =
//     target > now, sampled together with PSEN), then wait for PSDONE. PSDONE
//     is accepted only in the wait state, from the cycle after PSEN (the MMCM
//     answers 12 PSCLK cycles after PSEN); a PSDONE at any other time is
//     ignored. Every accepted PSDONE moves now_o by one step; the next PSEN
//     follows in the next cycle until now_o = target.
//   * no PSDONE within Timeout cycles after a PSEN: stop, done_o + err_o;
//     now_o keeps the steps that were acknowledged.
// now_o resets to 0 with rst_ni, which must be the reset of the MMCM phase
// itself (bow_ddr_dfi: ddr_rst_ni only, the MMCMs lost lock or were reset):
// a SoC reset leaves the MMCM phases where they are, so the steppers keep
// counting through it (and finish a move that was running). go_i while busy_o
// is ignored (bow_ddr_dfi waits for both steppers to be idle).

module bow_ddr_ps #(
  parameter int unsigned Limit   = 1008,
  parameter int unsigned Timeout = 64
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        go_i,         // one-cycle pulse
  input  logic [15:0] target_i,     // signed
  input  logic [15:0] ref_i,        // signed
  output logic        busy_o,
  output logic        done_o,       // one-cycle pulse: finished or refused
  output logic        err_o,        // with done_o: refused or no PSDONE
  output logic [15:0] now_o,        // signed current phase
  output logic        ps_en_o,      // MMCM PSEN
  output logic        ps_inc_o,     // MMCM PSINCDEC (1 = increment)
  input  logic        ps_done_i     // MMCM PSDONE
);

  localparam int unsigned TW = $clog2(Timeout + 1);

  logic          run_q, en_q, inc_q, done_q, err_q;
  logic [15:0]   now_q, tgt_q, now_n;
  logic [TW-1:0] tmr_q;              // cycles since the last PSEN

  // distance of the request from the reference phase (17 bits, no overflow)
  logic signed [16:0] diff;
  logic        [16:0] adiff;
  assign diff  = $signed({target_i[15], target_i}) - $signed({ref_i[15], ref_i});
  assign adiff = diff[16] ? 17'(-diff) : 17'(diff);

  assign now_n = inc_q ? now_q + 16'd1 : now_q - 16'd1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      run_q  <= 1'b0;
      en_q   <= 1'b0;
      inc_q  <= 1'b0;
      done_q <= 1'b0;
      err_q  <= 1'b0;
      now_q  <= '0;
      tgt_q  <= '0;
      tmr_q  <= '0;
    end else begin
      done_q <= 1'b0;
      err_q  <= 1'b0;
      en_q   <= 1'b0;
      if (!run_q) begin
        if (go_i) begin
          if (adiff > 17'(Limit)) begin
            done_q <= 1'b1;
            err_q  <= 1'b1;
          end else if (target_i == now_q) begin
            done_q <= 1'b1;
          end else begin
            run_q <= 1'b1;
            tgt_q <= target_i;
            en_q  <= 1'b1;
            inc_q <= $signed(target_i) > $signed(now_q);
            tmr_q <= '0;
          end
        end
      end else if (en_q) begin
        // the PSEN cycle: PSDONE is not looked at yet
        tmr_q <= TW'(1);
      end else if (ps_done_i) begin
        now_q <= now_n;
        if (now_n == tgt_q) begin
          run_q  <= 1'b0;
          done_q <= 1'b1;
        end else begin
          en_q  <= 1'b1;
          inc_q <= $signed(tgt_q) > $signed(now_n);
          tmr_q <= '0;
        end
      end else if (tmr_q == TW'(Timeout)) begin
        run_q  <= 1'b0;
        done_q <= 1'b1;
        err_q  <= 1'b1;
      end else begin
        tmr_q <= tmr_q + TW'(1);
      end
    end
  end

  assign busy_o   = run_q;
  assign done_o   = done_q;
  assign err_o    = err_q;
  assign now_o    = now_q;
  assign ps_en_o  = en_q;
  assign ps_inc_o = inc_q;

endmodule
