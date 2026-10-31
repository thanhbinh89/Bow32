// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 DMA controller: NumCh channels sharing one bus master port (a host
// of the main crossbar). docs/ip/dma.md.
//
// Every channel works in one of two modes:
//   M2M  memory -> memory: copies LEN bytes from SRC to DST (words)
//   S2M  stream -> memory: writes the words of its stream input (s_*[ch])
//        to DST + WPTR. Linear: stops (DONE) when LEN bytes are written,
//        the stream waits. Ring: WPTR wraps at LEN; the channel waits while
//        the buffer is full ((WPTR + 4) mod LEN == RPTR, RPTR is written by
//        the consumer). The end of a stream packet (tlast) updates PKT_CNT
//        and PKT_END (WPTR after the packet).
// A bus error stops the channel (ERR). The engine does one bus transfer at a
// time (2 cycles per word), the channels take turns (round robin).
//
// Registers (peripheral bus):
//   0x000 ID        R   0x444D4101 ("DMA", version 1)
//   0x004 INFO      R   [7:0] channels
//   channel c at 0x040 * (c + 1):
//   +0x00 CTRL      RW  [0] EN  [1] MODE (0 M2M, 1 S2M)  [2] RING
//                       [3] DROP (S2M: take the stream words and drop them)
//                       [8] IE_DONE  [9] IE_PKT  [10] IE_ERR
//                       EN 0 -> 1 starts the channel (WPTR, COUNT = 0);
//                       EN cleared by the channel when it is done or on error
//   +0x04 STATUS    R/W1C [0] BUSY  [1] DONE  [2] PKT  [3] ERR  [4] FULL
//   +0x08 SRC       RW  source address (M2M), word aligned
//   +0x0C DST       RW  destination address, word aligned
//   +0x10 LEN       RW  bytes (M2M: to copy, S2M: buffer size), multiple of 4
//   +0x14 WPTR      R   S2M: write offset in the buffer (M2M: bytes copied)
//   +0x18 RPTR      RW  S2M ring: read offset of the consumer
//   +0x1C PKT_CNT   R   stream packets written
//   +0x20 PKT_END   R   WPTR after the last packet
//   +0x24 COUNT     R   bytes written since the start

module bow_dma import bow_bus_pkg::*; #(
  parameter int unsigned NumCh = 2
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,

  input  bus_req_t                    reg_req_i,
  output bus_rsp_t                    reg_rsp_o,

  output bus_req_t                    host_req_o,   // bus master
  input  bus_rsp_t                    host_rsp_i,

  input  logic [NumCh-1:0]            s_tvalid_i,   // stream inputs (S2M)
  output logic [NumCh-1:0]            s_tready_o,
  input  logic [NumCh-1:0][31:0]      s_tdata_i,
  input  logic [NumCh-1:0]            s_tlast_i,

  output logic                        irq_o
);

  localparam int unsigned CW = (NumCh > 1) ? $clog2(NumCh) : 1;

  // ------------------------------------------------------------- registers
  logic [NumCh-1:0]       en_q, mode_q, ring_q, drop_q;
  logic [NumCh-1:0][2:0]  ie_q;
  logic [NumCh-1:0]       done_q, pkt_q, err_q;
  logic [NumCh-1:0][31:0] src_q, dst_q, len_q, wptr_q, rptr_q, pktcnt_q, pktend_q, count_q;

  logic [11:0] a;
  logic        we, re;
  logic [31:0] wd;
  logic [3:0]  rch;      // channel + 1 of the register address
  logic [5:0]  roff;

  assign a    = {reg_req_i.addr[11:2], 2'b00};
  assign we   = reg_req_i.req &  reg_req_i.we;
  assign re   = reg_req_i.req & ~reg_req_i.we;
  assign wd   = reg_req_i.wdata;
  assign rch  = a[9:6];
  assign roff = a[5:0];

  // ----------------------------------------------------------- the engine
  typedef enum logic [2:0] {EIdle, ERead, ERdata, EWrite, EWdone} estate_e;

  estate_e      est_q;
  logic [CW-1:0] ch_q, rr_q;     // active channel, round robin pointer
  bus_req_t     req_q;
  logic         last_q;          // the word in flight ends a stream packet

  // work of a channel
  logic [NumCh-1:0] full, can_s2m, can_m2m, want, dropping;

  for (genvar c = 0; c < NumCh; c++) begin : g_want
    logic [31:0] next;
    assign next       = (wptr_q[c] + 32'd4 == len_q[c]) ? 32'd0 : wptr_q[c] + 32'd4;
    assign full[c]    = ring_q[c] ? (next == rptr_q[c]) : (wptr_q[c] == len_q[c]);
    assign can_s2m[c] = en_q[c] && mode_q[c] && !drop_q[c] && s_tvalid_i[c] && !full[c];
    assign dropping[c] = en_q[c] && mode_q[c] && drop_q[c];
    assign can_m2m[c] = en_q[c] && !mode_q[c] && (wptr_q[c] != len_q[c]);
    assign want[c]    = can_s2m[c] || can_m2m[c];
  end

  // next channel after rr_q that wants the bus
  logic [CW-1:0] pick;
  logic          pick_ok;
  always_comb begin
    pick    = rr_q;
    pick_ok = 1'b0;
    for (int unsigned k = 1; k <= NumCh; k++) begin
      logic [CW-1:0] c;
      c = CW'((32'(rr_q) + k) % NumCh);
      if (!pick_ok && want[c]) begin
        pick    = c;
        pick_ok = 1'b1;
      end
    end
  end

  assign host_req_o = req_q;

  always_comb begin
    s_tready_o = dropping;
    if (est_q == EWrite && mode_q[ch_q] && host_rsp_i.gnt) s_tready_o[ch_q] = 1'b1;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      est_q    <= EIdle;
      ch_q     <= '0;
      rr_q     <= '0;
      req_q    <= BUS_REQ_DEFAULT;
      last_q   <= 1'b0;
      en_q     <= '0;
      mode_q   <= '0;
      ring_q   <= '0;
      drop_q   <= '0;
      ie_q     <= '0;
      done_q   <= '0;
      pkt_q    <= '0;
      err_q    <= '0;
      src_q    <= '0;
      dst_q    <= '0;
      len_q    <= '0;
      wptr_q   <= '0;
      rptr_q   <= '0;
      pktcnt_q <= '0;
      pktend_q <= '0;
      count_q  <= '0;
    end else begin
      // ---- engine
      unique case (est_q)
        EIdle: if (pick_ok) begin
          ch_q <= pick;
          rr_q <= pick;
          req_q.req <= 1'b1;
          req_q.be  <= 4'hF;
          if (mode_q[pick]) begin
            req_q.we    <= 1'b1;
            req_q.addr  <= dst_q[pick] + wptr_q[pick];
            req_q.wdata <= s_tdata_i[pick];
            last_q      <= s_tlast_i[pick];
            est_q       <= EWrite;
          end else begin
            req_q.we   <= 1'b0;
            req_q.addr <= src_q[pick] + wptr_q[pick];
            est_q      <= ERead;
          end
        end
        ERead: if (host_rsp_i.gnt) begin
          req_q.req <= 1'b0;
          est_q     <= ERdata;
        end
        ERdata: if (host_rsp_i.rvalid) begin
          if (host_rsp_i.err) begin
            err_q[ch_q] <= 1'b1;
            en_q[ch_q]  <= 1'b0;
            est_q       <= EIdle;
          end else begin
            req_q.req   <= 1'b1;
            req_q.we    <= 1'b1;
            req_q.addr  <= dst_q[ch_q] + wptr_q[ch_q];
            req_q.wdata <= host_rsp_i.rdata;
            last_q      <= 1'b0;
            est_q       <= EWrite;
          end
        end
        EWrite: if (host_rsp_i.gnt) begin
          req_q.req <= 1'b0;
          est_q     <= EWdone;
        end
        EWdone: if (host_rsp_i.rvalid) begin
          est_q <= EIdle;
          if (host_rsp_i.err) begin
            err_q[ch_q] <= 1'b1;
            en_q[ch_q]  <= 1'b0;
          end else begin
            logic [31:0] n;
            n = wptr_q[ch_q] + 32'd4;
            if (ring_q[ch_q] && mode_q[ch_q] && n == len_q[ch_q]) n = '0;
            wptr_q[ch_q]  <= n;
            count_q[ch_q] <= count_q[ch_q] + 32'd4;
            if (mode_q[ch_q] && last_q) begin
              pkt_q[ch_q]    <= 1'b1;
              pktcnt_q[ch_q] <= pktcnt_q[ch_q] + 32'd1;
              pktend_q[ch_q] <= n;
            end
            if (!(ring_q[ch_q] && mode_q[ch_q]) && wptr_q[ch_q] + 32'd4 == len_q[ch_q]) begin
              done_q[ch_q] <= 1'b1;
              en_q[ch_q]   <= 1'b0;
            end
          end
        end
        default: est_q <= EIdle;
      endcase

      // ---- dropped stream words still count the packets
      for (int unsigned c = 0; c < NumCh; c++) begin
        if (dropping[c] && s_tvalid_i[c] && s_tlast_i[c]) begin
          pkt_q[c]    <= 1'b1;
          pktcnt_q[c] <= pktcnt_q[c] + 32'd1;
        end
      end

      // ---- register writes (after the engine: the CPU wins)
      if (we && rch != 4'd0 && 32'(rch) <= NumCh) begin
        logic [CW-1:0] c;
        c = CW'(rch - 4'd1);
        unique case (roff)
          6'h00: begin
            if (wd[0] && !en_q[c]) begin
              wptr_q[c]   <= '0;
              count_q[c]  <= '0;
              pktcnt_q[c] <= '0;
              pktend_q[c] <= '0;
              done_q[c]   <= 1'b0;
            end
            en_q[c]   <= wd[0];
            mode_q[c] <= wd[1];
            ring_q[c] <= wd[2];
            drop_q[c] <= wd[3];
            ie_q[c]   <= wd[10:8];
          end
          6'h04: begin
            if (wd[1]) done_q[c] <= 1'b0;
            if (wd[2]) pkt_q[c]  <= 1'b0;
            if (wd[3]) err_q[c]  <= 1'b0;
          end
          6'h08: src_q[c]  <= {wd[31:2], 2'b00};
          6'h0C: dst_q[c]  <= {wd[31:2], 2'b00};
          6'h10: len_q[c]  <= {wd[31:2], 2'b00};
          6'h18: rptr_q[c] <= {wd[31:2], 2'b00};
          default: ;
        endcase
      end
    end
  end

  logic [NumCh-1:0] busy;
  for (genvar c = 0; c < NumCh; c++) begin : g_busy
    assign busy[c] = en_q[c] || (est_q != EIdle && ch_q == CW'(c));
  end

  always_comb begin
    irq_o = 1'b0;
    for (int unsigned c = 0; c < NumCh; c++) begin
      irq_o = irq_o | (ie_q[c][0] & done_q[c]) | (ie_q[c][1] & pkt_q[c]) | (ie_q[c][2] & err_q[c]);
    end
  end

  // ------------------------------------------------------------ read data
  logic [31:0] rdata_d, rdata_q;
  logic        rvalid_q;

  always_comb begin
    logic [CW-1:0] c;
    rdata_d = '0;
    c       = CW'(rch - 4'd1);
    if (a == 12'h000) begin
      rdata_d = 32'h444D_4101;
    end else if (a == 12'h004) begin
      rdata_d = 32'(NumCh);
    end else if (rch != 4'd0 && 32'(rch) <= NumCh) begin
      unique case (roff)
        6'h00: rdata_d = {21'h0, ie_q[c], 4'h0, drop_q[c], ring_q[c], mode_q[c], en_q[c]};
        6'h04: rdata_d = {27'h0, en_q[c] && mode_q[c] && full[c], err_q[c], pkt_q[c], done_q[c], busy[c]};
        6'h08: rdata_d = src_q[c];
        6'h0C: rdata_d = dst_q[c];
        6'h10: rdata_d = len_q[c];
        6'h14: rdata_d = wptr_q[c];
        6'h18: rdata_d = rptr_q[c];
        6'h1C: rdata_d = pktcnt_q[c];
        6'h20: rdata_d = pktend_q[c];
        6'h24: rdata_d = count_q[c];
        default: rdata_d = '0;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else begin
      rvalid_q <= reg_req_i.req;
      if (re) rdata_q <= rdata_d;
    end
  end

  assign reg_rsp_o.gnt    = 1'b1;
  assign reg_rsp_o.rvalid = rvalid_q;
  assign reg_rsp_o.err    = 1'b0;
  assign reg_rsp_o.rdata  = rdata_q;

  logic unused;
  assign unused = ^{reg_req_i.addr[31:12], reg_req_i.addr[1:0], reg_req_i.be, a[11:10], wd[7:4],
                    wd[31:11]};

endmodule
