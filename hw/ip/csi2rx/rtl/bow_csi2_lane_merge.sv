// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 lane merge (byte clock domain): turns the aligned bytes of the
// active data lanes back into the byte stream of the transmitter (byte
// n * k + l on lane l with n = 1, 2 or 4 active lanes, the lowest ones) and
// marks the HS bursts.
//
// * A burst starts when the arm (synchronised hs_active) of an active lane
//   rises and ends when all active lanes are out of HS again: exactly one
//   eob_o pulse per burst, also for a burst without data. With a
//   non-continuous clock the byte clock may stop before the end of the burst
//   reaches this domain; eob_o then comes when the clock runs again for the
//   next burst (well before its first byte). Unlocks, re-locks and sync
//   errors inside a burst do not end it.
// * Every active lane has a FIFO of 8 bytes, written from its sot. The output
//   starts when all active lane FIFOs hold a byte, then pops one byte per
//   lane per cycle (lockstep): up to 6 byte clocks between the first bytes
//   of the lanes are absorbed (e.g. 4 bytes of lane skew plus different PHY
//   FIFO latencies). The lanes may deliver their bytes with gaps (PHY valid):
//   the output then has gaps too. sop_o comes with the first output word of
//   the burst.
// * Skew error (ev_skew_o, at eob): some but not all active lanes locked, or a
//   lane FIFO overflowed before the output started (7 or more byte clocks
//   between the first bytes of the lanes: the earliest lane pushes its 9th
//   byte in the cycle the latest lane's first byte would allow the first
//   pop). Such a burst produces no output: the overflow also blocks the pop
//   of its own cycle.
// The output never has valid_o and eob_o in the same cycle.

module bow_csi2_lane_merge import bow_csi2rx_pkg::*; #(
  parameter int unsigned Lanes = 2    // 1, 2 or 4
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,       // byte clock, datapath reset
  input  logic                  lanes2_i,     // CTRL.LANES: 2 active lanes (ignored if Lanes = 1)
  input  logic                  lanes4_i,     // CTRL.LANES4: 4 active lanes (only if Lanes = 4)
  input  logic [Lanes-1:0]      arm_i,
  input  logic [Lanes-1:0]      valid_i,      // from bow_dphy_align
  input  logic [Lanes-1:0][7:0] data_i,
  input  logic [Lanes-1:0]      sot_i,
  output logic                  valid_o,
  output logic [Lanes-1:0][7:0] data_o,       // byte k of the word on [k], lane 0 in [7:0]
  output logic [2:0]            nbytes_o,     // bytes in data_o (the lowest): 1, 2 or 4
  output logic                  sop_o,
  output logic                  eob_o,
  output logic                  ev_skew_o
);

  logic [Lanes-1:0]      act, arm_q, sot_q, push, full, empty;
  logic [Lanes-1:0][7:0] head, word;
  logic [2:0]            nact;
  logic                  in_burst_q, started_q, ovf_q;
  logic                  rise, all_low, eob, all_ne, pop, ovf, skew;

  assign nact = active_lanes(Lanes, lanes2_i, lanes4_i);

  for (genvar l = 0; l < Lanes; l++) begin : g_act
    assign act[l]  = (l < 32'(nact));
    assign word[l] = act[l] ? head[l] : 8'h00;
  end

  assign rise    = |(arm_i & ~arm_q & act);
  assign all_low = ~|(arm_i & act);
  assign eob     = in_burst_q && all_low;
  assign all_ne  = &(~empty | ~act);
  // (ovf does not depend on pop: push, full and started_q only)
  assign pop     = in_burst_q && !all_low && !ovf_q && !ovf && all_ne;
  assign ovf     = |(push & full) && !started_q;
  assign skew    = (((sot_q & act) != '0) && ((sot_q | ~act) != '1)) || ovf_q;

  for (genvar l = 0; l < Lanes; l++) begin : g_lane
    assign push[l] = act[l] && in_burst_q && valid_i[l] && (sot_q[l] || sot_i[l]);

    bow_fifo_sync #(
      .Width (8),
      .Depth (8)
    ) u_fifo (
      .clk_i,
      .rst_ni,
      .clr_i   (eob),
      .push_i  (push[l]),
      .wdata_i (data_i[l]),
      .pop_i   (pop),
      .rdata_o (head[l]),
      .full_o  (full[l]),
      .empty_o (empty[l]),
      .level_o ()
    );
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      arm_q      <= '1;          // no burst start before arm was seen low
      in_burst_q <= 1'b0;
      started_q  <= 1'b0;
      ovf_q      <= 1'b0;
      sot_q      <= '0;
      valid_o    <= 1'b0;
      data_o     <= '0;
      nbytes_o   <= 3'd1;
      sop_o      <= 1'b0;
      eob_o      <= 1'b0;
      ev_skew_o  <= 1'b0;
    end else begin
      arm_q     <= arm_i;
      valid_o   <= pop;
      sop_o     <= pop && !started_q;
      eob_o     <= eob;
      ev_skew_o <= eob && skew;
      nbytes_o  <= nact;
      if (pop) data_o <= word;

      if (eob) begin
        in_burst_q <= 1'b0;
        started_q  <= 1'b0;
        ovf_q      <= 1'b0;
        sot_q      <= '0;
      end else begin
        if (rise) in_burst_q <= 1'b1;
        if (pop)  started_q  <= 1'b1;
        if (ovf)  ovf_q      <= 1'b1;
        sot_q <= sot_q | (sot_i & act & {Lanes{in_burst_q}});
      end
    end
  end

endmodule
