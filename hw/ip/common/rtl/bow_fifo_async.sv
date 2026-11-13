// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Dual clock FIFO, power-of-two depth (>= 4), gray coded pointers.
//
// Each pointer crosses into the other clock domain through a 2 flip-flop
// (ASYNC_REG) synchroniser; full_o / empty_o are conservative (a slot freed
// or filled on the other side shows up 2-3 cycles later). afull_o: at most
// one free slot (same conservative view), for writers that must keep a slot
// in reserve. Push when full and pop when empty are ignored. The FIFO keeps
// working when one clock stops for a long time (e.g. a gated write clock):
// the other side just sees the last pointer.
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
// (set_bus_skew) of at most one period of the faster clock, and the paths
// between the two clocks a data path limit of at most one destination period
// (set_max_delay -datapath_only), not a clock group: a RAM of LUTs is read
// through the read register (u_ram/rdata_o_reg) over fabric paths from its
// write clock, and a word must reach that register before the write pointer
// that announces it has passed the synchroniser (a clock group, which takes
// precedence over set_max_delay, leaves those paths unbounded; review of step
// 7 of docs/ip/mipi_rx_arch.md, the lane merge FIFO). The gray pointer
// flops (wgray_q, rgray_q, the sources of those buses) are DONT_TOUCH, which
// Vivado forwards to implementation: the top bit of a gray pointer equals the
// top bit of its binary pointer, and phys_opt_design's equivalent driver
// rewiring moved the synchroniser's load of that bit to the binary flop and
// deleted the gray one (the lane merge FIFO of the Huins camera build, step 7
// of docs/ip/mipi_rx_arch.md), so the bus skew constraint missed the bit.
//
// Simulation only, `define BOW_SYNC_JITTER: the two pointer synchronisers are bow_sync_bus
// instances (u_sync_rptr, u_sync_wptr) with the jitter model of bow_sync (a bit that changed
// less than 0.5 ns before the clock edge may resolve one cycle late), in place of the plain
// flops of every other build (rgray_w1_q / rgray_w2_q, wgray_r1_q / wgray_r2_q: the cell names
// of the FPGA constraints). A gray pointer then shows its old or its new value; a pointer
// that crosses with more than one bit changing at a time would show values it never had.

module bow_fifo_async #(
  parameter int unsigned Width = 8,
  parameter int unsigned Depth = 16    // power of two, >= 4
) (
  input  logic             wclk_i,
  input  logic             wrst_ni,
  input  logic             push_i,
  input  logic [Width-1:0] wdata_i,
  output logic             full_o,
  output logic             afull_o,    // at most one free slot

  input  logic             rclk_i,
  input  logic             rrst_ni,
  input  logic             pop_i,
  output logic [Width-1:0] rdata_o,    // head of the FIFO (valid when !empty_o)
  output logic             empty_o
);

  localparam int unsigned AW = $clog2(Depth);

  logic [AW:0] wbin_q, wbin_d;           // write pointer (wclk_i)
  logic [AW:0] rbin_q, rbin_d;           // read pointer (rclk_i)
  (* DONT_TOUCH = "TRUE" *) logic [AW:0] wgray_q;   // gray write pointer (to rclk_i)
  (* DONT_TOUCH = "TRUE" *) logic [AW:0] rgray_q;   // gray read pointer (to wclk_i)
  logic [AW:0] rbin_w, wlevel;           // read pointer seen by the write side
  logic        do_push, do_pop;

  (* ASYNC_REG = "TRUE" *) logic [AW:0] rgray_w1_q, rgray_w2_q;   // read pointer in wclk_i
  (* ASYNC_REG = "TRUE" *) logic [AW:0] wgray_r1_q, wgray_r2_q;   // write pointer in rclk_i

  // ------------------------------------------------------------ write side
  // full: the write pointer is one lap ahead of the read pointer
  assign full_o  = (wgray_q == {~rgray_w2_q[AW:AW-1], rgray_w2_q[AW-2:0]});
  assign do_push = push_i && !full_o;
  assign wbin_d  = wbin_q + (AW + 1)'(do_push);

  always_comb begin
    rbin_w[AW] = rgray_w2_q[AW];
    for (int i = int'(AW) - 1; i >= 0; i--) rbin_w[i] = rbin_w[i + 1] ^ rgray_w2_q[i];
  end

  assign wlevel  = wbin_q - rbin_w;
  assign afull_o = (wlevel >= (AW + 1)'(Depth - 1));

  always_ff @(posedge wclk_i or negedge wrst_ni) begin
    if (!wrst_ni) begin
      wbin_q  <= '0;
      wgray_q <= '0;
    end else begin
      wbin_q  <= wbin_d;
      wgray_q <= wbin_d ^ (wbin_d >> 1);
    end
  end

`ifndef BOW_SYNC_JITTER
  always_ff @(posedge wclk_i or negedge wrst_ni) begin
    if (!wrst_ni) begin
      rgray_w1_q <= '0;
      rgray_w2_q <= '0;
    end else begin
      rgray_w1_q <= rgray_q;
      rgray_w2_q <= rgray_w1_q;
    end
  end
`else
  bow_sync_bus #(
    .Width (AW + 1)
  ) u_sync_rptr (
    .clk_i  (wclk_i),
    .rst_ni (wrst_ni),
    .d_i    (rgray_q),
    .q_o    (rgray_w2_q)
  );

  assign rgray_w1_q = '0;
`endif

  // ------------------------------------------------------------- read side
  assign empty_o = (rgray_q == wgray_r2_q);
  assign do_pop  = pop_i && !empty_o;
  assign rbin_d  = rbin_q + (AW + 1)'(do_pop);

  always_ff @(posedge rclk_i or negedge rrst_ni) begin
    if (!rrst_ni) begin
      rbin_q  <= '0;
      rgray_q <= '0;
    end else begin
      rbin_q  <= rbin_d;
      rgray_q <= rbin_d ^ (rbin_d >> 1);
    end
  end

`ifndef BOW_SYNC_JITTER
  always_ff @(posedge rclk_i or negedge rrst_ni) begin
    if (!rrst_ni) begin
      wgray_r1_q <= '0;
      wgray_r2_q <= '0;
    end else begin
      wgray_r1_q <= wgray_q;
      wgray_r2_q <= wgray_r1_q;
    end
  end
`else
  bow_sync_bus #(
    .Width (AW + 1)
  ) u_sync_wptr (
    .clk_i  (rclk_i),
    .rst_ni (rrst_ni),
    .d_i    (wgray_q),
    .q_o    (wgray_r2_q)
  );

  assign wgray_r1_q = '0;
`endif

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
