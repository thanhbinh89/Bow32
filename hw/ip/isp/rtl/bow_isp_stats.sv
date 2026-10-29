// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Frame statistics for auto exposure / white balance / focus (the "3A"
// algorithms run in firmware). Measured on the linear RGB after demosaic,
// inside the window x0 <= x <= x1, y0 <= y <= y1:
//
//   Y      = (77 R + 150 G + 29 B + 128) >> 8           (10 bit luma)
//   sum_y  = sum Y,  hist[Y >> 4] += 1                   (64 bins, AE)
//   sum_r/g/b, cnt over pixels with R, G and B < sat     (grey world AWB)
//   af     = sum |G(x,y) - G(x-1,y)| for x0 < x <= x1    (sharpness, AF)
//   dpc    = number of pixels corrected by the DPC in the whole frame
//
// At the end of every frame the results are copied into stats_o, the
// accumulators restart and snap_o pulses (frame = running frame number).

module bow_isp_stats import bow_isp_pkg::*; (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic                 abort_i,
  input  logic [CoordW-1:0]    x0_i,
  input  logic [CoordW-1:0]    x1_i,
  input  logic [CoordW-1:0]    y0_i,
  input  logic [CoordW-1:0]    y1_i,
  input  logic [PixW-1:0]      sat_i,

  input  logic                 valid_i,
  input  logic [2:0][PixW-1:0] rgb_i,
  input  logic [CoordW-1:0]    x_i,
  input  logic [CoordW-1:0]    y_i,
  input  logic                 eof_i,

  input  logic                 dpc_valid_i,
  input  logic                 dpc_hit_i,
  input  logic                 dpc_eof_i,

  output isp_stats_t           stats_o,
  output logic                 snap_o
);

  // ---------------------------------------------------------------- stage 1
  logic                 v1_q, eof1_q, in1_q, ok1_q, edge1_q;
  logic [2:0][PixW-1:0] rgb1_q;
  logic [17:0]          yr1_q, yg1_q, yb1_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      v1_q    <= 1'b0;
      eof1_q  <= 1'b0;
      in1_q   <= 1'b0;
      ok1_q   <= 1'b0;
      edge1_q <= 1'b0;
      rgb1_q  <= '0;
      yr1_q   <= '0;
      yg1_q   <= '0;
      yb1_q   <= '0;
    end else begin
      v1_q    <= valid_i && !abort_i;
      eof1_q  <= valid_i && eof_i;
      in1_q   <= (x_i >= x0_i) && (x_i <= x1_i) && (y_i >= y0_i) && (y_i <= y1_i);
      edge1_q <= (x_i > x0_i);
      ok1_q   <= (rgb_i[0] < sat_i) && (rgb_i[1] < sat_i) && (rgb_i[2] < sat_i);
      rgb1_q  <= rgb_i;
      yr1_q   <= 18'(rgb_i[0]) * 18'd77;
      yg1_q   <= 18'(rgb_i[1]) * 18'd150;
      yb1_q   <= 18'(rgb_i[2]) * 18'd29;
    end
  end

  // ---------------------------------------------------------------- stage 2
  logic                 v2_q, eof2_q, in2_q, ok2_q, af2_q;
  logic [2:0][PixW-1:0] rgb2_q;
  logic [PixW-1:0]      y2_q, gdiff2_q, gprev_q;
  logic [17:0]          ysum;

  assign ysum = yr1_q + yg1_q + yb1_q + 18'd128;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      v2_q     <= 1'b0;
      eof2_q   <= 1'b0;
      in2_q    <= 1'b0;
      ok2_q    <= 1'b0;
      af2_q    <= 1'b0;
      rgb2_q   <= '0;
      y2_q     <= '0;
      gdiff2_q <= '0;
      gprev_q  <= '0;
    end else begin
      v2_q   <= v1_q && !abort_i;
      eof2_q <= eof1_q;
      in2_q  <= in1_q;
      ok2_q  <= ok1_q;
      af2_q  <= in1_q && edge1_q;
      rgb2_q <= rgb1_q;
      y2_q   <= PixW'(ysum >> 8);
      if (v1_q) begin
        gprev_q  <= rgb1_q[1];
        gdiff2_q <= (rgb1_q[1] > gprev_q) ? rgb1_q[1] - gprev_q : gprev_q - rgb1_q[1];
      end
    end
  end

  // ---------------------------------------------------------------- stage 3
  isp_stats_t acc_q;
  logic       snap_pend_q;
  logic [31:0] frame_q, dpc_cnt_q, dpc_last_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      acc_q       <= '0;
      snap_pend_q <= 1'b0;
      frame_q     <= '0;
      stats_o     <= '0;
      snap_o      <= 1'b0;
    end else begin
      snap_o      <= 1'b0;
      snap_pend_q <= 1'b0;
      if (abort_i) begin
        acc_q <= '0;
      end else if (snap_pend_q) begin
        // one cycle after the last pixel of the frame
        stats_o       <= acc_q;
        stats_o.dpc   <= dpc_last_q;
        stats_o.frame <= frame_q;
        frame_q       <= frame_q + 32'd1;
        snap_o        <= 1'b1;
        acc_q         <= '0;
      end else if (v2_q) begin
        if (in2_q) begin
          acc_q.sum_y                <= acc_q.sum_y + 32'(y2_q);
          // one incrementer per bin: no 64:1 read multiplexer in the path
          for (int unsigned b = 0; b < NumHistBins; b++) begin
            if (y2_q[PixW-1:4] == 6'(b)) acc_q.hist[b] <= acc_q.hist[b] + 22'd1;
          end
          if (ok2_q) begin
            acc_q.sum_r <= acc_q.sum_r + 32'(rgb2_q[0]);
            acc_q.sum_g <= acc_q.sum_g + 32'(rgb2_q[1]);
            acc_q.sum_b <= acc_q.sum_b + 32'(rgb2_q[2]);
            acc_q.cnt   <= acc_q.cnt + 32'd1;
          end
          if (af2_q) acc_q.af <= acc_q.af + 32'(gdiff2_q);
        end
        snap_pend_q <= eof2_q;
      end
    end
  end

  // DPC hit counter, frames delimited by the DPC output.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dpc_cnt_q  <= '0;
      dpc_last_q <= '0;
    end else if (abort_i) begin
      dpc_cnt_q <= '0;
    end else if (dpc_valid_i) begin
      if (dpc_eof_i) begin
        dpc_last_q <= dpc_cnt_q + 32'(dpc_hit_i);
        dpc_cnt_q  <= '0;
      end else begin
        dpc_cnt_q <= dpc_cnt_q + 32'(dpc_hit_i);
      end
    end
  end

endmodule
