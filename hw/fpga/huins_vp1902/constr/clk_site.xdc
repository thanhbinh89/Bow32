# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Clock input CLK_SRC = site (NOT USABLE YET: tcl/build.tcl refuses it): the PL
# clock of the FMC+ site (FMC+10: clock module output CLK0 through a
# CDCUN1208LP buffer, which also feeds FMC+01), a GC pair in a bank of the site
# (FMC+10: bank 710, VADJ 1.5 V). The board only AC-couples it (10 nF, no
# termination, no bias), so the input needs LVDS15 with the internal 100 ohm
# termination AND an internal DC bias. The bias is the open item: DQS_BIAS of
# UltraScale+ does not exist for LVDS15 on Versal (PORTPROP-6); DC_BIAS_0 below
# is the tool default and means no bias (AM010), the code that biases an
# AC-coupled LVDS15 input is not determined yet. Also the clock module is set
# to 16 MHz by the FPGA team (2026-11-09), while this file and tcl/build.tcl
# assume 100 MHz (main-board DIP SW209 1 OFF, 2 OFF, 3 ON = LVDS, 4 OFF; clock
# module CLK0: SW3-3 ON = PLL, M = 100, N = 3).
set_property IOSTANDARD LVDS15 [get_ports {clk_p_i clk_n_i}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {clk_p_i clk_n_i}]
set_property DC_BIAS DC_BIAS_0 [get_ports {clk_p_i clk_n_i}]
create_clock -name clk_in -period 10.000 [get_ports clk_p_i]
