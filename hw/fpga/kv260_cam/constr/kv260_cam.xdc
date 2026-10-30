# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Camera build of Bow32 on the KV260: MIPI D-PHY pins of the Raspberry Pi
# camera connector J9 (bow_dphy_io_xusp, instance u_dphy) and the clocks of
# the CSI-2 receiver. The other pins are in ../kv260/constr/kv260.xdc (added
# to the same project).

# ---- MIPI D-PHY, connector J9 (bank 66, 2 data lanes) ---------------------------
# Same pins as AMD's KV260 platforms. MIPI_DPHY_DCI: HS receiver and LP
# receivers in one IBUFDS_DPHY; the 100 ohm termination is switched together
# with the HS receiver (HSRX_DISABLE).
set_property PACKAGE_PIN D7 [get_ports mipi_phy_if_raspi_clk_p]
set_property PACKAGE_PIN D6 [get_ports mipi_phy_if_raspi_clk_n]
set_property PACKAGE_PIN E5 [get_ports {mipi_phy_if_raspi_data_p[0]}]
set_property PACKAGE_PIN D5 [get_ports {mipi_phy_if_raspi_data_n[0]}]
set_property PACKAGE_PIN G6 [get_ports {mipi_phy_if_raspi_data_p[1]}]
set_property PACKAGE_PIN F6 [get_ports {mipi_phy_if_raspi_data_n[1]}]

set_property IOSTANDARD MIPI_DPHY_DCI [get_ports {mipi_phy_if_raspi_clk_* mipi_phy_if_raspi_data_*}]
set_property DIFF_TERM_ADV TERM_100   [get_ports {mipi_phy_if_raspi_clk_* mipi_phy_if_raspi_data_*}]

# ---- Clocks -------------------------------------------------------------------------
# clk_sys (50 MHz, CPU) and clk_vid (200 MHz, ISP and D-PHY state machines)
# come from the MMCM of the block design. dphy_hs_clk is the HS clock of the
# camera: 912 Mbit/s DDR = 456 MHz. The byte clock (BUFGCE_DIV /4) and the
# internal /4 clock of the ISERDESE3 are derived from it automatically. For
# another lane rate change dphy_hs_period (ns = 2000 / Mbit/s): the bus skew
# limits of the byte clock domain below follow it.
set dphy_hs_period 2.193
create_clock -name dphy_hs_clk -period $dphy_hs_period [get_ports mipi_phy_if_raspi_clk_p]

# Every path between the three groups goes through a synchroniser, a gray
# coded bus or a dual clock RAM (bow_sync, bow_cdc_pulse, bow_fifo_async,
# quasi-static configuration registers). The camera clock group also covers
# the LP receiver of the clock pin (LP levels are synchronised in clk_vid).
set_clock_groups -asynchronous \
  -group [get_clocks -of_objects [get_nets clk_sys]] \
  -group [get_clocks -of_objects [get_nets clk_vid]] \
  -group [get_clocks -include_generated_clocks dphy_hs_clk]

# Data lanes: the capture cannot meet static timing (the clock arrives
# 0.4-1.4 ns after the data over PVT); software calibrates the IDELAY taps at
# run time. The LP receivers of the data pins are synchronised in clk_vid.
set_false_path -from [get_ports {mipi_phy_if_raspi_data_p[*] mipi_phy_if_raspi_data_n[*]}]

# Byte clock gate: CE is a clk_vid flop that only changes while the clock
# lane is static (HS-0), so there is no edge of the HS clock to time it to.
set_false_path -to [get_pins {u_dphy/u_hs_bufg/CE u_dphy/u_byte_bufg/CE}]

# ISERDESE3 CLK (HS clock) and CLKDIV (byte clock) come from two BUFGCE_DIV:
# balance the two clock trees. The nets are found through the buffer output
# pins, which keeps working when synthesis renames them (check clockInfo.txt
# of the implementation run: both nets must be listed in the group).
set_property CLOCK_DELAY_GROUP bow_dphy_rx_clk \
  [get_nets -of_objects [get_pins {u_dphy/u_hs_bufg/O u_dphy/u_byte_bufg/O}]]

# ---- Gray coded buses of the CSI-2 receiver (u_soc/u_csi2rx) ------------------------
# The clock groups do not cover set_bus_skew. A gray coded bus changes one bit
# per source clock cycle, so the skew between its bits must stay below one
# source clock period (byte clock = 4 x dphy_hs_period, clk_vid 5 ns); the
# CPU <-> byte command counters change rarely and get 5 ns. Destinations are
# the first synchroniser flops. Check report_bus_skew: 7 constraints, all met.
set dphy_byte_skew [expr {4 * $dphy_hs_period - 0.07}]
# pixel FIFO (bow_fifo_async): write pointer byte -> vid, read pointer vid -> byte
set_bus_skew -from [get_cells {u_soc/u_csi2rx/u_fifo/wgray_q_reg[*]}] \
             -to   [get_cells {u_soc/u_csi2rx/u_fifo/wgray_r1_q_reg[*]}] $dphy_byte_skew
set_bus_skew -from [get_cells {u_soc/u_csi2rx/u_fifo/rgray_q_reg[*]}] \
             -to   [get_cells {u_soc/u_csi2rx/u_fifo/rgray_w1_q_reg[*]}] 5.0
# byte clock meter, byte -> CPU
set_bus_skew -from [get_cells {u_soc/u_csi2rx/meter_gray_q_reg[*]}] \
             -to   [get_cells {u_soc/u_csi2rx/u_sync_meter/g_bit[*].u_sync/sync_q_reg[0]}] $dphy_byte_skew
# LOG / RAW capture requests (CPU -> byte) and acknowledges (byte -> CPU)
set_bus_skew -from [get_cells {u_soc/u_csi2rx/u_regs/log_req_q_reg[*]}] \
             -to   [get_cells {u_soc/u_csi2rx/u_sync_log_req/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
set_bus_skew -from [get_cells {u_soc/u_csi2rx/u_regs/raw_req_q_reg[*]}] \
             -to   [get_cells {u_soc/u_csi2rx/u_sync_raw_req/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
set_bus_skew -from [get_cells {u_soc/u_csi2rx/u_capture/log_ack_o_reg[*]}] \
             -to   [get_cells {u_soc/u_csi2rx/u_sync_log_ack/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
set_bus_skew -from [get_cells {u_soc/u_csi2rx/u_capture/raw_ack_o_reg[*]}] \
             -to   [get_cells {u_soc/u_csi2rx/u_sync_raw_ack/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
