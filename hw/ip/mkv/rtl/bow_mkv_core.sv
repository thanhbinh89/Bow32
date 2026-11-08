// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// MKV block cipher engine (TCVN 14263:2024): MKV-128 / MKV-256, keys of l,
// 3l/2 and 2l bits (R = 7, 8, 9 rounds), key schedule, encryption and
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
//     pass must give back the input (kept in in_q, and as a complement in
//     in_n_q for the second comparator),
//   * KEY runs the key schedule a second time from the master key and
//     compares every half-round key with the RAM (h[0] in Check); in the same
//     pass it reads back the rows 2R+1..31 that the first pass zeroed,
//   * every round key the RAM gives to ENC / DEC / KEY is checked with an
//     error detection code bound to the row address (bow_mkv_pkg::rk_edc): a
//     round key that changes in the RAM gives the same wrong result in both
//     passes, the code sees it, also a row read at the wrong address,
//   * the result register dout_q has a complement copy (dout_n_q), checked in
//     Check and for as long as the result can be read,
//   * each decision of Check comes from two comparators of a different
//     structure, and the flags that release a result or a key schedule are
//     mubi4 built from both: one stuck comparator cannot release anything,
//   * the version (R, block size) is kept as value and complement, a second
//     counter (cnt_q) has to run out exactly at the end of the command,
//   * the state register uses a sparse code (any two states differ in at
//     least 3 bits): a state outside the list, a return to Idle without Check
//     or an invalid mubi4 flag is an error,
//   * KEY_VALID of the register block without a checked key schedule here is
//     an error.
// A fault releases nothing (dout_valid_o stays 0): the engine pulses fault_o
// and wipes the RAM and its registers (Clear, without done_o).
//
// Clear writes zero into the 32 rows of the RAM, then reads every row back
// (it must be 0 with the right code), while the cycle counter has to follow
// the row counter in every cycle. Fault detection stays on in Clear: an error
// starts the wipe again and pulses fault_o, so a wipe that was cut short is
// never reported done.
//
// TEST (test_i with key_i / enc_i / dec_i): one bit of the second pass is
// changed, so the command has to end with fault_o (bow_mkv does not count it
// as an attack, and locks if it is not detected).
//
// Busy cycles after the cycle that takes the command: ENC / DEC 4R + 3, KEY
// 16R + 1, CLEAR 64 (the CYCLES register of bow_mkv also counts that cycle:
// 4R + 4, 16R + 2, 65).
//
// The half-round keys h[0..2R] = RK_0 .. RK_2R of the key schedule (round
// key i = K_i^0 || K_i^1 = h[2i] || h[2i+1], K_post = h[2R]) are kept in a
// 32 x (256 + 56 code) bit distributed RAM, written once by the key schedule.
//
// No key material is left where it is not needed (UpdateKS can be inverted:
// any pair RK_2i-1, RK_2i gives back the master key):
//   * the key schedule zeroes h[2R+1..31] (round keys of a previous, longer
//     key) in the cycles in which it does not write the RAM,
//   * the engine keeps its own copies (K_R, the state, the input) at zero
//     while it is idle,
//   * KEY zeroes the result of the previous key (dout_o),
//   * after a reset the engine wipes the whole RAM first (distributed RAM has
//     no reset): 64 cycles with busy_o = 1, without done_o,
//   * wipe_i (bow_mkv: KEY_VALID lost by a new key or version) wipes it too.
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
  input  logic         clear_i,      // wipe the round keys and the state, done_o at the end
  input  logic         wipe_i,       // the same without done_o (key schedule given up)
  input  logic         test_i,       // with key_i / enc_i / dec_i: fault in the second pass
  input  logic         lock_i,       // locked: key_i / enc_i / dec_i are ignored
  input  logic         key_valid_i,  // KEY_VALID of the register block
  input  logic         wide_i,       // with key_i: 0 MKV-128, 1 MKV-256
  input  logic [1:0]   klen_i,       // with key_i: 0 k = l, 1 k = 3l/2, 2 k = 2l
  input  logic [511:0] key_data_i,   // master key, byte b = key_data_i[8*b +: 8]
  input  logic [255:0] din_i,        // block, byte b = din_i[8*b +: 8]

  output logic         busy_o,
  output logic         clear_o,      // busy with a wipe (Clear): no key or data in use
  output logic         done_o,       // last cycle of a command that passed its check
  output logic         fault_o,      // fault detected: result dropped, all wiped
  output logic [255:0] dout_o,       // result of the last encryption / decryption
  output logic         dout_valid_o, // dout_o is a checked result
  output logic         ks_valid_o,   // the RAM holds a checked key schedule
  output logic         wide_o,       // version of the key schedule
  output logic [3:0]   rounds_o
);

  // Sparse state code: any two states differ in at least 3 bits, so one
  // flipped bit gives a code outside the list (fsm_err). fsm_encoding =
  // "none" keeps it (Vivado would otherwise re-encode the FSM).
  typedef enum logic [5:0] {
    Idle     = 6'b100110,
    KeySched = 6'b010101,
    Encrypt  = 6'b110011,
    Decrypt  = 6'b101101,
    Clear    = 6'b001011,
    Check    = 6'b011110
  } fsm_e;

  localparam int unsigned RkDepth     = 32;
  localparam int unsigned RkWidth     = 256 + RkEdcBits;
  localparam logic [7:0]  ClearCycles = 8'd64;   // zero 32 rows, read 32 rows back

  // The redundant registers of the fault detection must survive synthesis
  // (keep); an ASIC flow needs the same (dont_touch / size_only).
  (* fsm_encoding = "none" *) fsm_e fsm_q;
  logic       wipe_q;      // Clear not started by CLEAR (reset, fault, wipe_i): no done_o
  logic       run_q;       // a command is running (until Check / end of Clear)
  logic       vfy_q;       // Clear: 0 zeroing the rows, 1 reading them back
  logic       tst_q;       // the running command is a TEST
  (* keep = "true" *) mubi4_t     chk_q;       // second pass of the running command
  (* keep = "true" *) mubi4_t     op_key_q;    // the running command is KEY
  (* keep = "true" *) mubi4_t     ks_valid_q;  // the RAM holds a checked key schedule
  (* keep = "true" *) mubi4_t     dout_ok_q;   // dout_q holds a checked result
  logic       fault_q;     // a fault was seen in the last cycle
  (* keep = "true" *) logic       wide_q, wide_n_q;        // version: value and complement
  (* keep = "true" *) logic [3:0] rounds_q, rounds_n_q;    // R
  (* keep = "true" *) logic [7:0] cnt_q;       // busy cycles left in the running command
  logic [4:0] step_q;      // encryption / decryption step 0..2R, Clear row
                           // (key schedule: next stale round key 2R+1..31, 0 = done)
  logic [3:0] upd_q;       // key schedule update i = 1..R
  logic [1:0] half_q;      // key schedule: half-round of F(0, F(c, x))
  logic       left_q;      // key schedule: 0 right branch (-> new K^0), 1 left
  state_t     st_q, kl_q, kr_q, in_q, dout_q;   // kl_q, kr_q: K^0, K^1
  (* keep = "true" *) state_t in_n_q, dout_n_q;  // complements of in_q, dout_q

  logic chk, op_key, ks_valid, dout_ok;   // the mubi4 flags, True or not
  assign chk      = (chk_q == MuBi4True);
  assign op_key   = (op_key_q == MuBi4True);
  assign ks_valid = (ks_valid_q == MuBi4True);
  assign dout_ok  = (dout_ok_q == MuBi4True);

  logic key_go, enc_go, dec_go;
  assign key_go = key_i && !lock_i;
  assign enc_go = enc_i && !lock_i;
  assign dec_go = dec_i && !lock_i;

  logic [4:0] last_step;   // 2R
  assign last_step = {rounds_q, 1'b0};

  logic [3:0] rounds_d;    // R of the version of a KEY command (Table 1)
  assign rounds_d = 4'd7 + ((klen_i == 2'd3) ? 4'd2 : {2'b00, klen_i});

  state_t tvec;            // TEST: the bit changed at the start of the second pass
  assign tvec = {255'd0, tst_q};

  // ------------------------------------------------------- round key memory
  // half-round key and its code (bow_mkv_pkg::rk_edc, bound to the row)
  logic [RkWidth-1:0]   rk_mem [RkDepth];
  logic                 rk_we;
  logic [4:0]           rk_waddr, rk_raddr;
  state_t               rk_wdata, rk_rdata;
  logic [RkEdcBits-1:0] rk_wchk, rk_rchk;

  assign rk_wchk = rk_edc(rk_wdata, rk_waddr);

  always_ff @(posedge clk_i) begin
    if (rk_we) rk_mem[rk_waddr] <= {rk_wchk, rk_wdata};
  end
  assign {rk_rchk, rk_rdata} = rk_mem[rk_raddr];

  // ------------------------------- initial key state K_int = K^0 || K^1
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
  // L(S(x ^ k)): encryption (key h[s]) and key schedule. Key schedule, update
  // i = 1..R (clause 5.5, loop index i - 1): the first key addition of each
  // branch adds Const^1_l ^ <2i>_l (right branch, K^1) or Const^0_l ^
  // <2i - 1>_l (left branch, K^0); <v>_l has v in the last byte.
  state_t     fwd_in, fwd_key, fwd_out, sched_const;
  logic       fwd_mix;
  logic [7:0] sched_v;

  assign sched_v     = {3'b000, upd_q, 1'b0} - {7'h00, left_q};
  assign sched_const = ks_const(wide_q, left_q) ^
                       (wide_q ? {sched_v, 248'h0} : {128'h0, sched_v, 120'h0});

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
  logic last;   // last cycle of the running pass (Clear: of the read back)
  always_comb begin
    unique case (fsm_q)
      KeySched:         last = (half_q == 2'd3) && left_q && (upd_q == rounds_q);
      Encrypt, Decrypt: last = (step_q == last_step);
      Clear:            last = vfy_q && (step_q == 5'(RkDepth - 1));
      default:          last = 1'b0;
    endcase
  end

  // key schedule: half-round key of update i, h[2i-1] = RK_2i-1 = the new
  // K^0 (right branch) or h[2i] = RK_2i = the new K^1 (left branch)
  logic [4:0] ks_addr;
  assign ks_addr = left_q ? {upd_q, 1'b0} : {upd_q, 1'b0} - 5'd1;

  always_comb begin
    rk_we    = 1'b0;
    rk_waddr = step_q;
    rk_wdata = '0;
    unique case (fsm_q)
      Decrypt:  rk_raddr = last_step - step_q;
      KeySched: rk_raddr = (half_q == 2'd3) ? ks_addr : step_q;   // second pass: compare,
      Check:    rk_raddr = 5'd0;                                  // read back zeroed rows
      default:  rk_raddr = step_q;                                // Encrypt, Clear
    endcase
    unique case (fsm_q)
      Idle: begin
        if (key_go) begin
          rk_we    = 1'b1;                    // h[0] = K_0^L
          rk_waddr = 5'd0;
          rk_wdata = k0l;
        end
      end
      KeySched: begin
        if (half_q == 2'd3) begin
          rk_we    = !chk;                    // second pass: compare only
          rk_waddr = ks_addr;
          rk_wdata = left_q ? kr_q ^ fwd_out : fwd_out;
        end else if (!chk && step_q != 5'd0) begin
          rk_we = 1'b1;                       // h[step] = 0, step = 2R+1..31
        end
      end
      Check: begin                            // KEY: h[0] compared with K_0^L
        rk_waddr = 5'd0;
        rk_wdata = k0l;
      end
      Clear:   rk_we = !vfy_q;                // h[step] = 0
      default: ;
    endcase
  end

  // --------------------------------------------------------- fault checks
  // Two comparators of a different structure for each decision of Check
  logic res_eq_a, res_eq_b;   // the second pass gave back the input
  logic ks_eq_a, ks_eq_b;     // recomputed half-round key = the RAM row (data / code)
  assign res_eq_a = (st_q == in_q);
  assign res_eq_b = &(st_q ^ in_n_q);
  assign ks_eq_a  = (rk_wdata == rk_rdata);
  assign ks_eq_b  = (rk_wchk == rk_rchk);

  logic edc_err;     // code of the row read does not fit its data and address
  logic zero_err;    // a row that has to be 0 (with its code) is not
  logic dout_bad;    // the result and its complement copy disagree
  assign edc_err  = (rk_edc(rk_rdata, rk_raddr) != rk_rchk);
  assign zero_err = (rk_rdata != '0) || edc_err;
  assign dout_bad = (dout_q != ~dout_n_q);

  logic rk_use;      // a round key read that is used (ENC / DEC / KEY compare)
  logic stale_chk;   // KEY, second pass: rows 2R+1..31 have been zeroed
  assign rk_use    = (fsm_q == Encrypt) || (fsm_q == Decrypt) ||
                     ((fsm_q == KeySched) && chk && (half_q == 2'd3));
  assign stale_chk = (fsm_q == KeySched) && chk && (half_q != 2'd3) && (step_q != 5'd0);

  logic cfg_err;     // version and its complement disagree
  logic fsm_err;     // no such state
  logic lost;        // back in Idle without Check or Clear
  logic flag_err;    // a mubi4 flag is neither True nor False
  logic kv_err;      // KEY_VALID in the register block, no key schedule here
  logic det;         // fault seen in this cycle (acted on in the next one)
  assign cfg_err  = (rounds_q != ~rounds_n_q) || (wide_q != ~wide_n_q);
  assign fsm_err  = !(fsm_q inside {Idle, KeySched, Encrypt, Decrypt, Clear, Check});
  assign lost     = (fsm_q == Idle) && run_q;
  assign flag_err = mubi4_invalid(chk_q) || mubi4_invalid(op_key_q) ||
                    mubi4_invalid(ks_valid_q) || mubi4_invalid(dout_ok_q);
  assign kv_err   = key_valid_i && !ks_valid;
  assign det      = cfg_err || lost || flag_err || kv_err ||
                    (rk_use && edc_err) || (stale_chk && zero_err) ||
                    ((fsm_q == KeySched) && chk && (half_q == 2'd3) && !(ks_eq_a && ks_eq_b)) ||
                    (dout_ok && dout_bad);

  logic start_err;   // ENC / DEC without a checked key schedule
  logic ok_a, ok_b;  // the two comparators of Check
  logic check_ok;    // Check: both passes agree, nothing else went wrong
  logic clr_fail;    // Clear: cycle count off, or a row not wiped
  logic fault_now;   // drop everything in this cycle
  assign start_err = (fsm_q == Idle) && (enc_go || dec_go) && !ks_valid;
  assign ok_a      = op_key ? ks_eq_a : res_eq_a;
  assign ok_b      = op_key ? ks_eq_b : res_eq_b;
  assign check_ok  = !fault_q && (cnt_q == 8'd1) && ok_a && ok_b &&
                     (op_key ? (step_q == 5'd0) && !edc_err : !dout_bad);
  assign clr_fail  = (fsm_q == Clear) &&
                     ((cnt_q != ClearCycles - 8'({vfy_q, step_q})) || (vfy_q && zero_err));
  assign fault_now = fault_q || fsm_err || start_err || clr_fail ||
                     ((fsm_q == Check) && !check_ok);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fsm_q      <= Clear;                    // wipe the round key RAM first
      wipe_q     <= 1'b1;
      run_q      <= 1'b1;
      vfy_q      <= 1'b0;
      tst_q      <= 1'b0;
      chk_q      <= MuBi4False;
      op_key_q   <= MuBi4False;
      ks_valid_q <= MuBi4False;
      dout_ok_q  <= MuBi4False;
      fault_q    <= 1'b0;
      wide_q     <= 1'b0;
      wide_n_q   <= 1'b1;
      rounds_q   <= 4'd7;
      rounds_n_q <= ~4'd7;
      cnt_q      <= ClearCycles;
      step_q     <= '0;
      upd_q      <= 4'd1;
      half_q     <= '0;
      left_q     <= 1'b0;
      st_q       <= '0;
      kl_q       <= '0;
      kr_q       <= '0;
      in_q       <= '0;
      in_n_q     <= '0;
      dout_q     <= '0;
      dout_n_q   <= '0;
    end else begin
      fault_q <= det && !fault_now;           // one response per fault
      if (fsm_q != Idle) cnt_q <= cnt_q - 8'd1;
      unique case (fsm_q)
        Idle: begin
          step_q <= '0;
          vfy_q  <= 1'b0;
          tst_q  <= 1'b0;
          st_q   <= '0;                       // not needed while idle (K_R, the
          kl_q   <= '0;                       // state of the last key schedule,
          kr_q   <= '0;                       // the result of the second pass,
          in_q   <= '0;                       // the input)
          in_n_q <= '0;
          if (key_go) begin
            fsm_q      <= KeySched;
            run_q      <= 1'b1;
            tst_q      <= test_i;
            chk_q      <= MuBi4False;
            op_key_q   <= MuBi4True;
            ks_valid_q <= MuBi4False;
            dout_ok_q  <= MuBi4False;
            wide_q     <= wide_i;
            wide_n_q   <= ~wide_i;
            rounds_q   <= rounds_d;
            rounds_n_q <= ~rounds_d;
            cnt_q      <= {rounds_d, 4'b0001};  // 16R + 1
            step_q     <= {rounds_d, 1'b1};     // first stale round key: 2R + 1
            kl_q       <= k0l;
            kr_q       <= k0r;
            dout_q     <= '0;                   // result of the previous key
            dout_n_q   <= '0;
            upd_q      <= 4'd1;
            half_q     <= 2'd0;
            left_q     <= 1'b0;
          end else if (enc_go || dec_go) begin
            fsm_q     <= enc_go ? Encrypt : Decrypt;
            run_q     <= 1'b1;
            tst_q     <= test_i;
            chk_q     <= MuBi4False;
            op_key_q  <= MuBi4False;
            dout_ok_q <= MuBi4False;
            cnt_q     <= {2'b00, ~rounds_n_q, 2'b11};   // 4R + 3, R from the complement
            st_q      <= din_i & block_mask(wide_q);
            in_q      <= din_i & block_mask(wide_q);
            in_n_q    <= ~(din_i & block_mask(wide_q));
          end else if (clear_i || wipe_i) begin
            fsm_q      <= Clear;
            run_q      <= 1'b1;
            wipe_q     <= !clear_i;
            cnt_q      <= ClearCycles;
            ks_valid_q <= MuBi4False;         // nothing usable from the first cycle on
            dout_ok_q  <= MuBi4False;
          end
        end
        KeySched: begin
          st_q   <= fwd_out;
          half_q <= half_q + 2'd1;
          if (half_q != 2'd3 && step_q != 5'd0) step_q <= step_q + 5'd1;   // 31 -> 0: done
          if (half_q == 2'd3) begin
            left_q <= ~left_q;
            if (!left_q) begin
              kr_q <= fwd_out;               // the new K^0, until the left branch is done
            end else begin                   // SWAP: K^0 <- G(G(K^1 ^ c)),
              kl_q  <= kr_q;                 // K^1 <- G(G(K^0 ^ c')) ^ G(G(K^1 ^ c))
              kr_q  <= kr_q ^ fwd_out;
              upd_q <= upd_q + 4'd1;
              if (last) begin
                if (!chk) begin              // second pass, from the master key again
                  chk_q  <= MuBi4True;
                  kl_q   <= k0l ^ tvec;      // TEST: a wrong K^0
                  kr_q   <= k0r;
                  upd_q  <= 4'd1;
                  step_q <= {rounds_q, 1'b1};   // and read back the zeroed rows
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
            if (!chk) begin                  // ENC: check by decrypting C
              st_q     <= st_q ^ rk_rdata ^ tvec;   // whitening with K_post (TEST: wrong C)
              dout_q   <= st_q ^ rk_rdata;
              dout_n_q <= ~(st_q ^ rk_rdata);
              fsm_q    <= Decrypt;
              chk_q    <= MuBi4True;
              step_q   <= '0;
            end else begin                   // DEC: E(P) must give back C
              st_q  <= st_q ^ rk_rdata;
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
            if (!chk) begin                  // DEC: check by encrypting P
              st_q     <= inv_out ^ tvec;    // (TEST: wrong P)
              dout_q   <= inv_out;
              dout_n_q <= ~inv_out;
              fsm_q    <= Encrypt;
              chk_q    <= MuBi4True;
              step_q   <= '0;
            end else begin                   // ENC: D(C) must give back P
              fsm_q <= Check;
            end
          end
        end
        Check: begin
          if (check_ok) begin                // the flag comes from both comparators
            fsm_q <= Idle;
            run_q <= 1'b0;
            tst_q <= 1'b0;
            if (op_key) ks_valid_q <= tst_q ? MuBi4False : mubi4_and2(ks_eq_a, ks_eq_b);
            else        dout_ok_q  <= tst_q ? MuBi4False : mubi4_and2(res_eq_a, res_eq_b);
          end
        end
        Clear: begin
          step_q     <= step_q + 5'd1;
          if (step_q == 5'(RkDepth - 1)) vfy_q <= 1'b1;   // all rows zero: read back
          tst_q      <= 1'b0;
          st_q       <= '0;
          kl_q       <= '0;
          kr_q       <= '0;
          in_q       <= '0;
          in_n_q     <= '0;
          dout_q     <= '0;
          dout_n_q   <= '0;
          chk_q      <= MuBi4False;
          op_key_q   <= MuBi4False;
          ks_valid_q <= MuBi4False;
          dout_ok_q  <= MuBi4False;
          wide_q     <= 1'b0;                // a consistent version until the next KEY
          wide_n_q   <= 1'b1;
          rounds_q   <= 4'd7;
          rounds_n_q <= ~4'd7;
          if (last) begin
            fsm_q  <= Idle;
            run_q  <= 1'b0;
            wipe_q <= 1'b0;
            vfy_q  <= 1'b0;
          end
        end
        default: ;                           // fsm_err
      endcase
      if (fault_now) begin                   // release nothing, wipe everything
        fsm_q      <= Clear;
        wipe_q     <= 1'b1;
        run_q      <= 1'b1;
        vfy_q      <= 1'b0;
        tst_q      <= 1'b0;
        step_q     <= '0;
        cnt_q      <= ClearCycles;
        chk_q      <= MuBi4False;
        op_key_q   <= MuBi4False;
        ks_valid_q <= MuBi4False;
        dout_ok_q  <= MuBi4False;
        wide_q     <= 1'b0;
        wide_n_q   <= 1'b1;
        rounds_q   <= 4'd7;
        rounds_n_q <= ~4'd7;
      end
    end
  end

  assign busy_o       = (fsm_q != Idle);
  assign clear_o      = (fsm_q == Clear);
  assign done_o       = !fault_now &&
                        (((fsm_q == Check) && check_ok) || ((fsm_q == Clear) && last && !wipe_q));
  assign fault_o      = fault_now;
  assign dout_o       = dout_q;
  assign dout_valid_o = dout_ok && !dout_bad;
  assign ks_valid_o   = ks_valid;
  assign wide_o       = wide_q;
  assign rounds_o     = rounds_q;

`ifndef SYNTHESIS
  // Properties of the fault detection (Verilator --assert in hw/ip/mkv/dv)
  // A result is never readable while a command runs.
  a_no_dout_busy: assert property (@(posedge clk_i) disable iff (!rst_ni)
    busy_o |-> !dout_valid_o);
  // A result or a key schedule is released only when both comparators agree.
  a_release_both: assert property (@(posedge clk_i) disable iff (!rst_ni)
    ((fsm_q == Check) && done_o) |-> (ok_a && ok_b));
  // A fault is followed by the wipe, which ends without done_o.
  a_fault_wipe: assert property (@(posedge clk_i) disable iff (!rst_ni)
    fault_o |=> ((fsm_q == Clear) && wipe_q && !dout_valid_o && !ks_valid_o));
  // The wipe is reported done only after every row was read back as 0.
  a_clear_done: assert property (@(posedge clk_i) disable iff (!rst_ni)
    ((fsm_q == Clear) && last && !fault_now) |-> (cnt_q == 8'd1));
`endif

endmodule
