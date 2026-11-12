// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Port-only stubs of the AMD primitives that the Versal board level RTL instantiates
// (bow_dphy_io_versal, the Huins camera and RAM card tops, their clock modules, the DDR /
// HyperRAM pads and clocks), for the Verilator lint of `make lint`; with
// xilinx_xusp_stubs.sv also the UltraScale+ board level RTL (the primitives of both
// families are here: BUFG, BUFGCE, IBUFDS, IBUF, OBUF, OBUFT, OBUFDS, IOBUF, IDDRE1,
// ODDRE1, IBUFDS_DPHY). Lint only: no behaviour, every output is left undriven. Ports
// (names, directions, widths) follow the primitive port tables of AMD's Versal libraries
// guide (UG1353), its UltraScale guide (UG974) and the SelectIO / XPHY architecture manual
// (AM010); the parameters are only those the Bow32 RTL sets, with neutral defaults. The
// vendor simulation models stay in the Vivado installation (the xsim tests in
// hw/fpga/common/dv use them).

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

// ---------------------------------------------------------------- clock buffers, pads
module BUFG (
  input  wire I,
  output wire O
);
endmodule

module BUFGCE #(
  parameter CE_TYPE    = "SYNC",
  parameter SIM_DEVICE = ""
) (
  input  wire I,
  input  wire CE,
  output wire O
);
endmodule

module IBUFDS (
  input  wire I,
  input  wire IB,
  output wire O
);
endmodule

module IBUF (
  input  wire I,
  output wire O
);
endmodule

module OBUF (
  input  wire I,
  output wire O
);
endmodule

module OBUFT (
  input  wire I,
  input  wire T,
  output wire O
);
endmodule

module OBUFDS (
  input  wire I,
  output wire O,
  output wire OB
);
endmodule

module IOBUF (
  input  wire I,
  input  wire T,
  output wire O,
  inout  wire IO
);
endmodule

module IDDRE1 #(
  parameter       DDR_CLK_EDGE   = "OPPOSITE_EDGE",
  parameter [0:0] IS_C_INVERTED  = 1'b0,
  parameter [0:0] IS_CB_INVERTED = 1'b0
) (
  input  wire C,
  input  wire CB,
  input  wire D,
  input  wire R,
  output wire Q1,
  output wire Q2
);
endmodule

module ODDRE1 #(
  parameter       SIM_DEVICE    = "",
  parameter [0:0] SRVAL         = 1'b0,
  parameter [0:0] IS_C_INVERTED = 1'b0
) (
  input  wire C,
  input  wire D1,
  input  wire D2,
  input  wire SR,
  output wire Q
);
endmodule

// MIPI D-PHY input buffer: HS receiver output to the XPHY (Versal) / to the IDELAYE3 or the
// clock buffers (UltraScale+), LP receivers to the fabric
module IBUFDS_DPHY #(
  parameter IOSTANDARD = "DEFAULT",
  parameter SIM_DEVICE = ""
) (
  input  wire I,
  input  wire IB,
  input  wire HSRX_DISABLE,
  input  wire LPRX_DISABLE,
  output wire HSRX_O,
  output wire LPRX_O_P,
  output wire LPRX_O_N
);
endmodule

// ---------------------------------------------------------------- clock managers
module MMCME5 #(
  parameter              BANDWIDTH          = "OPTIMIZED",
  parameter real         CLKIN1_PERIOD      = 0.0,
  parameter integer      DIVCLK_DIVIDE      = 1,
  parameter integer      CLKFBOUT_MULT      = 1,
  parameter integer      CLKFBOUT_FRACT     = 0,
  parameter real         CLKFBOUT_PHASE     = 0.0,
  parameter integer      CLKOUT0_DIVIDE     = 1,
  parameter real         CLKOUT0_PHASE      = 0.0,
  parameter real         CLKOUT0_DUTY_CYCLE = 0.5,
  parameter [1:0]        CLKOUT0_PHASE_CTRL = 2'b00,
  parameter integer      CLKOUT1_DIVIDE     = 1,
  parameter real         CLKOUT1_PHASE      = 0.0,
  parameter real         CLKOUT1_DUTY_CYCLE = 0.5,
  parameter [1:0]        CLKOUT1_PHASE_CTRL = 2'b00,
  parameter integer      CLKOUT2_DIVIDE     = 1,
  parameter real         CLKOUT2_PHASE      = 0.0,
  parameter real         CLKOUT2_DUTY_CYCLE = 0.5,
  parameter [1:0]        CLKOUT2_PHASE_CTRL = 2'b00,
  parameter integer      CLKOUT3_DIVIDE     = 1,
  parameter real         CLKOUT3_PHASE      = 0.0,
  parameter real         CLKOUT3_DUTY_CYCLE = 0.5,
  parameter [1:0]        CLKOUT3_PHASE_CTRL = 2'b00,
  parameter integer      CLKOUT4_DIVIDE     = 1,
  parameter real         CLKOUT4_PHASE      = 0.0,
  parameter real         CLKOUT4_DUTY_CYCLE = 0.5,
  parameter [1:0]        CLKOUT4_PHASE_CTRL = 2'b00,
  parameter              COMPENSATION       = "AUTO",
  parameter              LOCK_WAIT          = "FALSE"
) (
  // clock inputs and feedback
  input  wire        CLKIN1,
  input  wire        CLKIN2,
  input  wire        CLKINSEL,
  input  wire        CLKFBIN,
  output wire        CLKFBOUT,
  output wire        CLKOUT0,
  output wire        CLKOUT1,
  output wire        CLKOUT2,
  output wire        CLKOUT3,
  output wire        CLKOUT4,
  output wire        CLKOUT5,
  output wire        CLKOUT6,
  // status and control
  input  wire        RST,
  input  wire        PWRDWN,
  output wire        LOCKED,
  output wire        LOCKED1_DESKEW,
  output wire        LOCKED2_DESKEW,
  output wire        LOCKED_FB,
  output wire        CLKFBSTOPPED,
  output wire        CLKINSTOPPED,
  // deskew
  input  wire        CLKIN1_DESKEW,
  input  wire        CLKFB1_DESKEW,
  input  wire        CLKIN2_DESKEW,
  input  wire        CLKFB2_DESKEW,
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

// XPIO PLL: CLKOUTPHY to the XPHYs of its bank
module XPLL #(
  parameter real    CLKIN_PERIOD     = 0.0,
  parameter integer CLKFBOUT_MULT    = 1,
  parameter integer DIVCLK_DIVIDE    = 1,
  parameter         CLKOUTPHY_DIVIDE = "DIV8",
  parameter integer CLKOUT0_DIVIDE   = 2,
  parameter integer CLKOUT1_DIVIDE   = 2,
  parameter integer CLKOUT2_DIVIDE   = 2,
  parameter integer CLKOUT3_DIVIDE   = 2,
  parameter real    REF_JITTER       = 0.0
) (
  // clocks
  input  wire        CLKIN,
  input  wire        CLKOUTPHYEN,
  output wire        CLKOUTPHY,
  output wire        CLKOUT0,
  output wire        CLKOUT1,
  output wire        CLKOUT2,
  output wire        CLKOUT3,
  input  wire        CLKOUTPHY_CASC_IN,
  output wire        CLKOUTPHY_CASC_OUT,
  // status and control
  input  wire        RST,
  input  wire        PWRDWN,
  output wire        LOCKED,
  output wire        LOCKED_FB,
  output wire        LOCKED1_DESKEW,
  output wire        LOCKED2_DESKEW,
  // deskew
  input  wire        CLKIN1_DESKEW,
  input  wire        CLKFB1_DESKEW,
  input  wire        CLKIN2_DESKEW,
  input  wire        CLKFB2_DESKEW,
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
  output wire        DRDY,
  // register interface unit
  input  wire        RIU_CLK,
  input  wire        RIU_NIBBLE_SEL,
  input  wire [7:0]  RIU_ADDR,
  input  wire [15:0] RIU_WR_DATA,
  input  wire        RIU_WR_EN,
  output wire [15:0] RIU_RD_DATA,
  output wire        RIU_VALID
);
endmodule

// ---------------------------------------------------------------- XPHY (one nibble, 6 slices)
module XPHY #(
  // receive and strobe
  parameter         SERIAL_MODE            = "FALSE",
  parameter         DQS_SRC                = "LOCAL",
  parameter         DQS_MODE               = "DDR4_1TCK",
  parameter         CONTINUOUS_DQS         = "FALSE",
  parameter         RX_GATING              = "DISABLE",
  parameter integer RX_DATA_WIDTH          = 8,
  parameter         RX_CLK_PHASE_P         = "SHIFT_0",
  parameter         RX_CLK_PHASE_N         = "SHIFT_0",
  parameter         INV_RXCLK              = "FALSE",
  parameter         CRSE_DLY_EN            = "FALSE",
  parameter         SELF_CALIBRATE         = "ENABLE",
  parameter real    REFCLK_FREQUENCY       = 0.0,
  parameter         EN_CLK_TO_UPPER        = "DISABLE",
  parameter         EN_CLK_TO_LOWER        = "DISABLE",
  parameter         EN_OTHER_PCLK          = "FALSE",
  parameter         EN_OTHER_NCLK          = "FALSE",
  parameter         EN_DYN_DLY_MODE        = "FALSE",
  parameter         FAST_CK                = "FALSE",
  parameter         LP4_DQS                = "FALSE",
  parameter         WRITE_LEVELING         = "FALSE",
  parameter [0:0]   PRIME_VAL              = 1'b0,
  // delays and VT tracking
  parameter         DIS_IDLY_VT_TRACK      = "FALSE",
  parameter         DIS_ODLY_VT_TRACK      = "FALSE",
  parameter         DIS_QDLY_VT_TRACK      = "FALSE",
  parameter integer DELAY_VALUE_0          = 0,
  parameter integer DELAY_VALUE_1          = 0,
  parameter integer DELAY_VALUE_2          = 0,
  parameter integer DELAY_VALUE_3          = 0,
  parameter integer DELAY_VALUE_4          = 0,
  parameter integer DELAY_VALUE_5          = 0,
  parameter         CASCADE_0              = "FALSE",
  parameter         CASCADE_1              = "FALSE",
  parameter         CASCADE_2              = "FALSE",
  parameter         CASCADE_3              = "FALSE",
  parameter         CASCADE_4              = "FALSE",
  parameter         CASCADE_5              = "FALSE",
  // per slice
  parameter         FIFO_MODE_0            = "BYPASS",
  parameter         FIFO_MODE_1            = "BYPASS",
  parameter         FIFO_MODE_2            = "BYPASS",
  parameter         FIFO_MODE_3            = "BYPASS",
  parameter         FIFO_MODE_4            = "BYPASS",
  parameter         FIFO_MODE_5            = "BYPASS",
  parameter         IBUF_DIS_SRC_0         = "EXTERNAL",
  parameter         IBUF_DIS_SRC_1         = "EXTERNAL",
  parameter         IBUF_DIS_SRC_2         = "EXTERNAL",
  parameter         IBUF_DIS_SRC_3         = "EXTERNAL",
  parameter         IBUF_DIS_SRC_4         = "EXTERNAL",
  parameter         IBUF_DIS_SRC_5         = "EXTERNAL",
  parameter         ODT_SRC_0              = "EXTERNAL",
  parameter         ODT_SRC_1              = "EXTERNAL",
  parameter         ODT_SRC_2              = "EXTERNAL",
  parameter         ODT_SRC_3              = "EXTERNAL",
  parameter         ODT_SRC_4              = "EXTERNAL",
  parameter         ODT_SRC_5              = "EXTERNAL",
  parameter         ODELAY_BYPASS_0        = "FALSE",
  parameter         ODELAY_BYPASS_1        = "FALSE",
  parameter         ODELAY_BYPASS_2        = "FALSE",
  parameter         ODELAY_BYPASS_3        = "FALSE",
  parameter         ODELAY_BYPASS_4        = "FALSE",
  parameter         ODELAY_BYPASS_5        = "FALSE",
  parameter         TBYTE_CTL_0            = "T",
  parameter         TBYTE_CTL_1            = "T",
  parameter         TBYTE_CTL_2            = "T",
  parameter         TBYTE_CTL_3            = "T",
  parameter         TBYTE_CTL_4            = "T",
  parameter         TBYTE_CTL_5            = "T",
  parameter         TXRX_LOOPBACK_0        = "FALSE",
  parameter         TXRX_LOOPBACK_1        = "FALSE",
  parameter         TXRX_LOOPBACK_2        = "FALSE",
  parameter         TXRX_LOOPBACK_3        = "FALSE",
  parameter         TXRX_LOOPBACK_4        = "FALSE",
  parameter         TXRX_LOOPBACK_5        = "FALSE",
  // transmit
  parameter integer TX_DATA_WIDTH          = 8,
  parameter         TX_GATING              = "DISABLE",
  parameter [0:0]   TX_INIT_0              = 1'b0,
  parameter [0:0]   TX_INIT_1              = 1'b0,
  parameter [0:0]   TX_INIT_2              = 1'b0,
  parameter [0:0]   TX_INIT_3              = 1'b0,
  parameter [0:0]   TX_INIT_4              = 1'b0,
  parameter [0:0]   TX_INIT_5              = 1'b0,
  parameter [0:0]   TX_INIT_TRI            = 1'b1,
  parameter         TX_OUTPUT_PHASE_90_0   = "FALSE",
  parameter         TX_OUTPUT_PHASE_90_1   = "FALSE",
  parameter         TX_OUTPUT_PHASE_90_2   = "FALSE",
  parameter         TX_OUTPUT_PHASE_90_3   = "FALSE",
  parameter         TX_OUTPUT_PHASE_90_4   = "FALSE",
  parameter         TX_OUTPUT_PHASE_90_5   = "FALSE",
  parameter         TX_OUTPUT_PHASE_90_TRI = "FALSE"
) (
  // clocks
  input  wire        PLL_CLK,
  input  wire        CTRL_CLK,
  input  wire        FIFO_RD_CLK,
  output wire        FIFO_WR_CLK,
  // resets, calibration, status
  input  wire        RST,
  input  wire [5:0]  RX_RST,
  input  wire [5:0]  TX_RST,
  input  wire        EN_VTC,
  input  wire [5:0]  RX_EN_VTC,
  input  wire [5:0]  TX_EN_VTC,
  output wire        DLY_RDY,
  output wire        PHY_RDY,
  input  wire        BISC_START_IN,
  output wire        BISC_START_OUT,
  input  wire        BISC_STOP_IN,
  output wire        BISC_STOP_OUT,
  // strobe forwarding between nibbles
  input  wire        CLK_FROM_OTHER_XPHY,
  output wire        CLK_TO_UPPER,
  output wire        CLK_TO_LOWER,
  input  wire        PCLK_NIBBLE_IN,
  input  wire        NCLK_NIBBLE_IN,
  output wire        PCLK_NIBBLE_OUT,
  output wire        NCLK_NIBBLE_OUT,
  // receive data
  input  wire [5:0]  DATAIN,
  input  wire        FIFO_RDEN,
  output wire        FIFO_EMPTY,
  input  wire [3:0]  PHY_RDEN,
  output wire [7:0]  Q0,
  output wire [7:0]  Q1,
  output wire [7:0]  Q2,
  output wire [7:0]  Q3,
  output wire [7:0]  Q4,
  output wire [7:0]  Q5,
  // delays (CTRL_CLK)
  input  wire [5:0]  CE,
  input  wire [5:0]  INC,
  input  wire [5:0]  LD,
  input  wire [5:0]  RXTX_SEL,
  input  wire [53:0] CNTVALUEIN,
  output wire [53:0] CNTVALUEOUT,
  // transmit
  input  wire [7:0]  D0,
  input  wire [7:0]  D1,
  input  wire [7:0]  D2,
  input  wire [7:0]  D3,
  input  wire [7:0]  D4,
  input  wire [7:0]  D5,
  input  wire [5:0]  T,
  output wire [5:0]  O0,
  output wire [5:0]  T_OUT,
  input  wire [3:0]  PHY_WREN,
  input  wire [3:0]  PHY_RDCS0,
  input  wire [3:0]  PHY_RDCS1,
  input  wire [3:0]  PHY_WRCS0,
  input  wire [3:0]  PHY_WRCS1,
  output wire        GT_STATUS,
  output wire [5:0]  IBUF_DISABLE,
  output wire [5:0]  DYN_DCI,
  // register interface unit
  input  wire        RIU_NIBBLE_SEL,
  input  wire [7:0]  RIU_ADDR,
  input  wire [15:0] RIU_WR_DATA,
  input  wire        RIU_WR_EN,
  output wire [15:0] RIU_RD_DATA,
  output wire        RIU_RD_VALID
);
endmodule

/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
