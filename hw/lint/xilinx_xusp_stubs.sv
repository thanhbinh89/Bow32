// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Port-only stubs of the AMD UltraScale+ primitives that the UltraScale+ board level RTL
// instantiates (bow_dphy_io_xusp, the KV260 tops, bow_ddr_clk_xusp and bow_hyperram_clk_xusp
// of the MPS4 top), for the Verilator lint of `make lint`; read together with
// xilinx_versal_stubs.sv (the primitives both families have: BUFG, BUFGCE, IBUFDS_DPHY,
// IOBUF, ODDRE1, IDDRE1, the I/O buffers). Lint only: no behaviour, every output is left
// undriven. Ports (names, directions, widths) follow the primitive port tables of AMD's
// UltraScale architecture libraries guide (UG974); the parameters are only those the Bow32
// RTL sets, with neutral defaults. The vendor simulation models stay in the Vivado
// installation (the xsim tests in hw/fpga/common/dv use them).

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

// ---------------------------------------------------------------- clock buffer with divider
module BUFGCE_DIV #(
  parameter integer BUFGCE_DIVIDE = 1,
  parameter         CE_TYPE       = "SYNC",
  parameter         SIM_DEVICE    = ""
) (
  input  wire I,
  input  wire CE,
  input  wire CLR,
  output wire O
);
endmodule

// ---------------------------------------------------------------- input delay, deserialiser
// IDELAYE3: 512 tap input delay line (COUNT mode: CNTVALUEIN / CNTVALUEOUT, 9 bit)
module IDELAYE3 #(
  parameter      CASCADE          = "NONE",
  parameter      DELAY_FORMAT     = "TIME",
  parameter      DELAY_SRC        = "IDATAIN",
  parameter      DELAY_TYPE       = "FIXED",
  parameter      DELAY_VALUE      = 0,
  parameter      UPDATE_MODE      = "ASYNC",
  parameter real REFCLK_FREQUENCY = 300.0,
  parameter      SIM_DEVICE       = ""
) (
  input  wire       CLK,
  input  wire       RST,
  input  wire       CE,
  input  wire       INC,
  input  wire       LOAD,
  input  wire       EN_VTC,
  input  wire [8:0] CNTVALUEIN,
  output wire [8:0] CNTVALUEOUT,
  input  wire       IDATAIN,
  input  wire       DATAIN,
  output wire       DATAOUT,
  input  wire       CASC_IN,
  input  wire       CASC_RETURN,
  output wire       CASC_OUT
);
endmodule

// ISERDESE3: 1:4 / 1:8 input deserialiser of a bitslice
module ISERDESE3 #(
  parameter integer DATA_WIDTH        = 8,
  parameter         FIFO_ENABLE       = "FALSE",
  parameter         FIFO_SYNC_MODE    = "FALSE",
  parameter         IDDR_MODE         = "FALSE",
  parameter [0:0]   IS_CLK_B_INVERTED = 1'b0,
  parameter         SIM_DEVICE        = ""
) (
  input  wire       CLK,
  input  wire       CLK_B,
  input  wire       CLKDIV,
  input  wire       D,
  input  wire       RST,
  input  wire       FIFO_RD_CLK,
  input  wire       FIFO_RD_EN,
  output wire [7:0] Q,
  output wire       FIFO_EMPTY,
  output wire       INTERNAL_DIVCLK
);
endmodule

// ---------------------------------------------------------------- clock manager
module MMCME4_ADV #(
  parameter              BANDWIDTH            = "OPTIMIZED",
  parameter real         CLKIN1_PERIOD        = 0.0,
  parameter integer      DIVCLK_DIVIDE        = 1,
  parameter real         CLKFBOUT_MULT_F      = 5.0,
  parameter real         CLKFBOUT_PHASE       = 0.0,
  parameter              CLKFBOUT_USE_FINE_PS = "FALSE",
  parameter real         CLKOUT0_DIVIDE_F     = 1.0,
  parameter real         CLKOUT0_PHASE        = 0.0,
  parameter real         CLKOUT0_DUTY_CYCLE   = 0.5,
  parameter              CLKOUT0_USE_FINE_PS  = "FALSE",
  parameter integer      CLKOUT1_DIVIDE       = 1,
  parameter real         CLKOUT1_PHASE        = 0.0,
  parameter real         CLKOUT1_DUTY_CYCLE   = 0.5,
  parameter              CLKOUT1_USE_FINE_PS  = "FALSE",
  parameter integer      CLKOUT2_DIVIDE       = 1,
  parameter real         CLKOUT2_PHASE        = 0.0,
  parameter real         CLKOUT2_DUTY_CYCLE   = 0.5,
  parameter              CLKOUT2_USE_FINE_PS  = "FALSE",
  parameter integer      CLKOUT3_DIVIDE       = 1,
  parameter real         CLKOUT3_PHASE        = 0.0,
  parameter real         CLKOUT3_DUTY_CYCLE   = 0.5,
  parameter              CLKOUT3_USE_FINE_PS  = "FALSE",
  parameter              COMPENSATION         = "AUTO",
  parameter              STARTUP_WAIT         = "FALSE"
) (
  // clocks
  input  wire        CLKIN1,
  input  wire        CLKIN2,
  input  wire        CLKINSEL,
  input  wire        CLKFBIN,
  output wire        CLKFBOUT,
  output wire        CLKFBOUTB,
  output wire        CLKOUT0,
  output wire        CLKOUT0B,
  output wire        CLKOUT1,
  output wire        CLKOUT1B,
  output wire        CLKOUT2,
  output wire        CLKOUT2B,
  output wire        CLKOUT3,
  output wire        CLKOUT3B,
  output wire        CLKOUT4,
  output wire        CLKOUT5,
  output wire        CLKOUT6,
  // status and control
  input  wire        RST,
  input  wire        PWRDWN,
  output wire        LOCKED,
  output wire        CLKINSTOPPED,
  output wire        CLKFBSTOPPED,
  input  wire        CDDCREQ,
  output wire        CDDCDONE,
  // dynamic phase shift
  input  wire        PSCLK,
  input  wire        PSEN,
  input  wire        PSINCDEC,
  output wire        PSDONE,
  // dynamic reconfiguration port
  input  wire        DCLK,
  input  wire        DEN,
  input  wire        DWE,
  input  wire [6:0]  DADDR,
  input  wire [15:0] DI,
  output wire [15:0] DO,
  output wire        DRDY
);
endmodule

/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
