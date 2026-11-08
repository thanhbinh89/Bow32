// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// HyperRAM built-in self test (hr_clk domain): a pattern generator for write
// bursts and a checker for read bursts, driven by bow_hyperram_ctrl like any
// other transaction source. docs/ip/hyperram.md, "BIST".
//
// start_i takes the configuration (quasi-static registers BIST_*):
//   addr_i  first HyperRAM word address, len_i words in total (>= 1),
//   burst_i words per transaction (1..255; the controller refuses a burst
//           whose CS# low time would exceed TCSM: the run stops with an error),
//   mode_i  [0] write pass, [1] read pass (both: the whole write pass, then the
//           whole read pass), [2] pattern: 0 = xorshift32 PRBS seeded with
//           seed_i at the start of each pass (word = state[15:0], then the
//           state advances), 1 = word address [15:0] ^ seed_i[15:0].
//   Byte A of a word = data[7:0], byte B = data[15:8] (memory order: the bus
//   reads the word at byte address 2 * waddr as data[15:0]).
// Bursts: req_o with req_wr_o / req_addr_o / req_n_o while a burst is due;
// the controller pulses take_i when the transaction starts, wnext_i for every
// write word it puts on DQ (wdata_o is the word of that cycle), rv_i for every
// word read, bdone_i at the end of every transaction (the read data are in),
// with berr_i when it failed or was refused: the run stops then.
// Results: errs_o (mismatching words of the read pass), faddr_o / fexp_o /
// fgot_o of the first mismatch, cycles_o (start to done), done_o (one pulse),
// busy_o. stop_i aborts after the running transaction (done_o, aborted_o).

module bow_hyperram_bist (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        start_i,
  input  logic        stop_i,
  input  logic [2:0]  mode_i,
  input  logic [7:0]  burst_i,
  input  logic [31:0] addr_i,
  input  logic [31:0] len_i,
  input  logic [31:0] seed_i,

  output logic        req_o,
  output logic        req_wr_o,
  output logic [31:0] req_addr_o,
  output logic [7:0]  req_n_o,
  input  logic        take_i,
  input  logic        wnext_i,
  output logic [15:0] wdata_o,
  input  logic        rv_i,
  input  logic [15:0] rdata_i,
  input  logic        bdone_i,
  input  logic        berr_i,

  output logic        busy_o,
  output logic        done_o,
  output logic        failed_o,    // with done_o: a transaction failed or was refused
  output logic        aborted_o,   // with done_o: stop_i
  output logic [31:0] errs_o,
  output logic [31:0] faddr_o,
  output logic [15:0] fexp_o,
  output logic [15:0] fgot_o,
  output logic [31:0] cycles_o
);

  typedef enum logic [2:0] {
    BIdle,
    BReq,      // next burst due (req_o)
    BRun,      // transaction running
    BDone
  } bstate_e;

  bstate_e     st_q;
  logic        pass_rd_q;          // 0 write pass, 1 read pass
  logic [2:0]  mode_q;
  logic [7:0]  burst_q;
  logic [31:0] base_q, len_q;
  logic [15:0] seed_q;             // counter pattern
  logic [31:0] next_q;             // next word address to request (offset)
  logic [31:0] gen_a_q, chk_a_q;   // address of the next generated / checked word
  logic [31:0] gen_x_q, chk_x_q;   // PRBS states
  logic        stop_q, fail_q;
  logic [31:0] errs_q, faddr_q, cyc_q;
  logic [15:0] fexp_q, fgot_q;
  logic [7:0]  cur_n;

  function automatic logic [31:0] xs32(logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13);
    y = y ^ (y >> 17);
    y = y ^ (y << 5);
    return y;
  endfunction

  function automatic logic [31:0] seed0(logic [31:0] s);
    return (s == 32'd0) ? 32'h1 : s;      // xorshift: never 0
  endfunction

  function automatic logic [15:0] word(logic pat, logic [15:0] x, logic [15:0] a, logic [15:0] s);
    return pat ? (a ^ s) : x;
  endfunction

  logic [31:0] remain;
  assign remain = len_q - next_q;
  assign cur_n  = (remain > 32'(burst_q)) ? burst_q : remain[7:0];

  logic [15:0] exp_w;
  assign exp_w   = word(mode_q[2], chk_x_q[15:0], chk_a_q[15:0], seed_q);
  assign wdata_o = word(mode_q[2], gen_x_q[15:0], gen_a_q[15:0], seed_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q      <= BIdle;
      pass_rd_q <= 1'b0;
      mode_q    <= '0;
      burst_q   <= 8'd1;
      base_q    <= '0;
      len_q     <= '0;
      seed_q    <= '0;
      next_q    <= '0;
      gen_a_q   <= '0;
      chk_a_q   <= '0;
      gen_x_q   <= 32'h1;
      chk_x_q   <= 32'h1;
      stop_q    <= 1'b0;
      fail_q    <= 1'b0;
      errs_q    <= '0;
      faddr_q   <= '0;
      fexp_q    <= '0;
      fgot_q    <= '0;
      cyc_q     <= '0;
    end else begin
      if (st_q != BIdle && st_q != BDone) cyc_q <= cyc_q + 32'd1;
      if (stop_i && st_q != BIdle) stop_q <= 1'b1;

      // write data generator: one word per wnext_i
      if (wnext_i) begin
        gen_a_q <= gen_a_q + 32'd1;
        gen_x_q <= xs32(gen_x_q);
      end
      // checker: one word per rv_i
      if (rv_i) begin
        chk_a_q <= chk_a_q + 32'd1;
        chk_x_q <= xs32(chk_x_q);
        if (rdata_i != exp_w) begin
          if (errs_q == 32'd0) begin
            faddr_q <= chk_a_q;       // chk_a_q is the absolute word address
            fexp_q  <= exp_w;
            fgot_q  <= rdata_i;
          end
          if (errs_q != '1) errs_q <= errs_q + 32'd1;
        end
      end

      unique case (st_q)
        BIdle: begin
          if (start_i && len_i != 32'd0 && mode_i[1:0] != 2'b00) begin
            mode_q    <= mode_i;
            burst_q   <= (burst_i == 8'd0) ? 8'd1 : burst_i;
            base_q    <= addr_i;
            len_q     <= len_i;
            seed_q    <= seed_i[15:0];
            pass_rd_q <= !mode_i[0];
            next_q    <= '0;
            gen_a_q   <= addr_i;
            chk_a_q   <= addr_i;
            gen_x_q   <= seed0(seed_i);
            chk_x_q   <= seed0(seed_i);
            stop_q    <= 1'b0;
            fail_q    <= 1'b0;
            errs_q    <= '0;
            faddr_q   <= '0;
            fexp_q    <= '0;
            fgot_q    <= '0;
            cyc_q     <= '0;
            st_q      <= BReq;
          end else if (start_i) begin
            st_q <= BDone;           // nothing to do: done at once
          end
        end

        BReq: begin
          if (stop_q || stop_i) begin
            st_q <= BDone;
          end else if (take_i && bdone_i && berr_i) begin
            fail_q <= 1'b1;          // refused at once (tCSM, device not ready): stop
            st_q   <= BDone;
          end else if (take_i) begin
            st_q <= BRun;
          end
        end

        BRun: begin
          if (bdone_i) begin
            if (berr_i) begin
              fail_q <= 1'b1;
              st_q   <= BDone;
            end else begin
              next_q <= next_q + 32'(cur_n);
              if (next_q + 32'(cur_n) >= len_q) begin
                if (!pass_rd_q && mode_q[1]) begin
                  pass_rd_q <= 1'b1;   // write pass done: read pass
                  next_q    <= '0;
                  st_q      <= stop_q ? BDone : BReq;
                end else begin
                  st_q <= BDone;
                end
              end else begin
                st_q <= stop_q ? BDone : BReq;
              end
            end
          end
        end

        default: st_q <= BIdle;      // BDone: one cycle (done_o)
      endcase
    end
  end

  assign req_o      = (st_q == BReq) && !stop_q;
  assign req_wr_o   = !pass_rd_q;
  assign req_addr_o = base_q + next_q;
  assign req_n_o    = cur_n;

  assign busy_o    = (st_q != BIdle);
  assign done_o    = (st_q == BDone);
  assign failed_o  = fail_q;
  assign aborted_o = stop_q;
  assign errs_o    = errs_q;
  assign faddr_o   = faddr_q;
  assign fexp_o    = fexp_q;
  assign fgot_o    = fgot_q;
  assign cycles_o  = cyc_q;

  logic unused;
  assign unused = mode_q[0];

endmodule
