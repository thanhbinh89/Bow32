// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// H.264 encoder register file (CPU clock domain). Register map:
// docs/ip/h264.md.
//
//   0x000 ID           R    0x48323602 ("H26", version 2)
//   0x004 CTRL         RW   [0] EN  [1] DEBLOCK
//   0x008 CMD          W    [0] START (only while EN = 1)  [1] STOP
//   0x00C STATUS       R/W1C [0] BUSY  [1] FRAME_DONE  [2] DONE  [3] ERR_OVF
//                           [4] ERR_INPUT  [5] ARMED
//   0x010 IRQ_EN       RW   STATUS bits 1..4
//   0x014 SIZE         RW   [11:0] width (multiple of 16, 16..min(MaxWidth, 4080))
//                           [27:16] height (even, 16..4080)
//   0x018 QP           RW   [5:0] 10..51, used from the next coded frame
//   0x01C FRAMES       RW   [15:0] frames to code after START, 0 = until STOP
//   0x020 SKIP         RW   [7:0] input frames dropped after each coded frame
//   0x024 FRAME_CNT    R    frames coded since START
//   0x028 FRAME_BYTES  R    bytes of the last coded frame (NAL unit, padded to 4)
//   0x02C FRAME_CYCLES R    video clock cycles from its start of frame to its end
//   0x030 MB_CYCLES    R    cycles the macroblock engine worked on it
//   0x034 INFO         R    [15:0] maximum width  [19:16] strips in the buffer
//   0x038 TOTAL_BYTES  R    bytes since START
//   0x03C FRAME_INFO   R    the last coded frame: [5:0] QP  [8] DEBLOCK  [9] idr_pic_id
//                           [12] ERR_OVF  [13] ERR_INPUT  [14] LAST (of FRAMES)
//
// SIZE, FRAMES, SKIP are quasi-static for the video domain: change them only
// while CTRL.EN = 0 (SIZE) or before START. EN, DEBLOCK, QP, START and STOP
// travel as one control record (ctrl_t, bow_cdc_hs) in the order they were
// written, for any ratio of the two clocks: a write while a record is on the
// way goes with the next one. STATUS: an event of the video domain wins over
// a write 1 to clear in the same cycle (it is never lost).

module bow_h264_regs import bow_bus_pkg::*; import bow_h264_pkg::*; #(
  parameter int unsigned MaxWidth  = 2048,
  parameter int unsigned NumStrips = 4
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              cdc_rst_ni,     // rst_ni or the video reset (synchronised)

  input  bus_req_t          bus_req_i,
  output bus_rsp_t          bus_rsp_o,

  // quasi-static configuration
  output logic [CoordW-1:0] width_o,
  output logic [CoordW-1:0] height_o,
  output logic [15:0]       frames_o,
  output logic [7:0]        skip_o,

  // control records for the video domain (bow_cdc_hs source side)
  output logic              ctrl_valid_o,
  input  logic              ctrl_ready_i,
  output ctrl_t             ctrl_o,

  // video domain events (already synchronised pulses / levels)
  input  logic              busy_i,
  input  logic              armed_i,
  input  logic              frame_done_i,   // pulse
  input  frame_t            frame_info_i,   // stable when frame_done_i pulses
  input  logic              err_ovf_i,
  input  logic              err_input_i,
  input  logic [23:0]       frame_bytes_i,  // stable when frame_done_i pulses
  input  logic [31:0]       frame_cycles_i,
  input  logic [31:0]       mb_cycles_i,

  output logic              irq_o
);

  localparam int unsigned StBusy = 0, StFrameDone = 1, StDone = 2, StErrOvf = 3, StErrInput = 4,
                          StArmed = 5;
  localparam logic [5:0]  W1cMask = 6'b011110;
  // largest width: the strip buffers, and 255 macroblocks
  localparam int unsigned MaxW = (MaxWidth < SizeMax) ? MaxWidth : SizeMax;

  logic [11:0] a;
  logic        we, re;
  logic [31:0] wd;

  assign a  = {bus_req_i.addr[11:2], 2'b00};
  assign we = bus_req_i.req &  bus_req_i.we;
  assign re = bus_req_i.req & ~bus_req_i.we;
  assign wd = bus_req_i.wdata;

  logic ctrl_we, qp_we, start_cmd, stop_cmd, status_we;

  assign ctrl_we   = we && (a == 12'h004);
  assign qp_we     = we && (a == 12'h018);
  assign start_cmd = we && (a == 12'h008) && wd[0];
  assign stop_cmd  = we && (a == 12'h008) && wd[1];
  assign status_we = we && (a == 12'h00C);

  function automatic logic [CoordW-1:0] clamp(logic [CoordW-1:0] v, logic [CoordW-1:0] lo,
                                               logic [CoordW-1:0] hi);
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
  endfunction

  logic              en_q, deblock_q;
  logic [CoordW-1:0] width_q, height_q;
  logic [5:0]        qp_q;
  logic [15:0]       frames_q;
  logic [7:0]        skip_q;
  logic [5:0]        status_q, irq_en_q, st_set, st_clr;
  logic [31:0]       frame_cnt_q, frame_bytes_q, frame_cycles_q, mb_cycles_q, total_q;
  frame_t            frame_info_q;

  always_comb begin
    st_set              = '0;
    st_set[StFrameDone] = frame_done_i;
    st_set[StDone]      = frame_done_i && frame_info_i.seq_last;
    st_set[StErrOvf]    = err_ovf_i;
    st_set[StErrInput]  = err_input_i;
    st_clr              = status_we ? (wd[5:0] & W1cMask) : '0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      en_q           <= 1'b0;
      deblock_q      <= 1'b1;
      width_q        <= CoordW'(1280);
      height_q       <= CoordW'(720);
      qp_q           <= 6'd30;
      frames_q       <= '0;
      skip_q         <= '0;
      status_q       <= '0;
      irq_en_q       <= '0;
      frame_cnt_q    <= '0;
      frame_bytes_q  <= '0;
      frame_cycles_q <= '0;
      mb_cycles_q    <= '0;
      total_q        <= '0;
      frame_info_q   <= '0;
    end else begin
      // events set, W1C clears: setting wins
      status_q <= (status_q & ~st_clr) | st_set;
      if (frame_done_i) begin
        frame_cnt_q    <= frame_cnt_q + 32'd1;
        frame_bytes_q  <= 32'(frame_bytes_i);
        frame_cycles_q <= frame_cycles_i;
        mb_cycles_q    <= mb_cycles_i;
        frame_info_q   <= frame_info_i;
        total_q        <= total_q + 32'(frame_bytes_i);
      end
      if (we) begin
        unique case (a)
          12'h004: {deblock_q, en_q} <= wd[1:0];
          // START begins a new sequence: it wins over an event of the old one
          // (and is ignored altogether while EN = 0)
          12'h008: if (wd[0] && en_q) begin
            frame_cnt_q      <= '0;
            total_q          <= '0;
            status_q[StDone] <= 1'b0;
          end
          12'h010: irq_en_q <= wd[5:0] & W1cMask;
          12'h014: begin
            width_q  <= clamp({wd[CoordW-1:4], 4'b0000}, CoordW'(SizeMin), CoordW'(MaxW));
            height_q <= clamp({wd[17 +: CoordW-1], 1'b0}, CoordW'(SizeMin), CoordW'(SizeMax));
          end
          12'h018: qp_q <= (wd[5:0] < 6'(QpMin)) ? 6'(QpMin) : (wd[5:0] > 6'(QpMax)) ? 6'(QpMax) : wd[5:0];
          12'h01C: frames_q <= wd[15:0];
          12'h020: skip_q   <= wd[7:0];
          default: ;
        endcase
      end
    end
  end

  assign width_o  = width_q;
  assign height_o = height_q;
  assign frames_o = frames_q;
  assign skip_o   = skip_q;

  // ------------------------------------------------- control records (ctrl_t)
  // A record is pending after every write of CTRL, QP or CMD and after a
  // reset of either domain (the video side then gets the configuration
  // again). It carries the register values of the cycle it is sent in; the
  // writes of that cycle go with the next record.
  logic pend_q, dis_q, start_q, stop_q, ctrl_send;

  assign ctrl_send = pend_q && ctrl_ready_i;

  always_ff @(posedge clk_i or negedge cdc_rst_ni) begin
    if (!cdc_rst_ni) begin
      pend_q  <= 1'b1;
      dis_q   <= 1'b0;
      start_q <= 1'b0;
      stop_q  <= 1'b0;
    end else begin
      if (ctrl_send) begin
        pend_q  <= 1'b0;
        dis_q   <= 1'b0;
        start_q <= 1'b0;
        stop_q  <= 1'b0;
      end
      if (ctrl_we || qp_we || start_cmd || stop_cmd) pend_q <= 1'b1;
      if (ctrl_we && !wd[0]) begin
        if (en_q) dis_q <= 1'b1;
        start_q <= 1'b0;                      // START needs EN
      end
      if (start_cmd && en_q) begin            // START + STOP in one write: START (as ever)
        start_q <= 1'b1;
        stop_q  <= 1'b0;
      end else if (stop_cmd) begin
        stop_q  <= 1'b1;
        start_q <= 1'b0;
      end
    end
  end

  assign ctrl_valid_o   = pend_q;
  assign ctrl_o.dis     = dis_q;
  assign ctrl_o.en      = en_q;
  assign ctrl_o.deblock = deblock_q;
  assign ctrl_o.qp      = qp_q;
  assign ctrl_o.start   = start_q;
  assign ctrl_o.stop    = stop_q;

  logic [5:0] status;
  always_comb begin
    status          = status_q;
    status[StBusy]  = busy_i;
    status[StArmed] = armed_i;
  end

  assign irq_o = |(status & irq_en_q);

  // ------------------------------------------------------------ read data
  logic [31:0] rdata_d, rdata_q;
  logic        rvalid_q;

  always_comb begin
    unique case (a)
      12'h000: rdata_d = 32'h4832_3602;
      12'h004: rdata_d = {30'h0, deblock_q, en_q};
      12'h00C: rdata_d = {26'h0, status};
      12'h010: rdata_d = {26'h0, irq_en_q};
      12'h014: rdata_d = {4'h0, height_q, 4'h0, width_q};
      12'h018: rdata_d = {26'h0, qp_q};
      12'h01C: rdata_d = {16'h0, frames_q};
      12'h020: rdata_d = {24'h0, skip_q};
      12'h024: rdata_d = frame_cnt_q;
      12'h028: rdata_d = frame_bytes_q;
      12'h02C: rdata_d = frame_cycles_q;
      12'h030: rdata_d = mb_cycles_q;
      12'h034: rdata_d = {12'h0, 4'(NumStrips), 16'(MaxWidth)};
      12'h038: rdata_d = total_q;
      12'h03C: rdata_d = {17'h0, frame_info_q.seq_last, frame_info_q.err_input,
                          frame_info_q.err_ovf, 2'b00, frame_info_q.idr_id,
                          frame_info_q.deblock, 2'b00, frame_info_q.qp};
      default: rdata_d = '0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else begin
      rvalid_q <= bus_req_i.req;
      if (re) rdata_q <= rdata_d;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = rdata_q;

  logic unused_bus;
  assign unused_bus = ^{bus_req_i.addr[31:12], bus_req_i.addr[1:0], bus_req_i.be, wd[31:28],
                        wd[16]};

endmodule
