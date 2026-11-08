// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MKV block cipher accelerator: MKV-128 / MKV-256 of TCVN 14263:2024
// with the six key sizes, key schedule in hardware, encryption and
// decryption of one block per command (bow_mkv_core).
// Register map (docs/ip/mkv.md):
//
//   0x000 ID        R     0x4D4B5602 ("MKV", version 2: TCVN 14263:2024;
//                         version 1 was the cipher of the draft)
//   0x004 INFO      R     [0] MKV-128  [1] MKV-256  [2] fault detection
//                         [3] round key code  [4] fault lockout  [5] TEST
//                         [6] NOSTALL  [7] KEY_LOCK and use policy
//                         [15:8] cycles per round of ENC / DEC (4: 2 + check)
//                         [19:16] FaultLimit
//   0x008 CTRL      RW    [0] BLOCK (0 MKV-128, 1 MKV-256)
//                         [2:1] KLEN (0 k = l, 1 k = 3l/2, 2 k = 2l)
//                         [3] NOSTALL  [4] KEY_LOCK (write 1 to set)
//                         [5] NO_DEC  [6] NO_ENC
//   0x00C CMD       W     one bit per write: [0] KEY  [1] ENC  [2] DEC  [3] CLEAR,
//                         [4] TEST with KEY / ENC / DEC
//   0x010 STATUS    R/W1C [0] BUSY  [1] KEY_VALID  [2] DONE  [3] ERR  [4] WIDE
//                         [5] FAULT  [6] LOCKED  [7] ALERT
//                         [11:8] ROUNDS  [15:12] FAULTS (since power-on)
//                         ([4], [11:8]: version of the key schedule, 0 = none)
//   0x014 IRQ_EN    RW    [2] DONE  [3] ERR  [5] FAULT
//   0x018 CYCLES    R     cycles of the last command (CMD write -> result)
//   0x040 KEY[0..15] W    master key: byte b = KEY[b / 4][8 * (b % 4) +: 8],
//                         zeroed at the end of the KEY command
//   0x080 DIN[0..7]  W    input block, same byte order, zeroed when ENC / DEC start
//   0x0C0 DOUT[0..7] R    output block, zeroed by KEY; reads 0 unless it holds
//                         a checked result
//
// Any other offset, a read of CMD / KEY / DIN and a write of ID / INFO /
// CYCLES / DOUT answer with a bus error.
//
// A command that cannot run sets ERR and does nothing: ENC / DEC without a
// valid key schedule or against the use policy (NO_ENC / NO_DEC), KEY with
// KLEN = 3, under KEY_LOCK or before every word of the key (k / 32 words for
// the version in CTRL) was written since the last KEY or CLEAR, more than
// one CMD bit, any command but CLEAR while LOCKED. A refused KEY zeroes the
// KEY registers. KEY_VALID is cleared by a write to KEY, by a change of the
// version in CTRL (both also wipe the old key schedule in the engine) and by
// CLEAR (which also zeroes KEY, DIN, DOUT and the round keys).
//
// Fault detection (bow_mkv_core): every command is done twice and checked.
// A fault sets FAULT (until written with 1), releases no result and zeroes
// the round keys, KEY, DIN, DOUT and KEY_VALID: software needs a new KEY.
// Faults are counted from power-on (FAULTS, por_rst_ni only); at FaultLimit
// the IP locks itself (LOCKED) until the next power-on reset: every command
// but CLEAR is refused and the fatal alert goes out (ALERT, to the NMI of
// the CPU). The expected fault of a TEST command is not counted; a TEST
// command without a fault (broken detection) locks the IP as well.
//
// KEY_LOCK (CTRL[4], cleared by reset only): KEY, the version and the use
// policy can no longer change, KEY is refused; ENC / DEC (as the policy
// allows) and CLEAR still work.
//
// While a command runs (BUSY), writes to CTRL / CMD and reads of DOUT wait
// (gnt = 0) until it is done, as do writes to KEY unless the engine is only
// wiping; so software can write CMD and read DOUT right away. With NOSTALL
// (or LOCKED) they do not wait: such a write is dropped and sets ERR, DOUT
// reads 0. DIN can be written during a command: it is copied into the
// engine when the command starts.

module bow_mkv import bow_bus_pkg::*; #(
  parameter int unsigned FaultLimit = 4   // detected faults since power-on that lock the IP, 1..15
) (
  input  logic     clk_i,
  input  logic     rst_ni,          // system reset
  input  logic     por_rst_ni,      // power-on reset: the only reset of FAULTS and LOCKED

  input  bus_req_t bus_req_i,
  output bus_rsp_t bus_rsp_o,

  output logic     irq_o,
  output logic     alert_fault_o,   // one cycle per counted fault (recoverable alert)
  output logic     alert_fatal_o    // the IP locked itself: ALERT, until written with 1 or reset
);

  import bow_mkv_pkg::*;

  if (FaultLimit < 1 || FaultLimit > 15) begin : gen_bad_limit
    $error("bow_mkv: FaultLimit must be 1..15");
  end

  localparam logic [31:0] IdValue   = 32'h4d4b_5602;
  localparam logic [31:0] InfoValue = {12'h0, 4'(FaultLimit), 8'd4, 8'hff};

  localparam logic [11:0] RegId = 12'h000, RegInfo = 12'h004, RegCtrl = 12'h008, RegCmd = 12'h00C,
                          RegStatus = 12'h010, RegIrqEn = 12'h014, RegCycles = 12'h018;

  // ------------------------------------------------------------ bus decode
  logic [11:0] a;
  logic        sel_key, sel_din, sel_dout, sel_r, sel_w, bad_acc;
  logic [31:0] wd;
  logic        core_busy, core_clear;

  assign a        = {bus_req_i.addr[11:2], 2'b00};
  assign sel_key  = (a[11:6] == 6'h01);   // 0x040 .. 0x07C
  assign sel_din  = (a[11:5] == 7'h04);   // 0x080 .. 0x09C
  assign sel_dout = (a[11:5] == 7'h06);   // 0x0C0 .. 0x0DC
  assign wd       = bus_req_i.wdata;
  assign sel_r    = (a == RegId) || (a == RegInfo) || (a == RegCtrl) || (a == RegStatus) ||
                    (a == RegIrqEn) || (a == RegCycles) || sel_dout;
  assign sel_w    = (a == RegCtrl) || (a == RegCmd) || (a == RegStatus) || (a == RegIrqEn) ||
                    sel_key || sel_din;
  assign bad_acc  = bus_req_i.we ? !sel_w : !sel_r;   // answered with a bus error

  logic locked;    // LOCKED (power-on domain, below)
  logic nostall_q;

  // Accesses that have to wait for the engine: a command needs an idle
  // engine, the KEY command reads CTRL and KEY again in its second pass, DOUT
  // is read when the result is there. KEY can be written during a wipe.
  logic blocked, stall, we, re, wr;
  assign blocked = core_busy &&
                   (bus_req_i.we ? (a == RegCtrl || a == RegCmd || (sel_key && !core_clear)) : sel_dout);
  assign stall   = bus_req_i.req && blocked && !nostall_q && !locked;
  assign we      = bus_req_i.req && !stall &&  bus_req_i.we;
  assign re      = bus_req_i.req && !stall && !bus_req_i.we;
  assign wr      = we && !bad_acc && !blocked;   // a write that takes effect

  function automatic logic [31:0] merge_be(logic [31:0] old, logic [31:0] data, logic [3:0] be);
    logic [31:0] r;
    for (int b = 0; b < 4; b++) r[8*b +: 8] = be[b] ? data[8*b +: 8] : old[8*b +: 8];
    return r;
  endfunction

  // -------------------------------------------------------------- registers
  logic              wide_q;
  logic [1:0]        klen_q;
  logic              key_lock_q, no_enc_q, no_dec_q;
  logic [15:0][31:0] key_q;
  logic [15:0]       key_wr_q;     // KEY words written since the last KEY / CLEAR
  logic [7:0][31:0]  din_q;
  logic              key_valid_q, key_run_q, test_run_q, done_q, err_q, fault_q, alert_q;
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

  // writes to CTRL that change the version of the next KEY / the use policy
  logic ver_change, pol_change;
  assign ver_change = (wd[0] != wide_q) || (wd[2:1] != klen_q);
  assign pol_change = (wd[5] != no_dec_q) || (wd[6] != no_enc_q);

  logic ctrl_wr, key_wr, din_wr, wr_drop;
  assign ctrl_wr = wr && (a == RegCtrl) && !locked;
  assign key_wr  = wr && sel_key && !locked && !key_lock_q;
  assign din_wr  = wr && sel_din && !locked;
  // dropped writes set ERR: waiting for the engine (NOSTALL / LOCKED), LOCKED,
  // KEY or another version / policy under KEY_LOCK
  assign wr_drop = (we && !bad_acc && blocked && (a != RegCmd)) ||
                   (wr && locked && ((a == RegCtrl) || sel_key || sel_din)) ||
                   (wr && !locked && key_lock_q &&
                    (sel_key || ((a == RegCtrl) && (ver_change || pol_change))));

  // KEY_VALID lost by a new key word or another version: the engine wipes
  // the key schedule it holds (it is idle: these writes wait otherwise)
  logic kv_drop;
  assign kv_drop = key_valid_q && (key_wr || (ctrl_wr && !key_lock_q && ver_change));

  // LOCKED: whatever the engine still holds (a key schedule, a result) is
  // wiped as soon as it is idle (a lock without a fault, e.g. a TEST that was
  // not caught, would leave them otherwise)
  logic lock_wipe;

  // commands (only while the engine is idle: CMD writes wait otherwise)
  logic cmd_key, cmd_enc, cmd_dec, cmd_clear, cmd_test, cmd_err, key_refused;
  always_comb begin
    cmd_key     = 1'b0;
    cmd_enc     = 1'b0;
    cmd_dec     = 1'b0;
    cmd_clear   = 1'b0;
    cmd_test    = 1'b0;
    cmd_err     = 1'b0;
    key_refused = 1'b0;
    if (we && !bad_acc && a == RegCmd) begin
      unique case (wd[4:0])
        5'b00000: ;
        5'b00001, 5'b10001: begin
          if (blocked || locked || key_lock_q || klen_q == 2'd3 || (key_need & ~key_wr_q) != '0) begin
            cmd_err     = 1'b1;
            key_refused = 1'b1;
          end else begin
            cmd_key  = 1'b1;
            cmd_test = wd[4];
          end
        end
        5'b00010, 5'b10010: begin
          if (blocked || locked || !key_valid_q || no_enc_q) cmd_err = 1'b1;
          else begin
            cmd_enc  = 1'b1;
            cmd_test = wd[4];
          end
        end
        5'b00100, 5'b10100: begin
          if (blocked || locked || !key_valid_q || no_dec_q) cmd_err = 1'b1;
          else begin
            cmd_dec  = 1'b1;
            cmd_test = wd[4];
          end
        end
        5'b01000: if (blocked) cmd_err = 1'b1; else cmd_clear = 1'b1;
        default:  cmd_err = 1'b1;
      endcase
    end
  end

  logic         core_done, core_fault, core_wide, core_dout_valid, core_ks_valid;
  logic [3:0]   core_rounds;
  logic [255:0] core_dout;

  assign lock_wipe = locked && !core_busy && (core_ks_valid || core_dout_valid);

  // ------------------------------------------- fault counter (power-on domain)
  // Kept with a complement copy; LOCKED is mubi4 and every value but False
  // locks. A system reset (software, UART break) clears neither.
  logic [3:0] fcnt_q, fcnt_inc;
  (* keep = "true" *) logic [3:0] fcnt_n_q;
  (* keep = "true" *) mubi4_t     locked_q;
  logic fault_cnt, test_bad, lock_event;

  assign fault_cnt  = core_fault && !test_run_q;   // the fault of a TEST is expected
  assign test_bad   = core_done && test_run_q;     // a TEST without fault: detection broken
  assign fcnt_inc   = (fcnt_q == 4'hF) ? 4'hF : fcnt_q + 4'd1;
  assign locked     = (locked_q != MuBi4False);
  assign lock_event = !locked && ((fault_cnt && (fcnt_inc >= 4'(FaultLimit))) || test_bad ||
                                  (fcnt_q != ~fcnt_n_q));

  always_ff @(posedge clk_i or negedge por_rst_ni) begin
    if (!por_rst_ni) begin
      fcnt_q   <= 4'h0;
      fcnt_n_q <= 4'hF;
      locked_q <= MuBi4False;
    end else begin
      if (fault_cnt) begin
        fcnt_q   <= fcnt_inc;
        fcnt_n_q <= ~fcnt_inc;
      end
      if (lock_event) locked_q <= MuBi4True;
    end
  end

  // ------------------------------------------------ registers (system reset)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wide_q      <= 1'b0;
      klen_q      <= 2'd0;
      nostall_q   <= 1'b0;
      key_lock_q  <= 1'b0;
      no_enc_q    <= 1'b0;
      no_dec_q    <= 1'b0;
      key_q       <= '0;
      key_wr_q    <= '0;
      din_q       <= '0;
      key_valid_q <= 1'b0;
      key_run_q   <= 1'b0;
      test_run_q  <= 1'b0;
      done_q      <= 1'b0;
      err_q       <= 1'b0;
      fault_q     <= 1'b0;
      alert_q     <= 1'b0;
      irq_en_q    <= '0;
      cycles_q    <= '0;
      cnt_q       <= '0;
    end else begin
      // register writes
      if (ctrl_wr) begin
        if (!key_lock_q) begin
          if (ver_change) key_valid_q <= 1'b0;
          wide_q   <= wd[0];
          klen_q   <= wd[2:1];
          no_dec_q <= wd[5];
          no_enc_q <= wd[6];
        end
        nostall_q <= wd[3];
        if (wd[4]) key_lock_q <= 1'b1;
      end
      if (wr && a == RegStatus) begin
        if (wd[2]) done_q  <= 1'b0;
        if (wd[3]) err_q   <= 1'b0;
        if (wd[5]) fault_q <= 1'b0;
        if (wd[7]) alert_q <= 1'b0;
      end
      if (wr && a == RegIrqEn) irq_en_q <= {wd[5], wd[3:2]};
      if (key_wr) begin
        key_q[a[5:2]]    <= merge_be(key_q[a[5:2]], wd, bus_req_i.be);
        key_wr_q[a[5:2]] <= 1'b1;
        key_valid_q      <= 1'b0;
      end
      if (din_wr) din_q[a[4:2]] <= merge_be(din_q[a[4:2]], wd, bus_req_i.be);
      if (wr_drop) err_q <= 1'b1;
      // commands and engine events (after the writes: setting wins over W1C)
      if (cmd_key || cmd_enc || cmd_dec || cmd_clear) cnt_q <= 32'd1;
      else if (core_busy)                              cnt_q <= cnt_q + 32'd1;
      if (cmd_key) begin
        key_valid_q <= 1'b0;
        key_run_q   <= 1'b1;
        key_wr_q    <= '0;       // KEY stays until the end: the check reads it again
      end
      if (cmd_key || cmd_enc || cmd_dec) test_run_q <= cmd_test;
      if (cmd_enc || cmd_dec) din_q <= '0;   // taken by the engine at this edge
      if (cmd_clear) begin
        key_valid_q <= 1'b0;
        key_q       <= '0;
        key_wr_q    <= '0;
        din_q       <= '0;
      end
      if (key_refused) begin     // a refused KEY leaves no key behind
        key_q    <= '0;
        key_wr_q <= '0;
      end
      if (cmd_err) err_q <= 1'b1;
      if (core_done) begin
        done_q     <= 1'b1;
        cycles_q   <= cnt_q + 32'd1;
        key_run_q  <= 1'b0;
        test_run_q <= 1'b0;
        if (key_run_q) begin
          if (!test_run_q) key_valid_q <= 1'b1;
          key_q <= '0;           // the engine is done with the master key
        end
      end
      if (core_fault) begin      // last: nothing of the command survives
        fault_q     <= 1'b1;
        key_valid_q <= 1'b0;
        key_run_q   <= 1'b0;
        test_run_q  <= 1'b0;
        key_q       <= '0;
        key_wr_q    <= '0;
        din_q       <= '0;
      end
      if (lock_event) begin      // nothing of the key survives a lock either
        alert_q     <= 1'b1;
        key_valid_q <= 1'b0;
        key_run_q   <= 1'b0;
        key_q       <= '0;
        key_wr_q    <= '0;
        din_q       <= '0;
      end
    end
  end

  assign irq_o = (done_q && irq_en_q[0]) || (err_q && irq_en_q[1]) || (fault_q && irq_en_q[2]);
  assign alert_fault_o = fault_cnt;
  assign alert_fatal_o = alert_q;

  // ----------------------------------------------------------------- engine
  bow_mkv_core u_core (
    .clk_i,
    .rst_ni,
    .key_i        (cmd_key),
    .enc_i        (cmd_enc),
    .dec_i        (cmd_dec),
    .clear_i      (cmd_clear),
    .wipe_i       (kv_drop || lock_wipe),
    .test_i       (cmd_test),
    .lock_i       (locked),
    .key_valid_i  (key_valid_q),
    .wide_i       (wide_q),
    .klen_i       (klen_q),
    .key_data_i   (key_q),
    .din_i        (din_q),
    .busy_o       (core_busy),
    .clear_o      (core_clear),
    .done_o       (core_done),
    .fault_o      (core_fault),
    .dout_o       (core_dout),
    .dout_valid_o (core_dout_valid),
    .ks_valid_o   (core_ks_valid),
    .wide_o       (core_wide),
    .rounds_o     (core_rounds)
  );

  // -------------------------------------------------------------- read data
  // KEY_VALID: the register block and the engine have to agree
  logic        key_valid;
  logic [31:0] rdata_d, rdata_q;
  logic        rvalid_q, err_rsp_q;

  assign key_valid = key_valid_q && core_ks_valid;

  always_comb begin
    rdata_d = '0;
    if (sel_dout) begin
      rdata_d = (core_dout_valid && !locked) ? core_dout[32 * a[4:2] +: 32] : '0;
    end else begin
      case (a)
        RegId:     rdata_d = IdValue;
        RegInfo:   rdata_d = InfoValue;
        RegCtrl:   rdata_d = {25'h0, no_enc_q, no_dec_q, key_lock_q, nostall_q, klen_q, wide_q};
        RegStatus: rdata_d = {16'h0, fcnt_q, key_valid ? core_rounds : 4'h0, alert_q, locked,
                              fault_q, core_wide && key_valid, err_q, done_q, key_valid, core_busy};
        RegIrqEn:  rdata_d = {26'h0, irq_en_q[2], 1'b0, irq_en_q[1:0], 2'b00};
        RegCycles: rdata_d = cycles_q;
        default:   rdata_d = '0;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q  <= 1'b0;
      err_rsp_q <= 1'b0;
      rdata_q   <= '0;
    end else begin
      rvalid_q  <= bus_req_i.req && !stall;
      err_rsp_q <= bus_req_i.req && !stall && bad_acc;
      if (re) rdata_q <= bad_acc ? '0 : rdata_d;
    end
  end

  assign bus_rsp_o.gnt    = !stall;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = err_rsp_q;
  assign bus_rsp_o.rdata  = rdata_q;

endmodule
