# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 pin constraints for the Kria KV260 carrier card.
#
# The four UART signals use the PMOD connector J2 (3.3 V, bank HDA). The
# package pins below are those of PMOD_tri_io[0..3] in AMD's KV260 reference
# designs. BEFORE wiring anything, check the J2 pin numbers against UG1089
# (KV260 user guide, PMOD table) or the carrier schematic - see
# docs/fpga_kria.md. Use a 3.3 V USB-UART adapter: adapter RX <- uart*_tx_o,
# adapter TX -> uart*_rx_i, and connect GND.

# ---- UART0: console + boot loader -------------------------------------------
set_property PACKAGE_PIN H12 [get_ports uart0_tx_o]   ;# PMOD_tri_io[0]
set_property PACKAGE_PIN E10 [get_ports uart0_rx_i]   ;# PMOD_tri_io[1]

# ---- UART1 -------------------------------------------------------------------
set_property PACKAGE_PIN D10 [get_ports uart1_tx_o]   ;# PMOD_tri_io[2]
set_property PACKAGE_PIN C11 [get_ports uart1_rx_i]   ;# PMOD_tri_io[3]

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
