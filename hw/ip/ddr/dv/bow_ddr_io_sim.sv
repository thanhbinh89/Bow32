// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Behavioural twin of hw/fpga/common/rtl/bow_ddr_io_xilinx.sv (spec 4.2, 8)
// for Verilator (--timing) and xsim: same fabric ports, the pins split into
// "value driven by the FPGA" / "its enable" / "value seen at the pin" (no
// inout). Nothing here models pad or routing delays: the pins change exactly
// at the clock edges below (the board model adds trace and buffer delays).
//
// Output paths ("PHY cycle j" = the ddr_clk cycle with that io_o_i value):
//   * CK: ODDRE1 on clk_i, D1 = ck_en, D2 = 0 (CK_N: complement): CK_P high in
//     the first half of pin cycle j+1 when ck_en of cycle j.
//   * cke, rst_n, odt, cs_n, ras_n, cas_n, we_n, ba, a: ODDRE1 on clk_i with
//     D1 = value of cycle j-1 (fabric flop), D2 = value of cycle j: the value
//     of cycle j is on the pins from (j+1.5)T to (j+2.5)T (centred on CK edge
//     j+2).
//   * DQS: ODDRE1 on wclk_i, D1 = dqs[l][0] (first half), D2 = dqs[l][1]
//     (second half), DQS_N the complement. The D inputs come from clk_i
//     registers; their arrival is modelled at the clk_i falling edge (a route
//     of T/2), so the PHY-cycle-j value is taken by the wclk edge j+1 for any
//     write phase in (-T/2, +T/2] (hardware: +-T/4 by STA).
//   * DQ / DM: ODDRE1 on wclk90_i with IS_C_INVERTED = 1 (sample and D1 at the
//     wclk90 falling edge = (j+0.75)T + phi_w, D2 at its rising edge), D
//     straight from the PHY registers: dq[j][0] on the pin in [(j+0.75)T,
//     (j+1.25)T), dq[j][1] in [(j+1.25)T, (j+1.75)T) (write phase phi_w = 0).
//     Valid for phi_w in (-0.75T, +0.25T]; beyond +T/4 the DQ path takes the
//     next cycle's value (as the hardware would fail its hold check).
//   * dq_oe / dqs_oe (IOBUF.T) and ls_oe_n, ls_dir_dq, ls_dir_dqs: fabric
//     flops on clk_i, value of cycle j in pin cycle j+1. ls_dir pins = the
//     read level LsDirReadLevel when the PHY asks for DRAM -> FPGA, else its
//     complement. Before the first clock (configuration INIT / ODDRE1 SRVAL):
//     CS#, RAS#, CAS#, WE#, CK_N, LS_OE# high; CK_P, CKE, ODT, RESET# low;
//     DQ / DQS not driven; DIR at the write level.
// Input path (IDDRE1 SAME_EDGE_PIPELINED, C = rd_clk_i, CB = ~rd_clk_i):
//   io_i_o.dq[0] = DQ sampled at rd_clk rising edge k, io_i_o.dq[1] = sampled
//   at the next falling edge, both presented after rising edge k+1 (rd_clk
//   domain). DQS (DQS_P only) the same into io_i_o.dqs. The sampled value is
//   dq_i / dqs_p_i (the pin as resolved by the board model), or the FPGA's own
//   output in Loopback mode.
// Loopback = 1 (no DRAM on the pads): DQ / DQS always driven (enables 1),
//   during lb_en_i the DQ / DQS ODDR data come from lb_dq_i / lb_dqs_i (io_o
//   timing; DM is driven low), LS_OE# = 1 and DIR = write level constants, and
//   the IDDRs sample the FPGA's own pad values (dq_i / dqs_*_i are unused).

`timescale 1ps / 1ps

// pin models: blocking assignments in edge processes are intended (one update
// per edge, no zero-width glitches)
/* verilator lint_off BLKSEQ */
module bow_ddr_io_sim import bow_ddr_pkg::*; #(
  parameter int unsigned DqBits         = 8,
  parameter int unsigned Lanes          = 1,
  parameter int unsigned AddrPins       = 14,
  parameter int unsigned BankPins       = 2,
  parameter bit          Loopback       = 1'b0,
  parameter bit          LsDirReadLevel = 1'b1     // DIR pin level for DRAM -> FPGA
) (
  input  logic                         clk_i,      // ddr_clk (CK, command, T flops)
  input  logic                         wclk_i,     // write clock (DQS)
  input  logic                         wclk90_i,   // write clock + 90 deg (DQ / DM)
  input  logic                         rd_clk_i,   // read capture clock
  input  ddr_io_out_t                  io_o_i,
  output ddr_io_in_t                   io_i_o,
  input  logic                         lb_en_i,
  input  logic [1:0][MaxDq-1:0]        lb_dq_i,
  input  logic [MaxLanes-1:0][1:0]     lb_dqs_i,
  // FPGA pins, split
  output logic                         ck_p_o,
  output logic                         ck_n_o,
  output logic                         cke_o,
  output logic                         rst_n_o,
  output logic                         odt_o,
  output logic                         cs_n_o,
  output logic                         ras_n_o,
  output logic                         cas_n_o,
  output logic                         we_n_o,
  output logic [BankPins-1:0]          ba_o,
  output logic [AddrPins-1:0]          a_o,
  output logic [DqBits-1:0]            dq_o,
  output logic                         dq_oe_o,
  input  logic [DqBits-1:0]            dq_i,
  output logic [Lanes-1:0]             dqs_p_o,
  output logic [Lanes-1:0]             dqs_n_o,
  output logic [Lanes-1:0]             dqs_oe_o,
  input  logic [Lanes-1:0]             dqs_p_i,
  input  logic [Lanes-1:0]             dqs_n_i,
  output logic [Lanes-1:0]             dm_o,
  output logic                         ls_oe_n_o,
  output logic                         ls_dir_dq_o,
  output logic                         ls_dir_dqs_o
);

  // ----------------------------------------------------------------- CK
  initial begin
    ck_p_o = 1'b0;
    ck_n_o = 1'b1;
  end
  always @(posedge clk_i or negedge clk_i) begin
    if (clk_i) begin
      ck_p_o = io_o_i.ck_en;
      ck_n_o = !io_o_i.ck_en;
    end else begin
      ck_p_o = 1'b0;
      ck_n_o = 1'b1;
    end
  end

  // ------------------------------------------------------- command pins
  typedef struct packed {
    logic                cke, rst_n, odt, cs_n, ras_n, cas_n, we_n;
    logic [BankPins-1:0] ba;
    logic [AddrPins-1:0] a;
  } cmd_pins_t;

  localparam cmd_pins_t CmdIdle = '{cke: 1'b0, rst_n: 1'b0, odt: 1'b0, cs_n: 1'b1, ras_n: 1'b1,
                                    cas_n: 1'b1, we_n: 1'b1, ba: '0, a: '0};

  cmd_pins_t cmd_now;              // value of the current PHY cycle (D2)
  assign cmd_now = '{cke: io_o_i.cke, rst_n: io_o_i.rst_n, odt: io_o_i.odt, cs_n: io_o_i.cs_n,
                     ras_n: io_o_i.ras_n, cas_n: io_o_i.cas_n, we_n: io_o_i.we_n,
                     ba: io_o_i.ba[BankPins-1:0], a: io_o_i.a[AddrPins-1:0]};

  cmd_pins_t cmd_prev = CmdIdle;   // fabric flop: value of the previous PHY cycle (D1)
  cmd_pins_t cmd_d2   = CmdIdle;   // D2 taken at the rising edge
  cmd_pins_t cmd_pin  = CmdIdle;

  always @(posedge clk_i or negedge clk_i) begin
    if (clk_i) begin
      cmd_pin  = cmd_prev;
      cmd_d2   = cmd_now;
      cmd_prev = cmd_now;
    end else begin
      cmd_pin = cmd_d2;
    end
  end

  assign {cke_o, rst_n_o, odt_o, cs_n_o, ras_n_o, cas_n_o, we_n_o, ba_o, a_o} = cmd_pin;

  // ---------------------------------------------------------------- DQS
  logic [Lanes-1:0][1:0] dqs_d = '0;      // ODDR D inputs (arrive at the clk falling edge)
  logic [Lanes-1:0]      dqs_d2 = '0;
  logic [Lanes-1:0]      dqs_pin = '0;

  always @(negedge clk_i) begin
    for (int unsigned l = 0; l < Lanes; l++) begin
      dqs_d[l] <= (Loopback && lb_en_i) ? lb_dqs_i[l] : io_o_i.dqs[l];
    end
  end

  always @(posedge wclk_i or negedge wclk_i) begin
    if (wclk_i) begin
      for (int unsigned l = 0; l < Lanes; l++) begin
        dqs_pin[l] = dqs_d[l][0];
        dqs_d2[l]  = dqs_d[l][1];
      end
    end else begin
      dqs_pin = dqs_d2;
    end
  end

  assign dqs_p_o = dqs_pin;
  assign dqs_n_o = ~dqs_pin;

  // ------------------------------------------------------------ DQ / DM
  logic [DqBits-1:0] dq_pin = '0, dq_d2 = '0;
  logic [Lanes-1:0]  dm_pin = '0, dm_d2 = '0;

  always @(posedge wclk90_i or negedge wclk90_i) begin
    if (!wclk90_i) begin                  // rising edge of the inverted clock
      if (Loopback && lb_en_i) begin
        dq_pin = lb_dq_i[0][DqBits-1:0];
        dq_d2  = lb_dq_i[1][DqBits-1:0];
        dm_pin = '0;
        dm_d2  = '0;
      end else begin
        dq_pin = io_o_i.dq[0][DqBits-1:0];
        dq_d2  = io_o_i.dq[1][DqBits-1:0];
        dm_pin = io_o_i.dm[0][Lanes-1:0];
        dm_d2  = io_o_i.dm[1][Lanes-1:0];
      end
    end else begin
      dq_pin = dq_d2;
      dm_pin = dm_d2;
    end
  end

  assign dq_o = dq_pin;
  assign dm_o = dm_pin;

  // ---------------------------------------------------- T and shifter flops
  logic             dq_oe_q = 1'b0;
  logic [Lanes-1:0] dqs_oe_q = '0;
  logic             ls_oe_n_q = 1'b1, ls_dir_dq_q = 1'b0, ls_dir_dqs_q = 1'b0;

  always @(posedge clk_i) begin
    dq_oe_q      <= io_o_i.dq_oe;
    dqs_oe_q     <= io_o_i.dqs_oe[Lanes-1:0];
    ls_oe_n_q    <= io_o_i.ls_oe_n;
    ls_dir_dq_q  <= io_o_i.ls_dir_dq;
    ls_dir_dqs_q <= io_o_i.ls_dir_dqs;
  end

  assign dq_oe_o      = Loopback ? 1'b1 : dq_oe_q;
  assign dqs_oe_o     = Loopback ? '1 : dqs_oe_q;
  assign ls_oe_n_o    = Loopback ? 1'b1 : ls_oe_n_q;
  assign ls_dir_dq_o  = (!Loopback && ls_dir_dq_q) ? LsDirReadLevel : !LsDirReadLevel;
  assign ls_dir_dqs_o = (!Loopback && ls_dir_dqs_q) ? LsDirReadLevel : !LsDirReadLevel;

  // -------------------------------------------------------------- IDDRs
  logic [DqBits-1:0] dq_in;
  logic [Lanes-1:0]  dqs_in;
  assign dq_in  = Loopback ? dq_o : dq_i;
  assign dqs_in = Loopback ? dqs_p_o : dqs_p_i;

  logic [DqBits-1:0] dq_r = '0, dq_f = '0, dq_q1 = '0, dq_q2 = '0;
  logic [Lanes-1:0]  dqs_r = '0, dqs_f = '0, dqs_q1 = '0, dqs_q2 = '0;

  always @(posedge rd_clk_i) begin
    dq_q1  <= dq_r;           // sample of rising edge k and falling edge k + 1/2,
    dq_q2  <= dq_f;           // presented after rising edge k + 1
    dqs_q1 <= dqs_r;
    dqs_q2 <= dqs_f;
    dq_r    = dq_in;
    dqs_r   = dqs_in;
  end

  always @(negedge rd_clk_i) begin
    dq_f  = dq_in;
    dqs_f = dqs_in;
  end

  always_comb begin
    io_i_o = '0;
    io_i_o.dq[0][DqBits-1:0] = dq_q1;
    io_i_o.dq[1][DqBits-1:0] = dq_q2;
    io_i_o.dqs[0][Lanes-1:0] = dqs_q1;
    io_i_o.dqs[1][Lanes-1:0] = dqs_q2;
  end

  // not used by the pads
  logic unused;
  assign unused = ^{dqs_n_i, Loopback ? {dq_i, dqs_p_i} : '0,
                    io_o_i.dqs_oe, io_o_i.dq, io_o_i.dm, io_o_i.ba, io_o_i.a, lb_dq_i, lb_dqs_i};

endmodule
/* verilator lint_on BLKSEQ */
