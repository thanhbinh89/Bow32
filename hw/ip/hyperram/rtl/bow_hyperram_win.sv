// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Memory window of bow_hyperram (clk_i domain): the main bus slave at the
// HyperRAM window (WinBits of decode, MemBytes of device) with a read buffer
// and a posted write buffer, talking to bow_hyperram_ctrl through two
// asynchronous FIFOs (instantiated in bow_hyperram). docs/ip/hyperram.md,
// "Cửa sổ bộ nhớ".
//
// Read buffer (RBUF_EN): Lines lines of 32 bytes (8 bus words) with a tag and
//   a valid bit per word. A read hit is answered like an SRAM (gnt in the
//   request cycle, rvalid the next). A miss pushes one line fill (WopRdLine;
//   with WRAP_FILL a wrapped burst that starts at the requested word, so it
//   comes first, else a linear burst from the start of the line) into a line
//   chosen round robin, and answers the request as soon as its word is in;
//   the rest of the line keeps arriving while other hits are served. Only one
//   fill is in flight; a read of another missing line, and any write, wait
//   until it is complete. RBUF_EN = 0: every read is one WopRdWord.
// Writes: the line buffer is updated when it holds the line (write through),
//   so it never returns stale data.
//   WPOST = 1 (posted): the write is merged into the write buffer (one 32 byte
//   block with byte enables) and granted at once; the block is pushed as one
//   WopWr burst (first .. last written word, unwritten bytes masked by RWDS)
//   when a write to another block comes, before any read miss (so the fill
//   sees the data), on CMD.FLUSH, or after wb_tmo_i cycles without a write
//   (0: no timeout). A posted write that the controller refuses (device not
//   active, EN = 0) is lost and raises STATUS.WR_ERR (ev, not a bus error).
//   The controller answers every block, posted or not (WrespWdone at the end
//   of its transaction, WrespErr when refused); pout_q counts the posted
//   blocks in flight and idle_o waits for them, so STATUS.WIN_IDLE = 1 after
//   CMD.FLUSH means the data are in the device. Responses come in command
//   order and a posted block is never pushed while a fill or a non-posted
//   write is outstanding, so a WrespWdone / WrespErr that arrives while
//   pout_q > 0 is the answer of the oldest posted block.
//   WPOST = 0: every write is one WopWr of one bus word, answered after the
//   controller's WrespWdone (bus error on WrespErr).
// Errors (bus error, no HyperRAM access): offset >= MemBytes (RANGE); window
//   not ready (STATUS.READY = 0: not initialised, device asleep, CORE_RST,
//   link down) or dead (NOT_READY). A read whose fill / word read fails gets
//   a bus error (the line is dropped). No response within WinTimeout cycles,
//   or the HyperRAM clock lost while the link stays up (abort_i with
//   clk_lost_i): bus error, BUS_TIMEOUT, and the window is dead (STATUS.BROKEN)
//   until the channel reset (CTRL.CORE_RST or a link reset): a late answer
//   must never be taken for the next request. err_addr_o keeps the address of
//   the last access answered with an error.
// Reset domains: the bus slave (state, rvalid, rdata, err, err_addr) uses
// rst_ni (SoC reset) so that a granted access always gets its rvalid; the
// channel side (fill, buffers, pusher, dead) uses chn_rst_ni (link reset or
// CORE_RST): a pending access is then answered with a bus error. CORE_RST
// drops posted data that is still in the write buffer.

module bow_hyperram_win import bow_bus_pkg::*; import bow_hyperram_pkg::*; #(
  parameter int unsigned MemBytes   = 32 << 20,   // device size, power of two, <= 2^WinBits
  parameter int unsigned WinBits    = 28,         // window decode (offset = addr[WinBits-1:0])
  parameter int unsigned Lines      = 4,          // read buffer lines, 1..8
  parameter int unsigned WinTimeout = 1 << 18     // clk_i cycles
) (
  input  logic              clk_i,
  input  logic              rst_ni,       // SoC reset
  input  logic              chn_rst_ni,   // channel reset (link reset or CORE_RST), clk_i side

  input  bus_req_t          mem_req_i,
  output bus_rsp_t          mem_rsp_o,

  input  logic              ready_i,      // STATUS.READY
  input  logic              abort_i,      // !CLK_OK or CORE_RST: answer a waiting access now
  input  logic              clk_lost_i,   // !CLK_OK: an abort makes the window dead
  input  logic              rbuf_en_i,
  input  logic              wrap_fill_i,
  input  logic              wpost_i,
  input  logic [15:0]       wb_tmo_i,
  input  logic              flush_i,      // one cycle (CMD.FLUSH)
  input  logic              inval_i,      // one cycle (CMD.INVAL)

  output logic              idle_o,       // no fill, no posted data, nothing to push or wait for
  output logic              dead_o,
  output logic              ev_not_ready_o,
  output logic              ev_range_o,
  output logic              ev_timeout_o,
  output logic              ev_rd_err_o,  // a read answered with a bus error by the controller
  output logic              ev_wr_err_o,  // a posted block refused by the controller
  output logic [31:0]       err_addr_o,
  output logic              st_hit_o,     // statistics pulses
  output logic              st_miss_o,
  output logic              st_flush_o,

  // command FIFO, write side
  output logic              wc_push_o,
  output logic [WcmdW-1:0]  wc_wdata_o,
  input  logic              wc_full_i,
  // response FIFO, read side
  input  logic              wr_empty_i,
  input  logic [WrespW-1:0] wr_rdata_i,
  output logic              wr_pop_o
);

  localparam int unsigned MemLog2 = $clog2(MemBytes);
  localparam int unsigned LnW     = (Lines > 1) ? $clog2(Lines) : 1;
  localparam int unsigned TW      = $clog2(WinTimeout + 1);

  // ===========================================================================
  // Request decode
  // ===========================================================================
  logic [WinBits-1:0] off;
  logic               beyond;
  logic [LineAw-1:0]  rline;
  logic [2:0]         rword;

  assign off    = mem_req_i.addr[WinBits-1:0];
  assign beyond = (MemLog2 < WinBits) ? (off[WinBits-1:MemLog2] != '0) : 1'b0;
  assign rline  = LineAw'(off[MemLog2-1:$clog2(LineBytes)]);
  assign rword  = off[$clog2(LineBytes)-1:2];

  // ===========================================================================
  // Channel side state (chn_rst_ni)
  // ===========================================================================
  // read buffer
  logic [Lines-1:0]                 lv_q;      // line holds a tag
  logic [Lines-1:0][LineAw-1:0]     tag_q;
  logic [Lines-1:0][7:0]            wv_q;      // word valid
  logic [Lines-1:0][7:0][31:0]      ld_q;      // data (no reset)
  logic [LnW-1:0]                   rr_q;      // next victim

  // fill in flight
  logic                             fill_q;    // a WopRdLine / WopRdWord is outstanding
  logic                             fword_q;   // ... a WopRdWord (uncached)
  logic [LnW-1:0]                   fl_q;      // line being filled
  logic [2:0]                       fcrit_q;   // requested word of the fill
  logic [3:0]                       fcnt_q;    // words received
  logic                             fdone_q;   // the fill's requested word is in (or failed)
  logic                             ferr_q;    // ... it failed
  logic [31:0]                      fword_d_q; // WopRdWord: the data

  // non-posted write in flight
  logic                             wwait_q;   // WopWr (not posted) outstanding
  logic                             wdone_q;   // its answer is in
  logic                             werr_q;

  // write buffer (posted)
  logic                             wb_q;      // holds data
  logic [LineAw-1:0]                wbl_q;     // block
  logic [7:0][31:0]                 wbd_q;
  logic [7:0][3:0]                  wbe_q;
  logic [15:0]                      wbage_q;   // cycles since the last posted write
  logic                             flush_pend_q;
  logic [4:0]                       pout_q;    // posted blocks pushed, not answered yet

  // pusher: one command (header + up to 8 data entries) into the FIFO
  logic                             pb_q;      // busy
  logic                             ph_q;      // header still to push
  whdr_t                            phdr_q;
  logic [7:0][31:0]                 pd_q;
  logic [7:0][3:0]                  pbe_q;
  logic [2:0]                       pidx_q;    // next data word
  logic [3:0]                       pleft_q;   // data entries still to push

  logic                             dead_q;
  logic [TW-1:0]                    tmr_q;     // outstanding response timer
  logic                             tmo_fire;  // ... runs out now
  logic                             tmo_fire_q;// the last failure was a timeout

  // ===========================================================================
  // Hit detection
  // ===========================================================================
  logic [Lines-1:0] tmatch;
  logic             thit, whit;     // tag present / word valid
  logic [LnW-1:0]   hl;             // matching line

  always_comb begin
    tmatch = '0;
    hl     = '0;
    for (int unsigned l = 0; l < Lines; l++) begin
      tmatch[l] = lv_q[l] && (tag_q[l] == rline);
      if (tmatch[l]) hl = LnW'(l);
    end
  end

  assign thit = |tmatch;
  assign whit = thit && wv_q[hl][rword];

  // ===========================================================================
  // Bus slave (rst_ni)
  // ===========================================================================
  typedef enum logic [1:0] {
    BIdle,
    BWait,     // waiting for the controller
    BGrant     // result in: gnt now, rvalid next cycle
  } bstate_e;

  bstate_e     bst_q;
  logic        rvalid_q, err_q;
  logic [31:0] rdata_q, err_addr_q;
  logic        nrdy_q, rng_q, tmo_q, rderr_q;

  logic ok;                 // the window may access the device
  logic fast_err, fast_hit, fast_wr;
  logic slow;               // a request that needs the slow path
  logic chn_ok;

  assign chn_ok   = chn_rst_ni && ready_i && !dead_q;
  assign ok       = chn_ok && !beyond;

  // posted write merge possible now: no fill, write buffer empty or same block,
  // or the pusher free to take the old block
  logic wb_same, can_post;
  assign wb_same  = wb_q && (wbl_q == rline);
  assign can_post = wpost_i && !fill_q && !wwait_q && (!wb_q || wb_same || !pb_q);

  assign fast_err = (bst_q == BIdle) && mem_req_i.req && (!chn_ok || beyond);
  assign fast_hit = (bst_q == BIdle) && mem_req_i.req && !mem_req_i.we && ok && rbuf_en_i && whit;
  assign fast_wr  = (bst_q == BIdle) && mem_req_i.req && mem_req_i.we && ok && can_post;
  assign slow     = (bst_q == BIdle) && mem_req_i.req && ok && !fast_hit && !fast_wr;

  // the slow path: what the request needs from the channel side. A read of a
  // line that is filling waits for its word (then it is a hit); a miss
  // flushes posted data first, then starts one fill (none may be in flight).
  // A line that holds the tag without the word outside a fill (not expected:
  // failed fills drop their tag) is filled again in place: tags stay unique.
  logic need_flush_rd, start_rd, start_wr;
  logic [LnW-1:0] victim;
  assign need_flush_rd = slow && !mem_req_i.we && !fill_q && wb_q && !pb_q;
  assign start_rd      = slow && !mem_req_i.we && !fill_q && !wb_q && !pb_q && !wwait_q;
  assign start_wr      = slow && mem_req_i.we && !wpost_i && !fill_q && !wb_q && !pb_q && !wwait_q;
  assign victim        = thit ? hl : rr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bst_q      <= BIdle;
      rvalid_q   <= 1'b0;
      err_q      <= 1'b0;
      rdata_q    <= '0;
      err_addr_q <= '0;
      nrdy_q     <= 1'b0;
      rng_q      <= 1'b0;
      tmo_q      <= 1'b0;
      rderr_q    <= 1'b0;
    end else begin
      rvalid_q <= mem_rsp_o.gnt && mem_req_i.req;
      nrdy_q   <= 1'b0;
      rng_q    <= 1'b0;
      tmo_q    <= 1'b0;
      rderr_q  <= 1'b0;
      unique case (bst_q)
        BIdle: begin
          if (fast_err) begin
            err_q      <= 1'b1;
            rdata_q    <= '0;
            err_addr_q <= mem_req_i.addr;
            nrdy_q     <= !chn_ok;
            rng_q      <= chn_ok && beyond;
          end else if (fast_hit) begin
            err_q   <= 1'b0;
            rdata_q <= ld_q[hl][rword];
          end else if (fast_wr) begin
            err_q   <= 1'b0;
            rdata_q <= '0;
          end else if (start_rd || start_wr) begin
            bst_q <= BWait;
          end
        end

        BWait: begin
          if (abort_i) begin
            err_q      <= 1'b1;
            rdata_q    <= '0;
            err_addr_q <= mem_req_i.addr;
            tmo_q      <= clk_lost_i;
            nrdy_q     <= !clk_lost_i;
            bst_q      <= BGrant;
          end else if (!mem_req_i.we && fdone_q) begin
            err_q   <= ferr_q;
            rdata_q <= ferr_q ? 32'd0 : (fword_q ? fword_d_q : ld_q[fl_q][fcrit_q]);
            if (ferr_q) begin
              err_addr_q <= mem_req_i.addr;
              tmo_q      <= tmo_fire_q;
              rderr_q    <= !tmo_fire_q;
            end
            bst_q   <= BGrant;
          end else if (mem_req_i.we && wdone_q) begin
            err_q   <= werr_q;
            rdata_q <= '0;
            if (werr_q) begin
              err_addr_q <= mem_req_i.addr;
              tmo_q      <= tmo_fire_q;
            end
            bst_q   <= BGrant;
          end
        end

        default: bst_q <= BIdle;    // BGrant
      endcase
    end
  end

  assign mem_rsp_o.gnt    = fast_err || fast_hit || fast_wr || (bst_q == BGrant);
  assign mem_rsp_o.rvalid = rvalid_q;
  assign mem_rsp_o.err    = rvalid_q && err_q;
  assign mem_rsp_o.rdata  = rdata_q;

  assign ev_not_ready_o = nrdy_q;
  assign ev_range_o     = rng_q;
  assign ev_timeout_o   = tmo_q;
  assign ev_rd_err_o    = rderr_q;
  assign err_addr_o     = err_addr_q;

  // ===========================================================================
  // Channel side
  // ===========================================================================
  // response FIFO: always popped
  wresp_e      rk;
  logic [31:0] rdw;
  logic        rpop;
  assign rk   = wresp_e'(wr_rdata_i[33:32]);
  assign rdw  = wr_rdata_i[31:0];
  assign rpop = !wr_empty_i;
  assign wr_pop_o = rpop;

  logic rdata_in, rerr_in, rwdone_in, pack_in, post_refused;
  assign pack_in   = rpop && (rk == WrespWdone || rk == WrespErr) && (pout_q != '0);
  assign post_refused = pack_in && (rk == WrespErr);
  assign ev_wr_err_o  = post_refused;   // with the pout_q update: WR_ERR no later than WIN_IDLE
  assign rdata_in  = rpop && (rk == WrespData || rk == WrespDataW);
  assign rerr_in   = rpop && (rk == WrespErr) && !pack_in;
  assign rwdone_in = rpop && (rk == WrespWdone) && !pack_in;

  // fill word index of an arriving word
  logic [2:0] fidx;
  assign fidx = (rk == WrespDataW) ? fcrit_q + fcnt_q[2:0] : fcnt_q[2:0];

  // timeout of the outstanding response
  assign tmo_fire = (fill_q || wwait_q) && (tmr_q == '0);

  // write buffer flush (posted data into the pusher)
  logic wb_flush, wb_to_pusher, post_merge, post_new;
  assign wb_to_pusher = wb_q && !pb_q && !fill_q && !wwait_q &&
                        (need_flush_rd || flush_pend_q || flush_i ||
                         (wb_tmo_i != 16'd0 && wbage_q >= wb_tmo_i) ||
                         (fast_wr && !wb_same) ||
                         (slow && mem_req_i.we && !wpost_i));
  assign wb_flush     = wb_to_pusher;
  // a write in the cycle the buffer goes to the pusher (another block, the
  // timeout, FLUSH) starts a new block: merged into the old one it would be
  // lost with it
  assign post_merge   = fast_wr && wb_same && !wb_flush;
  assign post_new     = fast_wr && (!wb_same || wb_flush);

  // line update by a write (posted at merge time, non-posted when done)
  logic        lw_en;
  logic [31:0] lw_d;
  logic [3:0]  lw_be;
  assign lw_en = (fast_wr || (bst_q == BWait && mem_req_i.we && wdone_q && !werr_q)) && thit &&
                 wv_q[hl][rword];
  assign lw_d  = mem_req_i.wdata;
  assign lw_be = mem_req_i.be;

  function automatic logic [31:0] merge(logic [31:0] o, logic [31:0] d, logic [3:0] be);
    logic [31:0] r;
    r = o;
    for (int unsigned b = 0; b < 4; b++) if (be[b]) r[8*b +: 8] = d[8*b +: 8];
    return r;
  endfunction

  // first / last written word of the write buffer
  logic [2:0] wb_first, wb_last;
  always_comb begin
    wb_first = 3'd0;
    wb_last  = 3'd0;
    for (int i = 7; i >= 0; i--) if (wbe_q[i] != 4'h0) wb_first = 3'(i);
    for (int i = 0; i < 8; i++)  if (wbe_q[i] != 4'h0) wb_last  = 3'(i);
  end

  // ---- channel flops
  always_ff @(posedge clk_i or negedge chn_rst_ni) begin
    if (!chn_rst_ni) begin
      lv_q         <= '0;
      tag_q        <= '0;
      wv_q         <= '0;
      rr_q         <= '0;
      fill_q       <= 1'b0;
      fword_q      <= 1'b0;
      fl_q         <= '0;
      fcrit_q      <= '0;
      fcnt_q       <= '0;
      fdone_q      <= 1'b0;
      ferr_q       <= 1'b0;
      fword_d_q    <= '0;
      wwait_q      <= 1'b0;
      wdone_q      <= 1'b0;
      werr_q       <= 1'b0;
      wb_q         <= 1'b0;
      wbl_q        <= '0;
      wbe_q        <= '0;
      wbage_q      <= '0;
      flush_pend_q <= 1'b0;
      pout_q       <= '0;
      pb_q         <= 1'b0;
      ph_q         <= 1'b0;
      phdr_q       <= '0;
      pbe_q        <= '0;
      pidx_q       <= '0;
      pleft_q      <= '0;
      dead_q       <= 1'b0;
      tmr_q        <= '0;
      tmo_fire_q   <= 1'b0;
    end else begin
      // ---- commands
      if (flush_i) flush_pend_q <= 1'b1;

      // ---- invalidate at once (CMD.INVAL, the IP's own INVAL after BIST /
      // WAKE / HW_RESET, a refused posted block whose data may sit in a line):
      // every line, also one still filling (its words keep arriving, the line
      // stays invalid; the access waiting for it is answered from the fill
      // data). A fill starting in this cycle keeps its line (assigned below).
      if (inval_i || post_refused) begin
        lv_q <= '0;
        wv_q <= '0;
      end

      // ---- start a read (slow path)
      if (start_rd) begin
        pb_q    <= 1'b1;
        ph_q    <= 1'b1;
        pleft_q <= 4'd0;
        fill_q  <= 1'b1;
        fdone_q <= 1'b0;
        ferr_q  <= 1'b0;
        fcnt_q  <= '0;
        fcrit_q <= rword;
        tmr_q   <= TW'(WinTimeout);
        tmo_fire_q <= 1'b0;
        if (rbuf_en_i) begin
          fword_q          <= 1'b0;
          fl_q             <= victim;
          lv_q[victim]     <= 1'b1;
          tag_q[victim]    <= rline;
          wv_q[victim]     <= '0;
          if (!thit) rr_q  <= (32'(rr_q) == Lines - 1) ? '0 : rr_q + LnW'(1);
          phdr_q           <= '{op: WopRdLine, posted: 1'b0, wrap: wrap_fill_i, crit: rword,
                                first: 3'd0, last: 3'd0, line: rline};
        end else begin
          fword_q <= 1'b1;
          phdr_q  <= '{op: WopRdWord, posted: 1'b0, wrap: 1'b0, crit: rword,
                       first: 3'd0, last: 3'd0, line: rline};
        end
      end

      // ---- start a non-posted write (slow path)
      if (start_wr) begin
        pb_q       <= 1'b1;
        ph_q       <= 1'b1;
        pleft_q    <= 4'd1;
        pidx_q     <= rword;
        pd_q[rword]  <= mem_req_i.wdata;
        pbe_q[rword] <= mem_req_i.be;
        phdr_q     <= '{op: WopWr, posted: 1'b0, wrap: 1'b0, crit: 3'd0, first: rword, last: rword,
                        line: rline};
        wwait_q    <= 1'b1;
        wdone_q    <= 1'b0;
        werr_q     <= 1'b0;
        tmr_q      <= TW'(WinTimeout);
        tmo_fire_q <= 1'b0;
      end

      // ---- write buffer -> pusher (posted data)
      if (wb_flush) begin
        pb_q         <= 1'b1;
        ph_q         <= 1'b1;
        pleft_q      <= 4'({1'b0, wb_last} - {1'b0, wb_first}) + 4'd1;
        pidx_q       <= wb_first;
        pd_q         <= wbd_q;
        pbe_q        <= wbe_q;
        phdr_q       <= '{op: WopWr, posted: 1'b1, wrap: 1'b0, crit: 3'd0, first: wb_first,
                          last: wb_last, line: wbl_q};
        wb_q         <= 1'b0;
        wbe_q        <= '0;
        flush_pend_q <= 1'b0;
      end else if (!wb_q) begin
        flush_pend_q <= 1'b0;
      end
      // posted blocks in flight (at most the command FIFO's worth)
      if (wb_flush && !pack_in) begin
        pout_q <= pout_q + 5'd1;
      end else if (pack_in && !wb_flush) begin
        pout_q <= pout_q - 5'd1;
      end

      // ---- posted write: merge into the write buffer
      if (post_new) begin
        wb_q                <= 1'b1;
        wbl_q               <= rline;
        wbe_q               <= '0;
        wbe_q[rword]        <= mem_req_i.be;
        wbd_q[rword]        <= mem_req_i.wdata;
        wbage_q             <= '0;
      end else if (post_merge) begin
        wbe_q[rword]        <= wbe_q[rword] | mem_req_i.be;
        wbd_q[rword]        <= merge(wbd_q[rword], mem_req_i.wdata, mem_req_i.be);
        wbage_q             <= '0;
      end else if (wb_q && wbage_q != '1) begin
        wbage_q <= wbage_q + 16'd1;
      end

      // ---- pusher
      if (pb_q && !wc_full_i) begin
        if (ph_q) begin
          ph_q <= 1'b0;
          if (pleft_q == 4'd0) pb_q <= 1'b0;
        end else begin
          pidx_q  <= pidx_q + 3'd1;
          pleft_q <= pleft_q - 4'd1;
          if (pleft_q == 4'd1) pb_q <= 1'b0;
        end
      end

      // ---- line update by a write
      if (lw_en) ld_q[hl][rword] <= merge(ld_q[hl][rword], lw_d, lw_be);

      // ---- responses
      if (rdata_in && fill_q) begin
        if (fword_q) begin
          fword_d_q <= rdw;
          fdone_q   <= 1'b1;
          fill_q    <= 1'b0;
        end else begin
          ld_q[fl_q][fidx] <= rdw;
          wv_q[fl_q][fidx] <= 1'b1;
          fcnt_q           <= fcnt_q + 4'd1;
          if (fidx == fcrit_q) fdone_q <= 1'b1;
          if (fcnt_q == 4'd7) fill_q <= 1'b0;
        end
      end
      if (rerr_in) begin
        if (fill_q) begin
          fill_q  <= 1'b0;
          fdone_q <= 1'b1;
          ferr_q  <= 1'b1;
          if (!fword_q) begin
            lv_q[fl_q] <= 1'b0;
            wv_q[fl_q] <= '0;
          end
        end
        if (wwait_q) begin
          wwait_q <= 1'b0;
          wdone_q <= 1'b1;
          werr_q  <= 1'b1;
        end
      end
      if (rwdone_in && wwait_q) begin
        wwait_q <= 1'b0;
        wdone_q <= 1'b1;
        werr_q  <= 1'b0;
      end
      // a non-posted write that failed leaves the line it may have touched
      if (bst_q == BWait && mem_req_i.we && wdone_q && werr_q && thit) begin
        lv_q[hl] <= 1'b0;
        wv_q[hl] <= '0;
      end

      // ---- timeout: the window is dead
      if ((fill_q || wwait_q) && tmr_q != '0) tmr_q <= tmr_q - TW'(1);
      if (tmo_fire) begin
        dead_q     <= 1'b1;
        tmo_fire_q <= 1'b1;
        if (fill_q) begin
          fill_q  <= 1'b0;
          fdone_q <= 1'b1;
          ferr_q  <= 1'b1;
          if (!fword_q) begin
            lv_q[fl_q] <= 1'b0;
            wv_q[fl_q] <= '0;
          end
        end
        if (wwait_q) begin
          wwait_q <= 1'b0;
          wdone_q <= 1'b1;
          werr_q  <= 1'b1;
        end
      end
      // an abort by a lost clock while the link is up: dead as well
      if (abort_i && clk_lost_i && (fill_q || wwait_q || bst_q == BWait)) dead_q <= 1'b1;

    end
  end

  // pusher output
  always_comb begin
    wc_push_o  = pb_q && !wc_full_i;
    wc_wdata_o = ph_q ? {1'b1, 36'(phdr_q)} : {1'b0, pbe_q[pidx_q], pd_q[pidx_q]};
  end

  assign idle_o     = !fill_q && !wwait_q && !wb_q && !pb_q && (pout_q == '0) && (bst_q != BWait);
  assign dead_o     = dead_q;
  assign st_hit_o   = fast_hit;
  assign st_miss_o  = start_rd;
  assign st_flush_o = wb_flush;

  logic unused;
  assign unused = ^{mem_req_i.addr[31:WinBits], mem_req_i.addr[1:0], off[MemLog2 > 0 ? 0 : 0]};

`ifndef SYNTHESIS
  if (MemLog2 > WinBits || (1 << MemLog2) != MemBytes || MemLog2 < 5) begin : g_bad_mem
    initial $fatal(1, "bow_hyperram_win: MemBytes must be a power of two, 32 B .. 2^WinBits");
  end
  if (Lines < 1 || Lines > 8) begin : g_bad_lines
    initial $fatal(1, "bow_hyperram_win: Lines must be 1..8");
  end
  if (MemLog2 - 5 > LineAw) begin : g_bad_aw
    initial $fatal(1, "bow_hyperram_win: MemBytes too large for LineAw");
  end
`endif

endmodule
