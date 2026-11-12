// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Fabric logic of the UltraScale+ AFE adapter bow_dphy_io_xusp, without a primitive (step 5
// of docs/ip/mipi_rx_arch.md, sections 3.7 and 10): what the AFE interface (section 3.2)
// leaves to the adapter, and what the receiver did for the KV260 PHY I/O up to step 4.
// The tests of the receiver run it in Verilator (csi2_tx_model instantiates it), xsim
// with the primitives (hw/fpga/common/dv/tb_bow_dphy_io_xusp.sv).
//
//   des_rst_i -------------> bow_rst_sync (byte clock) -------------> iserdes_rst_o
//   dly_code_i, dly_own_i --> per bit synchronisers (byte clock) --> load when changed
//                                                                    --> load_o, cntvaluein_o
//
// * ISERDESE3 RST: des_rst (the D-PHY's lp domain flop, ~clk_gate_en) asserts it at once, and
//   it is released 2 byte clocks after the clock restarts (u_iserdes_rst), once per gate
//   opening: the release aligns the internal /4 divider of the ISERDESE3 with CLKDIV. It
//   cannot hang: des_rst never touches the BUFGCE_DIV dividers. (Up to step 4 the D-PHY
//   did this: byte_rst_o.)
// * IDELAYE3 taps (VAR_LOAD, CLK = the byte clock, CNTVALUEOUT = the AFE's dly_q): the tap of
//   a lane is dly_code while dly_own = 1, else the adapter's own value, 0 (DELAY_VALUE). The
//   synchronised value (dly_own ? dly_code : 0) is loaded (CNTVALUEIN, then LOAD for one
//   cycle) when it was the same in two consecutive cycles and differs from the tap loaded
//   last. Code and OWN are a bus of independent synchronisers, the bits of a lane written in
//   one bus cycle; the board XDC bounds their skew to one byte clock period (set_bus_skew
//   in hw/fpga/kv260_cam/constr/kv260_cam.xdc), so a mix of old and new bits shows for one
//   cycle at most and is never loaded (without that bound a mix could stay for two cycles
//   and be loaded for a burst, then the right tap). tap_ld_q
//   mirrors the IDELAYE3 and has no reset (neither has the IDELAYE3): 0 after configuration,
//   as DELAY_VALUE. Only while the byte clock runs: a code written between bursts is loaded
//   at the start of the next one. dly_own 1 -> 0 loads the tap 0, lane by lane.
//   Against the D-PHY's loads of step 4 (g_dly_byte): with OWN set by every write (READY is
//   1 here) the same taps are loaded at the same byte clock; after a reset step 4 loaded the
//   reset code 0 at the first byte clocks in any case, this logic only when the tap is not 0
//   already.
// No reset input: the AFE interface has none, and nothing here needs one.

module bow_dphy_dly_xusp #(
  parameter int unsigned Lanes = 2
) (
  input  logic                  byte_clk_i,     // the gated byte clock (BUFGCE_DIV /4)
  // receive path reset
  input  logic                  des_rst_i,      // AFE des_rst, asynchronous (lp domain flop)
  output logic                  iserdes_rst_o,  // ISERDESE3 RST, active high
  // delays
  input  logic [Lanes-1:0][8:0] dly_code_i,     // AFE dly_code, asynchronous, static
  input  logic [Lanes-1:0]      dly_own_i,      // AFE dly_own, asynchronous
  output logic [Lanes-1:0][8:0] cntvaluein_o,   // IDELAYE3 CNTVALUEIN, byte clock domain
  output logic [Lanes-1:0]      load_o          // IDELAYE3 LOAD, one byte clock cycle
);

  // ---------------------------------------------------------------- ISERDESE3 RST
  logic iserdes_rst_n;

  bow_rst_sync u_iserdes_rst (
    .clk_i  (byte_clk_i),
    .rst_ni (!des_rst_i),
    .rst_no (iserdes_rst_n)
  );

  assign iserdes_rst_o = !iserdes_rst_n;

  // ---------------------------------------------------------------- IDELAYE3 taps
  logic [Lanes-1:0][8:0] code_s, tap_s, tap_ld_d;
  logic [Lanes-1:0]      own_s, load_d;
  logic [Lanes-1:0][8:0] tap_last_q = '0, tap_ld_q = '0;
  logic [Lanes-1:0]      load_q = '0;

  bow_sync_bus #(
    .Width (9 * Lanes)
  ) u_sync_code (
    .clk_i  (byte_clk_i),
    .rst_ni (1'b1),
    .d_i    (dly_code_i),
    .q_o    (code_s)
  );

  bow_sync_bus #(
    .Width (Lanes)
  ) u_sync_own (
    .clk_i  (byte_clk_i),
    .rst_ni (1'b1),
    .d_i    (dly_own_i),
    .q_o    (own_s)
  );

  // next state in variables, one non-blocking write per register (the xsim note in
  // bow_dphy_io_versal)
  always_comb begin
    tap_ld_d = tap_ld_q;
    load_d   = '0;
    for (int unsigned l = 0; l < Lanes; l++) begin
      tap_s[l] = own_s[l] ? code_s[l] : 9'd0;
      if ((tap_s[l] == tap_last_q[l]) && (tap_s[l] != tap_ld_q[l])) begin
        tap_ld_d[l] = tap_s[l];
        load_d[l]   = 1'b1;
      end
    end
  end

  always_ff @(posedge byte_clk_i) begin
    tap_last_q <= tap_s;
    tap_ld_q   <= tap_ld_d;
    load_q     <= load_d;
  end

  assign cntvaluein_o = tap_ld_q;
  assign load_o       = load_q;

endmodule
