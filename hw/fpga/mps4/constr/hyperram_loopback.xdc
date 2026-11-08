# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# HyperRAM pads of the MPS4 LOOPBACK build (HR_LOOPBACK=1, the default): the
# pads of bow_hyperram_io_xilinx (instance u_hr_io, Loopback = 1) sit on
# balls that are NOT connected to anything on the MPS4
# (hpi0376b_FPGA_ALL_PINS.xlsx: empty signal column), so the PHY drives real
# IOBs and the read data of the on-chip HyperRAM emulator come back through
# the output buffer, the pad and the input buffer of the same ball.
#
# Bank 65 (SLR1, VCCO 1.8 V, next to bank 64 of the DDR loopback pads and of
# the clock input). Its free balls are multi-function configuration pins that
# the MPS4 does not use (the FPGA is configured over SelectMAP x8: D08..D31,
# A00..A28, RS0, FOE_B, FWE_B, PERSTN1, I2C, SMBALERT are user I/O after
# configuration). The DDR loopback build keeps A20..A27 (BC20 BD18 BD20 BE17
# BE18 BE19 BF19) for its static pins.
#   DQ0..7  bank 65 T2 (L13 .. L18), RWDS T3 (L19P), CK on the L12 pair (T1),
#   CS# / RESET# on the L9 pair, the three level shifter controls (constants
#   in a loopback build) on L7P, L11N, L8P.

# ---- DQ, RWDS ------------------------------------------------------------------------
set_property PACKAGE_PIN AT17 [get_ports {hr_dq_io[0]}]   ;# IO_L17P_T2U_N8_AD10P_D14_65
set_property PACKAGE_PIN AU17 [get_ports {hr_dq_io[1]}]   ;# IO_L17N_T2U_N9_AD10N_D15_65
set_property PACKAGE_PIN AT20 [get_ports {hr_dq_io[2]}]   ;# IO_L18P_T2U_N10_AD2P_D12_65
set_property PACKAGE_PIN AT19 [get_ports {hr_dq_io[3]}]   ;# IO_L18N_T2U_N11_AD2N_D13_65
set_property PACKAGE_PIN AV20 [get_ports {hr_dq_io[4]}]   ;# IO_L15P_T2L_N4_AD11P_A02_D18_65
set_property PACKAGE_PIN AW20 [get_ports {hr_dq_io[5]}]   ;# IO_L15N_T2L_N5_AD11N_A03_D19_65
set_property PACKAGE_PIN AV19 [get_ports {hr_dq_io[6]}]   ;# IO_L13P_T2L_N0_GC_QBC_A06_D22_65
set_property PACKAGE_PIN AU18 [get_ports {hr_dq_io[7]}]   ;# IO_L14N_T2L_N3_GC_A05_D21_65
set_property PACKAGE_PIN AR18 [get_ports hr_rwds_io]      ;# IO_L19P_T3L_N0_DBC_AD9P_D10_65

# ---- CK, CS#, RESET# -------------------------------------------------------------------
set_property PACKAGE_PIN AW18 [get_ports hr_ck_p_o]       ;# IO_L12P_T1U_N10_GC_A08_D24_65
set_property PACKAGE_PIN AY18 [get_ports hr_ck_n_o]       ;# IO_L12N_T1U_N11_GC_A09_D25_65
set_property PACKAGE_PIN BB19 [get_ports hr_cs_n_o]       ;# IO_L9P_T1L_N4_AD12P_A14_D30_65
set_property PACKAGE_PIN BC19 [get_ports hr_rst_n_o]      ;# IO_L9N_T1L_N5_AD12N_A15_D31_65

# ---- static pins ------------------------------------------------------------------------
set_property PACKAGE_PIN AY20 [get_ports hr_ls_oe_n_o]    ;# IO_L7P_T1L_N0_QBC_AD13P_A18_65
set_property PACKAGE_PIN BA19 [get_ports hr_ls_dir_dq_o]  ;# IO_L11N_T1U_N9_GC_A11_D27_65
set_property PACKAGE_PIN BB18 [get_ports hr_ls_dir_rwds_o] ;# IO_L8P_T1L_N2_AD5P_A16_65

# ---- I/O standard ------------------------------------------------------------------------
set hr_ports [get_ports {hr_ck_* hr_cs_n_o hr_rst_n_o hr_dq_io[*] hr_rwds_io hr_ls_*}]
set_property IOSTANDARD LVCMOS18 $hr_ports
set_property DRIVE 8             $hr_ports
# Fast edges on the clocked pins: unloaded balls, the emulator's read data come
# back through them.
set_property SLEW FAST [get_ports {hr_ck_* hr_dq_io[*] hr_rwds_io}]

# ---- Timing --------------------------------------------------------------------------------
# DQ / RWDS are always driven by their ODDRE1 (T = 0 in a loopback build); the
# pin timing is fixed by the I/O tile. Clocks, read capture and the other
# outputs: constr/mps4.xdc.
set_false_path -to [get_ports {hr_dq_io[*] hr_rwds_io}]
