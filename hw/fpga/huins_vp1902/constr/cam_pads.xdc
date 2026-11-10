# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Camera pads of the Huins camera build (CARD=cam, bow32_huins_vp1902_cam_top): the
# Leopard LI-IMX274MIPI-FMC module on the Huins camera adapter on FMC+01. Every camera pin
# is in XPIO bank 705, PRSNT_M2C_L in bank 703; banks 703..706 run on the site VCCIO of
# FMC+01 (slide switch SW192), which must be at 1.2 V: MIPI_DPHY exists only with VCCO
# 1.2 V on XPIO, and LVCMOS12 (control pins) needs the same (docs/camera_huins.md).
# PACKAGE_PIN lines: generated (tools/huins_pins.py, constr/pins.txt [card=cam]).

# ---- MIPI D-PHY: clock lane + 4 data lanes (IBUFDS_DPHY of bow_dphy_io_versal) ----------
# 100 ohm termination (switched with the HS receiver by HSRX_DISABLE), receiver
# equalisation and offset control as AMD's D-PHY on Versal.
set mipi_ports [get_ports {mipi_clk_p_i mipi_clk_n_i mipi_data_p_i[*] mipi_data_n_i[*]}]
set_property IOSTANDARD    MIPI_DPHY  $mipi_ports
set_property DIFF_TERM_ADV TERM_100   $mipi_ports
set_property EQUALIZATION  EQ_LEVEL5  $mipi_ports
set_property OFFSET_CNTRL  CNTRL_NONE $mipi_ports

# ---- Sensor control and module present: LVCMOS12 -------------------------------------------
# I2C (open drain, ODDRE1 on I and T in the pad sites): internal pull-ups and 8 mA as AMD's
# camera designs (the module's own pull-ups are unknown: start the bus at 100 kHz).
# PRSNT_M2C_L has a 10k pull-up to the site VCCIO on the board.
set_property IOSTANDARD LVCMOS12 [get_ports {cam_scl_io cam_sda_io cam_xclr_o cam_xce_o cam_flash_o \
                                             fmc_prsnt_n_i}]
set_property DRIVE 8             [get_ports {cam_scl_io cam_sda_io cam_xclr_o cam_xce_o cam_flash_o}]
set_property PULLTYPE PULLUP     [get_ports {cam_scl_io cam_sda_io}]

# ---- Timing ------------------------------------------------------------------------------------
# Data lanes: the XPHYs capture them with the forwarded strobe (BISC aligned, the taps are
# calibrated at run time); the LP receivers of all pins are synchronised in clk_vid. The
# clock lane P pad carries dphy_hs_clk (constr/huins_vp1902_cam.xdc), its LP path is an
# asynchronous clock group crossing.
set_false_path -from [get_ports {mipi_data_p_i[*] mipi_data_n_i[*] mipi_clk_n_i}]
# I2C: SCL / SDA levels go through the controller's synchronisers; the I / T ODDRE1 sit in
# the pad sites (fixed pin timing). XCLR (PA7), XCE and FLASH are static levels.
set_false_path -from [get_ports {cam_scl_io cam_sda_io fmc_prsnt_n_i}]
set_false_path -to   [get_ports {cam_scl_io cam_sda_io cam_xclr_o cam_xce_o cam_flash_o}]
