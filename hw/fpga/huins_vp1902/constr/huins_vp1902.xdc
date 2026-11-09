# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 I/O standards and timing constraints for the Huins MFP-VP1902-S
# (xcvp1902-vsva6865-2MP-e-S). No ball numbers: the PACKAGE_PIN lines are
# generated at build time from the board netlist (tools/huins_pins.py,
# constr/pins.txt; the Huins documents are confidential). The clock input is
# in constr/clk_<CLK_SRC>.xdc, the card pads in constr/ddr_pads.xdc and
# constr/hyperram_pads.xdc (tcl/build.tcl adds them).
# The clock periods and CDC exceptions are those of hw/fpga/mps4/constr/mps4.xdc
# (same frequencies), with the Versal clock modules (bow_ddr_clk_versal,
# bow_hyperram_clk_versal).

# ---- Reset (USER_RESET_N: TPS3808 output, open drain, 10k pull-up), bank 408 HDIO 1.8 V --
set_property IOSTANDARD LVCMOS18 [get_ports rst_n_i]
set_property PULLTYPE PULLUP     [get_ports rst_n_i]

# ---- UARTs: CP2102N "UART0" (console) and "UART1" (PB0 / PB1), bank 408 HDIO 1.8 V ------
# Pull-ups: an unpowered bridge must not look like a BREAK (boot loader).
set_property IOSTANDARD LVCMOS18 [get_ports {uart0_tx_o uart0_rx_i uart1_tx_io uart1_rx_i}]
set_property PULLTYPE PULLUP     [get_ports {uart0_rx_i uart1_tx_io uart1_rx_i}]

# ---- User LEDs (active high, FET drivers) and push buttons (active high), bank 812 1.5 V --
set_property IOSTANDARD LVCMOS15 [get_ports {led_o[*] pb_i[*]}]
set_property PULLTYPE PULLDOWN   [get_ports {pb_i[*]}]

# ---- FMC+ site PRSNT_M2C_L (10k pull-up to the site VADJ), 1.5 V ---------------------------
set_property IOSTANDARD LVCMOS15 [get_ports fmc_prsnt_n_i]

# ---- Clocks --------------------------------------------------------------------------
# The input clock (create_clock on clk_p_i) is in constr/clk_<CLK_SRC>.xdc.
# Names of the MMCM outputs of bow_ddr_clk_versal (u_clk), see its header:
# MMCM_A = SoC clock, DDR clock (CK), write clocks (fine PS, 0 / 90 deg) and
# the LiteDRAM controller clock (CK / 4), one VCO; MMCM_B = read capture clock
# (any phase, calibrated).
create_generated_clock -name clk_sys     [get_pins u_clk/u_mmcm_a/CLKOUT0]
create_generated_clock -name ddr_clk     [get_pins u_clk/u_mmcm_a/CLKOUT1]
create_generated_clock -name ddr_wclk    [get_pins u_clk/u_mmcm_a/CLKOUT2]
create_generated_clock -name ddr_sys     [get_pins u_clk/u_mmcm_a/CLKOUT3]
create_generated_clock -name ddr_wclk90  [get_pins u_clk/u_mmcm_a/CLKOUT4]
create_generated_clock -name ddr_rd_clk  [get_pins u_clk/u_mmcm_b/CLKOUT0]

# Periods of the MMCM outputs (tcl/timing_checks.tcl checks them against the clocks)
set sys_period     20.000   ;# clk_sys
set ddr_period      7.500   ;# ddr_clk = tCK (ddr_rd_clk, ddr_wclk, ddr_wclk90 alike)
set ddr_sys_period 30.000   ;# ddr_sys = 4 tCK

# Clock domains of the DDR memory system (u_soc/g_ddr.u_ddr, docs/ip/ddr.md):
#   clk_sys      bus side of the window, CSR and register bridges
#   ddr_sys      LiteDRAM controller: native port and Wishbone side of the
#                bridges, DFI to the adapter
#   ddr_clk      DFI adapter, PHY, CK / command pads, the loopback emulator
#   ddr_rd_clk   read capture (IDDRE1), write side of the PHY's read FIFO
#   ddr_wclk(90) DQS / DQ / DM ODDRE1 and their T ODDRE1 only, fed by PHY
#                registers (ddr_clk)
# The exceptions below cover the asynchronous pairs; every other pair with
# paths (ddr_sys <-> ddr_clk, ddr_clk -> write clocks) is timed as
# synchronous.

# SoC <-> DDR (clk_sys <-> ddr_sys, ddr_clk, ddr_rd_clk), asynchronous: every
# path goes through a CDC of bow_ddr (4-phase request / acknowledge with
# quasi-static payloads and results, bow_sync levels, bow_rst_sync). As on
# the MPS4, a data path limit of at most one destination period instead of
# clock groups (a payload always arrives before the synchronised request /
# acknowledge that releases it); the write clocks have no path to clk_sys.
set_max_delay -datapath_only $ddr_period \
  -from [get_clocks clk_sys] -to [get_clocks {ddr_clk ddr_rd_clk}]
set_max_delay -datapath_only $ddr_period \
  -from [get_clocks {ddr_clk ddr_rd_clk}] -to [get_clocks clk_sys]
set sys_ddr_sys_max [expr {$sys_period < $ddr_sys_period ? $sys_period : $ddr_sys_period}]
set_max_delay -datapath_only $sys_ddr_sys_max -from [get_clocks clk_sys] -to [get_clocks ddr_sys]
set_max_delay -datapath_only $sys_ddr_sys_max -from [get_clocks ddr_sys] -to [get_clocks clk_sys]
set_clock_groups -asynchronous \
  -group [get_clocks clk_sys] \
  -group [get_clocks {ddr_wclk ddr_wclk90}]

# LiteDRAM controller <-> PHY clock (ddr_sys <-> ddr_clk): SYNCHRONOUS, no
# exception (both from u_mmcm_a at phase 0, CLKOUT3 = CLKOUT1 / 4: every
# ddr_sys rising edge is a ddr_clk rising edge). tcl/timing_checks.tcl checks
# that these paths exist and carry no exception.

# Read capture clock <-> ddr_clk / ddr_sys: the read phase is moved at run
# time, so the synchronous analysis means nothing: the read FIFO of
# bow_ddr_phy (gray pointers + dual clock RAM), its overflow flag, the reset
# synchronisers. A data path limit of one CK period, a bus skew limit on the
# gray pointers.
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
# The extra uncertainty makes setup and hold of the PHY -> ODDR paths (data
# and T) hold over that range: DQ/DM (C = ~ddr_wclk90, nominal 3T/4) need a
# path delay below T/2; DQS goes through a falling edge stage on ddr_wclk
# (bow_ddr_io_xilinx with TFromOddr, nominal T/2 from the PHY: below T/4),
# then a T/2 path within ddr_wclk to its ODDRs. Only PHY registers (ddr_clk)
# feed these paths; tcl/timing_checks.tcl checks that no path comes from
# ddr_sys.
set_clock_uncertainty [expr {$ddr_period / 4}] \
  -from [get_clocks ddr_clk] -to [get_clocks {ddr_wclk ddr_wclk90}]
# Matched clock trees for the synchronous outputs of MMCM_A: on the first
# build ddr_clk reached the fabric flops of the pad wrapper (DQS falling edge
# stage) 2.5 ns later than ddr_wclk reached the XPIO ODDRs, and the T/2 DQS
# path (T/4 left after the write phase uncertainty) failed by 1.2 ns. One
# clock delay group gives ddr_clk, ddr_sys, ddr_wclk and ddr_wclk90 a common
# root and balanced insertion delays (ddr_rd_clk is calibrated, clk_sys is
# asynchronous: not in the group).
set_property CLOCK_DELAY_GROUP bow_ddr_mmcm_a \
  [get_nets -of_objects [get_pins {u_clk/u_ddr_bufg/O u_clk/u_ddr_sys_bufg/O u_clk/u_ddr_wclk_bufg/O u_clk/u_ddr_w90_bufg/O}]]

# ---- HyperRAM clocks (u_soc/g_hr.u_hr, docs/ip/hyperram.md) ---------------------------------
# Names of the MMCM outputs of bow_hyperram_clk_versal (u_hr_clk): MMCM_H =
# controller clock hr_clk (static 270 deg) and write clock hr_wclk (0 deg +
# fine phase shift: hr_clk + T/4 at write phase 0), MMCM_R = read capture
# clock (any phase, calibrated). Both fed by the input pin through their own
# BUFG (u_hr_clk/u_in_bufg).
create_generated_clock -name hr_clk    [get_pins u_hr_clk/u_mmcm_h/CLKOUT0]
create_generated_clock -name hr_wclk   [get_pins u_hr_clk/u_mmcm_h/CLKOUT1]
create_generated_clock -name hr_rd_clk [get_pins u_hr_clk/u_mmcm_r/CLKOUT0]
set hr_period 10.000   ;# hr_clk = tCK (hr_wclk, hr_rd_clk alike)
# SoC <-> HyperRAM, asynchronous (bow_fifo_async command / response FIFOs,
# the command handshake, bow_sync, bow_cdc_pulse, bow_rst_sync): a data path
# limit of one CK period instead of clock groups, as for the DDR.
set_max_delay -datapath_only $hr_period \
  -from [get_clocks clk_sys] -to [get_clocks {hr_clk hr_rd_clk}]
set_max_delay -datapath_only $hr_period \
  -from [get_clocks {hr_clk hr_rd_clk}] -to [get_clocks clk_sys]
set_clock_groups -asynchronous -group [get_clocks clk_sys] -group [get_clocks hr_wclk]
# Read capture clock <-> hr_clk: the read phase moves at run time.
set_max_delay -datapath_only $hr_period -from [get_clocks hr_rd_clk] -to [get_clocks hr_clk]
set_max_delay -datapath_only $hr_period -from [get_clocks hr_clk] -to [get_clocks hr_rd_clk]
# Gray pointers of the three FIFOs (read data, commands, responses).
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_phy/u_rfifo/wgray_q_reg*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_phy/u_rfifo/wgray_r1_q_reg*}] [expr {$hr_period - 0.07}]
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_phy/u_rfifo/rgray_q_reg*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_phy/u_rfifo/rgray_w1_q_reg*}] [expr {$hr_period - 0.07}]
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_cmd_fifo/wgray_q_reg*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_cmd_fifo/wgray_r1_q_reg*}] [expr {$hr_period - 0.07}]
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_cmd_fifo/rgray_q_reg*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_cmd_fifo/rgray_w1_q_reg*}] [expr {$hr_period - 0.07}]
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_resp_fifo/wgray_q_reg*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_resp_fifo/wgray_r1_q_reg*}] [expr {$hr_period - 0.07}]
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_resp_fifo/rgray_q_reg*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ u_soc/g_hr.u_hr/u_resp_fifo/rgray_w1_q_reg*}] [expr {$hr_period - 0.07}]
# PHY register -> DQ / RWDS ODDRE1 and their T ODDRE1 (C = ~hr_wclk). Vivado
# models the 270 deg of hr_clk as clock latency, so its default edge pair
# would ask for the data before they are launched: one more hr_wclk period for
# setup (3T/4 of budget), hold against the edge just before it (as on the MPS4).
set_multicycle_path -setup 2 -from [get_clocks hr_clk] -to [get_clocks hr_wclk]
# Write phase (WPS): hr_wclk moves by up to +-3T/16 against hr_clk.
set_clock_uncertainty [expr {3 * $hr_period / 16}] -from [get_clocks hr_clk] -to [get_clocks hr_wclk]

# ---- Asynchronous board I/O --------------------------------------------------------------
# UART, GPIO pins and the reset are synchronised inside the SoC (bow_rstmgr,
# bow_sync).
set_false_path -from [get_ports {rst_n_i uart0_rx_i uart1_tx_io uart1_rx_i pb_i[*] fmc_prsnt_n_i}]
set_false_path -to   [get_ports {uart0_tx_o uart1_tx_io led_o[*]}]

# ---- DDR2 pads (constr/ddr_pads.xdc) ------------------------------------------------------
# Read data: IDDRE1 on ddr_rd_clk, the capture phase is calibrated at run time.
set_false_path -from [get_ports {ddr_dq_io[*] ddr_dqs_p_io ddr_dqs_n_io}]
# Outputs: each pin is driven by an ODDRE1 in its own I/O site (the timing
# between the pins is fixed by the I/O column).
set_false_path -to [get_ports {ddr_ck_* ddr_cke_o ddr_cs_n_o ddr_ras_n_o ddr_cas_n_o ddr_we_n_o \
                               ddr_ba_o[*] ddr_a_o[*] ddr_odt_o ddr_ls_*}]

# ---- HyperRAM pads (constr/hyperram_pads.xdc) ----------------------------------------------
# Read data: IDDRE1 on hr_rd_clk (calibrated); the RWDS pad level also enters
# a bow_sync (latency indication).
set_false_path -from [get_ports {hr_dq_io[*] hr_rwds_io}]
set_false_path -to [get_ports {hr_ck_* hr_cs_n_o hr_rst_n_o hr_ls_*}]
