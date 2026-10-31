// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// H.264 bit packer: tokens of up to 32 bits -> bytes -> NAL units -> 32 bit
// words for the output FIFO.
//
//   kind 1  NAL start: 00 00 00 01 + header byte, no emulation prevention
//   kind 0  bits (MSB first) into a 64 bit accumulator, one byte out per cycle
//   kind 2  rbsp_trailing_bits (stop bit + zeros to the byte boundary), then
//           the end of the NAL unit
//   EP      emulation prevention inside the NAL payload: 00 00 0x (x <= 3)
//           -> 00 00 03 0x
//   words   4 bytes per word, first byte in bits [7:0] (memory byte order);
//           the last word of a NAL unit is padded with zero bytes
//           (trailing_zero_8bits of the byte stream) and has last = 1
// frame_done_o pulses when the last word of the NAL unit is in the FIFO,
// with its size in bytes (multiple of 4).

module bow_h264_bitpack (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        tk_valid_i,
  output logic        tk_ready_o,
  input  logic [1:0]  tk_kind_i,
  input  logic [5:0]  tk_len_i,
  input  logic [31:0] tk_bits_i,
  input  logic        tk_seq_last_i,

  output logic        out_push_o,
  input  logic        out_full_i,
  output logic [31:0] out_data_o,
  output logic        out_last_o,

  output logic        frame_done_o,
  output logic [23:0] frame_bytes_o,
  output logic        seq_last_o,
  output logic        busy_o
);

  // --------------------------------------------------------- accumulator
  logic [63:0] acc_q;
  logic [6:0]  cnt_q;
  logic        raw_q;              // sending the start code + header
  logic [2:0]  raw_cnt_q;
  logic [7:0]  hdr_q;
  logic        end_q;              // trailing bits in, waiting for the last byte
  logic        seq_last_q;

  // byte offered to the emulation prevention / packer
  logic        b_valid, b_raw, b_take;
  logic [7:0]  b_data;

  always_comb begin
    b_raw  = raw_q;
    if (raw_q) begin
      b_valid = 1'b1;
      b_data  = (raw_cnt_q < 3'd3) ? 8'h00 : (raw_cnt_q == 3'd3) ? 8'h01 : hdr_q;
    end else begin
      b_valid = (cnt_q >= 7'd8);
      b_data  = acc_q[63:56];
    end
  end

  logic pk_ready, pk_end, pk_busy, ep_insert;

  // emulation prevention: two zero bytes then a byte <= 3 -> 0x03 first
  logic [1:0] zcnt_q;
  assign ep_insert = b_valid && !b_raw && (zcnt_q == 2'd2) && (b_data <= 8'h03);
  assign b_take    = b_valid && pk_ready && !ep_insert;

  logic       p_valid;
  logic [7:0] p_data;
  assign p_valid = b_valid && pk_ready;
  assign p_data  = ep_insert ? 8'h03 : b_data;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      zcnt_q <= '0;
    end else if (p_valid) begin
      if (b_raw || ep_insert) zcnt_q <= '0;
      else if (b_data == 8'h00) zcnt_q <= (zcnt_q == 2'd2) ? 2'd2 : zcnt_q + 2'd1;
      else zcnt_q <= '0;
    end
  end

  // tokens
  logic       tk_bits_ok, tk_nal_ok;
  logic [5:0] trail_len;

  assign trail_len  = 6'd8 - 6'(cnt_q[2:0]);
  assign tk_bits_ok = !raw_q && !end_q && (cnt_q <= 7'd32);
  assign tk_nal_ok  = !raw_q && !end_q && (cnt_q == '0) && !pk_busy;
  assign tk_ready_o = (tk_kind_i == 2'd1) ? tk_nal_ok : tk_bits_ok;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      acc_q      <= '0;
      cnt_q      <= '0;
      raw_q      <= 1'b0;
      raw_cnt_q  <= '0;
      hdr_q      <= '0;
      end_q      <= 1'b0;
      seq_last_q <= 1'b0;
    end else begin
      logic [63:0] a;
      logic [6:0]  c;
      a = acc_q;
      c = cnt_q;
      if (b_take && !raw_q) begin
        a = a << 8;
        c = c - 7'd8;
      end
      if (b_take && raw_q) begin
        raw_cnt_q <= raw_cnt_q + 3'd1;
        if (raw_cnt_q == 3'd4) raw_q <= 1'b0;
      end
      if (tk_valid_i && tk_ready_o) begin
        unique case (tk_kind_i)
          2'd1: begin
            raw_q     <= 1'b1;
            raw_cnt_q <= '0;
            hdr_q     <= tk_bits_i[7:0];
          end
          2'd2: begin
            // stop bit, zeros up to the byte boundary
            a = a | (64'd1 << (7'd63 - c));
            c = c + 7'(trail_len);
            end_q      <= 1'b1;
            seq_last_q <= tk_seq_last_i;
          end
          default: begin
            a = a | ((64'(tk_bits_i) & ((64'd1 << tk_len_i) - 64'd1)) << (7'd64 - c - 7'(tk_len_i)));
            c = c + 7'(tk_len_i);
          end
        endcase
      end
      if (pk_end) end_q <= 1'b0;
      acc_q <= a;
      cnt_q <= c;
    end
  end

  // the last byte of the NAL unit has gone: finish the word
  assign pk_end = end_q && (cnt_q == '0) && !raw_q;

  // ------------------------------------------------------------- words
  typedef enum logic [1:0] {KRun, KHold, KPad, KDone} kstate_e;

  kstate_e     kst_q;
  logic [23:0] wbuf_q;
  logic [1:0]  wcnt_q;
  logic        hold_q;
  logic [31:0] hold_data_q;
  logic [21:0] nwords_q;

  assign pk_ready = (kst_q == KRun) && !pk_end && (!hold_q || !out_full_i);
  assign pk_busy  = (kst_q != KRun) || hold_q || (wcnt_q != '0);

  always_comb begin
    out_push_o = 1'b0;
    out_data_o = hold_data_q;
    out_last_o = 1'b0;
    unique case (kst_q)
      KRun:  out_push_o = hold_q && !out_full_i && p_valid;
      KHold: begin
        out_push_o = hold_q && !out_full_i;
        out_last_o = (wcnt_q == '0);
      end
      KPad: begin
        out_push_o = !out_full_i;
        out_data_o = {8'h00 , wbuf_q} & ({32{1'b1}} >> (6'd32 - 6'(8 * wcnt_q)));
        out_last_o = 1'b1;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      kst_q         <= KRun;
      wbuf_q        <= '0;
      wcnt_q        <= '0;
      hold_q        <= 1'b0;
      hold_data_q   <= '0;
      nwords_q      <= '0;
      frame_done_o  <= 1'b0;
      frame_bytes_o <= '0;
      seq_last_o    <= 1'b0;
    end else begin
      frame_done_o <= 1'b0;
      if (out_push_o) nwords_q <= nwords_q + 22'd1;
      unique case (kst_q)
        KRun: begin
          if (p_valid) begin
            if (out_push_o) hold_q <= 1'b0;
            unique case (wcnt_q)
              2'd0: wbuf_q[7:0]   <= p_data;
              2'd1: wbuf_q[15:8]  <= p_data;
              2'd2: wbuf_q[23:16] <= p_data;
              default: begin
                hold_q      <= 1'b1;
                hold_data_q <= {p_data, wbuf_q};
              end
            endcase
            wcnt_q <= wcnt_q + 2'd1;
          end
          if (pk_end) kst_q <= KHold;
        end
        // the full word waiting (last when no bytes follow)
        KHold: begin
          if (!hold_q) begin
            kst_q <= (wcnt_q == '0) ? KDone : KPad;
          end else if (!out_full_i) begin
            hold_q <= 1'b0;
            kst_q  <= (wcnt_q == '0) ? KDone : KPad;
          end
        end
        KPad: if (!out_full_i) begin
          wcnt_q <= '0;
          kst_q  <= KDone;
        end
        KDone: begin
          frame_done_o  <= 1'b1;
          frame_bytes_o <= {nwords_q, 2'b00};
          seq_last_o    <= seq_last_q;
          nwords_q      <= '0;
          kst_q         <= KRun;
        end
        default: kst_q <= KRun;
      endcase
    end
  end

  assign busy_o = raw_q || end_q || (cnt_q != '0) || pk_busy;

endmodule
