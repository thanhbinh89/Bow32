# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# DDR pads of the MPS4 CARD build (DDR_LOOPBACK=0): the FMC+_DDR2_HyperRam
# card (ISSI IS43DR86400E x8 DDR2 behind TI TXV0108 level shifters) on the
# MPS4 FMC+ HPC connector. Build only until the card exists.
#
# FMC banks 69/70 (LA) and 71 (HB) are in SLR2 and powered by VADJ: the card
# needs VADJ = 1.5 V (config.txt `FMC_FORCE: 1V5`), hence LVCMOS15 on every
# pin (the shifter B side is at VCCB = VADJ). The clocks come from bank 64 in
# SLR1 and cross into SLR2.
# Pin = FMC signal -> FPGA ball (docs/fpga/MPS4/hpi0376b_FPGA_ALL_PINS.xlsx,
# FMC pin table hpi0376b_varA_FMC.pdf); pinout of the current (rev A) card as in
# docs/ddr_board_review.md.

# ---- CK, DQS, DQ ------------------------------------------------------------------------
set_property PACKAGE_PIN H32 [get_ports ddr_ck_p_o]       ;# LA17_P  bank 70
set_property PACKAGE_PIN G32 [get_ports ddr_ck_n_o]       ;# LA17_N  bank 70
set_property PACKAGE_PIN K27 [get_ports ddr_dqs_p_io]     ;# HB17_P  bank 71
set_property PACKAGE_PIN J27 [get_ports ddr_dqs_n_io]     ;# HB17_N  bank 71
set_property PACKAGE_PIN D25 [get_ports {ddr_dq_io[0]}]   ;# HB07_P  bank 71
set_property PACKAGE_PIN D26 [get_ports {ddr_dq_io[1]}]   ;# HB07_N  bank 71
set_property PACKAGE_PIN H28 [get_ports {ddr_dq_io[2]}]   ;# HB09_P  bank 71
set_property PACKAGE_PIN G28 [get_ports {ddr_dq_io[3]}]   ;# HB09_N  bank 71
set_property PACKAGE_PIN L24 [get_ports {ddr_dq_io[4]}]   ;# HB11_P  bank 71
set_property PACKAGE_PIN L25 [get_ports {ddr_dq_io[5]}]   ;# HB11_N  bank 71
set_property PACKAGE_PIN P24 [get_ports {ddr_dq_io[6]}]   ;# HB13_P  bank 71
set_property PACKAGE_PIN N24 [get_ports {ddr_dq_io[7]}]   ;# HB13_N  bank 71

# ---- level shifter control (DIR = H: DRAM -> FPGA) --------------------------------------
set_property PACKAGE_PIN D35 [get_ports ddr_ls_dir_dq_o]  ;# LA05_P  bank 69  DQ_DIR
set_property PACKAGE_PIN C35 [get_ports ddr_ls_dir_dqs_o] ;# LA05_N  bank 69  DQS_DIR
set_property PACKAGE_PIN A34 [get_ports ddr_ls_oe_n_o]    ;# LA10_P  bank 69  OE_N

# ---- command / address --------------------------------------------------------------------
set_property PACKAGE_PIN E39 [get_ports ddr_cke_o]        ;# LA02_P  bank 69
set_property PACKAGE_PIN D40 [get_ports ddr_cs_n_o]       ;# LA03_P  bank 69
set_property PACKAGE_PIN C39 [get_ports ddr_ras_n_o]      ;# LA04_P  bank 69
set_property PACKAGE_PIN A39 [get_ports ddr_cas_n_o]      ;# LA07_P  bank 69
set_property PACKAGE_PIN D34 [get_ports ddr_we_n_o]       ;# LA09_P  bank 69
set_property PACKAGE_PIN B36 [get_ports ddr_odt_o]        ;# LA12_P  bank 69
set_property PACKAGE_PIN C30 [get_ports {ddr_ba_o[0]}]    ;# LA15_P  bank 70
set_property PACKAGE_PIN E31 [get_ports {ddr_ba_o[1]}]    ;# LA19_P  bank 70
set_property PACKAGE_PIN D29 [get_ports {ddr_a_o[0]}]     ;# LA20_P  bank 70
set_property PACKAGE_PIN F34 [get_ports {ddr_a_o[1]}]     ;# LA21_P  bank 69
set_property PACKAGE_PIN F33 [get_ports {ddr_a_o[2]}]     ;# LA22_P  bank 70
set_property PACKAGE_PIN J36 [get_ports {ddr_a_o[3]}]     ;# LA24_P  bank 69
set_property PACKAGE_PIN J35 [get_ports {ddr_a_o[4]}]     ;# LA25_P  bank 69
set_property PACKAGE_PIN H34 [get_ports {ddr_a_o[5]}]     ;# LA26_P  bank 69
set_property PACKAGE_PIN H33 [get_ports {ddr_a_o[6]}]     ;# LA27_P  bank 70
set_property PACKAGE_PIN H38 [get_ports {ddr_a_o[7]}]     ;# LA28_P  bank 69
set_property PACKAGE_PIN K37 [get_ports {ddr_a_o[8]}]     ;# LA29_P  bank 69
set_property PACKAGE_PIN H39 [get_ports {ddr_a_o[9]}]     ;# LA30_P  bank 69
set_property PACKAGE_PIN J39 [get_ports {ddr_a_o[10]}]    ;# LA31_P  bank 69
set_property PACKAGE_PIN G40 [get_ports {ddr_a_o[11]}]    ;# LA32_P  bank 69
set_property PACKAGE_PIN F38 [get_ports {ddr_a_o[12]}]    ;# LA33_P  bank 69
set_property PACKAGE_PIN B32 [get_ports {ddr_a_o[13]}]    ;# LA13_N  bank 70

# ---- I/O standard ---------------------------------------------------------------------------
set ddr_ports [get_ports {ddr_ck_* ddr_cke_o ddr_cs_n_o ddr_ras_n_o ddr_cas_n_o ddr_we_n_o \
                          ddr_ba_o[*] ddr_a_o[*] ddr_odt_o ddr_dq_io[*] ddr_dqs_* ddr_ls_*}]
set_property IOSTANDARD LVCMOS15 $ddr_ports
# CK, DQ, DQS: 8 mA fast edges into the shifter B ports; the other pins keep
# the LVCMOS15 defaults (12 mA, slow).
set_property DRIVE 8   [get_ports {ddr_ck_* ddr_dq_io[*] ddr_dqs_*}]
set_property SLEW FAST [get_ports {ddr_ck_* ddr_dq_io[*] ddr_dqs_*}]

# ---- Timing ---------------------------------------------------------------------------------
# DQ/DQS data: ODDRE1 in the I/O tile, fixed pin timing. Clocks, read capture
# and the other DDR outputs: constr/mps4.xdc.
set_false_path -from [get_cells -hierarchical -filter {NAME =~ u_ddr_io/* && REF_NAME == OSERDESE3}] \
               -to [get_ports {ddr_dq_io[*] ddr_dqs_p_io ddr_dqs_n_io}]
# Output enables: one fabric flop per pad (u_ddr_io g_t_phy.*_t_q) drives the
# IOBUF T pin. The LVCMOS15 output buffer alone needs ~4.5 ns from T to the pad
# (slow corner); the limit keeps each flop next to its I/O, so the driver
# switches at the start of the pin cycle + 1..2 ns (the PHY keeps the driver on
# from the preamble through the postamble).
set_max_delay -datapath_only 6.500 \
  -from [get_cells -hierarchical -filter {NAME =~ u_ddr_io/g_t_phy.*_t_q_reg*}] \
  -to [get_ports {ddr_dq_io[*] ddr_dqs_p_io ddr_dqs_n_io}]
# DQS: the PHY flop (ddr_clk, falling edge) -> DQS ODDRE1 (ddr_wclk) has half a
# period minus the T/4 write phase uncertainty. The card's data pins are in
# bank 71 (clock region X4Y11), six regions above the DDR MMCMs, and with the
# clock roots Vivado picks (ddr_wclk at X4Y8) the clock skew left -0.07 ns
# (2026-11-07, with the HyperRAM in bank 71 too). Rooting ddr_wclk (two loads,
# the DQS ODDRs) at its MMCM's region delays it at the pads: +0.10 ns; roots
# nearer the pads (X4Y10, X4Y11) or a ddr_clk root move made it worse.
set_property USER_CLOCK_ROOT X4Y6 [get_nets -of_objects [get_pins u_clk/u_ddr_wclk_bufg/O]]
