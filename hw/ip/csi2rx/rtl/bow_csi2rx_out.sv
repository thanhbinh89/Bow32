// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 receiver output (video clock domain): pixel groups from the FIFO ->
// AXI4-Stream, one RAW10 pixel per clock.
//
// Two group registers: `cur` (being sent, pixel index idx) and `next`. The
// FIFO is popped whenever `next` is empty, independent of tready; tready only
// moves the output flops, idx and cur. tuser = first pixel of a sof group,
// tlast = last pixel of an eol group. All m_axis signals come from flops;
// groups of 4 pixels give 1 pixel per clock sustained. The reset (RX off)
// drops everything, also a line in the middle.

module bow_csi2rx_out import bow_csi2rx_pkg::*; (
  input  logic              clk_i,
  input  logic              rst_ni,       // video clock, datapath reset
  input  logic              empty_i,      // pixel FIFO, first word fall through
  input  logic [GroupW-1:0] group_i,
  output logic              pop_o,
  output logic              tvalid_o,
  input  logic              tready_i,
  output logic [9:0]        tdata_o,
  output logic              tuser_o,
  output logic              tlast_o
);

  logic [GroupW-1:0] cur_q, nxt_q;
  logic              cur_v_q, nxt_v_q;
  logic [1:0]        idx_q;
  logic              adv, cur_last, cur_done, load_cur;

  assign pop_o    = !nxt_v_q && !empty_i;
  assign adv      = !tvalid_o || tready_i;          // the output flops can take a pixel
  assign cur_last = (idx_q == cur_q[41:40]);
  assign cur_done = adv && cur_v_q && cur_last;
  assign load_cur = nxt_v_q && (!cur_v_q || cur_done);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cur_q    <= '0;
      nxt_q    <= '0;
      cur_v_q  <= 1'b0;
      nxt_v_q  <= 1'b0;
      idx_q    <= '0;
      tvalid_o <= 1'b0;
      tdata_o  <= '0;
      tuser_o  <= 1'b0;
      tlast_o  <= 1'b0;
    end else begin
      if (pop_o) begin
        nxt_q   <= group_i;
        nxt_v_q <= 1'b1;
      end else if (load_cur) begin
        nxt_v_q <= 1'b0;
      end

      if (adv) begin
        tvalid_o <= cur_v_q;
        tdata_o  <= cur_q[10*idx_q +: 10];
        tuser_o  <= cur_v_q && cur_q[43] && (idx_q == 2'd0);
        tlast_o  <= cur_v_q && cur_q[42] && cur_last;
      end

      if (load_cur) begin
        cur_q   <= nxt_q;
        cur_v_q <= 1'b1;
        idx_q   <= '0;
      end else if (cur_done) begin
        cur_v_q <= 1'b0;
      end else if (adv && cur_v_q) begin
        idx_q <= idx_q + 2'd1;
      end
    end
  end

endmodule
