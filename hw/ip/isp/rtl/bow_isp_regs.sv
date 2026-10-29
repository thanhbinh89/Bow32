// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// ISP register file (CPU clock domain). Register map: docs/ip/isp.md.
//
// Shadowed registers (0x020..0x0CC) are a staging copy: writing UPDATE asks
// the video domain to copy them into the active configuration between two
// frames; STATUS.UPD_PENDING stays set until that happened. Do not write
// shadowed registers while UPD_PENDING = 1.
//
// Everything that crosses into the video domain is either a pulse (through
// bow_cdc_pulse in bow_isp) or quasi-static data that only changes while the
// receiver does not look at it.

module bow_isp_regs import bow_bus_pkg::*; import bow_isp_pkg::*; #(
  parameter int unsigned MaxWidth = 2048,
  parameter int unsigned BufWords = 32768
) (
  input  logic                clk_i,
  input  logic                rst_ni,

  input  bus_req_t            bus_req_i,
  output bus_rsp_t            bus_rsp_o,

  // control
  output logic                enable_o,
  output logic                src_tpg_o,
  output isp_cfg_t            cfg_o,         // staging copy
  output logic                upd_req_o,     // pulse
  input  logic                upd_ack_i,     // pulse
  output isp_cap_cfg_t        cap_cfg_o,
  output logic                cap_start_o,   // pulse
  input  logic                cap_done_i,    // pulse

  // gamma tables
  output logic [2:0]          lut_we_o,
  output logic [PixW-1:0]     lut_addr_o,
  output logic [OutW-1:0]     lut_data_o,

  // events from the video domain (pulses, already synchronised)
  input  logic                snap_i,
  input  isp_stats_t          stats_i,       // stable when snap_i pulses
  input  logic [CoordW-1:0]   meas_width_i,
  input  logic [CoordW-1:0]   meas_height_i,
  input  logic                err_input_i,
  input  logic                err_fifo_i,
  input  logic                err_output_i,
  input  logic                err_cap_i,

  output logic                irq_o
);

  // Status bits
  localparam int unsigned StUpdPending = 0;
  localparam int unsigned StFrameDone  = 1;
  localparam int unsigned StCapDone    = 2;
  localparam int unsigned StCapBusy    = 3;
  localparam int unsigned StErrInput   = 4;
  localparam int unsigned StErrFifo    = 5;
  localparam int unsigned StErrOutput  = 6;
  localparam int unsigned StErrCap     = 7;
  localparam logic [7:0]  StW1cMask    = 8'b1111_0110;

  logic [11:0] a;
  logic        we, re;
  logic [31:0] wd;

  assign a  = {bus_req_i.addr[11:2], 2'b00};
  assign we = bus_req_i.req &  bus_req_i.we;
  assign re = bus_req_i.req & ~bus_req_i.we;
  assign wd = bus_req_i.wdata;

  // ------------------------------------------------------------- registers
  isp_cfg_t     cfg_q;
  isp_cap_cfg_t cap_q;
  logic         en_q, tpg_q, upd_pend_q, cap_busy_q;
  logic [7:0]   status_q, irq_en_q;
  logic [31:0]  frame_cnt_q;
  isp_stats_t   stats_q;
  logic [CoordW-1:0] in_w_q, in_h_q;
  logic [PixW-1:0]   lut_addr_q;
  logic [2:0]        lut_mask_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      en_q        <= 1'b0;
      tpg_q       <= 1'b0;
      upd_pend_q  <= 1'b0;
      cap_busy_q  <= 1'b0;
      status_q    <= '0;
      irq_en_q    <= '0;
      frame_cnt_q <= '0;
      stats_q     <= '0;
      in_w_q      <= '0;
      in_h_q      <= '0;
      lut_addr_q  <= '0;
      lut_mask_q  <= 3'b111;

      cfg_q             <= '0;
      cfg_q.width       <= CoordW'(1920);
      cfg_q.height      <= CoordW'(1080);
      cfg_q.blc         <= PixW'(64);
      cfg_q.dpc_th      <= PixW'(64);
      cfg_q.wb_gain     <= {4{GainW'(256)}};
      cfg_q.st_x1       <= '1;
      cfg_q.st_y1       <= '1;
      cfg_q.st_sat      <= '1;
      cfg_q.tpg_hblank  <= 16'd256;
      cfg_q.tpg_vblank  <= 16'd32;
      cfg_q.tpg_color   <= {3{PixW'(512)}};
      cfg_q.ccm         <= {CoefW'(256), CoefW'(0), CoefW'(0),
                            CoefW'(0), CoefW'(256), CoefW'(0),
                            CoefW'(0), CoefW'(0), CoefW'(256)};
      cfg_q.csc         <= {CoefW'(256), CoefW'(0), CoefW'(0),
                            CoefW'(0), CoefW'(256), CoefW'(0),
                            CoefW'(0), CoefW'(0), CoefW'(256)};

      cap_q             <= '0;
      cap_q.width       <= CoordW'(240);
      cap_q.height      <= CoordW'(135);
      cap_q.scale       <= 2'd3;
    end else begin
      // ---- events from the video domain
      if (upd_ack_i) upd_pend_q <= 1'b0;
      if (cap_done_i) begin
        cap_busy_q            <= 1'b0;
        status_q[StCapDone]   <= 1'b1;
      end
      if (snap_i) begin
        stats_q                 <= stats_i;
        in_w_q                  <= meas_width_i;
        in_h_q                  <= meas_height_i;
        frame_cnt_q             <= frame_cnt_q + 32'd1;
        status_q[StFrameDone]   <= 1'b1;
      end
      if (err_input_i)  status_q[StErrInput]  <= 1'b1;
      if (err_fifo_i)   status_q[StErrFifo]   <= 1'b1;
      if (err_output_i) status_q[StErrOutput] <= 1'b1;
      if (err_cap_i)    status_q[StErrCap]    <= 1'b1;

      // ---- register writes
      if (we) begin
        unique case (a)
          12'h004: begin
            en_q  <= wd[0];
            tpg_q <= wd[1];
          end
          12'h008: if (wd[0]) upd_pend_q <= 1'b1;
          12'h00C: status_q <= status_q & ~(wd[7:0] & StW1cMask);
          12'h010: irq_en_q <= wd[7:0] & StW1cMask;
          12'h020: begin
            cfg_q.width  <= wd[CoordW-1:0];
            cfg_q.height <= wd[16 +: CoordW];
          end
          12'h024: {cfg_q.csc_en, cfg_q.gamma_en, cfg_q.ccm_en, cfg_q.wb_en,
                    cfg_q.dpc_en, cfg_q.blc_en} <= wd[5:0];
          12'h028: cfg_q.bayer      <= wd[1:0];
          12'h02C: cfg_q.blc        <= wd[PixW-1:0];
          12'h030: cfg_q.dpc_th     <= wd[PixW-1:0];
          12'h034: cfg_q.wb_gain[0] <= wd[GainW-1:0];
          12'h038: cfg_q.wb_gain[1] <= wd[GainW-1:0];
          12'h03C: cfg_q.wb_gain[2] <= wd[GainW-1:0];
          12'h040: cfg_q.wb_gain[3] <= wd[GainW-1:0];
          12'h044: begin
            cfg_q.st_x0 <= wd[CoordW-1:0];
            cfg_q.st_x1 <= wd[16 +: CoordW];
          end
          12'h048: begin
            cfg_q.st_y0 <= wd[CoordW-1:0];
            cfg_q.st_y1 <= wd[16 +: CoordW];
          end
          12'h04C: cfg_q.st_sat <= wd[PixW-1:0];
          12'h050: begin
            cfg_q.tpg_pattern <= wd[1:0];
            cfg_q.tpg_motion  <= wd[4];
          end
          12'h054: begin
            cfg_q.tpg_hblank <= wd[15:0];
            cfg_q.tpg_vblank <= wd[31:16];
          end
          12'h058: cfg_q.tpg_color <= {wd[20 +: PixW], wd[10 +: PixW], wd[0 +: PixW]};
          12'h060, 12'h064, 12'h068, 12'h06C, 12'h070,
          12'h074, 12'h078, 12'h07C, 12'h080: cfg_q.ccm[(a - 12'h060) >> 2] <= wd[CoefW-1:0];
          12'h084: cfg_q.ccm_off[0] <= wd[10:0];
          12'h088: cfg_q.ccm_off[1] <= wd[10:0];
          12'h08C: cfg_q.ccm_off[2] <= wd[10:0];
          12'h0A0, 12'h0A4, 12'h0A8, 12'h0AC, 12'h0B0,
          12'h0B4, 12'h0B8, 12'h0BC, 12'h0C0: cfg_q.csc[(a - 12'h0A0) >> 2] <= wd[CoefW-1:0];
          12'h0C4: cfg_q.csc_off[0] <= wd[8:0];
          12'h0C8: cfg_q.csc_off[1] <= wd[8:0];
          12'h0CC: cfg_q.csc_off[2] <= wd[8:0];
          12'h0E0: begin
            lut_addr_q <= wd[PixW-1:0];
            lut_mask_q <= wd[18:16];
          end
          12'h0E4: lut_addr_q <= lut_addr_q + PixW'(1);
          12'h0F0: if (wd[0]) begin
            cap_busy_q          <= 1'b1;
            status_q[StCapDone] <= 1'b0;
          end
          12'h0F4: begin
            cap_q.x0 <= wd[CoordW-1:0];
            cap_q.y0 <= wd[16 +: CoordW];
          end
          12'h0F8: begin
            cap_q.width  <= wd[CoordW-1:0];
            cap_q.height <= wd[16 +: CoordW];
          end
          12'h0FC: cap_q.scale <= wd[1:0];
          default: ;
        endcase
      end
    end
  end

  assign enable_o    = en_q;
  assign src_tpg_o   = tpg_q;
  assign cfg_o       = cfg_q;
  assign cap_cfg_o   = cap_q;
  assign upd_req_o   = we && (a == 12'h008) && wd[0];
  assign cap_start_o = we && (a == 12'h0F0) && wd[0];
  assign lut_we_o    = (we && (a == 12'h0E4)) ? lut_mask_q : 3'b000;
  assign lut_addr_o  = lut_addr_q;
  assign lut_data_o  = wd[OutW-1:0];

  logic [7:0] status;
  always_comb begin
    status               = status_q;
    status[StUpdPending] = upd_pend_q;
    status[StCapBusy]    = cap_busy_q;
  end

  assign irq_o = |(status & irq_en_q);

  // ------------------------------------------------------------ read data
  logic [31:0] rdata_d, rdata_q;
  logic        rvalid_q;

  function automatic logic [31:0] sx_coef(logic [CoefW-1:0] c);
    return {{(32 - CoefW){c[CoefW-1]}}, c};
  endfunction

  always_comb begin
    rdata_d = '0;
    if (a >= 12'h200 && a < 12'h300) begin
      rdata_d = 32'(stats_q.hist[a[7:2]]);
    end else begin
      unique case (a)
        12'h000: rdata_d = 32'h4953_5001;     // "ISP", version 1
        12'h004: rdata_d = {30'h0, tpg_q, en_q};
        12'h00C: rdata_d = {24'h0, status};
        12'h010: rdata_d = {24'h0, irq_en_q};
        12'h014: rdata_d = frame_cnt_q;
        12'h018: rdata_d = {4'h0, in_h_q, 4'h0, in_w_q};
        12'h01C: rdata_d = {16'(BufWords / 1024), 16'(MaxWidth)};
        12'h020: rdata_d = {4'h0, cfg_q.height, 4'h0, cfg_q.width};
        12'h024: rdata_d = {26'h0, cfg_q.csc_en, cfg_q.gamma_en, cfg_q.ccm_en, cfg_q.wb_en,
                            cfg_q.dpc_en, cfg_q.blc_en};
        12'h028: rdata_d = {30'h0, cfg_q.bayer};
        12'h02C: rdata_d = 32'(cfg_q.blc);
        12'h030: rdata_d = 32'(cfg_q.dpc_th);
        12'h034: rdata_d = 32'(cfg_q.wb_gain[0]);
        12'h038: rdata_d = 32'(cfg_q.wb_gain[1]);
        12'h03C: rdata_d = 32'(cfg_q.wb_gain[2]);
        12'h040: rdata_d = 32'(cfg_q.wb_gain[3]);
        12'h044: rdata_d = {4'h0, cfg_q.st_x1, 4'h0, cfg_q.st_x0};
        12'h048: rdata_d = {4'h0, cfg_q.st_y1, 4'h0, cfg_q.st_y0};
        12'h04C: rdata_d = 32'(cfg_q.st_sat);
        12'h050: rdata_d = {27'h0, cfg_q.tpg_motion, 2'b0, cfg_q.tpg_pattern};
        12'h054: rdata_d = {cfg_q.tpg_vblank, cfg_q.tpg_hblank};
        12'h058: rdata_d = {2'b0, cfg_q.tpg_color[2], cfg_q.tpg_color[1], cfg_q.tpg_color[0]};
        12'h060, 12'h064, 12'h068, 12'h06C, 12'h070,
        12'h074, 12'h078, 12'h07C, 12'h080: rdata_d = sx_coef(cfg_q.ccm[(a - 12'h060) >> 2]);
        12'h084: rdata_d = {{21{cfg_q.ccm_off[0][10]}}, cfg_q.ccm_off[0]};
        12'h088: rdata_d = {{21{cfg_q.ccm_off[1][10]}}, cfg_q.ccm_off[1]};
        12'h08C: rdata_d = {{21{cfg_q.ccm_off[2][10]}}, cfg_q.ccm_off[2]};
        12'h0A0, 12'h0A4, 12'h0A8, 12'h0AC, 12'h0B0,
        12'h0B4, 12'h0B8, 12'h0BC, 12'h0C0: rdata_d = sx_coef(cfg_q.csc[(a - 12'h0A0) >> 2]);
        12'h0C4: rdata_d = {{23{cfg_q.csc_off[0][8]}}, cfg_q.csc_off[0]};
        12'h0C8: rdata_d = {{23{cfg_q.csc_off[1][8]}}, cfg_q.csc_off[1]};
        12'h0CC: rdata_d = {{23{cfg_q.csc_off[2][8]}}, cfg_q.csc_off[2]};
        12'h0E0: rdata_d = {13'h0, lut_mask_q, 6'h0, lut_addr_q};
        12'h0F4: rdata_d = {4'h0, cap_q.y0, 4'h0, cap_q.x0};
        12'h0F8: rdata_d = {4'h0, cap_q.height, 4'h0, cap_q.width};
        12'h0FC: rdata_d = {30'h0, cap_q.scale};
        12'h100: rdata_d = stats_q.sum_r;
        12'h104: rdata_d = stats_q.sum_g;
        12'h108: rdata_d = stats_q.sum_b;
        12'h10C: rdata_d = stats_q.cnt;
        12'h110: rdata_d = stats_q.sum_y;
        12'h114: rdata_d = stats_q.af;
        12'h118: rdata_d = stats_q.dpc;
        12'h11C: rdata_d = stats_q.frame;
        default: rdata_d = '0;
      endcase
    end
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
  assign unused_bus = ^{bus_req_i.addr[31:12], bus_req_i.addr[1:0], bus_req_i.be, wd[31:29]};

endmodule
