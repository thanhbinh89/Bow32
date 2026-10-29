// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Round-robin arbiter with a combinational one-hot grant.
//
// The requester granted last gets the lowest priority on the next arbitration.
// The priority pointer only moves when the grant is consumed (ack_i).
// A grant that is not consumed is locked: in the following cycles it stays
// with the same requester until ack_i, even if a requester with a higher
// priority arrives. A device that holds gnt low for several cycles (e.g. the
// AXI-Lite bridge) therefore sees one stable request (hosts must hold their
// request until it is granted, see bow_bus_pkg).

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
  logic [N-1:0] gnt_masked, gnt_unmasked, gnt_arb;
  logic [N-1:0] gnt_shift;
  logic         lock_q;
  logic [N-1:0] lock_gnt_q;

  assign req_masked   = req_i & mask_q;
  // x & -x isolates the lowest set bit.
  assign gnt_masked   = req_masked & (~req_masked + 1'b1);
  assign gnt_unmasked = req_i & (~req_i + 1'b1);
  assign gnt_arb      = (|req_masked) ? gnt_masked : gnt_unmasked;
  assign gnt_o        = lock_q ? (lock_gnt_q & req_i) : gnt_arb;

  // Priority for the next round: every index above the one just granted.
  // When the highest index was granted the shift overflows to zero and the
  // mask becomes zero (~(0 - 1) == 0), i.e. index 0 gets the highest priority.
  assign gnt_shift = gnt_o << 1;
  assign mask_d    = ~(gnt_shift - 1'b1);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mask_q     <= '0;
      lock_q     <= 1'b0;
      lock_gnt_q <= '0;
    end else begin
      if (ack_i && |gnt_o) begin
        mask_q <= mask_d;
      end
      lock_q     <= |gnt_o && !ack_i;
      lock_gnt_q <= gnt_o;
    end
  end

endmodule
