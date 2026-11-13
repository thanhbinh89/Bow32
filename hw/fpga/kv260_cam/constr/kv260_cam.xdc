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
# quasi-static configuration registers). clk_sys against everything else;
# clk_vid against the HS clock itself, whose source pin also drives the LP
# receiver of the clock pin (LP levels are synchronised in clk_vid). clk_vid and
# the byte clock (BUFGCE_DIV u_dphy/u_byte_bufg, a generated clock of
# dphy_hs_clk) are no clock group: their crossings get the data path limits below.
set_clock_groups -asynchronous \
  -group [get_clocks -of_objects [get_nets clk_sys]] \
  -group [list [get_clocks -of_objects [get_nets clk_vid]] \
               [get_clocks -include_generated_clocks dphy_hs_clk]]
set_clock_groups -asynchronous \
  -group [get_clocks -of_objects [get_nets clk_vid]] \
  -group [get_clocks dphy_hs_clk]

# Byte clock <-> clk_vid (review of step 7, docs/ip/mipi_rx_arch.md section 10): the lane
# merge's two clock FIFO (u_csi2rx/u_lane_merge/u_cdc_fifo, step 7) has a LUTRAM written on
# the byte clock and read through its read register (u_ram/rdata_o_reg) on clk_vid. A clock
# group would leave these RAM -> read register paths unbounded (it takes precedence over
# set_max_delay): every path between the two clocks gets a data path limit of one
# destination period instead, as the DDR / HyperRAM PHY FIFOs of the MPS4 and Huins builds
# have. A word then reaches the read register before the gray write pointer that announces
# it has passed its two synchroniser flops (the gray pointers keep their set_bus_skew
# below); the D-PHY's synchronisers and the CLR pins of the byte clock's reset synchronisers
# get the same limit. ooc/rx_ooc.tcl checks that these paths are timed.
set_max_delay -datapath_only 5.0 \
  -from [get_clocks -of_objects [get_pins u_dphy/u_byte_bufg/O]] \
  -to   [get_clocks -of_objects [get_nets clk_vid]]
set_max_delay -datapath_only [expr {4 * $dphy_hs_period}] \
  -from [get_clocks -of_objects [get_nets clk_vid]] \
  -to   [get_clocks -of_objects [get_pins u_dphy/u_byte_bufg/O]]

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
# command counters between the CPU and the LOG / RAW capture (the LOG on clk_vid since
# step 7, the RAW on the byte clock) change rarely and get 5 ns. Destinations are
# the first synchroniser flops. Check report_bus_skew: 11 constraints of the
# receiver, all met (13 in this file with the H.264 output FIFO).
# The cells are selected by the tail of their hierarchical name, not by their
# full path, so that a constraint follows its flops when the receiver's
# hierarchy changes (docs/ip/mipi_rx_arch.md, section 10, step 1): cells with
# names of their own (byte clock meter, synchronisers) by those names, the
# lane merge's FIFO (the pixel FIFO's crossing up to step 6, docs/ip/mipi_rx_arch.md
# section 10: one clock since step 7, the count stays 13), register file and capture
# flops by their path below u_csi2rx
# (the controller) or u_dphy_rx (the D-PHY's register file and RAW capture,
# step 4). Each tail selects the same cells as the full path it replaced. tcl/build.tcl
# also checks the cells of every constraint
# (hw/fpga/common/tcl/bus_skew_checks.tcl): all in u_soc/u_csi2rx,
# u_soc/u_h264/u_out or the adapter's delay logic u_dphy/u_dly, every
# destination reached from the sources, as many source as destination flops.
set dphy_byte_skew [expr {4 * $dphy_hs_period - 0.07}]
# the lane merge's two clock FIFO (bow_csi2_lane_merge u_cdc_fifo, bow_fifo_async, step 7):
# write pointer byte -> vid, read pointer vid -> byte (up to step 6 the pixel FIFO's)
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_lane_merge/u_cdc_fifo/wgray_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_lane_merge/u_cdc_fifo/wgray_r1_q_reg[*]}] \
             $dphy_byte_skew
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_lane_merge/u_cdc_fifo/rgray_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_lane_merge/u_cdc_fifo/rgray_w1_q_reg[*]}] 5.0
# byte clock meter, byte -> CPU
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */meter_gray_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_meter/g_bit[*].u_sync/sync_q_reg[0]}] \
             $dphy_byte_skew
# LOG / RAW capture requests (CPU -> capture) and acknowledges (capture -> CPU); LOG in the
# controller (u_csi2rx/u_regs, u_csi2rx/u_capture; its capture on clk_vid since step 7, the
# byte clock before), RAW in the D-PHY since step 4 (u_dphy_rx/u_regs, u_dphy_rx/u_raw, byte
# clock)
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_regs/log_req_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_log_req/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/raw_req_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_raw_req/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_capture/log_ack_o_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_log_ack/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_raw/raw_ack_o_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_raw_ack/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
# The D-PHY's event counters (step 6, lp -> CPU): 4 bit gray counters of the lp domain
# (u_dphy_rx/evc_gray_q, clk_vid here), at most one step per lp clock, read by the register
# file through u_sync_evc, which adds their differences to CNT_* / ERR_STATUS / IRQ_STATUS:
# their bits must arrive within one lp clock period of each other
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/evc_gray_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_evc/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
# The D-PHY's configuration (step 6, CPU -> lp; review of step 6): CTRL and TIM0..2 are shadow
# registers of the register file (u_dphy_rx/u_regs) that the lp domain copies (u_dphy_rx/
# cfg_lp_q, one clock enable) two lp cycles after the CMD.APPLY toggle (u_regs/apply_q) reached
# the first flop of its synchroniser (u_dphy_rx/u_sync_apply); the shadow is written at least a
# CPU cycle before the toggle. Every copied bit and the toggle within two lp periods (less a
# setup time) of each other: no bit is still in flight when the copy is taken (the clock groups
# leave these delays unbounded; report_cdc lists them as CDC-15).
set_bus_skew \
  -from [list [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/clk_cont_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/burst_rst_en_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/ulps_en_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/hsrx_early_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/clk_lost_en_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/miss_off_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/settle_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/lp_filter_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/clk_settle_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/clk_miss_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/hs_tmo_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/tog_div_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/tinit_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/esc_tmo_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/apply_q_reg}]] \
  -to   [list [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/cfg_lp_q_reg*}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_sync_apply/sync_q_reg[0]}]] \
  9.5
# CLK_TOG_DIV of the applied configuration (step 6, lp -> byte clock; review of step 6): 4 bits
# of u_dphy_rx/cfg_lp_q, each through a synchroniser of the byte clock domain (u_sync_tdiv);
# quasi-static (they change at an APPLY), a mixed value only makes one toggle period longer or
# shorter: bounded to one byte clock period.
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/cfg_lp_q_reg[tog_div]*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_sync_tdiv/g_bit[*].u_sync/sync_q_reg[0]}] \
             $dphy_byte_skew
# Input delay codes (DLYn CODE and OWN, CPU -> byte clock): the AFE's dly_code / dly_own,
# static levels of the D-PHY's register file (u_dphy_rx/u_regs), per lane 9 + 1 bits written
# in the same CPU cycle, each through a per-bit synchroniser of the adapter's delay logic
# (u_dphy/u_dly, bow_dphy_dly_xusp, step 5). The byte clock side loads a tap once it was the
# same in two consecutive cycles, so all these bits must arrive within one byte clock
# period of each other (the clock groups leave their delays unbounded; as the Huins build
# bounds its own to one video period).
set_bus_skew \
  -from [list [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/dly_code_q_reg[*]}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/own_q_reg[*]}]] \
  -to   [list [get_cells -hierarchical -filter {NAME =~ u_dphy/u_dly/u_sync_code/g_bit[*].u_sync/sync_q_reg[0]}] \
              [get_cells -hierarchical -filter {NAME =~ u_dphy/u_dly/u_sync_own/g_bit[*].u_sync/sync_q_reg[0]}]] \
  $dphy_byte_skew

# ---- H.264 encoder output FIFO (u_soc/u_h264/u_out, bow_fifo_async) -----------------
# write pointer clk_vid -> clk_sys, read pointer clk_sys -> clk_vid. 13 constraints in
# this file in total (tcl/build.tcl counts them).
set_bus_skew -from [get_cells {u_soc/u_h264/u_out/wgray_q_reg[*]}] \
             -to   [get_cells {u_soc/u_h264/u_out/wgray_r1_q_reg[*]}] 5.0
set_bus_skew -from [get_cells {u_soc/u_h264/u_out/rgray_q_reg[*]}] \
             -to   [get_cells {u_soc/u_h264/u_out/rgray_w1_q_reg[*]}] 5.0
