// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Two flip-flop synchroniser for asynchronous single bit inputs (pins).

module bow_sync #(
  parameter logic ResetValue = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic d_i,
  output logic q_o
);

  (* ASYNC_REG = "TRUE" *) logic [1:0] sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sync_q <= {2{ResetValue}};
    end else begin
      sync_q <= {sync_q[0], d_i};
    end
  end

  assign q_o = sync_q[1];

endmodule
