// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Defective pixel correction on the Bayer mosaic (5 x 5 window).
//
// The 8 nearest pixels of the same colour are at (+-2, 0), (0, +-2) and
// (+-2, +-2). A pixel brighter than all of them by more than th is replaced
// by their maximum, one darker than all of them by more than th by their
// minimum ("hot" / "dead" pixels). Everything else passes unchanged.
//
//   c' = c > max + th ? max : (c + th < min ? min : c)
//
// hit_o pulses for every corrected pixel. Latency: 4 cycles.

module bow_isp_dpc import bow_isp_pkg::*; (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic                         abort_i,
  input  logic                         enable_i,
  input  logic [PixW-1:0]              th_i,

  input  logic                         valid_i,
  input  logic [4:0][4:0][PixW-1:0]    win_i,     // [row][column]
  input  logic [CoordW-1:0]            x_i,
  input  logic [CoordW-1:0]            y_i,
  input  logic                         sof_i,
  input  logic                         eof_i,

  output logic                         valid_o,
  output logic [PixW-1:0]              data_o,
  output logic [CoordW-1:0]            x_o,
  output logic [CoordW-1:0]            y_o,
  output logic                         sof_o,
  output logic                         eof_o,
  output logic                         hit_o
);

  localparam int unsigned Lat = 4;

  // Side band: valid, coordinates and flags travel along the pipeline.
  logic [Lat-1:0]              v_q;
  logic [Lat-1:0][CoordW-1:0]  x_q, y_q;
  logic [Lat-1:0]              sof_q, eof_q;
  logic [Lat-2:0][PixW-1:0]    c_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      v_q   <= '0;
      x_q   <= '0;
      y_q   <= '0;
      sof_q <= '0;
      eof_q <= '0;
      c_q   <= '0;
    end else begin
      v_q   <= abort_i ? '0 : {v_q[Lat-2:0], valid_i};
      x_q   <= {x_q[Lat-2:0], x_i};
      y_q   <= {y_q[Lat-2:0], y_i};
      sof_q <= {sof_q[Lat-2:0], sof_i};
      eof_q <= {eof_q[Lat-2:0], eof_i};
      c_q   <= {c_q[Lat-3:0], win_i[2][2]};
    end
  end

  // Stage 1..3: min / max tree over the 8 same colour neighbours.
  logic [7:0][PixW-1:0] n;
  assign n = {win_i[0][0], win_i[0][2], win_i[0][4], win_i[2][0],
              win_i[2][4], win_i[4][0], win_i[4][2], win_i[4][4]};

  function automatic logic [PixW-1:0] min2(logic [PixW-1:0] a, logic [PixW-1:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [PixW-1:0] max2(logic [PixW-1:0] a, logic [PixW-1:0] b);
    return (a > b) ? a : b;
  endfunction

  logic [3:0][PixW-1:0] mn1_q, mx1_q;
  logic [1:0][PixW-1:0] mn2_q, mx2_q;
  logic [PixW-1:0]      mn3_q, mx3_q;

  always_ff @(posedge clk_i) begin
    for (int unsigned i = 0; i < 4; i++) begin
      mn1_q[i] <= min2(n[2 * i], n[2 * i + 1]);
      mx1_q[i] <= max2(n[2 * i], n[2 * i + 1]);
    end
    for (int unsigned i = 0; i < 2; i++) begin
      mn2_q[i] <= min2(mn1_q[2 * i], mn1_q[2 * i + 1]);
      mx2_q[i] <= max2(mx1_q[2 * i], mx1_q[2 * i + 1]);
    end
    mn3_q <= min2(mn2_q[0], mn2_q[1]);
    mx3_q <= max2(mx2_q[0], mx2_q[1]);
  end

  // Stage 4: decision (c_q[2] is the centre aligned with mn3_q / mx3_q).
  logic [PixW-1:0] c;
  logic            hot, dead;
  assign c    = c_q[Lat-2];
  assign hot  = {1'b0, c} > {1'b0, mx3_q} + {1'b0, th_i};
  assign dead = {1'b0, c} + {1'b0, th_i} < {1'b0, mn3_q};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      data_o <= '0;
      hit_o  <= 1'b0;
    end else begin
      hit_o  <= 1'b0;
      data_o <= c;
      if (enable_i && hot) begin
        data_o <= mx3_q;
        hit_o  <= v_q[Lat-2] && !abort_i;
      end else if (enable_i && dead) begin
        data_o <= mn3_q;
        hit_o  <= v_q[Lat-2] && !abort_i;
      end
    end
  end

  assign valid_o = v_q[Lat-1];
  assign x_o     = x_q[Lat-1];
  assign y_o     = y_q[Lat-1];
  assign sof_o   = sof_q[Lat-1];
  assign eof_o   = eof_q[Lat-1];

  logic unused_win;
  assign unused_win = ^{win_i};   // only the same colour positions are used

endmodule
