// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Reset synchroniser: asynchronous assertion, synchronous de-assertion.
// Use one per clock domain that receives an external reset.

module bow_rst_sync (
  input  logic clk_i,
  input  logic rst_ni,    // asynchronous, active low
  output logic rst_no     // synchronised to clk_i
);

  (* ASYNC_REG = "TRUE" *) logic [1:0] sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sync_q <= '0;
    end else begin
      sync_q <= {sync_q[0], 1'b1};
    end
  end

  assign rst_no = sync_q[1];

`ifdef VERILATOR
  // See bow_rstmgr: start released so that a reset pulse creates real edges.
  initial sync_q = 2'b11;
`endif

endmodule
