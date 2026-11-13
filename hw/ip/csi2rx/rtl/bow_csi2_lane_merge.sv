// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 lane merge: turns the aligned bytes of the active data lanes back into the byte
// stream of the transmitter (byte n * k + l on lane l with n = 1, 2 or 4 active lanes, the
// lowest ones), marks the HS bursts and hands the stream to the controller's continuous
// clock (csi_clk_i) through a two clock FIFO (step 7 of docs/ip/mipi_rx_arch.md, section 10:
// everything after this block runs on csi_clk_i, nothing there waits for a byte clock).
//
// Byte clock domain (clk_i = RxByteClkHS, which stops between bursts):
// * A burst starts when the arm (RxActiveHS) of an active lane rises and ends when all
//   active lanes are out of HS again: exactly one end of burst per burst, also for a burst
//   without data. Unlocks, re-locks and sync errors inside a burst do not end it.
// * Every active lane has a FIFO of 8 bytes, written from its sot. The merged output starts
//   when all active lane FIFOs hold a byte, then pops one byte per lane per cycle (lockstep):
//   up to 6 byte clocks between the first bytes of the lanes are absorbed (e.g. 4 bytes of
//   lane skew plus different PHY FIFO latencies). The lanes may deliver their bytes with
//   gaps (PHY valid): the output then has gaps too. sop comes with the first word.
// * Skew error (at the end of the burst): some but not all active lanes locked, or a lane
//   FIFO overflowed before the output started (7 or more byte clocks between the first
//   bytes of the lanes: the earliest lane pushes its 9th byte in the cycle the latest lane's
//   first byte would allow the first pop). Such a burst produces no words: the overflow
//   also blocks the pop of its own cycle.
// * Every cycle with a word, the end of a burst or an event of the PPI that must stay in
//   order with the stream (ev_sot_i: ErrSotSyncHS of each lane, ev_dsk_i: a deskew burst,
//   as bow_csi2rx gated them) writes one entry {word valid, sop, eob, skew, events, word}
//   into the two clock FIFO (u_cdc_fifo, bow_fifo_async, gray pointers). A word never comes
//   with the end of its burst. The end of a burst is in the FIFO two byte clock edges after
//   the edge at which the last active RxActiveHS fell (the edge that registers it, the one
//   that writes it), together with an ErrSotSyncHS of the cycle after the fall (the D-PHY
//   of Bow32); a word three edges after the edge that delivered its last byte. That is all
//   the byte clock this block needs after a burst: if it stops earlier, the rest comes with
//   its next edges (the next burst, before its first word).
//
// Controller clock domain (csi_clk_i, continuous): the FIFO is read whenever it holds an
// entry (one per cycle, nothing after it has backpressure); the outputs are flops: a word
// (valid_o, data_o, sop_o), the end of a burst (eob_o, ev_skew_o), the events (ev_sot_o,
// ev_dsk_o). The output never has valid_o and eob_o in the same cycle.
//
// FIFO depth and the clock rule: the controller takes one entry per csi_clk_i cycle, the
// lane merge writes at most one per byte clock, so csi_clk_i must be at least the highest
// byte clock (bow_csi2rx checks PpiByteClkHz <= its clock at elaboration). Then the FIFO
// only holds the entries on their way through the two pointer synchronisers: from a write
// to the writer seeing its slot free again takes at most 1 write cycle (gray write
// pointer), 3 read cycles (synchroniser, the pop) and 3 write cycles (synchroniser), 7 byte
// clocks at a ratio of 1, 9 when every synchroniser bit resolves a cycle late: CdcDepth 16
// leaves 6 entries for a csi_clk_i a little slower than the byte clock (e.g. the ppm of two
// oscillators: 6 entries in the longest packet, 65 541 bytes in 16 386 words of 4 lanes, is
// 366 ppm). Should the controller still fall behind (a csi_clk_i below the byte clock), a word
// is only written into two free slots or more, so the end of the burst always finds one;
// a dropped word makes the burst a skew error (ERR_STATUS.SKEW, lost before the packet
// layer), the words already written go on as a cut packet.

module bow_csi2_lane_merge import bow_csi2rx_pkg::*; #(
  parameter int unsigned Lanes    = 2,    // 1, 2 or 4
  parameter int unsigned CdcDepth = 16    // entries of the two clock FIFO, power of two
) (
  // byte clock domain
  input  logic                  clk_i,        // RxByteClkHS
  input  logic                  rst_ni,       // byte clock, datapath reset
  input  logic                  lanes2_i,     // CTRL.LANES: 2 active lanes (ignored if Lanes = 1)
  input  logic                  lanes4_i,     // CTRL.LANES4: 4 active lanes (only if Lanes = 4)
  input  logic [Lanes-1:0]      arm_i,        // RxActiveHS
  input  logic [Lanes-1:0]      valid_i,      // RxValidHS
  input  logic [Lanes-1:0][7:0] data_i,       // RxDataHS
  input  logic [Lanes-1:0]      sot_i,        // RxSyncHS
  input  logic [Lanes-1:0]      ev_sot_i,     // in order with the stream: ErrSotSyncHS per lane
  input  logic                  ev_dsk_i,     //   a deskew burst

  // controller clock domain
  input  logic                  csi_clk_i,
  input  logic                  csi_rst_ni,   // csi clock, datapath reset (the source of rst_ni)
  output logic                  valid_o,
  output logic [Lanes-1:0][7:0] data_o,       // byte k of the word on [k], lane 0 in [7:0]
  output logic                  sop_o,
  output logic                  eob_o,
  output logic                  ev_skew_o,    // with eob_o
  output logic [Lanes-1:0]      ev_sot_o,
  output logic                  ev_dsk_o
);

  if ((CdcDepth < 8) || ((1 << $clog2(CdcDepth)) != CdcDepth)) begin : g_bad_depth
    $error("bow_csi2_lane_merge: CdcDepth must be a power of two >= 8, not %0d", CdcDepth);
  end

  // =========================================================================
  // Byte clock domain: lane FIFOs, burst marking
  // =========================================================================
  logic [Lanes-1:0]      act, arm_q, sot_q, push, full, empty;
  logic [Lanes-1:0][7:0] head, word;
  logic [2:0]            nact;
  logic                  in_burst_q, started_q, ovf_q;
  logic                  rise, all_low, eob, all_ne, pop, ovf, skew;
  logic                  m_valid_q, m_sop_q, m_eob_q, m_skew_q;
  logic [Lanes-1:0][7:0] m_data_q;

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
      m_valid_q  <= 1'b0;
      m_data_q   <= '0;
      m_sop_q    <= 1'b0;
      m_eob_q    <= 1'b0;
      m_skew_q   <= 1'b0;
    end else begin
      arm_q     <= arm_i;
      m_valid_q <= pop;
      m_sop_q   <= pop && !started_q;
      m_eob_q   <= eob;
      m_skew_q  <= eob && skew;
      if (pop) m_data_q <= word;

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

  // =========================================================================
  // Two clock FIFO: byte clock -> csi_clk_i
  // =========================================================================
  // entry: {valid, sop, eob, skew, sot per lane, deskew, word}
  localparam int unsigned EntryW = 4 + Lanes + 1 + 8 * Lanes;

  logic                  f_full, f_afull, f_empty, f_push, f_word, lost_q;
  logic [EntryW-1:0]     f_wdata, f_rdata;
  logic                  r_valid, r_sop, r_eob, r_skew, r_dsk;
  logic [Lanes-1:0]      r_sot;
  logic [Lanes-1:0][7:0] r_data;

  // a word only into two free slots or more (the end of its burst always finds one); a word
  // dropped there makes its burst a skew error (lost_q, until the end of the burst is written)
  assign f_word  = m_valid_q && !f_afull;
  assign f_push  = f_word || m_eob_q || (ev_sot_i != '0) || ev_dsk_i;
  assign f_wdata = {f_word, m_sop_q && f_word, m_eob_q, m_eob_q && (m_skew_q || lost_q), ev_sot_i,
                    ev_dsk_i, m_data_q};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)                     lost_q <= 1'b0;
    else if (m_valid_q && f_afull)   lost_q <= 1'b1;
    else if (m_eob_q && !f_full)     lost_q <= 1'b0;
  end

  bow_fifo_async #(
    .Width (EntryW),
    .Depth (CdcDepth)
  ) u_cdc_fifo (
    .wclk_i  (clk_i),
    .wrst_ni (rst_ni),
    .push_i  (f_push),
    .wdata_i (f_wdata),
    .full_o  (f_full),
    .afull_o (f_afull),
    .rclk_i  (csi_clk_i),
    .rrst_ni (csi_rst_ni),
    .pop_i   (!f_empty),
    .rdata_o (f_rdata),
    .empty_o (f_empty)
  );

  assign {r_valid, r_sop, r_eob, r_skew, r_sot, r_dsk, r_data} = f_rdata;

  // =========================================================================
  // Controller clock domain: output flops
  // =========================================================================
  always_ff @(posedge csi_clk_i or negedge csi_rst_ni) begin
    if (!csi_rst_ni) begin
      valid_o   <= 1'b0;
      data_o    <= '0;
      sop_o     <= 1'b0;
      eob_o     <= 1'b0;
      ev_skew_o <= 1'b0;
      ev_sot_o  <= '0;
      ev_dsk_o  <= 1'b0;
    end else begin
      valid_o   <= !f_empty && r_valid;
      sop_o     <= !f_empty && r_sop;
      eob_o     <= !f_empty && r_eob;
      ev_skew_o <= !f_empty && r_skew;
      ev_sot_o  <= f_empty ? '0 : r_sot;
      ev_dsk_o  <= !f_empty && r_dsk;
      if (!f_empty && r_valid) data_o <= r_data;
    end
  end

endmodule
