// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// MIPI D-PHY receive I/O on AMD UltraScale+ HP banks (component mode
// primitives, no vendor D-PHY IP): the board level half of the Bow32 CSI-2
// receiver. bow_csi2rx (hw/ip/csi2rx) runs the LP state machines, the byte
// alignment and the CSI-2 layer on these signals.
//
//   clock lane  IBUFDS_DPHY --HSRX_O--+--> BUFGCE_DIV /1 --> hs_clk    ISERDES CLK, CLK_B
//                                     +--> BUFGCE_DIV /4 --> byte_clk  ISERDES CLKDIV, IDELAY CLK
//   data lane   IBUFDS_DPHY --HSRX_O----> IDELAYE3 --> ISERDESE3 1:8 --> rx_data_o
//   all lanes   LPRX_O_P/N ---------------------------------------------> lp_o (asynchronous)
//
// * IBUFDS_DPHY: hs_en = 0 switches off the HS receiver and the 100 ohm
//   termination (HSRX_O is then 0); the LP receivers are always on. The pins
//   are MIPI_DPHY_DCI with DIFF_TERM_ADV TERM_100 in the XDC.
// * Both BUFGCE_DIV share byte_ce_i (CE_TYPE SYNC): a closed gate freezes the
//   two dividers together, so the /1 and /4 clocks stay aligned. The receiver
//   opens the gate only while the clock lane is static (HS-0 after the clock
//   settle time) and closes it once the clock has stopped: with a
//   non-continuous clock lane the byte clock runs only during HS bursts.
// * ISERDESE3: Q[0] is the first bit received. D-PHY sends the LSB first, so
//   an aligned word is the byte. Its internal /4 clock is aligned to CLKDIV
//   only by RST: byte_rst_i is high while the gate is closed and is released
//   after the clock has restarted, once per burst.
// * IDELAYE3 (COUNT, VAR_LOAD, EN_VTC 0, no IDELAYCTRL): 511 taps of
//   2.7-4.7 ps cover more than one UI at 912 Mbit/s. The capture cannot meet
//   static timing, software centres the taps in the eye at run time. Its CLK
//   must be the CLKDIV net of the ISERDESE3 (otherwise DRC REQP-1742 fails
//   and the pair is not packed into one bitslice), so a tap is only loaded
//   while the byte clock runs.
// * The /1 and /4 clock trees must be balanced: the board XDC puts both nets
//   in one CLOCK_DELAY_GROUP and selects them by the output pins of
//   u_hs_bufg/u_byte_bufg (Vivado synthesis drops the attribute in RTL, and a
//   net name match silently misses a renamed net). Keep the instance names.
// There is no fabric logic here: bow_csi2rx registers rx_data_o and
// dly_tap_o on byte_clk_o.

module bow_dphy_io_xusp #(
  parameter int unsigned Lanes = 2
) (
  input  wire                   clk_p, clk_n,     // clock lane pads
  input  wire  [Lanes-1:0]      data_p, data_n,   // data lane pads
  output logic                  byte_clk_o,       // gated HS clock / 4 (BUFGCE_DIV)
  input  logic                  byte_ce_i,        // CE of both BUFGCE_DIV (CE_TYPE SYNC)
  input  logic                  byte_rst_i,       // ISERDESE3 RST, active high
  output logic [1:0]            clk_lp_o,         // clock lane LP receivers {P, N}, async
  input  logic                  clk_hs_en_i,      // 1: clock lane HS receiver + termination on
  output logic [Lanes-1:0][1:0] lp_o,             // data lanes LP {P, N}, async
  input  logic [Lanes-1:0]      hs_en_i,          // 1: data lane HS receiver + termination on
  output logic [Lanes-1:0][7:0] rx_data_o,        // ISERDESE3 Q, byte clock domain, Q[0] first bit
  input  logic [Lanes-1:0][8:0] dly_tap_i,        // IDELAYE3 CNTVALUEIN (byte clock domain)
  input  logic [Lanes-1:0]      dly_load_i,       // IDELAYE3 LOAD (byte clock domain, 1 cycle)
  output logic [Lanes-1:0][8:0] dly_tap_o         // IDELAYE3 CNTVALUEOUT (byte clock domain)
);

  // ---------------------------------------------------------------------------
  // Clock lane
  // ---------------------------------------------------------------------------
  logic clk_hs;

  IBUFDS_DPHY #(
    .IOSTANDARD ("MIPI_DPHY_DCI"),
    .SIM_DEVICE ("ULTRASCALE_PLUS")
  ) u_clk_ibuf (
    .I            (clk_p),
    .IB           (clk_n),
    .HSRX_DISABLE (~clk_hs_en_i),
    .LPRX_DISABLE (1'b0),
    .HSRX_O       (clk_hs),
    .LPRX_O_P     (clk_lp_o[1]),
    .LPRX_O_N     (clk_lp_o[0])
  );

  logic hs_clk, byte_clk;

  BUFGCE_DIV #(
    .BUFGCE_DIVIDE (1),
    .CE_TYPE       ("SYNC"),
    .SIM_DEVICE    ("ULTRASCALE_PLUS")
  ) u_hs_bufg (
    .I   (clk_hs),
    .CE  (byte_ce_i),
    .CLR (1'b0),
    .O   (hs_clk)
  );

  BUFGCE_DIV #(
    .BUFGCE_DIVIDE (4),
    .CE_TYPE       ("SYNC"),
    .SIM_DEVICE    ("ULTRASCALE_PLUS")
  ) u_byte_bufg (
    .I   (clk_hs),
    .CE  (byte_ce_i),
    .CLR (1'b0),
    .O   (byte_clk)
  );

  assign byte_clk_o = byte_clk;

  // ---------------------------------------------------------------------------
  // Data lanes
  // ---------------------------------------------------------------------------
  for (genvar l = 0; l < Lanes; l++) begin : g_lane
    logic d_hs, d_dly;

    IBUFDS_DPHY #(
      .IOSTANDARD ("MIPI_DPHY_DCI"),
      .SIM_DEVICE ("ULTRASCALE_PLUS")
    ) u_ibuf (
      .I            (data_p[l]),
      .IB           (data_n[l]),
      .HSRX_DISABLE (~hs_en_i[l]),
      .LPRX_DISABLE (1'b0),
      .HSRX_O       (d_hs),
      .LPRX_O_P     (lp_o[l][1]),
      .LPRX_O_N     (lp_o[l][0])
    );

    IDELAYE3 #(
      .CASCADE          ("NONE"),
      .DELAY_FORMAT     ("COUNT"),
      .DELAY_SRC        ("IDATAIN"),
      .DELAY_TYPE       ("VAR_LOAD"),
      .DELAY_VALUE      (0),
      .UPDATE_MODE      ("ASYNC"),
      .REFCLK_FREQUENCY (300.0),
      .SIM_DEVICE       ("ULTRASCALE_PLUS")
    ) u_idelay (
      .CLK         (byte_clk),
      .CE          (1'b0),
      .INC         (1'b0),
      .RST         (1'b0),
      .EN_VTC      (1'b0),
      .LOAD        (dly_load_i[l]),
      .CNTVALUEIN  (dly_tap_i[l]),
      .CNTVALUEOUT (dly_tap_o[l]),
      .IDATAIN     (d_hs),
      .DATAIN      (1'b0),
      .DATAOUT     (d_dly),
      .CASC_IN     (1'b0),
      .CASC_RETURN (1'b0),
      .CASC_OUT    ()
    );

    ISERDESE3 #(
      .DATA_WIDTH        (8),
      .FIFO_ENABLE       ("FALSE"),
      .FIFO_SYNC_MODE    ("FALSE"),
      .IDDR_MODE         ("FALSE"),
      .IS_CLK_B_INVERTED (1'b1),
      .SIM_DEVICE        ("ULTRASCALE_PLUS")
    ) u_iserdes (
      .CLK             (hs_clk),
      .CLK_B           (hs_clk),
      .CLKDIV          (byte_clk),
      .D               (d_dly),
      .RST             (byte_rst_i),
      .FIFO_RD_CLK     (1'b0),
      .FIFO_RD_EN      (1'b0),
      .Q               (rx_data_o[l]),
      .FIFO_EMPTY      (),
      .INTERNAL_DIVCLK ()
    );
  end

endmodule
