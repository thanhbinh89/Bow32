// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// H.264 encoder register file (CPU clock domain). Register map:
// docs/ip/h264.md.
//
//   0x000 ID           R    0x48323601 ("H26", version 1)
//   0x004 CTRL         RW   [0] EN  [1] DEBLOCK
//   0x008 CMD          W    [0] START  [1] STOP
//   0x00C STATUS       R/W1C [0] BUSY  [1] FRAME_DONE  [2] DONE  [3] ERR_OVF
//                           [4] ERR_INPUT  [5] ARMED
//   0x010 IRQ_EN       RW   STATUS bits 1..4
//   0x014 SIZE         RW   [11:0] width (multiple of 16)  [27:16] height (even)
//   0x018 QP           RW   [5:0] 10..51, used from the next coded frame
//   0x01C FRAMES       RW   [15:0] frames to code after START, 0 = until STOP
//   0x020 SKIP         RW   [7:0] input frames dropped after each coded frame
//   0x024 FRAME_CNT    R    frames coded since START
//   0x028 FRAME_BYTES  R    bytes of the last coded frame (NAL unit, padded to 4)
//   0x02C FRAME_CYCLES R    video clock cycles from its start of frame to its end
//   0x030 MB_CYCLES    R    cycles the macroblock engine worked on it
//   0x034 INFO         R    [15:0] maximum width  [19:16] strips in the buffer
//   0x038 TOTAL_BYTES  R    bytes since START
//
// SIZE, CTRL.DEBLOCK, FRAMES, SKIP are quasi-static for the video domain:
// change them only while CTRL.EN = 0 (SIZE) or before START. QP crosses with
// a pulse when it is written.

module bow_h264_regs import bow_bus_pkg::*; import bow_h264_pkg::*; #(
  parameter int unsigned MaxWidth  = 2048,
  parameter int unsigned NumStrips = 4
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  bus_req_t          bus_req_i,
  output bus_rsp_t          bus_rsp_o,

  output logic              enable_o,
  output logic              deblock_o,
  output logic [CoordW-1:0] width_o,
  output logic [CoordW-1:0] height_o,
  output logic [5:0]        qp_o,
  output logic              qp_upd_o,      // pulse
  output logic [15:0]       frames_o,
  output logic [7:0]        skip_o,
  output logic              start_o,       // pulse
  output logic              stop_o,        // pulse

  // video domain events (already synchronised pulses / levels)
  input  logic              busy_i,
  input  logic              armed_i,
  input  logic              frame_done_i,
  input  logic              seq_done_i,
  input  logic              err_ovf_i,
  input  logic              err_input_i,
  input  logic [23:0]       frame_bytes_i, // stable when frame_done_i pulses
  input  logic [31:0]       frame_cycles_i,
  input  logic [31:0]       mb_cycles_i,

  output logic              irq_o
);

  localparam int unsigned StBusy = 0, StFrameDone = 1, StDone = 2, StErrOvf = 3, StErrInput = 4,
                          StArmed = 5;
  localparam logic [5:0]  W1cMask = 6'b011110;

  logic [11:0] a;
  logic        we, re;
  logic [31:0] wd;

  assign a  = {bus_req_i.addr[11:2], 2'b00};
  assign we = bus_req_i.req &  bus_req_i.we;
  assign re = bus_req_i.req & ~bus_req_i.we;
  assign wd = bus_req_i.wdata;

  logic              en_q, deblock_q;
  logic [CoordW-1:0] width_q, height_q;
  logic [5:0]        qp_q;
  logic [15:0]       frames_q;
  logic [7:0]        skip_q;
  logic [5:0]        status_q, irq_en_q;
  logic [31:0]       frame_cnt_q, frame_bytes_q, frame_cycles_q, mb_cycles_q, total_q;

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
    end else begin
      if (frame_done_i) begin
        status_q[StFrameDone] <= 1'b1;
        frame_cnt_q           <= frame_cnt_q + 32'd1;
        frame_bytes_q         <= 32'(frame_bytes_i);
        frame_cycles_q        <= frame_cycles_i;
        mb_cycles_q           <= mb_cycles_i;
        total_q               <= total_q + 32'(frame_bytes_i);
      end
      if (seq_done_i)  status_q[StDone]     <= 1'b1;
      if (err_ovf_i)   status_q[StErrOvf]   <= 1'b1;
      if (err_input_i) status_q[StErrInput] <= 1'b1;
      if (we) begin
        unique case (a)
          12'h004: {deblock_q, en_q} <= wd[1:0];
          12'h008: if (wd[0]) begin
            frame_cnt_q        <= '0;
            total_q            <= '0;
            status_q[StDone]   <= 1'b0;
          end
          12'h00C: status_q <= status_q & ~(wd[5:0] & W1cMask);
          12'h010: irq_en_q <= wd[5:0] & W1cMask;
          12'h014: begin
            width_q  <= {wd[CoordW-1:4], 4'b0000};
            height_q <= {wd[17 +: CoordW-1], 1'b0};
          end
          12'h018: qp_q <= (wd[5:0] < 6'(QpMin)) ? 6'(QpMin) : (wd[5:0] > 6'(QpMax)) ? 6'(QpMax) : wd[5:0];
          12'h01C: frames_q <= wd[15:0];
          12'h020: skip_q   <= wd[7:0];
          default: ;
        endcase
      end
    end
  end

  assign enable_o  = en_q;
  assign deblock_o = deblock_q;
  assign width_o   = width_q;
  assign height_o  = height_q;
  assign qp_o      = qp_q;
  assign frames_o  = frames_q;
  assign skip_o    = skip_q;
  assign start_o   = we && (a == 12'h008) && wd[0];
  assign stop_o    = we && (a == 12'h008) && wd[1];

  // QP crosses with a pulse one cycle after the register changed
  logic qp_we_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) qp_we_q <= 1'b0;
    else         qp_we_q <= we && (a == 12'h018);
  end
  assign qp_upd_o = qp_we_q;

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
      12'h000: rdata_d = 32'h4832_3601;
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
                        wd[15:12], wd[3:0], wd[16]};

endmodule
