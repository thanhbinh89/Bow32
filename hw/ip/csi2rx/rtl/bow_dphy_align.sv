// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// MIPI D-PHY receive data lane, HS side (byte clock domain, one per lane):
// finds the SoT sync byte in the deserialised words and outputs byte
// aligned data.
//
// The ISERDES words arrive at an unknown bit phase (bit 0 = first bit on
// the wire). With w24 = {rx_i, q1, q2} (the last three words, bit j received
// after bit j-1), offset o matches when w24[o +: 8] == 8'h00 (HS-zero) and
// w24[o+8 +: 8] == 8'hB8 (sync); only one offset can match. The search
// runs from a rising edge of arm_i until the match. From the next word on,
// every word gives one byte, {rx_i, q1}[o +: 8], until arm_i falls; sot_o
// comes with the first byte after the sync byte. arm_i falling while still
// searching is a sync error. An arm_i that is already high when the reset
// is released (receiver enabled in the middle of a burst) does not start a
// search: the next rising edge does.
//
// Outputs are flops (one cycle after the word they come from).

module bow_dphy_align (
  input  logic       clk_i,
  input  logic       rst_ni,         // byte clock, datapath reset
  input  logic       arm_i,          // hs_active of the lane, synchronised
  input  logic [7:0] rx_i,           // registered ISERDES word
  output logic       valid_o,        // aligned byte, every cycle while locked
  output logic [7:0] data_o,         // LSB = first bit on the wire
  output logic       sot_o,          // with the first byte after the sync byte
  output logic       locked_o,
  output logic       ev_sync_err_o   // pulse: arm_i fell and no sync was found
);

  logic [7:0]  q1_q, q2_q;
  logic        arm_q, search_q, locked_q, first_q;
  logic [2:0]  off_q;
  logic [23:0] w24;
  logic [15:0] w16;
  logic [7:0]  hit;
  logic [2:0]  hit_off;
  logic        search;

  assign w24 = {rx_i, q1_q, q2_q};
  assign w16 = {rx_i, q1_q};

  always_comb begin
    for (int unsigned o = 0; o < 8; o++) begin
      hit[o] = (w24[o +: 8] == 8'h00) && (w24[o + 8 +: 8] == 8'hB8);
    end
    hit_off = 3'd0;
    for (int o = 7; o >= 0; o--) begin
      if (hit[o]) hit_off = 3'(o);
    end
  end

  // searching: from the cycle of the rising edge of arm_i until a match
  assign search = arm_i && (search_q || !arm_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      q1_q          <= '0;
      q2_q          <= '0;
      arm_q         <= 1'b1;
      search_q      <= 1'b0;
      locked_q      <= 1'b0;
      first_q       <= 1'b0;
      off_q         <= '0;
      valid_o       <= 1'b0;
      data_o        <= '0;
      sot_o         <= 1'b0;
      ev_sync_err_o <= 1'b0;
    end else begin
      q1_q          <= rx_i;
      q2_q          <= q1_q;
      arm_q         <= arm_i;
      search_q      <= search && (hit == '0);
      ev_sync_err_o <= arm_q && !arm_i && search_q;

      if (!arm_i) begin
        locked_q <= 1'b0;
      end else if (search && (hit != '0)) begin
        locked_q <= 1'b1;
        off_q    <= hit_off;
        first_q  <= 1'b1;
      end else if (locked_q) begin
        first_q <= 1'b0;
      end

      valid_o <= locked_q;
      sot_o   <= locked_q && first_q;
      if (locked_q) data_o <= w16[{1'b0, off_q} +: 8];
    end
  end

  assign locked_o = locked_q;

endmodule
