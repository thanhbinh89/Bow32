// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 pixel unpacker (byte clock domain): payload bytes of the accepted
// lines -> groups of up to 4 pixels for the pixel FIFO.
//
//   RAW10: 5 bytes -> 4 pixels, P_i = {B_i, B4[2i+1:2i]}
//   RAW8:  4 bytes -> 4 pixels, P_i = {B_i, 2'b00}
//
// Group (FIFO entry, bow_csi2rx_pkg::GroupW bits):
//   [43] sof  first group after an FS of the selected VC
//   [42] eol  last group of a line (normal end or truncation)
//   [41:40]   number of pixels - 1
//   [39:0]    px3 .. px0, px0 in [9:0] (first pixel)
// A RAW8 line with WC % 4 != 0 ends with a partial group; leftover RAW10
// bytes (WC % 5 != 0) are dropped. The last formed group is held back one
// step so that eol lands on the real last group: when a line ends, the last
// group is pushed in the cycle of eol_i, or one cycle later if eol_i also
// formed a partial group. A group that finds the FIFO full is dropped
// (ovf_o, cleared at the next sol_i).
// The frame sum adds up all pixels pushed into the FIFO from FS to FE.

module bow_csi2_unpack import bow_csi2rx_pkg::*; (
  input  logic              clk_i,
  input  logic              rst_ni,     // byte clock, datapath reset
  input  logic              sol_i,      // an accepted line starts (no bytes in this cycle)
  input  logic              raw10_i,    // 1: RAW10, 0: RAW8 (static during a line)
  input  logic [1:0]        valid_i,    // payload bytes ([1] only with [0])
  input  logic [15:0]       data_i,
  input  logic              eol_i,      // end of the line (no bytes in this cycle)
  input  logic              fs_i,
  input  logic              fe_i,

  output logic              push_o,
  output logic [GroupW-1:0] group_o,
  input  logic              full_i,

  output logic              ovf_o,
  output logic [31:0]       frame_sum_o // sum of the last complete frame
);

  logic [4:0][7:0] buf_q;     // bytes of the group being formed
  logic [2:0]      n_q;       // number of bytes in buf_q
  logic            hold_v_q, hold_last_q, hold_sof_q;
  logic [1:0]      hold_cnt_q;
  logic [3:0][9:0] hold_px_q;
  logic [11:0]     hold_sum_q;
  logic            sof_pend_q, ovf_q;
  logic [31:0]     sum_q;

  logic [9:0][7:0] v;         // buf_q followed by the new bytes
  logic [4:0][7:0] buf_d;
  logic [2:0]      nb, tot, g;
  logic            full_grp, part_grp, formed, push_eol;
  logic [3:0][9:0] px;
  logic [1:0]      cnt;
  logic [11:0]     psum;

  assign nb       = {2'b00, valid_i[0]} + {2'b00, valid_i[1]};
  assign tot      = n_q + nb;
  assign g        = raw10_i ? 3'd5 : 3'd4;
  assign full_grp = (tot >= g);
  assign part_grp = eol_i && !raw10_i && (n_q != 3'd0);
  assign formed   = full_grp || part_grp;

  always_comb begin
    v = '0;
    for (int unsigned k = 0; k < 5; k++) begin
      v[k] = buf_q[k];
    end
    v[n_q]        = data_i[7:0];
    v[n_q + 3'd1] = data_i[15:8];

    // leftover after a full group: at most one byte (n_q < g, nb <= 2)
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

  assign push_o   = hold_v_q && (formed || eol_i || hold_last_q);
  assign push_eol = hold_last_q || (eol_i && !formed);
  assign group_o  = {hold_sof_q, push_eol, hold_cnt_q, hold_px_q};

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
      ovf_q       <= 1'b0;
      sum_q       <= '0;
      frame_sum_o <= '0;
    end else begin
      buf_q <= buf_d;
      if (sol_i || eol_i) n_q <= 3'd0;
      else if (full_grp)  n_q <= tot - g;
      else                n_q <= tot;

      if (formed) begin
        hold_v_q    <= 1'b1;
        hold_last_q <= eol_i;       // a partial group formed by eol_i is the last one
        hold_sof_q  <= sof_pend_q;
        hold_cnt_q  <= cnt;
        hold_px_q   <= px;
        hold_sum_q  <= psum;
      end else if (push_o) begin
        hold_v_q    <= 1'b0;
        hold_last_q <= 1'b0;
      end

      if (fs_i)        sof_pend_q <= 1'b1;
      else if (formed) sof_pend_q <= 1'b0;

      if (sol_i)                 ovf_q <= 1'b0;
      else if (push_o && full_i) ovf_q <= 1'b1;

      if (fs_i)                   sum_q <= '0;
      else if (push_o && !full_i) sum_q <= sum_q + 32'(hold_sum_q);
      if (fe_i) frame_sum_o <= sum_q;
    end
  end

  assign ovf_o = ovf_q;

endmodule
