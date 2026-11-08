# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# HyperRAM pads of the MPS4 CARD build (HR_LOOPBACK=0): the S80KS2562 of the
# FMC+_DDR2_HyperRam card behind TI TXV0108 level shifters (U4: DQ0..7, DIR =
# FMC_HB_DIR; U6: CK_P, CK_N, CS#, RESET#, DIR tied low; U8: RWDS, DIR =
# FMC_HB_RWDS_DIR; common OE# FMC_HB_OE_N), on the MPS4 FMC+ HPC connector.
#
# FMC banks 69 / 70 (LA) and 71 (HB) are in SLR2 and powered by VADJ: the card
# needs VADJ = 1.5 V (config.txt `FMC_FORCE: 1V5`), hence LVCMOS15 on every
# pin (the shifter B side is at VCCB = VADJ). The clocks come from SLR1.
# Pin = card net = FMC signal -> FPGA ball (docs/fpga/ram_extension schematic
# sheets 6-8; docs/fpga/MPS4/hpi0376b_FPGA_ALL_PINS.xlsx: HB_P<n> / LA_N<n> ...).

# ---- DQ, RWDS (bank 71) -------------------------------------------------------------------
set_property PACKAGE_PIN C28 [get_ports {hr_dq_io[0]}]    ;# FMC_HB_DQ0 = HB01_N
set_property PACKAGE_PIN D27 [get_ports {hr_dq_io[1]}]    ;# FMC_HB_DQ1 = HB01_P
set_property PACKAGE_PIN C27 [get_ports {hr_dq_io[2]}]    ;# FMC_HB_DQ2 = HB02_P
set_property PACKAGE_PIN B27 [get_ports {hr_dq_io[3]}]    ;# FMC_HB_DQ3 = HB02_N
set_property PACKAGE_PIN G25 [get_ports {hr_dq_io[4]}]    ;# FMC_HB_DQ4 = HB05_P
set_property PACKAGE_PIN F25 [get_ports {hr_dq_io[5]}]    ;# FMC_HB_DQ5 = HB05_N
set_property PACKAGE_PIN F28 [get_ports {hr_dq_io[6]}]    ;# FMC_HB_DQ6 = HB04_P
set_property PACKAGE_PIN E28 [get_ports {hr_dq_io[7]}]    ;# FMC_HB_DQ7 = HB04_N
set_property PACKAGE_PIN M25 [get_ports hr_rwds_io]       ;# FMC_HB_RWDS = HB10_P

# ---- CK, CS#, RESET# (bank 71) --------------------------------------------------------------
set_property PACKAGE_PIN K26 [get_ports hr_ck_p_o]        ;# FMC_HB_CK_P = HB06_P_CC
set_property PACKAGE_PIN J26 [get_ports hr_ck_n_o]        ;# FMC_HB_CK_N = HB06_N_CC
set_property PACKAGE_PIN M28 [get_ports hr_cs_n_o]        ;# FMC_HB_CS# = HB21_N
set_property PACKAGE_PIN M27 [get_ports hr_rst_n_o]       ;# FMC_HB_RESET = HB21_P

# ---- level shifter control (DIR = H: HyperRAM -> FPGA) --------------------------------------
set_property PACKAGE_PIN D37 [get_ports hr_ls_dir_dq_o]   ;# FMC_HB_DIR = LA08_P       bank 69
set_property PACKAGE_PIN C37 [get_ports hr_ls_oe_n_o]     ;# FMC_HB_OE_N = LA08_N      bank 69
set_property PACKAGE_PIN D32 [get_ports hr_ls_dir_rwds_o] ;# FMC_HB_RWDS_DIR = LA14_N  bank 70

# ---- I/O standard ---------------------------------------------------------------------------
set hr_ports [get_ports {hr_ck_* hr_cs_n_o hr_rst_n_o hr_dq_io[*] hr_rwds_io hr_ls_*}]
set_property IOSTANDARD LVCMOS15 $hr_ports
# CK, DQ, RWDS: 8 mA fast edges into the shifter B ports; the other pins keep
# the LVCMOS15 defaults (12 mA, slow).
set_property DRIVE 8   [get_ports {hr_ck_* hr_dq_io[*] hr_rwds_io}]
set_property SLEW FAST [get_ports {hr_ck_* hr_dq_io[*] hr_rwds_io}]
# DQ / RWDS: weak pull-down. The TXV0108 data inputs are always active, also
# with OE# high ("should be kept at a valid logic level", data sheet function
# table), but the FPGA releases DQ / RWDS during a channel reset (no drive
# overlap with shifters still driving a cut read, HR_IO_OUT_RST) and from
# configuration to the first PHY cycle: the pull-down holds them low then.
set_property PULLTYPE PULLDOWN [get_ports {hr_dq_io[*] hr_rwds_io}]

# ---- Timing ---------------------------------------------------------------------------------
# DQ / RWDS data: ODDRE1 in the I/O tile, fixed pin timing. Clocks, read
# capture and the other outputs: constr/mps4.xdc.
set_false_path -from [get_cells -hierarchical -filter {NAME =~ u_hr_io/* && REF_NAME == OSERDESE3}] \
               -to [get_ports {hr_dq_io[*] hr_rwds_io}]
# Output enables: one fabric flop per pad (u_hr_io g_t_phy.*_t_q) drives the
# IOBUF T pin; the limit keeps each flop next to its I/O, so the driver
# switches at the start of the pin cycle + 1..2 ns (the controller's windows
# leave a full cycle around every turnaround, docs/ip/hyperram.md).
set_max_delay -datapath_only 6.500 \
  -from [get_cells -hierarchical -filter {NAME =~ u_hr_io/g_t_phy.*_t_q_reg*}] \
  -to [get_ports {hr_dq_io[*] hr_rwds_io}]
