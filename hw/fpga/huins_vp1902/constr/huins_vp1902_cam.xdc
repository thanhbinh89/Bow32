# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 camera build for the Huins MFP-VP1902-S (CARD=cam, bow32_huins_vp1902_cam_top):
# board I/O standards, clocks and clock domain crossings. No ball numbers: the PACKAGE_PIN
# lines are generated at build time from the board netlist (tools/huins_pins.py,
# constr/pins.txt). The clock input is in constr/clk_ref200.xdc (clk_in, 200 MHz), the
# camera pads in constr/cam_pads.xdc (tcl/build.tcl adds them). The board I/O part is the
# one of constr/huins_vp1902.xdc (RAM card build); the CDC part follows
# hw/fpga/kv260_cam/constr/kv260_cam.xdc (same receiver, 4 lanes, 1440 Mbit/s).

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

# ---- Asynchronous board I/O ------------------------------------------------------------------
# UART, GPIO pins and the reset are synchronised inside the SoC (bow_rstmgr, bow_sync); the
# LEDs show static levels.
set_false_path -from [get_ports {rst_n_i uart0_rx_i uart1_tx_io uart1_rx_i pb_i[*]}]
set_false_path -to   [get_ports {uart0_tx_o uart1_tx_io led_o[*]}]

# ---- Clocks ----------------------------------------------------------------------------------
# MMCM outputs of bow32_huins_vp1902_cam_clk (u_clk), named after its pins:
#   clk_sys 50 MHz (SoC), clk_vid 200 MHz (ISP, H.264, CSI-2 LP state machines and PHY
#   control, CTRL_CLK of the XPHYs)
create_generated_clock -name clk_sys [get_pins u_clk/u_mmcm/CLKOUT0]
create_generated_clock -name clk_vid [get_pins u_clk/u_mmcm/CLKOUT1]

# D-PHY (bow_dphy_io_versal, u_dphy). The IMX274 always sends 1440 Mbit/s per lane: HS
# clock 720 MHz DDR on the clock lane pad; for another rate change dphy_hs_period (ns =
# 2000 / Mbit/s), the byte period (4 x) and the bus skew limits follow.
set dphy_hs_period   1.389
set dphy_byte_period [expr {4 * $dphy_hs_period}]
create_clock -name dphy_hs_clk -period $dphy_hs_period [get_ports mipi_clk_p_i]
# Pad clocks do not propagate through an XPHY: the byte clock (strobe / 4) is a new clock
# on the FIFO_WR_CLK pin of the strobe nibble, the one that drives the byte clock BUFGCE
# (u_dphy/u_byte_bufg, a TIMING-3 waiver below as AMD's own XDC has). The BUFGCE output and
# the FIFO_RD_CLK of every XPHY inherit it. The clock lane also reaches the inter-byte
# receivers inside the XPHYs: Vivado derives RX_DQS_DIV4 clocks there from dphy_hs_clk.
create_clock -name dphy_byte_clk -period $dphy_byte_period \
  [get_pins -leaf -of_objects [get_nets -of_objects [get_pins u_dphy/u_byte_bufg/I]] \
            -filter {REF_PIN_NAME == FIFO_WR_CLK}]
# XPLL of the D-PHY bank: CLKOUTPHY 1500 MHz = PLL_CLK of the XPHYs (BISC, VT tracking;
# no fabric paths). Renamed from Vivado's derived name; its RX/TX_DIV4 clocks follow.
create_generated_clock -name dphy_pll_clk \
  [get_pins -of_objects [get_cells -hierarchical -filter {REF_NAME == XPLL && NAME =~ u_dphy/*}] \
            -filter {REF_PIN_NAME == CLKOUTPHY}]

# Periods (tcl/timing_checks_cam.tcl checks them against the clocks)
set sys_period  20.000   ;# clk_sys
set vid_period   5.000   ;# clk_vid

# Every path between these groups goes through a synchroniser, a gray coded bus or a dual
# clock RAM (bow_sync, bow_cdc_pulse, bow_fifo_async, quasi-static configuration
# registers), as on the KV260. clk_sys and clk_vid come from one MMCM but are treated as
# unrelated (all their crossings are synchronised). The LP receivers of the clock lane pad
# are synchronised in clk_vid (dphy_hs_clk -> clk_vid). clk_in only clocks the lock-loss
# reset of the MMCM.
set_clock_groups -asynchronous \
  -group [get_clocks clk_in] \
  -group [get_clocks clk_sys] \
  -group [get_clocks clk_vid] \
  -group [get_clocks -include_generated_clocks dphy_byte_clk] \
  -group [get_clocks -include_generated_clocks dphy_hs_clk] \
  -group [get_clocks -include_generated_clocks dphy_pll_clk]

# ---- D-PHY capture ---------------------------------------------------------------------------
# The flops behind the XPHY Q outputs (4 lanes + the clock lane samples, 40) go into the
# BLI sites of the XPIO (as AMD's D-PHY: BLI on its data_to_fabric flops).
set_property BLI TRUE [get_cells -hierarchical -filter {NAME =~ u_dphy/*bli_q_reg*}]
# Byte clock gate: CE is a clk_vid flop that only changes while the clock lane is static
# (HS-0 or LP), so there is no edge of the strobe to time it to.
set_false_path -to [get_pins u_dphy/u_byte_bufg/CE]
# A primary clock on an XPHY output pin (Clock Modifying Block): intended, the strobe based
# byte clock has no other source. Vivado's hidden RX_DQS_DIV4 clock pins of the XPHYs give
# the same check.
create_waiver -type METHODOLOGY -id {TIMING-3} -user bow32 \
  -description {D-PHY byte clock created on the FIFO_WR_CLK pin of the strobe XPHY (no clock propagates through an XPHY)} \
  -objects [get_pins -of_objects [get_cells -hierarchical -filter {REF_NAME == XPHY && NAME =~ u_dphy/*}] \
                     -filter {REF_PIN_NAME == FIFO_WR_CLK}]
create_waiver -type METHODOLOGY -id {TIMING-3} -user bow32 \
  -description {Clocks Vivado derives on the hidden RX_DQS_DIV4 pins of the inter-byte XPHY receivers} \
  -objects [get_pins -quiet -of_objects [get_cells -hierarchical -filter {REF_NAME == XPHY && NAME =~ u_dphy/*}] \
                     -filter {REF_PIN_NAME =~ RX_DQS_DIV4*}]

# ---- Gray coded buses of the CSI-2 receiver (u_soc/u_csi2rx) --------------------------------
# The clock groups do not cover set_bus_skew. A gray coded bus changes one bit per source
# clock cycle, so the skew between its bits must stay below one source period (byte clock
# 5.556 ns, clk_vid 5 ns); the CPU <-> byte command counters change rarely and get 5 ns.
# Destinations are the first synchroniser flops. tcl/build.tcl counts the constraints of
# report_bus_skew: 14 in this file (CSI-2 receiver 12, H.264 output FIFO 2), all met.
# The receiver's cells are selected by the tail of their hierarchical name, not by their
# full path, so that a constraint follows its flops when the receiver's hierarchy changes
# (docs/ip/mipi_rx_arch.md, section 10, step 1): cells with names of their own (byte clock
# meter, synchronisers) by those names, the pixel FIFO, register file and capture flops by
# their path below u_csi2rx (the controller) or u_dphy_rx (the D-PHY's register file and RAW
# capture, step 4); the adapter's delay control (step 5) by its path below u_dphy. Each tail
# selects the same cells as the full path it replaced. Two cell groups of one side are a
# list of two selectors (not an OR in one filter), so that Vivado warns about each one that
# matches nothing. tcl/build.tcl also checks the cells of every constraint
# (hw/fpga/common/tcl/bus_skew_checks.tcl):
# all in u_soc/u_csi2rx, u_soc/u_h264/u_out or u_dphy, every destination reached from
# the sources, as many source as destination flops.
set dphy_byte_skew [expr {$dphy_byte_period - 0.07}]
# pixel FIFO (bow_fifo_async): write pointer byte -> vid, read pointer vid -> byte
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_fifo/wgray_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_fifo/wgray_r1_q_reg[*]}] \
             $dphy_byte_skew
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_fifo/rgray_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_fifo/rgray_w1_q_reg[*]}] \
             $vid_period
# byte clock meter, byte -> CPU
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */meter_gray_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_meter/g_bit[*].u_sync/sync_q_reg[0]}] \
             $dphy_byte_skew
# LOG / RAW capture requests (CPU -> byte) and acknowledges (byte -> CPU); LOG in the
# controller (u_csi2rx/u_regs, u_csi2rx/u_capture), RAW in the D-PHY since step 4
# (u_dphy_rx/u_regs, u_dphy_rx/u_raw)
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_regs/log_req_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_log_req/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/raw_req_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_raw_req/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_csi2rx/u_capture/log_ack_o_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_log_ack/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_raw/raw_ack_o_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_raw_ack/g_bit[*].u_sync/sync_q_reg[0]}] 5.0
# The D-PHY's event counters (step 6, lp -> CPU): 4 bit gray counters of the lp domain
# (u_dphy_rx/evc_gray_q, clk_vid), at most one step per lp clock, read by the register file
# through u_sync_evc, which adds their differences to CNT_* / ERR_STATUS / IRQ_STATUS: their
# bits must arrive within one lp clock period of each other
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/evc_gray_q_reg[*]}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_evc/g_bit[*].u_sync/sync_q_reg[0]}] \
             $vid_period
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
  [expr {2 * $vid_period - 0.5}]
# CLK_TOG_DIV of the applied configuration (step 6, lp -> byte clock; review of step 6): 4 bits
# of u_dphy_rx/cfg_lp_q, each through a synchroniser of the byte clock domain (u_sync_tdiv);
# quasi-static (they change at an APPLY), a mixed value only makes one toggle period longer or
# shorter: bounded to one byte clock period.
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/cfg_lp_q_reg[tog_div]*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_sync_tdiv/g_bit[*].u_sync/sync_q_reg[0]}] \
             $dphy_byte_skew
# Input delay codes (DLYn CODE and OWN, CPU -> clk_vid): the AFE's dly_code / dly_own, static
# levels of the D-PHY's register file (u_dphy_rx/u_regs), per lane 9 + 1 bits written in the
# same CPU cycle, each through a per-bit synchroniser of the adapter's delay control
# (u_dphy/u_dly, bow_dphy_dly_xphy, step 5; the D-PHY's request counter and tap
# synchronisers up to step 4). The video side takes a value once it was the same in two
# consecutive cycles, so all these bits must arrive within one video period of each other
# (the clock groups leave their delays unbounded).
set_bus_skew \
  -from [list [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/dly_code_q_reg[*]}] \
              [get_cells -hierarchical -filter {NAME =~ */u_dphy_rx/u_regs/own_q_reg[*]}]] \
  -to   [list [get_cells -hierarchical -filter {NAME =~ u_dphy/u_dly/u_sync_code/g_bit[*].u_sync/sync_q_reg[0]}] \
              [get_cells -hierarchical -filter {NAME =~ u_dphy/u_dly/u_sync_own/g_bit[*].u_sync/sync_q_reg[0]}]] \
  $vid_period
# Input delay readback (DLYn[24:16], clk_vid -> CPU): CNTVALUEOUT of the XPHYs (CTRL_CLK =
# clk_vid; binary, and VT tracking may step it by a tap until the first load of the lane)
# through a per-bit synchroniser. Not a gray code: a CPU read at a step can still mix old
# and new bits, so software compares two reads; the bound keeps that window to one video
# period (the clock groups leave these delays unbounded).
set_bus_skew -from [get_cells -hierarchical -filter {REF_NAME == XPHY && NAME =~ u_dphy/*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ */u_sync_tap_out/g_bit[*].u_sync/sync_q_reg[0]}] \
             $vid_period

# ---- H.264 encoder output FIFO (u_soc/u_h264/u_out, bow_fifo_async) -----------------------
# write pointer clk_vid -> clk_sys, read pointer clk_sys -> clk_vid
set_bus_skew -from [get_cells {u_soc/u_h264/u_out/wgray_q_reg[*]}] \
             -to   [get_cells {u_soc/u_h264/u_out/wgray_r1_q_reg[*]}] $vid_period
set_bus_skew -from [get_cells {u_soc/u_h264/u_out/rgray_q_reg[*]}] \
             -to   [get_cells {u_soc/u_h264/u_out/rgray_w1_q_reg[*]}] $vid_period
