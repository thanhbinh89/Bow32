# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 pin constraints for the Kria KV260 carrier card.
#
# The four UART signals use the odd pins 1/3/5/7 of the PMOD connector J2
# (3.3 V, bank HDA); J2 pins 9/10 are GND, 11/12 are 3.3 V. Each line below
# gives J2 pin -> carrier net -> SOM240_1 pin, checked against the KV260
# carrier schematic (XTP682, pages 6 and 17) and the K26 board file - see
# docs/fpga_kria.md. Use a 3.3 V USB-UART adapter: adapter RX <- uart*_tx_o,
# adapter TX -> uart*_rx_i, and connect GND.

# ---- UART0: console + boot loader -------------------------------------------
set_property PACKAGE_PIN H12 [get_ports uart0_tx_o]   ;# J2.1  HDA11  som240_1_a17
set_property PACKAGE_PIN E10 [get_ports uart0_rx_i]   ;# J2.3  HDA12  som240_1_d20

# ---- UART1 -------------------------------------------------------------------
set_property PACKAGE_PIN D10 [get_ports uart1_tx_o]   ;# J2.5  HDA13  som240_1_d21
set_property PACKAGE_PIN C11 [get_ports uart1_rx_i]   ;# J2.7  HDA14  som240_1_d22

set_property IOSTANDARD LVCMOS33 [get_ports {uart0_* uart1_*}]
set_property PULLUP true         [get_ports {uart0_rx_i uart1_rx_i}]
# Weak, slow outputs limit the current if a pin is ever wired to another output.
set_property DRIVE 4             [get_ports {uart0_tx_o uart1_tx_o}]
set_property SLEW SLOW           [get_ports {uart0_tx_o uart1_tx_o}]

# ---- SOM fan ------------------------------------------------------------------
set_property PACKAGE_PIN A12      [get_ports fan_en_b]
set_property IOSTANDARD LVCMOS33  [get_ports fan_en_b]
set_property SLEW SLOW            [get_ports fan_en_b]
set_property DRIVE 4              [get_ports fan_en_b]

# ---- Timing ---------------------------------------------------------------------
# pl_clk0 is constrained by the Zynq UltraScale+ PS IP; the 50 MHz SoC clock
# out of BUFGCE_DIV is derived automatically.
# UART pins are asynchronous and synchronised inside the SoC.
set_false_path -from [get_ports {uart0_rx_i uart1_rx_i}]
set_false_path -to   [get_ports {uart0_tx_o uart1_tx_o fan_en_b}]

# ---- Bitstream ------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
