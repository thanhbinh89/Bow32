// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// N x N neighbourhood generator for a raster pixel stream.
//
// For every input pixel (x, y) of a width x height frame it outputs the
// window of pixels (x-R .. x+R, y-R .. y+R), R = (N-1)/2, centred on (x, y).
//
//   * N-1 previous lines are kept in one block RAM (one word = one column).
//   * Borders are mirrored without repeating the edge pixel ("reflect 101":
//     p[-1] = p[1], p[-2] = p[2], p[W] = p[W-2]). This keeps the colour of
//     every neighbour correct on a Bayer mosaic.
//   * The window of pixel (x, y) needs input pixel (x+R, y+R). To produce the
//     last R columns of a line and the last R lines of a frame the generator
//     inserts "virtual" pixels itself: R cycles after each line and R extra
//     lines after each frame. in_ready_o is low during these cycles, so the
//     source needs some horizontal and vertical blanking (any camera has it).
//
// Latency from the last needed input pixel to the output: 3 cycles.
// Requirements: N odd, 3 <= N, width >= N, height >= N, width <= MaxWidth.

module bow_isp_window import bow_isp_pkg::*; #(
  parameter int unsigned N        = 3,
  parameter int unsigned DataW    = PixW,
  parameter int unsigned MaxWidth = 2048    // line buffer depth, power of two
) (
  input  logic                           clk_i,
  input  logic                           rst_ni,
  input  logic                           abort_i,

  input  logic [CoordW-1:0]              width_i,   // sampled while idle
  input  logic [CoordW-1:0]              height_i,

  input  logic                           in_valid_i,
  output logic                           in_ready_o,
  input  logic [DataW-1:0]               in_data_i,
  input  logic                           in_sof_i,

  output logic                           busy_o,

  output logic                           out_valid_o,
  output logic [N-1:0][N-1:0][DataW-1:0] out_win_o,  // [row][column], [0][0] = (x-R, y-R)
  output logic [CoordW-1:0]              out_x_o,
  output logic [CoordW-1:0]              out_y_o,
  output logic                           out_sof_o,
  output logic                           out_eol_o,
  output logic                           out_eof_o
);

  localparam int unsigned R    = (N - 1) / 2;
  localparam int unsigned AW   = $clog2(MaxWidth);
  localparam int unsigned SelW = $clog2(N);
  localparam int unsigned IW   = CoordW + 1;   // input side coordinates go up to size-1+R

  typedef logic [N-1:0][SelW-1:0] sel_t;

  // --------------------------------------------------------------------------
  // Event sequencer: real pixels from the input, virtual pixels at the borders
  // --------------------------------------------------------------------------
  logic              run_q;
  logic [CoordW-1:0] w_q, h_q;
  logic [IW-1:0]     ix_q, iy_q;
  logic              want_real;

  assign want_real  = (ix_q < IW'(w_q)) && (iy_q < IW'(h_q));
  assign in_ready_o = !run_q || want_real;

  logic          ev, ev_real;
  logic [IW-1:0] ev_ix, ev_iy;
  logic [CoordW-1:0] w_eff, h_eff;   // frame size seen by the current event

  assign w_eff = run_q ? w_q : width_i;
  assign h_eff = run_q ? h_q : height_i;

  always_comb begin
    if (!run_q) begin
      ev      = in_valid_i && in_sof_i;
      ev_real = 1'b1;
      ev_ix   = '0;
      ev_iy   = '0;
    end else begin
      ev      = want_real ? in_valid_i : 1'b1;
      ev_real = want_real;
      ev_ix   = ix_q;
      ev_iy   = iy_q;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      run_q <= 1'b0;
      w_q   <= CoordW'(N);
      h_q   <= CoordW'(N);
      ix_q  <= '0;
      iy_q  <= '0;
    end else if (abort_i) begin
      run_q <= 1'b0;
    end else if (!run_q) begin
      w_q <= width_i;
      h_q <= height_i;
      if (ev) begin
        run_q <= 1'b1;
        ix_q  <= IW'(1);
        iy_q  <= '0;
      end
    end else if (ev) begin
      if (ix_q == IW'(w_q) + IW'(R - 1)) begin
        ix_q <= '0;
        if (iy_q == IW'(h_q) + IW'(R - 1)) begin
          run_q <= 1'b0;
        end else begin
          iy_q <= iy_q + IW'(1);
        end
      end else begin
        ix_q <= ix_q + IW'(1);
      end
    end
  end

  // Mirror selection: element k of a column (row y-k) or of the window
  // (column x-k) is replaced by element sel[k] at the borders.
  function automatic sel_t mirror_sel(logic [IW-1:0] pos, logic [CoordW-1:0] size);
    logic signed [IW:0] dist_end;   // pos - (size-1), > 0 beyond the end
    sel_t               sel;
    dist_end = $signed({1'b0, pos}) - $signed({2'b0, size}) + $signed((IW + 1)'(1));
    for (int unsigned k = 0; k < N; k++) begin
      if (pos < IW'(k)) begin
        sel[k] = SelW'(2 * int'(pos[SelW:0]) - int'(k));
      end else if (dist_end > $signed((IW + 1)'(k))) begin
        sel[k] = SelW'(2 * int'(dist_end[SelW:0]) - int'(k));
      end else begin
        sel[k] = SelW'(k);
      end
    end
    return sel;
  endfunction

  // --------------------------------------------------------------------------
  // S0: issue the line buffer read
  // --------------------------------------------------------------------------
  logic              s0_valid, s0_inside;
  logic [IW-1:0]     s0_ix, s0_iy;
  logic [DataW-1:0]  s0_data;
  sel_t              s0_vsel, s0_hsel;
  logic [(N-1)*DataW-1:0] lb_rdata, lb_wdata;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s0_valid  <= 1'b0;
      s0_inside <= 1'b0;
      s0_ix     <= '0;
      s0_iy     <= '0;
      s0_data   <= '0;
      s0_vsel   <= '0;
      s0_hsel   <= '0;
    end else begin
      s0_valid <= ev && !abort_i;
      if (ev) begin
        s0_inside <= ev_ix < IW'(w_eff);
        s0_ix     <= ev_ix;
        s0_iy     <= ev_iy;
        s0_data   <= ev_real ? in_data_i : '0;
        s0_vsel   <= mirror_sel(ev_iy, h_eff);
        s0_hsel   <= mirror_sel(ev_ix, w_eff);
      end
    end
  end

  bow_ram_sdp #(
    .Width ((N - 1) * DataW),
    .Depth (MaxWidth)
  ) u_linebuf (
    .wclk_i  (clk_i),
    .we_i    (s0_valid && s0_inside),
    .waddr_i (s0_ix[AW-1:0]),
    .wdata_i (lb_wdata),
    .rclk_i  (clk_i),
    .re_i    (ev && (ev_ix < IW'(w_eff))),
    .raddr_i (ev_ix[AW-1:0]),
    .rdata_o (lb_rdata)
  );

  // --------------------------------------------------------------------------
  // S1: build the column (rows y .. y-N+1), mirror vertically, update the RAM
  // --------------------------------------------------------------------------
  logic [N-1:0][DataW-1:0] col, vcol;

  always_comb begin
    col[0] = s0_data;
    for (int unsigned k = 1; k < N; k++) begin
      col[k] = lb_rdata[(k - 1) * DataW +: DataW];
    end
    for (int unsigned k = 0; k < N; k++) begin
      vcol[k] = col[s0_vsel[k]];
    end
    for (int unsigned k = 0; k + 1 < N; k++) begin
      lb_wdata[k * DataW +: DataW] = col[k];
    end
  end

  logic                    s1_valid;
  logic [IW-1:0]           s1_ix, s1_iy;
  sel_t                    s1_hsel;
  logic [N-1:0][DataW-1:0] s1_vcol;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid <= 1'b0;
      s1_ix    <= '0;
      s1_iy    <= '0;
      s1_hsel  <= '0;
      s1_vcol  <= '0;
    end else begin
      s1_valid <= s0_valid && !abort_i;
      if (s0_valid) begin
        s1_ix   <= s0_ix;
        s1_iy   <= s0_iy;
        s1_hsel <= s0_hsel;
        s1_vcol <= vcol;
      end
    end
  end

  // --------------------------------------------------------------------------
  // S2: horizontal shift register, win[c] = column x-c
  // --------------------------------------------------------------------------
  logic [N-1:0][N-1:0][DataW-1:0] win;   // [column][row]
  logic                           s2_valid;
  logic [IW-1:0]                  s2_ix, s2_iy;
  sel_t                           s2_hsel;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      win      <= '0;
      s2_valid <= 1'b0;
      s2_ix    <= '0;
      s2_iy    <= '0;
      s2_hsel  <= '0;
    end else begin
      s2_valid <= s1_valid && !abort_i;
      if (s1_valid) begin
        win[0] <= s1_vcol;
        for (int unsigned c = 1; c < N; c++) begin
          win[c] <= win[c - 1];
        end
        s2_ix   <= s1_ix;
        s2_iy   <= s1_iy;
        s2_hsel <= s1_hsel;
      end
    end
  end

  // --------------------------------------------------------------------------
  // S3: mirror horizontally, output
  // --------------------------------------------------------------------------
  logic [CoordW-1:0] ox, oy;
  assign ox = CoordW'(s2_ix - IW'(R));
  assign oy = CoordW'(s2_iy - IW'(R));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      out_win_o   <= '0;
      out_x_o     <= '0;
      out_y_o     <= '0;
      out_sof_o   <= 1'b0;
      out_eol_o   <= 1'b0;
      out_eof_o   <= 1'b0;
    end else begin
      out_valid_o <= s2_valid && !abort_i && (s2_ix >= IW'(R)) && (s2_iy >= IW'(R));
      if (s2_valid) begin
        for (int unsigned r = 0; r < N; r++) begin
          for (int unsigned j = 0; j < N; j++) begin
            out_win_o[r][j] <= win[s2_hsel[2 * R - j]][2 * R - r];
          end
        end
        out_x_o   <= ox;
        out_y_o   <= oy;
        out_sof_o <= (ox == '0) && (oy == '0);
        out_eol_o <= (ox == w_q - CoordW'(1));
        out_eof_o <= (ox == w_q - CoordW'(1)) && (oy == h_q - CoordW'(1));
      end
    end
  end

  assign busy_o = run_q || s0_valid || s1_valid || s2_valid || out_valid_o;

endmodule
