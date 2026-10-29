// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Frame capture into the ISP buffer (read by the CPU through the bus).
//
// After start_i the next complete output frame is captured: the region of
// (width << scale) x (height << scale) pixels at (x0, y0) is reduced by a
// D x D box filter, D = 1 << scale, and written as one 24 bit word
// {c0, c1, c2} per output pixel (R G B, or Y Cb Cr) at address
// by * width + bx. With scale = 0 this is a plain crop at full resolution.
//
//   out(bx, by) = (sum of the D x D block + D*D/2) >> (2 * scale)
//
// Horizontal sums are kept in registers, vertical sums in a column RAM.
// Words beyond the buffer are dropped (ovf_o). done_o pulses after the last
// write of the frame; an abort keeps the capture armed for the next frame.

module bow_isp_capture import bow_isp_pkg::*; #(
  parameter int unsigned BufWords = 32768,
  parameter int unsigned MaxColumns = 1024   // max width for scale >= 1
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic                          abort_i,
  input  logic                          start_i,
  input  isp_cap_cfg_t                  cfg_i,
  output logic                          busy_o,
  output logic                          done_o,
  output logic                          ovf_o,

  input  logic                          valid_i,
  input  logic [2:0][OutW-1:0]          comp_i,    // [0] = c0 (R or Y)
  input  logic [CoordW-1:0]             x_i,
  input  logic [CoordW-1:0]             y_i,
  input  logic                          sof_i,
  input  logic                          eof_i,

  output logic                          we_o,
  output logic [$clog2(BufWords)-1:0]   waddr_o,
  output logic [3*OutW-1:0]             wdata_o
);

  localparam int unsigned BufAW = $clog2(BufWords);
  localparam int unsigned ColAW = $clog2(MaxColumns);
  localparam int unsigned HW    = OutW + 3;    // horizontal sum of up to 8 pixels
  localparam int unsigned VW    = OutW + 6;    // block sum of up to 64 pixels
  localparam int unsigned RegW  = CoordW + 3;  // region size (width << scale)

  logic armed_q, active_q;
  assign busy_o = armed_q || active_q;

  // ------------------------------------------------------------------- C0
  logic                  take;
  logic signed [CoordW:0] rx, ry;
  logic [RegW-1:0]       rw, rh;

  assign take = valid_i && (active_q || (armed_q && sof_i));
  assign rx   = $signed({1'b0, x_i}) - $signed({1'b0, cfg_i.x0});
  assign ry   = $signed({1'b0, y_i}) - $signed({1'b0, cfg_i.y0});
  assign rw   = RegW'(cfg_i.width) << cfg_i.scale;
  assign rh   = RegW'(cfg_i.height) << cfg_i.scale;

  logic                  c0_v, c0_eof;
  logic [CoordW-1:0]     c0_rx, c0_ry;
  logic [2:0][OutW-1:0]  c0_comp;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      armed_q  <= 1'b0;
      active_q <= 1'b0;
      c0_v     <= 1'b0;
      c0_eof   <= 1'b0;
      c0_rx    <= '0;
      c0_ry    <= '0;
      c0_comp  <= '0;
    end else begin
      c0_v   <= 1'b0;
      c0_eof <= 1'b0;
      if (abort_i) begin
        if (active_q) armed_q <= 1'b1;
        active_q <= 1'b0;
      end else begin
        if (start_i) armed_q <= 1'b1;
        if (take) begin
          if (sof_i) begin
            armed_q  <= 1'b0;
            active_q <= 1'b1;
          end
          if (eof_i) begin
            active_q <= 1'b0;
            c0_eof   <= 1'b1;
          end
          c0_v <= !rx[CoordW] && !ry[CoordW] &&
                  (RegW'(rx[CoordW-1:0]) < rw) && (RegW'(ry[CoordW-1:0]) < rh);
        end
      end
      c0_rx   <= rx[CoordW-1:0];
      c0_ry   <= ry[CoordW-1:0];
      c0_comp <= comp_i;
    end
  end

  // ------------------------------------------------------------------- C1
  logic                 c1_v, c1_eof;
  logic [CoordW-1:0]    c1_bx, c1_by;
  logic [2:0]           c1_dx, c1_dy;
  logic [2:0][OutW-1:0] c1_comp;
  logic [2:0]           dmask;

  assign dmask = 3'((4'd1 << cfg_i.scale) - 4'd1);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      c1_v    <= 1'b0;
      c1_eof  <= 1'b0;
      c1_bx   <= '0;
      c1_by   <= '0;
      c1_dx   <= '0;
      c1_dy   <= '0;
      c1_comp <= '0;
    end else begin
      c1_v    <= c0_v && !abort_i;
      c1_eof  <= c0_eof && !abort_i;
      c1_bx   <= c0_rx >> cfg_i.scale;
      c1_by   <= c0_ry >> cfg_i.scale;
      c1_dx   <= c0_rx[2:0] & dmask;
      c1_dy   <= c0_ry[2:0] & dmask;
      c1_comp <= c0_comp;
    end
  end

  // ------------------------------------------- C2: horizontal accumulation
  // Column accumulator RAM: read at the first pixel of a block row, written
  // back (or emitted) at its last pixel.
  logic [3*VW-1:0] col_rdata, col_wdata;
  logic            col_we;
  logic [ColAW-1:0] col_waddr;
  logic            rd_pend_q;
  logic [3*VW-1:0] vacc_q, vacc_cur;

  bow_ram_sdp #(
    .Width (3 * VW),
    .Depth (MaxColumns)
  ) u_colacc (
    .wclk_i  (clk_i),
    .we_i    (col_we),
    .waddr_i (col_waddr),
    .wdata_i (col_wdata),
    .rclk_i  (clk_i),
    .re_i    (c1_v && (c1_dx == '0)),
    .raddr_i (c1_bx[ColAW-1:0]),
    .rdata_o (col_rdata)
  );

  assign vacc_cur = rd_pend_q ? col_rdata : vacc_q;

  logic [2:0][HW-1:0] hsum_q, hsum_tot;
  logic               seg_done;

  always_comb begin
    for (int unsigned c = 0; c < 3; c++) begin
      hsum_tot[c] = (c1_dx == '0) ? HW'(c1_comp[c]) : hsum_q[c] + HW'(c1_comp[c]);
    end
  end
  assign seg_done = c1_v && (c1_dx == dmask);

  logic                 s_v, s_eof;
  logic [2:0][HW-1:0]   s_sum;
  logic [3*VW-1:0]      s_vacc;
  logic [CoordW-1:0]    s_bx, s_by;
  logic [2:0]           s_dy;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_pend_q <= 1'b0;
      vacc_q    <= '0;
      hsum_q    <= '0;
      s_v       <= 1'b0;
      s_eof     <= 1'b0;
      s_sum     <= '0;
      s_vacc    <= '0;
      s_bx      <= '0;
      s_by      <= '0;
      s_dy      <= '0;
    end else begin
      rd_pend_q <= c1_v && (c1_dx == '0);
      if (rd_pend_q) vacc_q <= col_rdata;
      if (c1_v) hsum_q <= hsum_tot;
      s_v   <= seg_done && !abort_i;
      s_eof <= c1_eof && !abort_i;
      if (seg_done) begin
        s_sum  <= hsum_tot;
        s_vacc <= vacc_cur;
        s_bx   <= c1_bx;
        s_by   <= c1_by;
        s_dy   <= c1_dy;
      end
    end
  end

  // --------------------------------------------- C3: vertical accumulation
  logic [2:0][VW-1:0] vsum;
  logic [2:0][OutW-1:0] pix;
  logic [VW-1:0]      round;
  logic               last_row;

  assign round    = (cfg_i.scale == '0) ? '0 : VW'(1) << (2 * cfg_i.scale - 1);
  assign last_row = (s_dy == dmask);

  always_comb begin
    for (int unsigned c = 0; c < 3; c++) begin
      vsum[c] = (s_dy == '0) ? VW'(s_sum[c]) : s_vacc[c * VW +: VW] + VW'(s_sum[c]);
      pix[c]  = OutW'((vsum[c] + round) >> (2 * cfg_i.scale));
    end
    for (int unsigned c = 0; c < 3; c++) begin
      col_wdata[c * VW +: VW] = vsum[c];
    end
  end

  assign col_we    = s_v && !last_row;
  assign col_waddr = s_bx[ColAW-1:0];

  // Output address: row base advances by width whenever by moves on.
  logic [BufAW:0] row_base_q, row_base, addr;
  logic [CoordW-1:0] cur_by_q;

  assign row_base = (s_by != cur_by_q) ? row_base_q + (BufAW + 1)'(cfg_i.width) : row_base_q;
  assign addr     = row_base + (BufAW + 1)'(s_bx);

  logic [1:0] done_sr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      row_base_q <= '0;
      cur_by_q   <= '0;
      we_o       <= 1'b0;
      waddr_o    <= '0;
      wdata_o    <= '0;
      ovf_o      <= 1'b0;
      done_sr_q  <= '0;
      done_o     <= 1'b0;
    end else begin
      we_o  <= 1'b0;
      ovf_o <= 1'b0;
      if (start_i || abort_i) begin
        row_base_q <= '0;
        cur_by_q   <= '0;
      end else if (s_v && last_row) begin
        row_base_q <= row_base;
        cur_by_q   <= s_by;
        if (addr < (BufAW + 1)'(BufWords)) begin
          we_o    <= 1'b1;
          waddr_o <= addr[BufAW-1:0];
          wdata_o <= {pix[0], pix[1], pix[2]};
        end else begin
          ovf_o <= 1'b1;
        end
      end
      done_sr_q <= abort_i ? '0 : {done_sr_q[0], s_eof};
      done_o    <= done_sr_q[1];
      if (done_sr_q[1]) begin
        row_base_q <= '0;
        cur_by_q   <= '0;
      end
    end
  end

endmodule
