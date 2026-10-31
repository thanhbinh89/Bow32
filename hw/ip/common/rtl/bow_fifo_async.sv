// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Dual clock FIFO, power-of-two depth (>= 4), gray coded pointers.
//
// Each pointer crosses into the other clock domain through a 2 flip-flop
// (ASYNC_REG) synchroniser; full_o / empty_o are conservative (a slot freed
// or filled on the other side shows up 2-3 cycles later). Push when full and
// pop when empty are ignored. The FIFO keeps working when one clock stops
// for a long time (e.g. a gated write clock): the other side just sees the
// last pointer.
//
// Read side: first word fall through. The RAM is read every cycle at
// rptr + pop, so rdata_o always shows the head of the FIFO; the write
// pointer synchroniser guarantees that a word was written before the
// read side can see it (empty_o low).
//
// Reset rule: wrst_ni and rrst_ni must be asserted together (same
// asynchronous source, each released synchronously to its own clock). They
// may be released at different times: the side that is still in reset
// shows a pointer of 0 to the other side.
//
// Static timing: the gray pointer buses need a bus skew constraint
// (set_bus_skew) of at most one period of the faster clock.

module bow_fifo_async #(
  parameter int unsigned Width = 8,
  parameter int unsigned Depth = 16    // power of two, >= 4
) (
  input  logic             wclk_i,
  input  logic             wrst_ni,
  input  logic             push_i,
  input  logic [Width-1:0] wdata_i,
  output logic             full_o,

  input  logic             rclk_i,
  input  logic             rrst_ni,
  input  logic             pop_i,
  output logic [Width-1:0] rdata_o,    // head of the FIFO (valid when !empty_o)
  output logic             empty_o
);

  localparam int unsigned AW = $clog2(Depth);

  logic [AW:0] wbin_q, wbin_d, wgray_q;   // write pointer (wclk_i)
  logic [AW:0] rbin_q, rbin_d, rgray_q;   // read pointer (rclk_i)
  logic        do_push, do_pop;

  (* ASYNC_REG = "TRUE" *) logic [AW:0] rgray_w1_q, rgray_w2_q;   // read pointer in wclk_i
  (* ASYNC_REG = "TRUE" *) logic [AW:0] wgray_r1_q, wgray_r2_q;   // write pointer in rclk_i

  // ------------------------------------------------------------ write side
  // full: the write pointer is one lap ahead of the read pointer
  assign full_o  = (wgray_q == {~rgray_w2_q[AW:AW-1], rgray_w2_q[AW-2:0]});
  assign do_push = push_i && !full_o;
  assign wbin_d  = wbin_q + (AW + 1)'(do_push);

  always_ff @(posedge wclk_i or negedge wrst_ni) begin
    if (!wrst_ni) begin
      wbin_q     <= '0;
      wgray_q    <= '0;
      rgray_w1_q <= '0;
      rgray_w2_q <= '0;
    end else begin
      wbin_q     <= wbin_d;
      wgray_q    <= wbin_d ^ (wbin_d >> 1);
      rgray_w1_q <= rgray_q;
      rgray_w2_q <= rgray_w1_q;
    end
  end

  // ------------------------------------------------------------- read side
  assign empty_o = (rgray_q == wgray_r2_q);
  assign do_pop  = pop_i && !empty_o;
  assign rbin_d  = rbin_q + (AW + 1)'(do_pop);

  always_ff @(posedge rclk_i or negedge rrst_ni) begin
    if (!rrst_ni) begin
      rbin_q     <= '0;
      rgray_q    <= '0;
      wgray_r1_q <= '0;
      wgray_r2_q <= '0;
    end else begin
      rbin_q     <= rbin_d;
      rgray_q    <= rbin_d ^ (rbin_d >> 1);
      wgray_r1_q <= wgray_q;
      wgray_r2_q <= wgray_r1_q;
    end
  end

  // --------------------------------------------------------------- storage
  bow_ram_sdp #(
    .Width (Width),
    .Depth (Depth)
  ) u_ram (
    .wclk_i  (wclk_i),
    .we_i    (do_push),
    .waddr_i (wbin_q[AW-1:0]),
    .wdata_i (wdata_i),
    .rclk_i  (rclk_i),
    .re_i    (1'b1),
    .raddr_i (rbin_d[AW-1:0]),
    .rdata_o (rdata_o)
  );

endmodule
