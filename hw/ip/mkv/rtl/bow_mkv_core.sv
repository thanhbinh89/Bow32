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
// Fault detection: every command is done twice and its result is released
// only when both passes agree (state Check):
//   * ENC is followed by a decryption of its result on the inverse datapath,
//     DEC by an encryption of its result on the forward datapath; the second
//     pass must give back the input (kept in in_q),
//   * KEY runs the key schedule a second time from the master key and
//     compares every half-round key with the RAM (h[0] in Check),
//   * the round key RAM keeps a parity bit per byte, checked on every read of
//     ENC / DEC (a round key that changes in the RAM gives the same wrong
//     result in both passes),
//   * the version (R, block size) is kept as value and complement, a second
//     counter (cnt_q) has to run out exactly at the end of the command, a
//     state outside fsm_e or a return to Idle without Check is an error.
// A fault releases nothing (dout_valid_o stays 0): the engine pulses fault_o
// and zeroes the RAM and its registers (Clear, without done_o).
//
// Busy cycles after the cycle that takes the command: ENC / DEC 4R + 3, KEY
// 16R + 1, CLEAR 32 (the CYCLES register of bow_mkv also counts that cycle:
// 4R + 4, 16R + 2, 33).
//
// The half-round keys h[0..2R] = K_0^L, K_1^L, K_1^R, ..., K_R^R (round key
// i = h[2i] || h[2i+1], K_post = h[2R]) are kept in a 32 x (256 + 32 parity)
// bit distributed RAM, written once by the key schedule.
//
// No key material is left where it is not needed (UpdateKS can be inverted:
// any K_i^L, K_i^R gives back the master key):
//   * the key schedule zeroes h[2R+1..31] (round keys of a previous, longer
//     key) in the cycles in which it does not write the RAM,
//   * the engine keeps its own copies (K_R, the state, the input) at zero
//     while it is idle,
//   * KEY zeroes the result of the previous key (dout_o),
//   * after a reset the engine zeroes the whole RAM first (distributed RAM
//     has no reset): 32 cycles with busy_o = 1, without done_o.
//
// Commands are one cycle pulses, taken only while busy_o = 0 (the register
// block makes sure). wide_i / klen_i / key_data_i are sampled with key_i and
// read again by the second pass, so they must not change until the command
// ends; encryption and decryption use the version of the last key schedule.

module bow_mkv_core import bow_mkv_pkg::*; (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         key_i,        // key schedule from key_data_i
  input  logic         enc_i,        // encrypt din_i
  input  logic         dec_i,        // decrypt din_i
  input  logic         clear_i,      // zero the round keys and the state
  input  logic         wide_i,       // with key_i: 0 MKV-128, 1 MKV-256
  input  logic [1:0]   klen_i,       // with key_i: 0 k = l, 1 k = 3l/2, 2 k = 2l
  input  logic [511:0] key_data_i,   // master key, byte b = key_data_i[8*b +: 8]
  input  logic [255:0] din_i,        // block, byte b = din_i[8*b +: 8]

  output logic         busy_o,
  output logic         done_o,       // last cycle of a command that passed its check
  output logic         fault_o,      // fault detected: result dropped, all zeroed
  output logic [255:0] dout_o,       // result of the last encryption / decryption
  output logic         dout_valid_o, // dout_o is a checked result
  output logic         wide_o,       // version of the key schedule
  output logic [3:0]   rounds_o
);

  typedef enum logic [2:0] {Idle, KeySched, Encrypt, Decrypt, Clear, Check} fsm_e;

  localparam int unsigned RkDepth = 32;

  // Keep the encoding of fsm_e (Encrypt / Decrypt = 01x): Vivado re-encodes an
  // FSM from its reset state (Clear), which makes the state decoders of the
  // whole datapath larger (about +200 LUT measured on kv260).
  (* fsm_encoding = "none" *) fsm_e fsm_q;
  logic       wipe_q;      // Clear not started by CLEAR (reset, fault): no done_o
  logic       run_q;       // a command is running (until Check / end of Clear)
  logic       chk_q;       // second pass of the running command
  logic       op_key_q;    // the running command is KEY
  logic       ks_valid_q;  // the RAM holds a checked key schedule
  logic       dout_ok_q;   // dout_q holds a checked result
  logic       fault_q;     // a fault was seen in the last cycle
  logic       wide_q, wide_n_q;        // version: value and complement
  logic [3:0] rounds_q, rounds_n_q;    // R
  logic [7:0] cnt_q;       // busy cycles left in the running command
  logic [4:0] step_q;      // encryption / decryption step 0..2R, clear address
                           // (key schedule: next stale round key 2R+1..31, 0 = done)
  logic [3:0] upd_q;       // key schedule update i = 1..R
  logic [1:0] half_q;      // key schedule: half-round of F(0, F(c, x))
  logic       left_q;      // key schedule: 0 right branch (-> K_i^L), 1 left
  state_t     st_q, kl_q, kr_q, in_q, dout_q;

  logic [4:0] last_step;   // 2R
  assign last_step = {rounds_q, 1'b0};

  logic [3:0] rounds_d;    // R of the version of a KEY command
  assign rounds_d = 4'd6 + ((klen_i == 2'd3) ? 4'd2 : {2'b00, klen_i});

  // ------------------------------------------------------- round key memory
  // half-round key and one even parity bit per byte
  function automatic logic [31:0] byte_parity(state_t x);
    logic [31:0] p;
    for (int b = 0; b < 32; b++) p[b] = ^x[8*b +: 8];
    return p;
  endfunction

  logic [287:0] rk_mem [RkDepth];
  logic         rk_we;
  logic [4:0]   rk_waddr, rk_raddr;
  state_t       rk_wdata, rk_rdata;
  logic [31:0]  rk_rpar;

  always_ff @(posedge clk_i) begin
    if (rk_we) rk_mem[rk_waddr] <= {byte_parity(rk_wdata), rk_wdata};
  end
  assign {rk_rpar, rk_rdata} = rk_mem[rk_raddr];

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
  logic last;   // last cycle of the running pass
  always_comb begin
    unique case (fsm_q)
      KeySched:         last = (half_q == 2'd3) && left_q && (upd_q == rounds_q);
      Encrypt, Decrypt: last = (step_q == last_step);
      Clear:            last = (step_q == 5'(RkDepth - 1));
      default:          last = 1'b0;
    endcase
  end

  // key schedule: half-round key of this update, h[2i-1] = K_i^L (right
  // branch) or h[2i] = K_i^R (left branch)
  logic [4:0] ks_addr;
  assign ks_addr = left_q ? {upd_q, 1'b0} : {upd_q, 1'b0} - 5'd1;

  always_comb begin
    rk_we    = 1'b0;
    rk_waddr = step_q;
    rk_wdata = '0;
    unique case (fsm_q)
      Decrypt:  rk_raddr = last_step - step_q;
      KeySched: rk_raddr = ks_addr;          // second pass: compare
      Check:    rk_raddr = 5'd0;             // KEY: h[0]
      default:  rk_raddr = step_q;
    endcase
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
          rk_we    = !chk_q;                  // second pass: compare only
          rk_waddr = ks_addr;
          rk_wdata = left_q ? kr_q ^ fwd_out : fwd_out;
        end else if (!chk_q && step_q != 5'd0) begin
          rk_we = 1'b1;                       // h[step] = 0, step = 2R+1..31
        end
      end
      Check:   rk_wdata = k0l;                // KEY: compared with h[0]
      Clear:   rk_we = 1'b1;                  // h[step] = 0
      default: ;
    endcase
  end

  // --------------------------------------------------------- fault checks
  logic ks_ne;       // computed half-round key != the one in the RAM
  logic res_ne;      // result of the second pass != input
  logic par_err;     // parity error in the round key read
  logic cfg_err;     // version and its complement disagree
  logic fsm_err;     // no such state
  logic lost;        // back in Idle without Check or Clear
  logic det;         // fault seen in this cycle (acted on in the next one)
  logic start_err;   // ENC / DEC without a checked key schedule
  logic check_ok;    // Check: both passes agree, nothing else went wrong
  logic fault_now;   // drop everything in this cycle

  assign ks_ne     = (rk_wdata != rk_rdata);
  assign res_ne    = (st_q != in_q);
  assign par_err   = (byte_parity(rk_rdata) != rk_rpar);
  assign cfg_err   = (rounds_q != ~rounds_n_q) || (wide_q != ~wide_n_q);
  assign fsm_err   = (3'(fsm_q) > 3'(Check));
  assign lost      = (fsm_q == Idle) && run_q;
  assign det       = cfg_err || lost ||
                     ((fsm_q == Encrypt || fsm_q == Decrypt) && par_err) ||
                     ((fsm_q == KeySched) && chk_q && (half_q == 2'd3) && ks_ne);
  assign start_err = (fsm_q == Idle) && (enc_i || dec_i) && !ks_valid_q;
  assign check_ok  = !fault_q && (cnt_q == 8'd1) && (op_key_q ? !ks_ne : !res_ne);
  assign fault_now = (fsm_q != Clear) &&
                     (fault_q || fsm_err || start_err || ((fsm_q == Check) && !check_ok));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fsm_q      <= Clear;                    // zero the round key RAM first
      wipe_q     <= 1'b1;
      run_q      <= 1'b0;
      chk_q      <= 1'b0;
      op_key_q   <= 1'b0;
      ks_valid_q <= 1'b0;
      dout_ok_q  <= 1'b0;
      fault_q    <= 1'b0;
      wide_q     <= 1'b0;
      wide_n_q   <= 1'b1;
      rounds_q   <= 4'd6;
      rounds_n_q <= ~4'd6;
      cnt_q      <= '0;
      step_q     <= '0;
      upd_q      <= 4'd1;
      half_q     <= '0;
      left_q     <= 1'b0;
      st_q       <= '0;
      kl_q       <= '0;
      kr_q       <= '0;
      in_q       <= '0;
      dout_q     <= '0;
    end else begin
      fault_q <= (fsm_q != Clear) && det;
      if (fsm_q != Idle) cnt_q <= cnt_q - 8'd1;
      case (fsm_q)
        Idle: begin
          step_q <= '0;
          st_q   <= '0;                       // not needed while idle (K_R, the
          kl_q   <= '0;                       // state of the last key schedule,
          kr_q   <= '0;                       // the result of the second pass,
          in_q   <= '0;                       // the input)
          if (key_i) begin
            fsm_q      <= KeySched;
            run_q      <= 1'b1;
            chk_q      <= 1'b0;
            op_key_q   <= 1'b1;
            ks_valid_q <= 1'b0;
            dout_ok_q  <= 1'b0;
            wide_q     <= wide_i;
            wide_n_q   <= ~wide_i;
            rounds_q   <= rounds_d;
            rounds_n_q <= ~rounds_d;
            cnt_q      <= {rounds_d, 4'b0001};  // 16R + 1
            step_q     <= {rounds_d, 1'b1};     // first stale round key: 2R + 1
            kl_q       <= k0l;
            kr_q       <= k0r;
            dout_q     <= '0;                   // result of the previous key
            upd_q      <= 4'd1;
            half_q     <= 2'd0;
            left_q     <= 1'b0;
          end else if (enc_i || dec_i) begin
            fsm_q     <= enc_i ? Encrypt : Decrypt;
            run_q     <= 1'b1;
            chk_q     <= 1'b0;
            op_key_q  <= 1'b0;
            dout_ok_q <= 1'b0;
            cnt_q     <= {2'b00, ~rounds_n_q, 2'b11};   // 4R + 3, R from the complement
            st_q      <= din_i & block_mask(wide_q);
            in_q      <= din_i & block_mask(wide_q);
          end else if (clear_i) begin
            fsm_q  <= Clear;
            run_q  <= 1'b1;
            wipe_q <= 1'b0;
          end
        end
        KeySched: begin
          st_q   <= fwd_out;
          half_q <= half_q + 2'd1;
          if (half_q != 2'd3 && step_q != 5'd0) step_q <= step_q + 5'd1;   // 31 -> 0: done
          if (half_q == 2'd3) begin
            left_q <= ~left_q;
            if (!left_q) begin
              kr_q <= fwd_out;               // K_i^L, until the left branch is done
            end else begin
              kl_q  <= kr_q;                 // K_i^L
              kr_q  <= kr_q ^ fwd_out;       // K_i^R = K_i^L ^ F(0, F(c(2i-1), K_{i-1}^L))
              upd_q <= upd_q + 4'd1;
              if (last) begin
                if (!chk_q) begin            // second pass, from the master key again
                  chk_q <= 1'b1;
                  kl_q  <= k0l;
                  kr_q  <= k0r;
                  upd_q <= 4'd1;
                end else begin
                  fsm_q <= Check;
                end
              end
            end
          end
        end
        Encrypt: begin
          step_q <= step_q + 5'd1;
          if (last) begin
            st_q <= st_q ^ rk_rdata;         // whitening with K_post
            if (!chk_q) begin                // ENC: check by decrypting C
              dout_q <= st_q ^ rk_rdata;
              fsm_q  <= Decrypt;
              chk_q  <= 1'b1;
              step_q <= '0;
            end else begin                   // DEC: E(P) must give back C
              fsm_q <= Check;
            end
          end else begin
            st_q <= fwd_out;
          end
        end
        Decrypt: begin
          step_q <= step_q + 5'd1;
          st_q   <= (step_q == 5'd0) ? st_q ^ rk_rdata : inv_out;   // C ^ K_post first
          if (last) begin
            if (!chk_q) begin                // DEC: check by encrypting P
              dout_q <= inv_out;
              fsm_q  <= Encrypt;
              chk_q  <= 1'b1;
              step_q <= '0;
            end else begin                   // ENC: D(C) must give back P
              fsm_q <= Check;
            end
          end
        end
        Check: begin
          if (check_ok) begin
            fsm_q <= Idle;
            run_q <= 1'b0;
            if (op_key_q) ks_valid_q <= 1'b1;
            else          dout_ok_q  <= 1'b1;
          end
        end
        Clear: begin
          step_q     <= step_q + 5'd1;
          st_q       <= '0;
          kl_q       <= '0;
          kr_q       <= '0;
          in_q       <= '0;
          dout_q     <= '0;
          chk_q      <= 1'b0;
          ks_valid_q <= 1'b0;
          dout_ok_q  <= 1'b0;
          wide_q     <= 1'b0;                // a consistent version until the next KEY
          wide_n_q   <= 1'b1;
          rounds_q   <= 4'd6;
          rounds_n_q <= ~4'd6;
          if (last) begin
            fsm_q  <= Idle;
            run_q  <= 1'b0;
            wipe_q <= 1'b0;
          end
        end
        default: ;                           // fsm_err
      endcase
      if (fault_now) begin                   // release nothing, zero everything
        fsm_q      <= Clear;
        wipe_q     <= 1'b1;
        run_q      <= 1'b1;
        step_q     <= '0;
        ks_valid_q <= 1'b0;
        dout_ok_q  <= 1'b0;
      end
    end
  end

  assign busy_o       = (fsm_q != Idle);
  assign done_o       = ((fsm_q == Check) && check_ok) || ((fsm_q == Clear) && last && !wipe_q);
  assign fault_o      = fault_now;
  assign dout_o       = dout_q;
  assign dout_valid_o = dout_ok_q;
  assign wide_o       = wide_q;
  assign rounds_o     = rounds_q;

endmodule
