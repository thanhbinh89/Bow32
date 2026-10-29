# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Camera build of Bow32 on the KV260: MIPI CSI-2 pins of the Raspberry Pi
# camera connector J9 and the clocks of the block design. The other pins are
# in ../kv260/constr/kv260.xdc (added to the same project).

# ---- MIPI CSI-2 D-PHY, connector J9 (bank 66, 2 data lanes) ---------------------
# Same pins as AMD's KV260 platforms (port mipi_phy_if_raspi). Older Vivado
# versions also set them from the IP parameters (tcl/cam_bd.tcl).
set_property PACKAGE_PIN D7 [get_ports mipi_phy_if_raspi_clk_p]
set_property PACKAGE_PIN D6 [get_ports mipi_phy_if_raspi_clk_n]
set_property PACKAGE_PIN E5 [get_ports {mipi_phy_if_raspi_data_p[0]}]
set_property PACKAGE_PIN D5 [get_ports {mipi_phy_if_raspi_data_n[0]}]
set_property PACKAGE_PIN G6 [get_ports {mipi_phy_if_raspi_data_p[1]}]
set_property PACKAGE_PIN F6 [get_ports {mipi_phy_if_raspi_data_n[1]}]

set_property IOSTANDARD MIPI_DPHY_DCI [get_ports {mipi_phy_if_raspi_clk_* mipi_phy_if_raspi_data_*}]
set_property DIFF_TERM_ADV TERM_100   [get_ports {mipi_phy_if_raspi_clk_* mipi_phy_if_raspi_data_*}]

# ---- Clocks -------------------------------------------------------------------------
# clk_sys (50 MHz) and clk_vid (200 MHz) both come from the MMCM of the block
# design, but every path between them goes through a synchroniser or a dual
# clock RAM inside the ISP (bow_cdc_pulse, bow_sync, quasi-static
# configuration registers): treat them as unrelated clocks.
set_clock_groups -asynchronous \
  -group [get_clocks -of_objects [get_nets clk_sys]] \
  -group [get_clocks -of_objects [get_nets clk_vid]]
