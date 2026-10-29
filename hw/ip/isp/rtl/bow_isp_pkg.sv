// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 ISP: shared types and helpers. The arithmetic of every stage is
// specified in docs/ip/isp.md and mirrored bit-exactly by tools/isp/isp_model.py.

package bow_isp_pkg;

  localparam int unsigned PixW   = 10;   // raw and linear RGB component width
  localparam int unsigned OutW   = 8;    // output component width
  localparam int unsigned CoordW = 12;   // x / y coordinates, frame size (max 4095)
  localparam int unsigned CoefW  = 12;   // matrix coefficients, s3.8
  localparam int unsigned GainW  = 12;   // white balance gains, u4.8
  localparam int unsigned NumHistBins = 64;

  // Colour of a Bayer pixel. Encoding {row parity, column parity} relative to
  // the red pixel of the pattern: 0 = R, 1 = Gr (G on a red row), 2 = Gb, 3 = B.
  typedef enum logic [1:0] {
    CfaR  = 2'd0,
    CfaGr = 2'd1,
    CfaGb = 2'd2,
    CfaB  = 2'd3
  } cfa_e;

  // BAYER register: colour of pixel (0,0). 0 = RGGB, 1 = GRBG, 2 = GBRG, 3 = BGGR.
  function automatic cfa_e cfa_color(logic [1:0] pattern, logic x_lsb, logic y_lsb);
    return cfa_e'({y_lsb ^ pattern[1], x_lsb ^ pattern[0]});
  endfunction

  // Configuration seen by the video domain. Software writes a staging copy;
  // it becomes active between two frames after a write to UPDATE.
  typedef struct packed {
    logic [CoordW-1:0]            width;
    logic [CoordW-1:0]            height;
    logic [1:0]                   bayer;
    logic                         blc_en;
    logic                         dpc_en;
    logic                         wb_en;
    logic                         ccm_en;
    logic                         gamma_en;
    logic                         csc_en;
    logic [PixW-1:0]              blc;
    logic [PixW-1:0]              dpc_th;
    logic [3:0][GainW-1:0]        wb_gain;   // indexed by cfa_e
    logic [CoordW-1:0]            st_x0;
    logic [CoordW-1:0]            st_x1;
    logic [CoordW-1:0]            st_y0;
    logic [CoordW-1:0]            st_y1;
    logic [PixW-1:0]              st_sat;
    logic [1:0]                   tpg_pattern;
    logic                         tpg_motion;
    logic [15:0]                  tpg_hblank;
    logic [15:0]                  tpg_vblank;
    logic [2:0][PixW-1:0]         tpg_color; // [0] R, [1] G, [2] B
    logic [8:0][CoefW-1:0]        ccm;       // row major, [3*i+j] = c_ij
    logic [2:0][10:0]             ccm_off;   // signed, output units
    logic [8:0][CoefW-1:0]        csc;
    logic [2:0][8:0]              csc_off;   // signed, output units
  } isp_cfg_t;

  // Capture configuration (not shadowed: write it before CAP_CTRL.START).
  typedef struct packed {
    logic [CoordW-1:0] x0;
    logic [CoordW-1:0] y0;
    logic [CoordW-1:0] width;    // output pixels
    logic [CoordW-1:0] height;
    logic [1:0]        scale;    // log2 of the box filter size (1, 2, 4, 8)
  } isp_cap_cfg_t;

  // Statistics of one frame (see docs/ip/isp.md, "Statistics").
  typedef struct packed {
    logic [31:0]                       sum_r;
    logic [31:0]                       sum_g;
    logic [31:0]                       sum_b;
    logic [31:0]                       cnt;
    logic [31:0]                       sum_y;
    logic [31:0]                       af;
    logic [31:0]                       dpc;
    logic [31:0]                       frame;
    logic [NumHistBins-1:0][21:0]      hist;
  } isp_stats_t;

endpackage
