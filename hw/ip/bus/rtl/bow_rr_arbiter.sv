// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Round-robin arbiter with a combinational one-hot grant.
//
// The requester granted last gets the lowest priority on the next arbitration.
// The priority pointer only moves when the grant is consumed (ack_i), so a
// request that is waiting for the downstream device keeps its grant stable.

module bow_rr_arbiter #(
  parameter int unsigned N = 2
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [N-1:0] req_i,
  input  logic         ack_i,   // grant consumed in this cycle
  output logic [N-1:0] gnt_o    // one-hot (or zero when no request)
);

  // mask_q has a 1 for every requester that currently has priority over the
  // others (all requesters after the one granted last).
  logic [N-1:0] mask_q, mask_d;
  logic [N-1:0] req_masked;
  logic [N-1:0] gnt_masked, gnt_unmasked;
  logic [N-1:0] gnt_shift;

  assign req_masked   = req_i & mask_q;
  // x & -x isolates the lowest set bit.
  assign gnt_masked   = req_masked & (~req_masked + 1'b1);
  assign gnt_unmasked = req_i & (~req_i + 1'b1);
  assign gnt_o        = (|req_masked) ? gnt_masked : gnt_unmasked;

  // Priority for the next round: every index above the one just granted.
  // When the highest index was granted the shift overflows to zero and the
  // mask becomes zero (~(0 - 1) == 0), i.e. index 0 gets the highest priority.
  assign gnt_shift = gnt_o << 1;
  assign mask_d    = ~(gnt_shift - 1'b1);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mask_q <= '0;
    end else if (ack_i && |gnt_o) begin
      mask_q <= mask_d;
    end
  end

endmodule
