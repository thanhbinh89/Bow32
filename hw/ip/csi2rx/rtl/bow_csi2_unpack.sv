// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 pixel unpacker (the controller's clock csi_clk; the byte clock domain up to step 6
// of docs/ip/mipi_rx_arch.md): payload bytes of the accepted
// lines -> groups of up to 4 pixels for the pixel FIFO.
//
//   RAW10: 5 bytes -> 4 pixels, P_i = {B_i, B4[2i+1:2i]}
//   RAW8:  4 bytes -> 4 pixels, P_i = {B_i, 2'b00}
//
// Group (FIFO entry, bow_csi2rx_pkg::GroupW bits):
//   [44] err  with eol: the line is bad (CRC / format error, truncated, cut
//             by a FIFO overflow) or a line of the frame was lost before it
//             (see Lost and drop_i below)
//   [43] sof  first group of the first line of a frame (FS .. first group)
//   [42] eol  last group of a line (normal end or truncation)
//   [41:40]   number of pixels - 1
//   [39:0]    px3 .. px0, px0 in [9:0] (first pixel)
// Up to 4 bytes per cycle (Bytes = 4: RAW10 0.8 groups, RAW8 1 group per
// cycle on average) still form at most one group per cycle: fewer than g
// bytes (5 or 4) wait in the buffer, so at most g - 1 + 4 bytes are there.
// A RAW8 line with WC % 4 != 0 ends with a partial group; leftover RAW10
// bytes (WC % 5 != 0) are dropped. The last formed group is held back one
// step so that eol lands on the real last group: when a line ends, the last
// group is pushed in the cycle of eol_i, or one cycle later if eol_i also
// formed a partial group.
//
// FIFO overflow keeps the line structure of the output: a group that is not
// the last of its line is only written while the FIFO has 2 free slots
// (!afull_i), so the eol group of a line that has started always finds one
// (one push per cycle at most, whatever Bytes).
//   Ok    groups are written
//   Cut   a group found the FIFO almost full: the rest of the line is
//         dropped except its eol group (err set): a short line with tlast
//   Lost  the FIFO was full: the whole line is dropped, its eol group too;
//         the next line of the frame that reaches the FIFO has err set
//         (so does the line after an accepted line without any group)
// Every group dropped by the FIFO sets ovf_o (cleared at the next sol_i).
//
// drop_i: a burst of the frame was lost before this layer (uncorrectable
// header, sync error, lane skew, a packet cut in its header or a dropped
// packet cut short, packets after EXTRA, an HS entry refused at the LP
// level): the next line of the frame that reaches the FIFO has err set, as
// after a Lost line.
//
// A frame is only output from its first line on: sof is never moved to
// another group. If the sof group cannot be written (FIFO), the first
// accepted line has no pixel group, or a burst of the frame is lost before
// its first group was formed (drop_i), the rest of the frame is skipped: no
// groups until the next FS or FE, skip_o pulses once (ERR_STATUS.SKIP).
// Skipped groups do not set ovf_o. So a consumer sees each frame either
// from its pixel (0, 0) or not at all.
// FS and FE clear the frame state (sof pending, lost line, skip), and only
// lines inside a frame (FS .. FE) set the lost-line flag: lines outside a
// frame never carry sof or a lost-line err.
// The frame sum adds up all pixels pushed into the FIFO from FS to FE.

module bow_csi2_unpack import bow_csi2rx_pkg::*; #(
  parameter int unsigned Bytes = 2      // bytes per cycle at most: 1, 2 or 4
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,     // csi clock, datapath reset
  input  logic                  sol_i,      // an accepted line starts (no bytes in this cycle)
  input  logic                  raw10_i,    // 1: RAW10, 0: RAW8 (static during a line)
  input  logic [Bytes-1:0]      valid_i,    // payload bytes ([k] only with [k-1])
  input  logic [Bytes-1:0][7:0] data_i,
  input  logic                  eol_i,      // end of the line (no bytes in this cycle)
  input  logic                  err_i,      // with eol_i: CRC / format error, truncated
  input  logic                  fs_i,
  input  logic                  fe_i,       // FE that completes a frame
  input  logic                  drop_i,     // a burst of the frame was lost (see the header)

  output logic                  push_o,
  output logic [GroupW-1:0]     group_o,
  input  logic                  full_i,
  input  logic                  afull_i,    // at most one free slot

  output logic                  ovf_o,
  output logic                  skip_o,     // pulse: the rest of the frame is skipped
  output logic [31:0]           frame_sum_o // sum of the last complete frame
);

  logic [4:0][7:0] buf_q;     // bytes of the group being formed
  logic [2:0]      n_q;       // number of bytes in buf_q (< g)
  logic            hold_v_q, hold_last_q, hold_sof_q;
  logic [1:0]      hold_cnt_q;
  logic [3:0][9:0] hold_px_q;
  logic [11:0]     hold_sum_q;
  logic            sof_pend_q, ovf_q, lost_q, eerr_q, skip_q, skip_set, inf_q, nogrp;
  logic [31:0]     sum_q;

  typedef enum logic [1:0] {
    Ok,
    Cut,
    Lost
  } mode_e;

  mode_e           mode_q;

  logic [9:0][7:0] v;         // buf_q followed by the new bytes
  logic [4:0][7:0] buf_d;
  logic [3:0]      nb, tot;
  logic [2:0]      g;
  logic            full_grp, part_grp, formed, push_eol, leave, fifo_ok, wr_ok, gerr;
  logic [3:0][9:0] px;
  logic [1:0]      cnt;
  logic [11:0]     psum;

  always_comb begin
    nb = '0;
    for (int unsigned k = 0; k < Bytes; k++) begin
      nb = nb + {3'b000, valid_i[k]};
    end
  end

  assign tot      = {1'b0, n_q} + nb;
  assign g        = raw10_i ? 3'd5 : 3'd4;
  assign full_grp = (tot >= {1'b0, g});
  assign part_grp = eol_i && !raw10_i && (n_q != 3'd0);
  assign formed   = full_grp || part_grp;

  always_comb begin
    v = '0;
    for (int unsigned k = 0; k < 5; k++) begin
      v[k] = buf_q[k];
    end
    for (int unsigned k = 0; k < Bytes; k++) begin
      v[4'({1'b0, n_q} + 4'(k))] = data_i[k];
    end

    // leftover after a full group: at most Bytes - 1 bytes (n_q < g)
    buf_d = full_grp ? (raw10_i ? v[9:5] : v[8:4]) : v[4:0];

    psum = '0;
    for (int unsigned i = 0; i < 4; i++) begin
      if (raw10_i)                         px[i] = {v[i], v[4][2*i +: 2]};
      else if (full_grp || (i < 32'(n_q))) px[i] = {v[i], 2'b00};
      else                                 px[i] = '0;
      psum = psum + 12'(px[i]);
    end
    cnt = full_grp ? 2'd3 : 2'(n_q - 3'd1);
  end

  // The held group leaves (written or dropped) when the next one is formed
  // or the line ends.
  assign leave    = hold_v_q && (formed || eol_i || hold_last_q);
  assign push_eol = hold_last_q || (eol_i && !formed);
  assign fifo_ok  = push_eol ? ((mode_q != Lost) && !full_i) : ((mode_q == Ok) && !afull_i);
  assign wr_ok    = fifo_ok && !skip_q;
  assign push_o   = leave && wr_ok;
  assign gerr     = push_eol && ((hold_last_q ? eerr_q : err_i) || (mode_q == Cut) || lost_q);
  // an accepted line ends without any pixel group
  assign nogrp    = eol_i && !hold_v_q && !formed;
  // the sof group is dropped, or the first line or a burst before it is lost
  assign skip_set = !skip_q && ((leave && !wr_ok && hold_sof_q) ||
                                ((drop_i || nogrp) && sof_pend_q));
  assign group_o  = {gerr, hold_sof_q, push_eol, hold_cnt_q, hold_px_q};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      buf_q       <= '0;
      n_q         <= '0;
      hold_v_q    <= 1'b0;
      hold_last_q <= 1'b0;
      hold_sof_q  <= 1'b0;
      hold_cnt_q  <= '0;
      hold_px_q   <= '0;
      hold_sum_q  <= '0;
      sof_pend_q  <= 1'b0;
      inf_q       <= 1'b0;
      skip_q      <= 1'b0;
      skip_o      <= 1'b0;
      ovf_q       <= 1'b0;
      lost_q      <= 1'b0;
      eerr_q      <= 1'b0;
      mode_q      <= Ok;
      sum_q       <= '0;
      frame_sum_o <= '0;
    end else begin
      buf_q <= buf_d;
      if (sol_i || eol_i) n_q <= 3'd0;
      else if (full_grp)  n_q <= 3'(tot - {1'b0, g});
      else                n_q <= 3'(tot);

      if (formed) begin
        hold_v_q    <= 1'b1;
        hold_last_q <= eol_i;       // a partial group formed by eol_i is the last one
        hold_sof_q  <= sof_pend_q;
        hold_cnt_q  <= cnt;
        hold_px_q   <= px;
        hold_sum_q  <= psum;
      end else if (leave) begin
        hold_v_q    <= 1'b0;
        hold_last_q <= 1'b0;
      end

      if (fs_i)                 sof_pend_q <= 1'b1;
      else if (fe_i || formed)  sof_pend_q <= 1'b0;

      if (fs_i)      inf_q <= 1'b1;
      else if (fe_i) inf_q <= 1'b0;

      if (fs_i || fe_i)  skip_q <= 1'b0;
      else if (skip_set) skip_q <= 1'b1;
      skip_o <= skip_set && !fs_i && !fe_i;

      if (eol_i) eerr_q <= err_i;

      // FIFO overflow of the line (see the header); sol_i starts a line
      if (sol_i) begin
        mode_q <= Ok;
      end else if (leave && !wr_ok) begin
        if (push_eol)            mode_q <= Lost;
        else if (mode_q == Ok)   mode_q <= full_i ? Lost : Cut;
      end

      // A line lost (eol group dropped, a line without any pixel group, a
      // burst lost before this layer) is reported with the next line of the
      // frame that reaches the FIFO.
      if (fs_i || fe_i)                         lost_q <= 1'b0;
      else if (drop_i)                          lost_q <= 1'b1;
      else if (push_o && push_eol)              lost_q <= 1'b0;
      else if (leave && push_eol && inf_q)      lost_q <= 1'b1;
      else if (nogrp && inf_q)                  lost_q <= 1'b1;

      if (sol_i)                              ovf_q <= 1'b0;
      else if (leave && !fifo_ok && !skip_q)  ovf_q <= 1'b1;

      if (fs_i)        sum_q <= '0;
      else if (push_o) sum_q <= sum_q + 32'(hold_sum_q);
      if (fe_i) frame_sum_o <= sum_q;
    end
  end

  assign ovf_o = ovf_q;

endmodule
