# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Clock input CLK_SRC = ref200 (default): the fixed 200 MHz MEMS oscillator of
# the Huins main board (Microchip DSC1123, LVDS) through a CDCLVD1204 buffer to
# the C2_DDR4_SYS_CLK pair of XPIO bank 718 (VCCO = DDR4 VDDQ, 1.2 V).
# Main-board switch SW12 must be OFF (oscillator, not the U.FL input).
# tcl/build.tcl sets the MMCM input to 5 ns (VCO = 200 MHz x 16).
#
# The board AC-couples the pair (100 nF), puts 100 ohm across it and biases
# each leg with 6.81k to VCC_RDIMM and 2k to GND (~0.27 V). The input is a
# differential SSTL receiver of the bank's VCCO with its on-die termination
# kept at 40 ohm (the DIFF_SSTL12 default, set explicitly here): with the
# board network it brings the common mode to ~0.53 V, near the SSTL12 Vref of
# 0.6 V, and leaves ~110..230 mV of differential swing (receiver threshold
# 100 mV). RTT_NONE would leave the common mode at the board's ~0.27 V.
# Measured on the board 2026-11-09: MMCMs locked, SoC clock 50 MHz.
set_property IOSTANDARD DIFF_SSTL12 [get_ports {clk_p_i clk_n_i}]
set_property ODT RTT_40 [get_ports {clk_p_i clk_n_i}]
create_clock -name clk_in -period 5.000 [get_ports clk_p_i]
