// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI CSI-2 receiver: shared constants, types and the helpers of the
// CSI-2 protocol layer (header ECC and packet footer CRC of CSI-2 v1.x).

package bow_csi2rx_pkg;

  localparam logic [31:0] Csi2rxId = 32'h4353_3201;   // "CS2", version 1

  // Largest Lanes parameter (data lanes: 1, 2 or 4)
  localparam int unsigned MaxLanes = 4;

  // Data types (DI[5:0]). 0x00..0x0F are short packets.
  localparam logic [5:0] DtFs    = 6'h00;
  localparam logic [5:0] DtFe    = 6'h01;
  localparam logic [5:0] DtRaw8  = 6'h2A;
  localparam logic [5:0] DtRaw10 = 6'h2B;

  // Header ECC result (LOG entry [25:24])
  localparam logic [1:0] EccOk   = 2'd0;
  localparam logic [1:0] EccCorr = 2'd1;   // one bit error corrected
  localparam logic [1:0] EccErr  = 2'd2;   // uncorrectable

  // Pixel FIFO entry: up to 4 pixels, px0 in [9:0]
  localparam int unsigned GroupW = 45;     // {err, sof, eol, cnt-1 [1:0], px3..px0}

  // CTRL fields (CPU domain; synchronised per bit where they are used). The PHY fields
  // (CLK_FORCE, PHY_CFG) are registers of the D-PHY since step 4 of
  // docs/ip/mipi_rx_arch.md: CTRL.CLK_CONT and TIM0 of bow_dphy_rx_regs.
  typedef struct packed {
    logic       phy_en;
    logic       rx_en;
    logic       lanes2;       // 2 data lanes in use (CTRL.LANES)
    logic       lanes4;       // 4 data lanes in use (CTRL.LANES4, wins over lanes2)
    logic       vc_any;
    logic [1:0] vc;
    logic [5:0] dt;
    logic [7:0] extra;        // bytes after a packet in its burst before ERR EXTRA, 0 = off
  } csi2_cfg_t;

  // Events of the packet layer: one cycle pulses of the controller's clock csi_clk,
  // each at most once per packet (= once per HS burst)
  typedef struct packed {
    logic pkt;        // header ok or corrected
    logic ecc_corr;
    logic ecc_err;
    logic crc_err;
    logic trunc;      // packet cut by the end of the burst
    logic drop;       // long packet not accepted by the VC/DT filter
    logic line;       // accepted pixel packet complete
    logic fs;         // FS of the selected VC
    logic fe;         // FE of the selected VC that completes a frame
    logic frame_err;  // FS inside a frame, FE without FS
    logic fmt;        // accepted line with WC = 0, or RAW10 with WC % 5 != 0
    logic ovf;        // pixel FIFO full during an accepted packet
    logic extra;      // more than CTRL.EXTRA bytes after a packet in its burst
  } csi2_pkt_ev_t;

  // All events as seen by the register file (synchronised to clk_i). Lane fields: [l] data
  // lane l; the bits of lanes above the Lanes parameter are 0. The HS entries and the LP
  // errors per lane are counted by the D-PHY since step 4 (CNT_BURSTn, CNT_CLK, CNT_LPERR);
  // the controller keeps one flag for ERR_STATUS.LP.
  typedef struct packed {
    csi2_pkt_ev_t        pl;
    logic                skew;    // lanes did not lock together
    logic [MaxLanes-1:0] sot;     // sync byte not found, per data lane
    logic                lp;      // ErrControl / ErrControlClk of the PPI (masked by the D-PHY)
    logic                deskew;  // deskew (skew calibration) burst on data lane 0
    logic                skip;    // the rest of a frame is skipped (bow_csi2_unpack)
  } csi2_ev_t;

  // Header ECC (CSI-2 v1.x): data bits D0..D23 = DI[7:0], WC[15:0];
  // EccCol[d] has bit i set when parity bit P_i covers D_d.
  localparam logic [23:0][5:0] EccCol = {
    6'h3B, 6'h37, 6'h2F, 6'h1F, 6'h38, 6'h34, 6'h32, 6'h31,   // D23 .. D16
    6'h2C, 6'h2A, 6'h29, 6'h26, 6'h25, 6'h23, 6'h1C, 6'h1A,   // D15 .. D8
    6'h19, 6'h16, 6'h15, 6'h13, 6'h0E, 6'h0D, 6'h0B, 6'h07    // D7  .. D0
  };

  function automatic logic [5:0] ecc_parity(logic [23:0] d);
    logic [5:0] p;
    p = '0;
    for (int unsigned i = 0; i < 24; i++) begin
      if (d[i]) p ^= EccCol[i];
    end
    return p;
  endfunction

  // Packet footer CRC-16: x^16 + x^12 + x^5 + 1, bits LSB first (reflected,
  // 0x8408), initial value 0xFFFF, no final XOR (CRC-16/MCRF4XX). Running it
  // over the payload and then over the two received CRC bytes (LS byte
  // first) leaves 0 exactly when the CRC matches.
  function automatic logic [15:0] crc16_byte(logic [15:0] crc, logic [7:0] b);
    logic [15:0] c;
    c = crc ^ {8'h00, b};
    for (int unsigned i = 0; i < 8; i++) begin
      c = c[0] ? ((c >> 1) ^ 16'h8408) : (c >> 1);
    end
    return c;
  endfunction

  // Data lanes in use (1, 2 or 4) for the CTRL fields LANES (lanes2) and
  // LANES4 (lanes4), never more than the Lanes parameter (`lanes`)
  function automatic logic [2:0] active_lanes(int unsigned lanes, logic lanes2, logic lanes4);
    if ((lanes == 4) && lanes4)                  return 3'd4;
    else if ((lanes >= 2) && (lanes2 || lanes4)) return 3'd2;
    else                                         return 3'd1;
  endfunction

  // v % 5 == 0 for a 16 bit word count (16 = 1 mod 5: sum of the nibbles)
  function automatic logic mod5_zero(logic [15:0] v);
    logic [5:0] s;
    s = 6'(v[3:0]) + 6'(v[7:4]) + 6'(v[11:8]) + 6'(v[15:12]);
    return (s % 6'd5) == 6'd0;
  endfunction

  // Gray code helpers of the clock domain crossings
  function automatic logic [3:0] gray_inc4(logic [3:0] g);
    logic [3:0] b;
    b[3] = g[3];
    for (int i = 2; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
    b = b + 4'd1;
    return b ^ (b >> 1);
  endfunction

  function automatic logic [19:0] gray2bin20(logic [19:0] g);
    logic [19:0] b;
    b[19] = g[19];
    for (int i = 18; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
    return b;
  endfunction

endpackage
