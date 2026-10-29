# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 pin constraints for the Kria KV260 carrier card.
#
# All user pins are on the PMOD connector J2 (3.3 V, bank HDA); J2 pins 9/10
# are GND, 11/12 are 3.3 V. Each line gives J2 pin -> carrier net -> SOM240_1
# pin, checked against the KV260 carrier schematic (XTP682, pages 6 and 17)
# and the K26 board file - see docs/fpga_kria.md.
#   odd row : 1 UART0 TX, 3 UART0 RX, 5 PB0 (UART1 TX), 7 PB1 (UART1 RX)
#   even row: 2 PA0, 4 PA1, 6 PA2, 8 PA3
# Use a 3.3 V USB-UART adapter: adapter RX <- TX pin, adapter TX -> RX pin,
# and connect GND.

# ---- UART0: console + boot loader -------------------------------------------
set_property PACKAGE_PIN H12 [get_ports uart0_tx_o]   ;# J2.1  HDA11  som240_1_a17
set_property PACKAGE_PIN E10 [get_ports uart0_rx_i]   ;# J2.3  HDA12  som240_1_d20

set_property IOSTANDARD LVCMOS33 [get_ports {uart0_*}]
set_property PULLUP true         [get_ports uart0_rx_i]
# Weak, slow outputs limit the current if a pin is ever wired to another output.
set_property DRIVE 4             [get_ports uart0_tx_o]
set_property SLEW SLOW           [get_ports uart0_tx_o]

# ---- GPIO pads (bidirectional) ----------------------------------------------
set_property PACKAGE_PIN B10 [get_ports {gpioa_io[0]}]   ;# J2.2  HDA15     som240_1_b20  PA0
set_property PACKAGE_PIN E12 [get_ports {gpioa_io[1]}]   ;# J2.4  HDA16_CC  som240_1_b21  PA1
set_property PACKAGE_PIN D11 [get_ports {gpioa_io[2]}]   ;# J2.6  HDA17     som240_1_b22  PA2
set_property PACKAGE_PIN B11 [get_ports {gpioa_io[3]}]   ;# J2.8  HDA18     som240_1_c22  PA3
set_property PACKAGE_PIN D10 [get_ports {gpiob_io[0]}]   ;# J2.5  HDA13     som240_1_d21  PB0 = UART1 TX
set_property PACKAGE_PIN C11 [get_ports {gpiob_io[1]}]   ;# J2.7  HDA14     som240_1_d22  PB1 = UART1 RX

set_property IOSTANDARD LVCMOS33 [get_ports {gpioa_io[*] gpiob_io[*]}]
# Inputs float high (button to GND, idle UART line); 8 mA drives an LED.
set_property PULLUP true         [get_ports {gpioa_io[*] gpiob_io[*]}]
set_property DRIVE 8             [get_ports {gpioa_io[*] gpiob_io[*]}]
set_property SLEW SLOW           [get_ports {gpioa_io[*] gpiob_io[*]}]

# ---- Raspberry Pi camera connector J9: control signals --------------------------
# RPI_ENABLE (camera power enable) and the PL I2C bus, which goes through the
# TCA9546A I2C switch (address 0x74, channel 2 = camera). See docs/camera_kv260.md.
set_property PACKAGE_PIN F11 [get_ports cam_en_io]    ;# HDA09     som240_1_a15  RPI_ENABLE (PA7)
set_property PACKAGE_PIN G11 [get_ports i2c_scl_io]   ;# HDA00_CC  som240_1_d16  -> TCA9546A SCL
set_property PACKAGE_PIN F10 [get_ports i2c_sda_io]   ;# HDA01     som240_1_d17  -> TCA9546A SDA

set_property IOSTANDARD LVCMOS33 [get_ports {cam_en_io i2c_scl_io i2c_sda_io}]
set_property DRIVE 4             [get_ports {cam_en_io i2c_scl_io i2c_sda_io}]
set_property SLEW SLOW           [get_ports {cam_en_io i2c_scl_io i2c_sda_io}]
# The board has I2C pull-ups; the weak internal ones only keep the lines high
# when nothing is connected. The camera stays off while PA7 is an input.
set_property PULLUP true         [get_ports {i2c_scl_io i2c_sda_io}]
set_property PULLDOWN true       [get_ports cam_en_io]

# ---- SOM fan ------------------------------------------------------------------
set_property PACKAGE_PIN A12      [get_ports fan_en_b]
set_property IOSTANDARD LVCMOS33  [get_ports fan_en_b]
set_property SLEW SLOW            [get_ports fan_en_b]
set_property DRIVE 4              [get_ports fan_en_b]

# ---- Timing ---------------------------------------------------------------------
# pl_clk0 is constrained by the Zynq UltraScale+ PS IP; the 50 MHz SoC clock
# out of BUFGCE_DIV is derived automatically.
# UART and GPIO pins are asynchronous and synchronised inside the SoC.
set_false_path -from [get_ports {uart0_rx_i gpioa_io[*] gpiob_io[*] cam_en_io i2c_scl_io i2c_sda_io}]
set_false_path -to   [get_ports {uart0_tx_o gpioa_io[*] gpiob_io[*] cam_en_io i2c_scl_io i2c_sda_io fan_en_b}]

# ---- Bitstream ------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
