// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Synchronous FIFO (single clock), power-of-two depth.
// Push when full and pop when empty are ignored.

module bow_fifo_sync #(
  parameter int unsigned Width = 8,
  parameter int unsigned Depth = 16    // must be a power of two, >= 2
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic                   clr_i,    // synchronous flush

  input  logic                   push_i,
  input  logic [Width-1:0]       wdata_i,
  input  logic                   pop_i,
  output logic [Width-1:0]       rdata_o,  // head of the FIFO (valid when !empty_o)

  output logic                   full_o,
  output logic                   empty_o,
  output logic [$clog2(Depth):0] level_o
);

  localparam int unsigned PtrW = $clog2(Depth);

  logic [Width-1:0] storage [Depth];
  logic [PtrW:0]    wptr_q, rptr_q;   // one extra bit to tell full from empty
  logic             do_push, do_pop;

  assign full_o  = (wptr_q[PtrW] != rptr_q[PtrW]) && (wptr_q[PtrW-1:0] == rptr_q[PtrW-1:0]);
  assign empty_o = (wptr_q == rptr_q);
  assign level_o = wptr_q - rptr_q;
  assign do_push = push_i && !full_o;
  assign do_pop  = pop_i && !empty_o;
  assign rdata_o = storage[rptr_q[PtrW-1:0]];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wptr_q <= '0;
      rptr_q <= '0;
    end else if (clr_i) begin
      wptr_q <= '0;
      rptr_q <= '0;
    end else begin
      if (do_push) wptr_q <= wptr_q + 1'b1;
      if (do_pop)  rptr_q <= rptr_q + 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (do_push) begin
      storage[wptr_q[PtrW-1:0]] <= wdata_i;
    end
  end

endmodule
