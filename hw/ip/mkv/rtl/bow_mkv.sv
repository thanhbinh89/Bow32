// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MKV block cipher accelerator: MKV-128 / MKV-256 of the draft
// TCVN XXXX:2024 with the six key sizes, key schedule in hardware,
// encryption and decryption of one block per command (bow_mkv_core).
// Register map (docs/ip/mkv.md):
//
//   0x000 ID        R     0x4D4B5601 ("MKV", version 1)
//   0x004 INFO      R     [0] MKV-128  [1] MKV-256  [2] fault detection
//                         [15:8] cycles per round of ENC / DEC (4: 2 + check)
//   0x008 CTRL      RW    [0] BLOCK (0 MKV-128, 1 MKV-256)
//                         [2:1] KLEN (0 k = l, 1 k = 3l/2, 2 k = 2l)
//   0x00C CMD       W     one bit per write: [0] KEY  [1] ENC  [2] DEC  [3] CLEAR
//   0x010 STATUS    R/W1C [0] BUSY  [1] KEY_VALID  [2] DONE  [3] ERR  [4] WIDE
//                         [5] FAULT
//                         ([4], [11:8] ROUNDS: version of the key schedule, 0 = none)
//   0x014 IRQ_EN    RW    [2] DONE  [3] ERR  [5] FAULT
//   0x018 CYCLES    R     cycles of the last command (CMD write -> result)
//   0x040 KEY[0..15] W    master key: byte b = KEY[b / 4][8 * (b % 4) +: 8],
//                         zeroed at the end of the KEY command
//   0x080 DIN[0..7]  RW   input block, same byte order, zeroed when ENC / DEC start
//   0x0C0 DOUT[0..7] R    output block, zeroed by KEY; reads 0 unless it holds
//                         a checked result
//
// A command that cannot run sets ERR and does nothing: ENC / DEC without a
// valid key schedule, KEY with KLEN = 3 or before every word of the key
// (k / 32 words for the version in CTRL) was written since the last KEY or
// CLEAR, more than one CMD bit. KEY_VALID is cleared by a write to KEY, by
// a change of CTRL and by CLEAR (which also zeroes KEY, DIN, DOUT and the
// round keys).
//
// Fault detection (bow_mkv_core): every command is done twice and checked.
// A fault sets FAULT (until written with 1), releases no result and zeroes
// the round keys, KEY, DIN, DOUT and KEY_VALID: software needs a new KEY.
//
// Key material and data stay only as long as they are needed: KEY takes the
// key out of the KEY registers (a byte that is not written again before the
// next KEY is 0, never a byte of the previous key), ENC / DEC take the block
// out of DIN, and the engine zeroes its own copies (bow_mkv_core).
//
// While a command runs (BUSY), writes to CTRL / CMD / KEY and reads of DOUT
// wait (gnt = 0) until it is done, so software can write CMD and read DOUT
// right away. DIN can be written during a command: it is copied into the
// engine when the command starts.

module bow_mkv import bow_bus_pkg::*; (
  input  logic     clk_i,
  input  logic     rst_ni,

  input  bus_req_t bus_req_i,
  output bus_rsp_t bus_rsp_o,

  output logic     irq_o
);

  localparam logic [31:0] IdValue   = 32'h4d4b_5601;
  localparam logic [31:0] InfoValue = 32'h0000_0407;   // 4 cycles per round, fault detection,
                                                        // both block sizes

  localparam logic [11:0] RegId = 12'h000, RegInfo = 12'h004, RegCtrl = 12'h008, RegCmd = 12'h00C,
                          RegStatus = 12'h010, RegIrqEn = 12'h014, RegCycles = 12'h018;

  // ------------------------------------------------------------ bus decode
  logic [11:0] a;
  logic        sel_key, sel_din, sel_dout;
  logic [31:0] wd;
  logic        core_busy;

  assign a        = {bus_req_i.addr[11:2], 2'b00};
  assign sel_key  = (a[11:6] == 6'h01);   // 0x040 .. 0x07C
  assign sel_din  = (a[11:5] == 7'h04);   // 0x080 .. 0x09C
  assign sel_dout = (a[11:5] == 7'h06);   // 0x0C0 .. 0x0DC
  assign wd       = bus_req_i.wdata;

  logic stall, we, re;
  assign stall = core_busy && bus_req_i.req &&
                 (bus_req_i.we ? (a == RegCtrl || a == RegCmd || sel_key) : sel_dout);
  assign we    = bus_req_i.req && !stall &&  bus_req_i.we;
  assign re    = bus_req_i.req && !stall && !bus_req_i.we;

  function automatic logic [31:0] merge_be(logic [31:0] old, logic [31:0] data, logic [3:0] be);
    logic [31:0] r;
    for (int b = 0; b < 4; b++) r[8*b +: 8] = be[b] ? data[8*b +: 8] : old[8*b +: 8];
    return r;
  endfunction

  // -------------------------------------------------------------- registers
  logic              wide_q;
  logic [1:0]        klen_q;
  logic [15:0][31:0] key_q;
  logic [15:0]       key_wr_q;     // KEY words written since the last KEY / CLEAR
  logic [7:0][31:0]  din_q;
  logic              key_valid_q, key_run_q, done_q, err_q, fault_q;
  logic [2:0]        irq_en_q;     // [0] DONE  [1] ERR  [2] FAULT
  logic [31:0]       cycles_q, cnt_q;

  // KEY words the version in CTRL takes: k / 32
  logic [15:0] key_need;
  always_comb begin
    unique case ({wide_q, klen_q})
      3'b0_00: key_need = 16'h000F;
      3'b0_01: key_need = 16'h003F;
      3'b0_10: key_need = 16'h00FF;
      3'b1_00: key_need = 16'h00FF;
      3'b1_01: key_need = 16'h0FFF;
      default: key_need = 16'hFFFF;
    endcase
  end

  // commands (only while the engine is idle: CMD writes stall otherwise)
  logic cmd_key, cmd_enc, cmd_dec, cmd_clear, cmd_err;
  always_comb begin
    cmd_key   = 1'b0;
    cmd_enc   = 1'b0;
    cmd_dec   = 1'b0;
    cmd_clear = 1'b0;
    cmd_err   = 1'b0;
    if (we && a == RegCmd) begin
      unique case (wd[3:0])
        4'b0000: ;
        4'b0001: if (klen_q == 2'd3 || (key_need & ~key_wr_q) != '0) cmd_err = 1'b1;
                 else                                               cmd_key = 1'b1;
        4'b0010: if (!key_valid_q)   cmd_err = 1'b1; else cmd_enc = 1'b1;
        4'b0100: if (!key_valid_q)   cmd_err = 1'b1; else cmd_dec = 1'b1;
        4'b1000: cmd_clear = 1'b1;
        default: cmd_err = 1'b1;
      endcase
    end
  end

  logic         core_done, core_fault, core_wide, core_dout_valid;
  logic [3:0]   core_rounds;
  logic [255:0] core_dout;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wide_q      <= 1'b0;
      klen_q      <= 2'd0;
      key_q       <= '0;
      key_wr_q    <= '0;
      din_q       <= '0;
      key_valid_q <= 1'b0;
      key_run_q   <= 1'b0;
      done_q      <= 1'b0;
      err_q       <= 1'b0;
      fault_q     <= 1'b0;
      irq_en_q    <= '0;
      cycles_q    <= '0;
      cnt_q       <= '0;
    end else begin
      // register writes
      if (we) begin
        if (a == RegCtrl) begin
          if (wd[0] != wide_q || wd[2:1] != klen_q) key_valid_q <= 1'b0;
          wide_q <= wd[0];
          klen_q <= wd[2:1];
        end
        if (a == RegStatus) begin
          if (wd[2]) done_q  <= 1'b0;
          if (wd[3]) err_q   <= 1'b0;
          if (wd[5]) fault_q <= 1'b0;
        end
        if (a == RegIrqEn) irq_en_q <= {wd[5], wd[3:2]};
        if (sel_key) begin
          key_q[a[5:2]]    <= merge_be(key_q[a[5:2]], wd, bus_req_i.be);
          key_wr_q[a[5:2]] <= 1'b1;
          key_valid_q      <= 1'b0;
        end
        if (sel_din) din_q[a[4:2]] <= merge_be(din_q[a[4:2]], wd, bus_req_i.be);
      end
      // commands and engine events (after the writes: setting wins over W1C)
      if (cmd_key || cmd_enc || cmd_dec || cmd_clear) cnt_q <= 32'd1;
      else if (core_busy)                              cnt_q <= cnt_q + 32'd1;
      if (cmd_key) begin
        key_valid_q <= 1'b0;
        key_run_q   <= 1'b1;
        key_wr_q    <= '0;       // KEY stays until the end: the check reads it again
      end
      if (cmd_enc || cmd_dec) din_q <= '0;   // taken by the engine at this edge
      if (cmd_clear) begin
        key_valid_q <= 1'b0;
        key_q       <= '0;
        key_wr_q    <= '0;
        din_q       <= '0;
      end
      if (cmd_err) err_q <= 1'b1;
      if (core_done) begin
        done_q    <= 1'b1;
        cycles_q  <= cnt_q + 32'd1;
        key_run_q <= 1'b0;
        if (key_run_q) begin
          key_valid_q <= 1'b1;
          key_q       <= '0;     // the engine is done with the master key
        end
      end
      if (core_fault) begin      // last: nothing of the command survives
        fault_q     <= 1'b1;
        key_valid_q <= 1'b0;
        key_run_q   <= 1'b0;
        key_q       <= '0;
        key_wr_q    <= '0;
        din_q       <= '0;
      end
    end
  end

  assign irq_o = (done_q && irq_en_q[0]) || (err_q && irq_en_q[1]) || (fault_q && irq_en_q[2]);

  // ----------------------------------------------------------------- engine
  bow_mkv_core u_core (
    .clk_i,
    .rst_ni,
    .key_i      (cmd_key),
    .enc_i      (cmd_enc),
    .dec_i      (cmd_dec),
    .clear_i    (cmd_clear),
    .wide_i     (wide_q),
    .klen_i     (klen_q),
    .key_data_i (key_q),
    .din_i      (din_q),
    .busy_o       (core_busy),
    .done_o       (core_done),
    .fault_o      (core_fault),
    .dout_o       (core_dout),
    .dout_valid_o (core_dout_valid),
    .wide_o       (core_wide),
    .rounds_o     (core_rounds)
  );

  // -------------------------------------------------------------- read data
  logic [31:0] rdata_d, rdata_q;
  logic        rvalid_q;

  always_comb begin
    rdata_d = '0;
    if (sel_din) begin
      rdata_d = din_q[a[4:2]];
    end else if (sel_dout) begin
      rdata_d = core_dout_valid ? core_dout[32 * a[4:2] +: 32] : '0;
    end else begin
      case (a)
        RegId:     rdata_d = IdValue;
        RegInfo:   rdata_d = InfoValue;
        RegCtrl:   rdata_d = {29'h0, klen_q, wide_q};
        RegStatus: rdata_d = {20'h0, key_valid_q ? core_rounds : 4'h0, 2'h0, fault_q,
                              core_wide && key_valid_q, err_q, done_q, key_valid_q, core_busy};
        RegIrqEn:  rdata_d = {26'h0, irq_en_q[2], 1'b0, irq_en_q[1:0], 2'b00};
        RegCycles: rdata_d = cycles_q;
        default:   rdata_d = '0;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else begin
      rvalid_q <= bus_req_i.req && !stall;
      if (re) rdata_q <= rdata_d;
    end
  end

  assign bus_rsp_o.gnt    = !stall;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = rdata_q;

endmodule
