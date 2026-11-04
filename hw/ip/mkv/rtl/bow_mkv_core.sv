// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// MKV block cipher engine (draft TCVN XXXX:2024): MKV-128 / MKV-256, keys of
// l, 3l/2 and 2l bits (R = 6, 7, 8 rounds), key schedule, encryption and
// decryption. One half-round per clock (docs/ip/mkv.md):
//
//   encryption  2R half-rounds  x <- L(S(x ^ h[s])), L = MixWords (s even) or
//               XWords (s odd), then x ^ K_post                 2R + 1 cycles
//   decryption  x ^ K_post, then 2R inverse half-rounds
//               x <- S^-1(L^-1(x)) ^ h[2R - s]                   2R + 1 cycles
//   key         R updates UpdateKS, each two F(0, F(c, x)) on the forward
//               half-round datapath, 8 cycles per update        8R cycles
//
// (busy cycles after the cycle that takes the command; the CYCLES register
// of bow_mkv also counts that one: 2R + 2 and 8R + 1)
//
// The half-round keys h[0..2R] = K_0^L, K_1^L, K_1^R, ..., K_R^R (round key
// i = h[2i] || h[2i+1], K_post = h[2R]) are kept in a 32 x 256 bit
// distributed RAM, written once by the key schedule.
//
// Commands are one cycle pulses, taken only while busy_o = 0 (the register
// block makes sure). wide_i / klen_i are sampled with key_i: encryption and
// decryption use the version of the last key schedule.

module bow_mkv_core import bow_mkv_pkg::*; (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         key_i,       // key schedule from key_data_i
  input  logic         enc_i,       // encrypt din_i
  input  logic         dec_i,       // decrypt din_i
  input  logic         clear_i,     // zero the round keys and the state
  input  logic         wide_i,      // with key_i: 0 MKV-128, 1 MKV-256
  input  logic [1:0]   klen_i,      // with key_i: 0 k = l, 1 k = 3l/2, 2 k = 2l
  input  logic [511:0] key_data_i,  // master key, byte b = key_data_i[8*b +: 8]
  input  logic [255:0] din_i,       // block, byte b = din_i[8*b +: 8]

  output logic         busy_o,
  output logic         done_o,      // last cycle of a command
  output logic [255:0] dout_o,      // result of the last encryption / decryption
  output logic         wide_o,      // version of the key schedule
  output logic [3:0]   rounds_o
);

  typedef enum logic [2:0] {Idle, KeySched, Encrypt, Decrypt, Clear} fsm_e;

  localparam int unsigned RkDepth = 32;

  fsm_e       fsm_q;
  logic       wide_q;
  logic [3:0] rounds_q;   // R
  logic [4:0] step_q;     // encryption / decryption step 0..2R, clear address
  logic [3:0] upd_q;      // key schedule update i = 1..R
  logic [1:0] half_q;     // key schedule: half-round of F(0, F(c, x))
  logic       left_q;     // key schedule: 0 right branch (-> K_i^L), 1 left
  state_t     st_q, kl_q, kr_q, dout_q;

  logic [4:0] last_step;  // 2R
  assign last_step = {rounds_q, 1'b0};

  // ------------------------------------------------------- round key memory
  state_t     rk_mem [RkDepth];
  logic       rk_we;
  logic [4:0] rk_waddr, rk_raddr;
  state_t     rk_wdata, rk_rdata;

  always_ff @(posedge clk_i) begin
    if (rk_we) rk_mem[rk_waddr] <= rk_wdata;
  end
  assign rk_rdata = rk_mem[rk_raddr];

  // ----------------------------------------------- initial key state K_0
  //   k = 2l    k0 .. k7          k = 3l/2   k0 .. k5 ~k2 ~k3
  //   k = l     k0 .. k3 ~k0 .. ~k3            (words k_i of l/4 bits)
  state_t k0l, k0r;
  always_comb begin
    if (wide_i) begin
      k0l = key_data_i[255:0];
      unique case (klen_i)
        2'd0:    k0r = ~key_data_i[255:0];
        2'd1:    k0r = {~key_data_i[255:128], key_data_i[383:256]};
        default: k0r = key_data_i[511:256];
      endcase
    end else begin
      k0l = {128'h0, key_data_i[127:0]};
      unique case (klen_i)
        2'd0:    k0r = {128'h0, ~key_data_i[127:0]};
        2'd1:    k0r = {128'h0, ~key_data_i[127:64], key_data_i[191:128]};
        default: k0r = {128'h0, key_data_i[255:128]};
      endcase
    end
  end

  // ------------------------------------------------- forward half-round
  // L(S(x ^ k)): encryption (key h[s]) and key schedule. Key schedule
  // constant of update i: c(v) = <v>_l || 0^l, v = 2i (right branch) or
  // 2i - 1 (left branch), i.e. v in the last byte of the first key.
  state_t     fwd_in, fwd_key, fwd_out, sched_const;
  logic       fwd_mix;
  logic [7:0] sched_v;

  assign sched_v     = {3'b000, upd_q, 1'b0} - {7'h00, left_q};
  assign sched_const = wide_q ? {sched_v, 248'h0} : {128'h0, sched_v, 120'h0};

  always_comb begin
    if (fsm_q == KeySched) begin
      fwd_in  = (half_q == 2'd0) ? (left_q ? kl_q : kr_q) : st_q;
      fwd_key = (half_q == 2'd0) ? sched_const : '0;
      fwd_mix = ~half_q[0];
    end else begin
      fwd_in  = st_q;
      fwd_key = rk_rdata;
      fwd_mix = ~step_q[0];
    end
  end

  state_t fwd_sub;
  assign fwd_sub = sub_cells(fwd_in ^ fwd_key);
  assign fwd_out = fwd_mix ? mix_words(fwd_sub, wide_q) : x_words(fwd_sub, wide_q);

  // ------------------------------------------------- inverse half-round
  // S^-1(L^-1(x)) ^ h[2R - s], L^-1 = XWords (s odd) or invMixWords (s even)
  state_t inv_lin, inv_out;
  assign inv_lin = step_q[0] ? x_words(st_q, wide_q) : inv_mix_words(st_q, wide_q);
  assign inv_out = (inv_sub_cells(inv_lin) ^ rk_rdata) & block_mask(wide_q);

  // ---------------------------------------------------------------- control
  logic last;   // last cycle of the running command
  always_comb begin
    unique case (fsm_q)
      KeySched:         last = (half_q == 2'd3) && left_q && (upd_q == rounds_q);
      Encrypt, Decrypt: last = (step_q == last_step);
      Clear:            last = (step_q == 5'(RkDepth - 1));
      default:          last = 1'b0;
    endcase
  end

  always_comb begin
    rk_we    = 1'b0;
    rk_waddr = step_q;
    rk_wdata = '0;
    rk_raddr = (fsm_q == Decrypt) ? last_step - step_q : step_q;
    unique case (fsm_q)
      Idle: begin
        if (key_i) begin
          rk_we    = 1'b1;                    // h[0] = K_0^L
          rk_waddr = 5'd0;
          rk_wdata = k0l;
        end
      end
      KeySched: begin
        if (half_q == 2'd3) begin
          rk_we    = 1'b1;                    // h[2i-1] = K_i^L, h[2i] = K_i^R
          rk_waddr = left_q ? {upd_q, 1'b0} : {upd_q, 1'b0} - 5'd1;
          rk_wdata = left_q ? kr_q ^ fwd_out : fwd_out;
        end
      end
      Clear:   rk_we = 1'b1;                  // h[step] = 0
      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fsm_q    <= Idle;
      wide_q   <= 1'b0;
      rounds_q <= 4'd6;
      step_q   <= '0;
      upd_q    <= 4'd1;
      half_q   <= '0;
      left_q   <= 1'b0;
      st_q     <= '0;
      kl_q     <= '0;
      kr_q     <= '0;
      dout_q   <= '0;
    end else begin
      unique case (fsm_q)
        Idle: begin
          step_q <= '0;
          if (key_i) begin
            fsm_q    <= KeySched;
            wide_q   <= wide_i;
            rounds_q <= 4'd6 + ((klen_i == 2'd3) ? 4'd2 : {2'b00, klen_i});
            kl_q     <= k0l;
            kr_q     <= k0r;
            upd_q    <= 4'd1;
            half_q   <= 2'd0;
            left_q   <= 1'b0;
          end else if (enc_i || dec_i) begin
            fsm_q <= enc_i ? Encrypt : Decrypt;
            st_q  <= din_i & block_mask(wide_q);
          end else if (clear_i) begin
            fsm_q  <= Clear;
            st_q   <= '0;
            kl_q   <= '0;
            kr_q   <= '0;
            dout_q <= '0;
          end
        end
        KeySched: begin
          st_q   <= fwd_out;
          half_q <= half_q + 2'd1;
          if (half_q == 2'd3) begin
            left_q <= ~left_q;
            if (!left_q) begin
              kr_q <= fwd_out;               // K_i^L, until the left branch is done
            end else begin
              kl_q  <= kr_q;                 // K_i^L
              kr_q  <= kr_q ^ fwd_out;       // K_i^R = K_i^L ^ F(0, F(c(2i-1), K_{i-1}^L))
              upd_q <= upd_q + 4'd1;
              if (last) fsm_q <= Idle;
            end
          end
        end
        Encrypt: begin
          step_q <= step_q + 5'd1;
          if (last) begin
            st_q   <= st_q ^ rk_rdata;       // whitening with K_post
            dout_q <= st_q ^ rk_rdata;
            fsm_q  <= Idle;
          end else begin
            st_q <= fwd_out;
          end
        end
        Decrypt: begin
          step_q <= step_q + 5'd1;
          st_q   <= (step_q == 5'd0) ? st_q ^ rk_rdata : inv_out;   // C ^ K_post first
          if (last) begin
            dout_q <= inv_out;
            fsm_q  <= Idle;
          end
        end
        Clear: begin
          step_q <= step_q + 5'd1;
          if (last) fsm_q <= Idle;
        end
        default: fsm_q <= Idle;
      endcase
    end
  end

  assign busy_o   = (fsm_q != Idle);
  assign done_o   = (fsm_q != Idle) && last;
  assign dout_o   = dout_q;
  assign wide_o   = wide_q;
  assign rounds_o = rounds_q;

endmodule
