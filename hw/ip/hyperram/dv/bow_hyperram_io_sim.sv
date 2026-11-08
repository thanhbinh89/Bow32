// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Behavioural twin of the HyperRAM pad wrapper of a board top
// (hw/fpga/common/rtl/bow_hyperram_io_xilinx.sv: ODDRE1 / IDDRE1 / IOBUF)
// for Verilator (--timing) and xsim, with the timing contract of
// bow_hyperram_pkg (hr_io_out_t / hr_io_in_t). Same fabric ports; the pins
// split into "value driven by the FPGA" / "its enable" / "value seen at the
// pin" (no inout). Every pin output changes PadOutPs after its clock edge
// (output buffer and package), every input reaches the IDDRs / the RWDS wire
// PadInPs after the pin (input buffer); the board model adds the traces and
// the level shifters.
//
// Output paths ("PHY cycle j" = the hr_clk cycle in which io_o_i holds that
// value; its rising edges are at jT and (j+1)T):
//   * CK: ODDRE1 on clk_i, D1 = ck_en, D2 = 0 (CK_N: the complement): CK_P
//     high during [(j+1)T, (j+1.5)T) when ck_en of cycle j, low otherwise.
//   * CS#, RESET#, LS_OE#, DIR (DQ), DIR (RWDS): ODDRE1 / fabric flops on
//     clk_i: the value of cycle j during [(j+1)T, (j+2)T). DIR pin = 1 means
//     HyperRAM -> FPGA (the card's TXV0108 DIR = H: A -> B).
//   * DQ / RWDS: ODDRE1 clocked by ~wclk_i (IS_C_INVERTED), D1 = dq[0] /
//     rwds[0], D2 = dq[1] / rwds[1] straight from the PHY register: at the
//     wclk_i falling edge after the hr_clk edge jT (= (j+0.75)T + write phase)
//     both are sampled and D1 goes to the pin, at the next wclk_i rising
//     edge D2 does: at write phase 0 dq[0] on the pin during
//     [(j+0.75)T, (j+1.25)T), dq[1] during [(j+1.25)T, (j+1.75)T). The real
//     wclk_i edges are used, so a write phase of w steps shifts both by
//     w * T / PsSteps. Valid for |w| <= PsSteps / 4 (the contract): a wclk_i
//     falling edge that coincides with an hr_clk rising edge (w = +T/4)
//     still takes the value of the cycle that ends there (the register's
//     clock-to-out covers the ODDR hold); beyond +T/4 the next cycle's value
//     is taken (the hardware would fail its timing).
//   * dq_oe / rwds_oe: IOBUF T driven by fabric flops on clk_i: the FPGA
//     drives the pads from (j+1)T (dq_oe_o / rwds_oe_o) with the value of
//     cycle j.
//   Before the first clock edge the pins are in the HR_IO_OUT_IDLE state:
//   CS# and RESET# high, CK_P low (CK_N high), DQ / RWDS driven low, LS_OE#
//   high, DIR low.
// Input path (IDDRE1 SAME_EDGE_PIPELINED, C = rd_clk_i, CB = ~rd_clk_i):
//   io_i_o.dq[0] / rwds[0] = the input sampled at rd_clk rising edge k,
//   io_i_o.dq[1] / rwds[1] = sampled at the next falling edge, both
//   presented after rising edge k+1 (rd_clk domain). The value at an FPGA pin
//   is the FPGA's own driver when its enable is 1, else the board's value
//   (dq_i / rwds_i: the pin as the board model resolves it).
//   rwds_pad_o = the RWDS input (after PadInPs), asynchronous: the latency
//   indication of the CA phase for the core's synchroniser.
// Loopback = 1 (the MPS4 loopback build with the on-chip emulator, no
//   HyperRAM on the pads): DQ / RWDS always driven (dq_oe_o = rwds_oe_o = 1
//   whatever io_o_i says), the DQ ODDR data come from lb_dq_i while
//   lb_dq_en_i, the RWDS ODDR data from lb_rwds_i while lb_rwds_en_i (lb_*
//   of hr_clk cycle j behave like io_o_i of cycle j), the IDDRs read the
//   pads back (dq_i / rwds_i are ignored), LS_OE# = 1 and DIR = 0 constants.
// HasLs = 0 (a board without level shifters): LS_OE# = 1, DIR = 0 constants.

`timescale 1ps / 1ps

// pin models: blocking assignments in edge processes are intended (one update
// per edge, no zero-width glitches)
/* verilator lint_off BLKSEQ */
module bow_hyperram_io_sim import bow_hyperram_pkg::*; #(
  parameter bit          Loopback = 1'b0,
  parameter bit          HasLs    = 1'b1,
  parameter int unsigned PadOutPs = 1500,
  parameter int unsigned PadInPs  = 800
) (
  input  logic            clk_i,          // hr_clk (CK, CS#, RESET#, shifter controls, T flops)
  input  logic            wclk_i,         // write clock (DQ / RWDS ODDRs on ~wclk_i)
  input  logic            rd_clk_i,       // read capture clock (IDDRs)
  input  hr_io_out_t      io_o_i,
  output hr_io_in_t       io_i_o,
  output logic            rwds_pad_o,     // RWDS input level, asynchronous
  input  logic            lb_dq_en_i,     // Loopback: DQ ODDR data from lb_dq_i
  input  logic [1:0][7:0] lb_dq_i,
  input  logic            lb_rwds_en_i,   // Loopback: RWDS ODDR data from lb_rwds_i
  input  logic [1:0]      lb_rwds_i,
  // FPGA pins, split
  output logic            ck_p_o,
  output logic            ck_n_o,
  output logic            cs_n_o,
  output logic            rst_n_o,
  output logic [7:0]      dq_o,
  output logic            dq_oe_o,
  input  logic [7:0]      dq_i,
  output logic            rwds_o,
  output logic            rwds_oe_o,
  input  logic            rwds_i,
  output logic            ls_oe_n_o,
  output logic            ls_dir_dq_o,
  output logic            ls_dir_rwds_o
);

  // delays in this module's 1 ps whatever the parent's unit
  /* verilator no_inline_module */

  // pad delays (never 0: Verilator --timing)
  localparam int unsigned DOut = (PadOutPs > 0) ? PadOutPs : 1;
  localparam int unsigned DIn  = (PadInPs > 0) ? PadInPs : 1;

  // one evaluation of every delayed copy at 2 ps (inputs that keep their
  // time-0 value never trigger an @(change))
  logic kick = 1'b0;
  initial #2 kick = 1'b1;

  // ----------------------------------------------------------------- CK
  logic ck_int = 1'b0;                    // ODDR output (before the pad)
  always @(posedge clk_i or negedge clk_i) begin
    if (clk_i) ck_int = io_o_i.ck_en;     // D1 of cycle j (value before this edge's update)
    else       ck_int = 1'b0;             // D2 = 0
  end

  initial begin
    ck_p_o = 1'b0;
    ck_n_o = 1'b1;
  end
  always @(ck_int or kick) begin
    ck_p_o <= #(DOut) ck_int;
    ck_n_o <= #(DOut) !ck_int;
  end

  // ------------------------------------- CS#, RESET#, shifters, T flops
  logic cs_n_q = 1'b1, rst_n_q = 1'b1, ls_oe_n_q = 1'b1, ls_dir_dq_q = 1'b0, ls_dir_rwds_q = 1'b0;
  logic dq_oe_q = 1'b1, rwds_oe_q = 1'b1;

  always @(posedge clk_i) begin
    cs_n_q        <= io_o_i.cs_n;
    rst_n_q       <= io_o_i.rst_n;
    ls_oe_n_q     <= io_o_i.ls_oe_n;
    ls_dir_dq_q   <= io_o_i.ls_dir_dq;
    ls_dir_rwds_q <= io_o_i.ls_dir_rwds;
    dq_oe_q       <= io_o_i.dq_oe;
    rwds_oe_q     <= io_o_i.rwds_oe;
  end

  // the values that go to the pads (Loopback / HasLs constants)
  logic dq_oe_int, rwds_oe_int, ls_oe_n_int, ls_dir_dq_int, ls_dir_rwds_int;
  assign dq_oe_int       = Loopback ? 1'b1 : dq_oe_q;
  assign rwds_oe_int     = Loopback ? 1'b1 : rwds_oe_q;
  assign ls_oe_n_int     = (Loopback || !HasLs) ? 1'b1 : ls_oe_n_q;
  assign ls_dir_dq_int   = (!Loopback && HasLs) && ls_dir_dq_q;
  assign ls_dir_rwds_int = (!Loopback && HasLs) && ls_dir_rwds_q;

  initial begin
    cs_n_o        = 1'b1;
    rst_n_o       = 1'b1;
    ls_oe_n_o     = 1'b1;
    ls_dir_dq_o   = 1'b0;
    ls_dir_rwds_o = 1'b0;
    dq_oe_o       = 1'b1;
    rwds_oe_o     = 1'b1;
  end
  always @(cs_n_q or kick)          cs_n_o        <= #(DOut) cs_n_q;
  always @(rst_n_q or kick)         rst_n_o       <= #(DOut) rst_n_q;
  always @(ls_oe_n_int or kick)     ls_oe_n_o     <= #(DOut) ls_oe_n_int;
  always @(ls_dir_dq_int or kick)   ls_dir_dq_o   <= #(DOut) ls_dir_dq_int;
  always @(ls_dir_rwds_int or kick) ls_dir_rwds_o <= #(DOut) ls_dir_rwds_int;
  always @(dq_oe_int or kick)       dq_oe_o       <= #(DOut) dq_oe_int;
  always @(rwds_oe_int or kick)     rwds_oe_o     <= #(DOut) rwds_oe_int;

  // ------------------------------------------------------------ DQ / RWDS
  typedef struct packed {
    logic [1:0][7:0] dq;
    logic [1:0]      rwds;
  } dsrc_t;

  // D inputs of the DQ / RWDS ODDRs (the PHY register, or the emulator)
  function automatic dsrc_t d_now();
    dsrc_t v;
    v.dq   = (Loopback && lb_dq_en_i) ? lb_dq_i : io_o_i.dq;
    v.rwds = (Loopback && lb_rwds_en_i) ? lb_rwds_i : io_o_i.rwds;
    return v;
  endfunction

  // value of the cycle that ends at the last hr_clk rising edge (taken
  // before the PHY register updates), for a wclk falling edge at that time
  dsrc_t  d_prev = '0;
  longint t_hr   = -1;
  always @(posedge clk_i) begin
    d_prev = d_now();
    t_hr   = $time;
  end

  logic [7:0] dq_int = '0, dq_d2 = '0;
  logic       rwds_int = 1'b0, rwds_d2 = 1'b0;
  always @(posedge wclk_i or negedge wclk_i) begin
    if (!wclk_i) begin                    // rising edge of the inverted clock: D1, D2 sampled
      dsrc_t v;
      v        = ($time == t_hr) ? d_prev : d_now();
      dq_int   = v.dq[0];
      dq_d2    = v.dq[1];
      rwds_int = v.rwds[0];
      rwds_d2  = v.rwds[1];
    end else begin                        // falling edge of the inverted clock: D2
      dq_int   = dq_d2;
      rwds_int = rwds_d2;
    end
  end

  initial begin
    dq_o   = '0;
    rwds_o = 1'b0;
  end
  always @(dq_int or kick)   dq_o   <= #(DOut) dq_int;
  always @(rwds_int or kick) rwds_o <= #(DOut) rwds_int;

  // -------------------------------------------------------------- inputs
  // the pin: the FPGA's own driver, else the board
  logic [7:0] pin_dq;
  logic       pin_rwds;
  assign pin_dq   = (Loopback || dq_oe_o) ? dq_o : dq_i;
  assign pin_rwds = (Loopback || rwds_oe_o) ? rwds_o : rwds_i;

  logic [7:0] in_dq = '0;
  logic       in_rwds = 1'b0;
  always @(pin_dq or kick)   in_dq   <= #(DIn) pin_dq;
  always @(pin_rwds or kick) in_rwds <= #(DIn) pin_rwds;

  assign rwds_pad_o = in_rwds;

  // -------------------------------------------------------------- IDDRs
  logic [7:0] dq_r = '0, dq_f = '0;
  logic       rwds_r = 1'b0, rwds_f = 1'b0;
  hr_io_in_t  in_q = '0;

  always @(posedge rd_clk_i) begin
    in_q <= '{dq: {dq_f, dq_r}, rwds: {rwds_f, rwds_r}};   // samples of edge k and k + 1/2
    dq_r   = in_dq;
    rwds_r = in_rwds;
  end

  always @(negedge rd_clk_i) begin
    dq_f   = in_dq;
    rwds_f = in_rwds;
  end

  assign io_i_o = in_q;

  // not used by the pads
  logic unused;
  assign unused = ^{Loopback ? {dq_i, rwds_i} : '0, Loopback ? 20'h0 : {lb_dq_en_i, lb_dq_i,
                    lb_rwds_en_i, lb_rwds_i}};

endmodule
/* verilator lint_on BLKSEQ */
