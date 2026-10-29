// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bayer test pattern generator: produces RAW10 frames with the same AXI4-Stream
// video framing as a camera receiver (tuser = start of frame, tlast = end of
// line), so the ISP can be brought up without a sensor.
//
// Frame timing: width x height active pixels, hblank idle cycles after every
// line and vblank idle lines (of width + hblank cycles) after every frame.
// The configuration is loaded while disabled and at the end of every frame.
//
// Patterns (value of the colour channel selected by the Bayer phase):
//   0 colour bars: 8 vertical bars white, yellow, cyan, green, magenta, red,
//     blue, black of width/8 pixels (the last bar takes the remainder);
//     "on" = 0x3C0, "off" = 0
//   1 ramp: (x + y + offset) mod 1024 on every channel (grey ramp)
//   2 checker: 32 x 32 squares, 0x3C0 / 0x040, shifted right by offset
//   3 solid colour from tpg_color
// With motion = 1 the offset grows by 4 every frame (moving ramp / checker).

module bow_isp_tpg import bow_isp_pkg::*; (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            enable_i,
  input  isp_cfg_t        cfg_i,

  output logic            tvalid_o,
  input  logic            tready_i,
  output logic [PixW-1:0] tdata_o,
  output logic            tuser_o,   // start of frame
  output logic            tlast_o    // end of line
);

  localparam logic [PixW-1:0] LevelOn  = 10'h3C0;
  localparam logic [PixW-1:0] LevelLow = 10'h040;

  // Frame configuration, constant during a frame.
  logic [CoordW-1:0]    w_q, h_q, bar_w_q;
  logic [16:0]          line_last_q, frame_last_q;   // w + hblank - 1, h + vblank - 1
  logic [1:0]           pattern_q, bayer_q;
  logic                 motion_q;
  logic [2:0][PixW-1:0] color_q;

  logic [16:0]       x_q, y_q;       // position including blanking
  logic [PixW-1:0]   offset_q;
  logic [CoordW-1:0] bar_cnt_q;
  logic [2:0]        bar_q;

  logic adv, active, line_end, frame_end;

  assign adv       = !tvalid_o || tready_i;
  assign active    = (x_q < {5'b0, w_q}) && (y_q < {5'b0, h_q});
  assign line_end  = (x_q == line_last_q);
  assign frame_end = line_end && (y_q == frame_last_q);

  // Value of the pixel at (x_q, y_q).
  logic [2:0][PixW-1:0] rgb;
  logic [PixW-1:0]      value, xs;

  always_comb begin
    xs = x_q[PixW-1:0] + offset_q;
    unique case (pattern_q)
      2'd0: begin
        rgb[0] = bar_q[1] ? '0 : LevelOn;
        rgb[1] = bar_q[2] ? '0 : LevelOn;
        rgb[2] = bar_q[0] ? '0 : LevelOn;
      end
      2'd1:    rgb = {3{xs + y_q[PixW-1:0]}};
      2'd2:    rgb = {3{(xs[5] ^ y_q[5]) ? LevelOn : LevelLow}};
      default: rgb = color_q;
    endcase
    unique case (cfa_color(bayer_q, x_q[0], y_q[0]))
      CfaR:    value = rgb[0];
      CfaB:    value = rgb[2];
      default: value = rgb[1];
    endcase
  end

  // New frame configuration (minimum sizes keep the timing well formed).
  logic [CoordW-1:0] cfg_w, cfg_h;
  logic [15:0]       cfg_hb, cfg_vb;

  assign cfg_w  = (cfg_i.width  < CoordW'(16)) ? CoordW'(16) : cfg_i.width;
  assign cfg_h  = (cfg_i.height < CoordW'(2))  ? CoordW'(2)  : cfg_i.height;
  assign cfg_hb = (cfg_i.tpg_hblank < 16'd16) ? 16'd16 : cfg_i.tpg_hblank;
  assign cfg_vb = (cfg_i.tpg_vblank < 16'd1)  ? 16'd1  : cfg_i.tpg_vblank;

  logic load_cfg;
  assign load_cfg = !enable_i || (adv && frame_end);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_q          <= CoordW'(16);
      h_q          <= CoordW'(2);
      bar_w_q      <= CoordW'(2);
      line_last_q  <= 17'd31;
      frame_last_q <= 17'd2;
      pattern_q    <= '0;
      bayer_q      <= '0;
      motion_q     <= 1'b0;
      color_q      <= '0;
    end else if (load_cfg) begin
      w_q          <= cfg_w;
      h_q          <= cfg_h;
      bar_w_q      <= cfg_w >> 3;
      line_last_q  <= {5'b0, cfg_w} + {1'b0, cfg_hb} - 17'd1;
      frame_last_q <= {5'b0, cfg_h} + {1'b0, cfg_vb} - 17'd1;
      pattern_q    <= cfg_i.tpg_pattern;
      bayer_q      <= cfg_i.bayer;
      motion_q     <= cfg_i.tpg_motion;
      color_q      <= cfg_i.tpg_color;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      x_q       <= '0;
      y_q       <= '0;
      offset_q  <= '0;
      bar_cnt_q <= '0;
      bar_q     <= '0;
      tvalid_o  <= 1'b0;
      tdata_o   <= '0;
      tuser_o   <= 1'b0;
      tlast_o   <= 1'b0;
    end else if (!enable_i) begin
      x_q       <= '0;
      y_q       <= '0;
      offset_q  <= '0;
      bar_cnt_q <= '0;
      bar_q     <= '0;
      tvalid_o  <= 1'b0;
    end else if (adv) begin
      // Output register
      tvalid_o <= active;
      if (active) begin
        tdata_o <= value;
        tuser_o <= (x_q == '0) && (y_q == '0);
        tlast_o <= (x_q == {5'b0, w_q} - 17'd1);
      end

      // Position
      if (line_end) begin
        x_q       <= '0;
        bar_cnt_q <= '0;
        bar_q     <= '0;
        if (frame_end) begin
          y_q <= '0;
          if (motion_q) offset_q <= offset_q + PixW'(4);
        end else begin
          y_q <= y_q + 17'd1;
        end
      end else begin
        x_q <= x_q + 17'd1;
        if (bar_cnt_q == bar_w_q - CoordW'(1)) begin
          bar_cnt_q <= '0;
          if (bar_q != 3'd7) bar_q <= bar_q + 3'd1;
        end else begin
          bar_cnt_q <= bar_cnt_q + CoordW'(1);
        end
      end
    end
  end

  logic unused_cfg;
  assign unused_cfg = ^{cfg_i};   // only the TPG fields are used

endmodule
