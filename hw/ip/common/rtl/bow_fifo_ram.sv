// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Single clock FIFO in a RAM (bow_ram_sdp: block RAM on an FPGA, an SRAM macro on an ASIC),
// power-of-two depth (>= 4), first word fall through. The single clock counterpart of
// bow_fifo_async for deep FIFOs (bow_fifo_sync keeps its words in flops).
//
// The RAM's read port has one cycle of latency: it is read in every cycle at the read
// pointer after this cycle's pop (rptr + pop), so rdata_o always shows the head of the FIFO.
// A word becomes readable in the cycle after its write (a read of the address written in
// the same cycle returns the old contents), so empty_o compares the read pointer with the
// write pointer of the cycle before (wvis_q): a pushed word reaches empty_o two cycles after
// the push. full_o, afull_o (at most one free slot) and level_o count it at once, exactly
// (no synchroniser: bow_fifo_async's full and almost full are conservative instead). Push
// when full and pop when empty are ignored.

module bow_fifo_ram #(
  parameter int unsigned Width = 8,
  parameter int unsigned Depth = 16    // power of two, >= 4
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic                   push_i,
  input  logic [Width-1:0]       wdata_i,
  output logic                   full_o,
  output logic                   afull_o,    // at most one free slot
  input  logic                   pop_i,
  output logic [Width-1:0]       rdata_o,    // head of the FIFO (valid when !empty_o)
  output logic                   empty_o,
  output logic [$clog2(Depth):0] level_o     // words written and not yet popped
);

  localparam int unsigned AW = $clog2(Depth);

  if ((Depth < 4) || ((1 << AW) != Depth)) begin : g_bad_depth
    $error("bow_fifo_ram: Depth must be a power of two >= 4, not %0d", Depth);
  end

  logic [AW:0] wptr_q, wvis_q, rptr_q, rptr_d;
  logic        do_push, do_pop;

  assign level_o = wptr_q - rptr_q;
  assign full_o  = (level_o == (AW + 1)'(Depth));
  assign afull_o = (level_o >= (AW + 1)'(Depth - 1));
  assign empty_o = (rptr_q == wvis_q);
  assign do_push = push_i && !full_o;
  assign do_pop  = pop_i && !empty_o;
  assign rptr_d  = rptr_q + (AW + 1)'(do_pop);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wptr_q <= '0;
      wvis_q <= '0;
      rptr_q <= '0;
    end else begin
      wptr_q <= wptr_q + (AW + 1)'(do_push);
      wvis_q <= wptr_q;
      rptr_q <= rptr_d;
    end
  end

  bow_ram_sdp #(
    .Width (Width),
    .Depth (Depth)
  ) u_ram (
    .wclk_i  (clk_i),
    .we_i    (do_push),
    .waddr_i (wptr_q[AW-1:0]),
    .wdata_i (wdata_i),
    .rclk_i  (clk_i),
    .re_i    (1'b1),
    .raddr_i (rptr_d[AW-1:0]),
    .rdata_o (rdata_o)
  );

endmodule
