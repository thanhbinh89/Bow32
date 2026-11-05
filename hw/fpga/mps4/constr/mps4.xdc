# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 pin and timing constraints for the Arm MPS4 (HBI0376B,
# xcvu13p-fhga2104-1-e). Balls and nets from
# docs/fpga/MPS4/hpi0376b_FPGA_ALL_PINS.xlsx (MPS4 rev B pinout, V9); the
# trailing comment of each pin line is the board net and its bank.
# The DDR2 pads are in constr/ddr_loopback.xdc or constr/ddr_card.xdc
# (tcl/build.tcl adds one of them, DDR_LOOPBACK=1/0).

# ---- Clock: OSCCLKA[2] = OSC2 of sdcard/bow32.txt, 100 MHz ----------------------
set_property PACKAGE_PIN AW23    [get_ports osc_clk_i]       ;# OSCCLKA<2>     bank 64 (GC)
set_property IOSTANDARD LVCMOS18 [get_ports osc_clk_i]

# ---- Resets from the MCC ----------------------------------------------------------
# IOFPGA_nRST holds the MMCMs in reset while the MCC configures the board
# and the oscillators; CB_nPOR (cold) and CB_nRST (warm, released last, MCC
# RESET command) reset the design. The weak pull-ups keep the design running
# if a line is not driven.
set_property PACKAGE_PIN AM12    [get_ports iofpga_nrst_i]   ;# IOFPGA_NRST    bank 67
set_property PACKAGE_PIN AJ13    [get_ports cb_npor_i]       ;# CB_nPOR        bank 67
set_property PACKAGE_PIN AL12    [get_ports cb_nrst_i]       ;# CB_nRST        bank 67
set_property IOSTANDARD LVCMOS18 [get_ports {iofpga_nrst_i cb_npor_i cb_nrst_i}]
set_property PULLUP true         [get_ports {iofpga_nrst_i cb_npor_i cb_nrst_i}]

# ---- UARTs: FT4232H on the USB-C debug port (port 0 = MCC) ------------------------
# Routing of the MCC with config.txt UARTMODE: 0, measured on the board (the
# _F names are seen from the FPGA): Bow32 UART0 (console, boot loader) on
# FPGA UART0 = FT4232H port 1 (Linux: /dev/serial/by-id/usb-FTDI_..._<serial>-
# if01-port0); PB0/PB1 (UART1 after reset) on FPGA UART2 = port 2 (-if02-).
# FPGA UART1 (AW8 / AV9) reaches no port in this mode.
set_property PACKAGE_PIN AW7     [get_ports uart0_tx_o]      ;# UART_TX_F<0>   bank 66
set_property PACKAGE_PIN AV8     [get_ports uart0_rx_i]      ;# UART_RX_F<0>   bank 66
set_property PACKAGE_PIN AY7     [get_ports uart1_tx_io]     ;# UART_TX_F<2>   bank 66  PB0
set_property PACKAGE_PIN BB7     [get_ports uart1_rx_i]      ;# UART_RX_F<2>   bank 66  PB1
set_property IOSTANDARD LVCMOS18 [get_ports {uart0_tx_o uart0_rx_i uart1_tx_io uart1_rx_i}]
set_property PULLUP true         [get_ports {uart0_rx_i uart1_tx_io uart1_rx_i}]
set_property DRIVE 4             [get_ports {uart0_tx_o uart1_tx_io}]
set_property SLEW SLOW           [get_ports {uart0_tx_o uart1_tx_io}]

# ---- User LEDs (active low): PA0..PA7, heartbeat, DDR clocks locked ---------------
set_property PACKAGE_PIN B7      [get_ports {led_n_o[0]}]    ;# USER_nLED<0>   bank 73  PA0
set_property PACKAGE_PIN B8      [get_ports {led_n_o[1]}]    ;# USER_nLED<1>   bank 73  PA1
set_property PACKAGE_PIN B10     [get_ports {led_n_o[2]}]    ;# USER_nLED<2>   bank 73  PA2
set_property PACKAGE_PIN B11     [get_ports {led_n_o[3]}]    ;# USER_nLED<3>   bank 73  PA3
set_property PACKAGE_PIN B12     [get_ports {led_n_o[4]}]    ;# USER_nLED<4>   bank 73  PA4
set_property PACKAGE_PIN B13     [get_ports {led_n_o[5]}]    ;# USER_nLED<5>   bank 73  PA5
set_property PACKAGE_PIN B15     [get_ports {led_n_o[6]}]    ;# USER_nLED<6>   bank 73  PA6
set_property PACKAGE_PIN B16     [get_ports {led_n_o[7]}]    ;# USER_nLED<7>   bank 73  PA7
set_property PACKAGE_PIN C7      [get_ports {led_n_o[8]}]    ;# USER_nLED<8>   bank 73  heartbeat
set_property PACKAGE_PIN C8      [get_ports {led_n_o[9]}]    ;# USER_nLED<9>   bank 73  MMCMs locked
set_property IOSTANDARD LVCMOS18 [get_ports {led_n_o[*]}]
set_property DRIVE 4             [get_ports {led_n_o[*]}]
set_property SLEW SLOW           [get_ports {led_n_o[*]}]

# ---- Push buttons (active low) and switches (1.2 V bank) --------------------------
set_property PACKAGE_PIN B17     [get_ports {pb_n_i[0]}]     ;# USER_nPB<0>    bank 75  PB2
set_property PACKAGE_PIN A18     [get_ports {pb_n_i[1]}]     ;# USER_nPB<1>    bank 75  PB3
set_property IOSTANDARD LVCMOS18 [get_ports {pb_n_i[*]}]
set_property PACKAGE_PIN K23     [get_ports {sw_i[0]}]       ;# USER_SW<0>     bank 74  PB4
set_property PACKAGE_PIN B22     [get_ports {sw_i[1]}]       ;# USER_SW<1>     bank 74  PB5
set_property PACKAGE_PIN B21     [get_ports {sw_i[2]}]       ;# USER_SW<2>     bank 74  PB6
set_property PACKAGE_PIN J20     [get_ports {sw_i[3]}]       ;# USER_SW<3>     bank 74  PB7
set_property IOSTANDARD LVCMOS12 [get_ports {sw_i[*]}]

# ---- TRM "minimum RTL" tie-offs (Table 3-2) -----------------------------------------
set_property PACKAGE_PIN AP33    [get_ports mmb_idclk_o]     ;# MMB_IDCLK_R    bank 63  low
set_property PACKAGE_PIN AP35    [get_ports mmb_sck_o]       ;# MMB_SCK_R      bank 63  low
set_property PACKAGE_PIN AA14    [get_ports qspi_ncs_o]      ;# QSPI_nCS       bank 72  high
set_property PACKAGE_PIN AA13    [get_ports qspi_sclk_o]     ;# QSPI_SCLK_R    bank 72  low
set_property PACKAGE_PIN AJ12    [get_ports iofpga_syswdt_o] ;# IOFPGA_SYSWDT  bank 67  low
set_property PACKAGE_PIN AK13    [get_ports wdog_rreq_o]     ;# WDOG_RREQ      bank 67  low
set_property PACKAGE_PIN H17     [get_ports smbm_nwait_o]    ;# SMBM_nWAIT     bank 75  high
set_property PACKAGE_PIN D19     [get_ports cfg_dataout_o]   ;# CFG_DATAOUT    bank 75  low
set_property PACKAGE_PIN BD22    [get_ports aud_rst_o]       ;# AUD_RST        bank 64  low
set_property PACKAGE_PIN T13     [get_ports usd_clk_o]       ;# USD_CLK_R      bank 72  low
set_property PACKAGE_PIN C9      [get_ports sh_nrst_o]       ;# SH_nRST        bank 73  low
set_property PACKAGE_PIN B18     [get_ports pex_nperst_o]    ;# PEX_nPERST     bank 75  low
set tie_offs [get_ports {mmb_idclk_o mmb_sck_o qspi_ncs_o qspi_sclk_o iofpga_syswdt_o \
                         wdog_rreq_o smbm_nwait_o cfg_dataout_o aud_rst_o usd_clk_o \
                         sh_nrst_o pex_nperst_o}]
set_property IOSTANDARD LVCMOS18 $tie_offs
set_property DRIVE 4             $tie_offs
set_property SLEW SLOW           $tie_offs

# ---- Clocks --------------------------------------------------------------------------
create_clock -name osc_clk -period 10.000 [get_ports osc_clk_i]
# Names of the MMCM outputs of bow_ddr_clk_xusp (u_clk), see its header:
# MMCM_A = SoC clock, DDR clock (CK), LiteDRAM controller clock (CK / 4) and
# the write phase source (one VCO, fixed phases), MMCM_W = write clocks
# (0 / +90 deg of ddr_wps_clk), MMCM_B = read capture clock (any phase,
# calibrated).
create_generated_clock -name clk_sys     [get_pins u_clk/u_mmcm_a/CLKOUT0]
create_generated_clock -name ddr_clk     [get_pins u_clk/u_mmcm_a/CLKOUT1]
create_generated_clock -name ddr_wps_clk [get_pins u_clk/u_mmcm_a/CLKOUT2]
create_generated_clock -name ddr_sys     [get_pins u_clk/u_mmcm_a/CLKOUT3]
create_generated_clock -name ddr_wclk    [get_pins u_clk/u_mmcm_w/CLKOUT0]
create_generated_clock -name ddr_wclk90  [get_pins u_clk/u_mmcm_w/CLKOUT1]
create_generated_clock -name ddr_rd_clk  [get_pins u_clk/u_mmcm_b/CLKOUT0]

# Periods of the MMCM outputs (tcl/build.tcl checks them against the clocks)
set sys_period     20.000   ;# clk_sys
set ddr_period      7.500   ;# ddr_clk = tCK (ddr_rd_clk, ddr_wclk, ddr_wclk90 alike)
set ddr_sys_period 30.000   ;# ddr_sys = 4 tCK

# Clock domains of the DDR memory system (u_soc/g_ddr.u_ddr, docs/ip/ddr.md):
#   clk_sys      bus side of the window, CSR and register bridges
#   ddr_sys      LiteDRAM controller: native port and Wishbone side of the
#                bridges, DFI to the adapter
#   ddr_clk      DFI adapter, PHY, CK / command / output enable pads, DRAM
#                emulator of the loopback build
#   ddr_rd_clk   read capture (IDDRE1), write side of the PHY's read FIFO
#   ddr_wclk(90) DQS / DQ / DM ODDRE1 only, fed by PHY registers (ddr_clk)
# The exceptions below cover the asynchronous pairs; every other pair with
# paths (ddr_sys <-> ddr_clk, ddr_clk -> write clocks) is timed as
# synchronous.

# SoC <-> DDR (clk_sys <-> ddr_sys, ddr_clk, ddr_rd_clk), asynchronous: every
# path goes through a CDC of bow_ddr (4-phase request / acknowledge with
# quasi-static payloads and results: window and CSR bridges to the
# controller, register channel to the PHY; bow_sync levels, bow_rst_sync).
# The SoC and the DDR logic sit in different SLRs, so instead of clock groups
# (which would leave these routes untimed) every path gets a data path limit
# of at most one destination period: a payload then always arrives before
# the synchronised request / acknowledge that releases it (two destination
# cycles). Limits: one CK period between clk_sys and the CK clocks, the
# faster period of the two clocks (clk_sys, 20 ns) between clk_sys and
# ddr_sys. The write clocks have no path to clk_sys.
set_max_delay -datapath_only $ddr_period \
  -from [get_clocks clk_sys] -to [get_clocks {ddr_clk ddr_rd_clk}]
set_max_delay -datapath_only $ddr_period \
  -from [get_clocks {ddr_clk ddr_rd_clk}] -to [get_clocks clk_sys]
set sys_ddr_sys_max [expr {$sys_period < $ddr_sys_period ? $sys_period : $ddr_sys_period}]
set_max_delay -datapath_only $sys_ddr_sys_max -from [get_clocks clk_sys] -to [get_clocks ddr_sys]
set_max_delay -datapath_only $sys_ddr_sys_max -from [get_clocks ddr_sys] -to [get_clocks clk_sys]
set_clock_groups -asynchronous \
  -group [get_clocks clk_sys] \
  -group [get_clocks {ddr_wps_clk ddr_wclk ddr_wclk90}]

# LiteDRAM controller <-> PHY clock (ddr_sys <-> ddr_clk): SYNCHRONOUS, no
# exception. Both come from u_mmcm_a at phase 0 (CLKOUT3 = CLKOUT1 / 4), every
# ddr_sys rising edge is a ddr_clk rising edge: Vivado times the DFI between
# LiteDRAM and bow_ddr_dfi (commands, write data, read data, the phase
# toggle) at the closest edge pair (setup 7.5 ns, hold 0). tcl/build.tcl
# checks that these paths exist and carry no exception.

# Read capture clock <-> ddr_clk / ddr_sys: the read phase is moved at run
# time (up to two CK periods either way), so the synchronous analysis of
# these clocks means nothing. The paths are the read FIFO of bow_ddr_phy
# (u_rfifo, bow_fifo_async ddr_rd_clk -> ddr_clk: dual clock RAM and gray
# pointers), its overflow flag (bow_sync) and the reset synchronisers of the
# link reset and the RFIFO_SYNC flush; ddr_sys has no path to ddr_rd_clk
# other than reset synchronisers. A data path limit of one CK period, and a
# bus skew limit on the gray pointers (one source period). The read FIFO is
# found by name below the DDR instance (the PHY's own instance path is left
# open).
set_max_delay -datapath_only $ddr_period \
  -from [get_clocks ddr_rd_clk] -to [get_clocks {ddr_clk ddr_sys}]
set_max_delay -datapath_only $ddr_period \
  -from [get_clocks {ddr_clk ddr_sys}] -to [get_clocks ddr_rd_clk]
set rfifo {NAME =~ u_soc/g_ddr.u_ddr/*u_rfifo}
set_bus_skew -from [get_cells -hierarchical -filter "$rfifo/wgray_q_reg*"] \
             -to   [get_cells -hierarchical -filter "$rfifo/wgray_r1_q_reg*"] [expr {$ddr_period - 0.07}]
set_bus_skew -from [get_cells -hierarchical -filter "$rfifo/rgray_q_reg*"] \
             -to   [get_cells -hierarchical -filter "$rfifo/rgray_w1_q_reg*"] [expr {$ddr_period - 0.07}]

# Write phase (WPS): the write clocks move by up to +-T/4 against ddr_clk.
# The extra uncertainty makes setup and hold of the PHY -> ODDR paths hold
# over that range: DQ/DM (C = ~ddr_wclk90, nominal 3T/4) need a path delay
# below T/2, DQS (C = ddr_wclk, nominal T) between T/4 and 3T/4. Only PHY
# registers (ddr_clk) feed these ODDRs; tcl/build.tcl checks that no path
# comes from ddr_sys.
set_clock_uncertainty [expr {$ddr_period / 4}] \
  -from [get_clocks ddr_clk] -to [get_clocks {ddr_wclk ddr_wclk90}]

# ---- Asynchronous board I/O --------------------------------------------------------------
# UART, GPIO pins and resets are synchronised inside the SoC (bow_rstmgr,
# bow_sync) or go straight to the MMCM reset.
set_false_path -from [get_ports {iofpga_nrst_i cb_npor_i cb_nrst_i uart0_rx_i uart1_tx_io uart1_rx_i \
                                 pb_n_i[*] sw_i[*]}]
set_false_path -to   [get_ports {uart0_tx_o uart1_tx_io led_n_o[*]}]
set_false_path -to   $tie_offs

# ---- DDR2 pads (pins in ddr_loopback.xdc / ddr_card.xdc) --------------------------------
# Read data: IDDRE1 on ddr_rd_clk, the capture phase is calibrated at run time.
set_false_path -from [get_ports {ddr_dq_io[*] ddr_dqs_p_io ddr_dqs_n_io}]
# Outputs: each pin is driven by an ODDRE1 in its I/O tile (the timing between
# the pins is fixed by the I/O column), the level shifter pins are static in
# a loopback build. Output enables of DQ/DQS: ddr_card.xdc.
set_false_path -to [get_ports {ddr_ck_* ddr_cke_o ddr_cs_n_o ddr_ras_n_o ddr_cas_n_o ddr_we_n_o \
                               ddr_ba_o[*] ddr_a_o[*] ddr_odt_o ddr_ls_*}]

# ---- Bitstream -------------------------------------------------------------------------------
# Compressed: smaller file on the microSD card, faster load by the MCC.
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
