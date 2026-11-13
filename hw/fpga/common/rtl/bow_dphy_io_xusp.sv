// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// MIPI D-PHY receive I/O on AMD UltraScale+ HP banks (component mode
// primitives, no vendor D-PHY IP): the AFE adapter of the Bow32 receiver on the
// KV260 (docs/ip/mipi_rx_arch.md, section 3.7). Its ports are the AFE interface
// of section 3.2 (the signals this adapter has); bow_mipi_rx (hw/ip/csi2rx:
// bow_dphy_rx + bow_csi2rx) drives it with the LP state machines and runs the
// byte alignment and the CSI-2 layer on its words.
//
//   clock lane  IBUFDS_DPHY --HSRX_O--+--> BUFGCE_DIV /1 --> hs_clk    ISERDES CLK, CLK_B
//                                     +--> BUFGCE_DIV /4 --> byte_clk  ISERDES CLKDIV, IDELAY CLK
//   data lane   IBUFDS_DPHY --HSRX_O----> IDELAYE3 --> ISERDESE3 1:8 --> hs_data_o
//   all lanes   LPRX_O_P/N ---------------------------------------------> lp_o (asynchronous)
//   u_dly       bow_dphy_dly_xusp (no primitive): ISERDESE3 RST from des_rst, IDELAYE3 loads
//               from dly_code / dly_own
//
// AFE signals (section 3.7):
// * hs_byte_clk_o: BUFGCE_DIV /4 of HSRX_O of the clock lane; hs_valid_o = '1 (a word every
//   byte clock); clk_gate_en_i = CE of both BUFGCE_DIV (CE_TYPE SYNC): a closed gate freezes
//   the two dividers together, so the /1 and /4 clocks stay aligned. The D-PHY opens the
//   gate only while the clock lane is static (HS-0 after the clock settle time) and closes
//   it once the clock has stopped: with a non-continuous clock lane the byte clock runs only
//   during HS bursts.
// * hs_data_o: ISERDESE3 Q, Q[0] is the first bit received. D-PHY sends the LSB first, so an
//   aligned word is the byte. Its internal /4 clock is aligned to CLKDIV only by RST: des_rst
//   (high while the gate is closed) asserts RST, bow_dphy_dly_xusp releases it 2 byte clocks
//   after the clock restarted, once per gate opening.
// * hsrx_en, term_en: IBUFDS_DPHY has one pin for the HS receiver and the termination:
//   HSRX_DISABLE = ~term_en, so the termination never comes on before LP-00 (hsrx_en alone,
//   the D-PHY's CTRL.HSRX_EARLY from LP-01, would terminate LP-01; it changes nothing here:
//   without HSRX_EARLY the two enables are equal, bow_afe_chk). HSRX_O is 0 while disabled.
//   The LP receivers are always on (LPRX_DISABLE = 0: lprx_en is not modelled). The pins are
//   MIPI_DPHY_DCI with DIFF_TERM_ADV TERM_100 in the XDC.
// * dly_code, dly_own, dly_q: IDELAYE3 (COUNT, VAR_LOAD, EN_VTC 0, no IDELAYCTRL), 511 taps of
//   2.7-4.7 ps cover more than one UI at 912 Mbit/s; dly_q = CNTVALUEOUT (byte clock
//   domain). bow_dphy_dly_xusp loads a changed code at the next byte clocks (only while the
//   byte clock runs: the next burst); dly_own 1 -> 0 loads the tap 0, lane by lane. The
//   capture cannot meet static timing, software centres the taps in the eye at run time.
//   The IDELAYE3 CLK must be the CLKDIV net of the ISERDESE3 (otherwise DRC REQP-1742 fails
//   and the pair is not packed into one bitslice).
// * pd, cal_start, lprx_en: not modelled (no power down, no internal calibration);
//   ready_o = 1, status_o = 0.
// * The /1 and /4 clock trees must be balanced: the board XDC puts both nets in one
//   CLOCK_DELAY_GROUP and selects them by the output pins of u_hs_bufg/u_byte_bufg (Vivado
//   synthesis drops the attribute in RTL, and a net name match silently misses a renamed
//   net). Keep the instance names.

module bow_dphy_io_xusp #(
  parameter int unsigned Lanes = 2
) (
  input  wire                   clk_p, clk_n,     // clock lane pads
  input  wire  [Lanes-1:0]      data_p, data_n,   // data lane pads
  // AFE interface (docs/ip/mipi_rx_arch.md section 3.2)
  output logic                  hs_byte_clk_o,    // gated HS clock / 4 (BUFGCE_DIV)
  output logic [Lanes-1:0][7:0] hs_data_o,        // ISERDESE3 Q, byte clock domain, Q[0] first bit
  output logic [Lanes-1:0]      hs_valid_o,       // '1: a word every byte clock
  input  logic                  clk_gate_en_i,    // CE of both BUFGCE_DIV (CE_TYPE SYNC)
  input  logic                  des_rst_i,        // asynchronous: ISERDESE3 RST (u_dly)
  output logic [1:0]            clk_lp_o,         // clock lane LP receivers {P, N}, async
  output logic [Lanes-1:0][1:0] lp_o,             // data lanes LP {P, N}, async
  input  logic                  clk_lprx_en_i,    // not modelled (LP receivers always on)
  input  logic [Lanes-1:0]      lprx_en_i,
  input  logic                  clk_hsrx_en_i,    // not used: one pin for the HS receiver
  input  logic [Lanes-1:0]      hsrx_en_i,        //   and the termination, which follows
  input  logic                  clk_term_en_i,    // clock lane HS receiver + termination on
  input  logic [Lanes-1:0]      term_en_i,        //   (HSRX_DISABLE = ~term_en)
  input  logic [Lanes-1:0][8:0] dly_code_i,       // asynchronous, static (u_dly)
  input  logic [Lanes-1:0]      dly_own_i,        // asynchronous (u_dly)
  output logic [Lanes-1:0][8:0] dly_q_o,          // IDELAYE3 CNTVALUEOUT (byte clock domain)
  input  logic                  pd_i,             // not modelled (no power down)
  output logic                  ready_o,          // 1
  input  logic                  cal_start_i,      // not modelled (no internal calibration)
  output logic [7:0]            status_o          // 0
);

  // ---------------------------------------------------------------------------
  // Adapter logic (no primitive): ISERDESE3 reset, IDELAYE3 loads
  // ---------------------------------------------------------------------------
  logic                  byte_clk, iserdes_rst;
  logic [Lanes-1:0][8:0] dly_cntin;
  logic [Lanes-1:0]      dly_load;

  bow_dphy_dly_xusp #(
    .Lanes (Lanes)
  ) u_dly (
    .byte_clk_i    (byte_clk),
    .des_rst_i,
    .iserdes_rst_o (iserdes_rst),
    .dly_code_i,
    .dly_own_i,
    .cntvaluein_o  (dly_cntin),
    .load_o        (dly_load)
  );

  assign hs_valid_o = '1;
  assign ready_o    = 1'b1;
  assign status_o   = '0;

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
    .HSRX_DISABLE (~clk_term_en_i),
    .LPRX_DISABLE (1'b0),
    .HSRX_O       (clk_hs),
    .LPRX_O_P     (clk_lp_o[1]),
    .LPRX_O_N     (clk_lp_o[0])
  );

  logic hs_clk;

  BUFGCE_DIV #(
    .BUFGCE_DIVIDE (1),
    .CE_TYPE       ("SYNC"),
    .SIM_DEVICE    ("ULTRASCALE_PLUS")
  ) u_hs_bufg (
    .I   (clk_hs),
    .CE  (clk_gate_en_i),
    .CLR (1'b0),
    .O   (hs_clk)
  );

  BUFGCE_DIV #(
    .BUFGCE_DIVIDE (4),
    .CE_TYPE       ("SYNC"),
    .SIM_DEVICE    ("ULTRASCALE_PLUS")
  ) u_byte_bufg (
    .I   (clk_hs),
    .CE  (clk_gate_en_i),
    .CLR (1'b0),
    .O   (byte_clk)
  );

  assign hs_byte_clk_o = byte_clk;

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
      .HSRX_DISABLE (~term_en_i[l]),
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
      .LOAD        (dly_load[l]),
      .CNTVALUEIN  (dly_cntin[l]),
      .CNTVALUEOUT (dly_q_o[l]),
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
      .RST             (iserdes_rst),
      .FIFO_RD_CLK     (1'b0),
      .FIFO_RD_EN      (1'b0),
      .Q               (hs_data_o[l]),
      .FIFO_EMPTY      (),
      .INTERNAL_DIVCLK ()
    );
  end

  logic unused;
  assign unused = ^{clk_lprx_en_i, lprx_en_i, clk_hsrx_en_i, hsrx_en_i, pd_i, cal_start_i};

endmodule
