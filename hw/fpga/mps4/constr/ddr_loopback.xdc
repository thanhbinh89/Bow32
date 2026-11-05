# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# DDR pads of the MPS4 LOOPBACK build (DDR_LOOPBACK=1, the default): the
# pads of bow_ddr_io_xilinx (instance u_ddr_io, Loopback = 1) sit on balls
# that are NOT connected to anything on the MPS4 (hpi0376b_FPGA_ALL_PINS.xlsx:
# empty signal column), so the PHY drives real IOBs and the read data of the
# on-chip DRAM emulator come back through the output buffer, the pad and the
# input buffer of the same ball.
#
# 30 unconnected balls of bank 64 (SLR1, VCCO 1.8 V, the bank of the clock
# input OSCCLKA[2]) carry CK, DQ, DQS and the command/address pins A0..A10;
# the 7 static pins (A11..A13, ODT and the three level shifter controls,
# constants in a loopback build) use unconnected balls of bank 65 (SLR1,
# 1.8 V, multi-function configuration pins A20..A27 that the MPS4 does not use:
# the FPGA is configured over SelectMAP x8). Byte group = T0..T3 of the bank.
#   DQ/DQS  bank 64 T3 (one byte group), CK on the L24 pair of T3
#   CS..A2  bank 64 T2, A3..A10 bank 64 T1

# ---- CK and DQS (P/N pairs) -------------------------------------------------------
set_property PACKAGE_PIN AL24 [get_ports ddr_ck_p_o]      ;# IO_L24P_T3U_N10_64
set_property PACKAGE_PIN AM24 [get_ports ddr_ck_n_o]      ;# IO_L24N_T3U_N11_64
set_property PACKAGE_PIN AM23 [get_ports ddr_dqs_p_io]    ;# IO_L22P_T3U_N6_DBC_AD0P_64
set_property PACKAGE_PIN AM22 [get_ports ddr_dqs_n_io]    ;# IO_L22N_T3U_N7_DBC_AD0N_64

# ---- DQ ------------------------------------------------------------------------------
set_property PACKAGE_PIN AP23 [get_ports {ddr_dq_io[0]}]  ;# IO_L19P_T3L_N0_DBC_AD9P_64
set_property PACKAGE_PIN AP22 [get_ports {ddr_dq_io[1]}]  ;# IO_L19N_T3L_N1_DBC_AD9N_64
set_property PACKAGE_PIN AN24 [get_ports {ddr_dq_io[2]}]  ;# IO_L20P_T3L_N2_AD1P_64
set_property PACKAGE_PIN AN23 [get_ports {ddr_dq_io[3]}]  ;# IO_L20N_T3L_N3_AD1N_64
set_property PACKAGE_PIN AN21 [get_ports {ddr_dq_io[4]}]  ;# IO_L21P_T3L_N4_AD8P_64
set_property PACKAGE_PIN AP21 [get_ports {ddr_dq_io[5]}]  ;# IO_L21N_T3L_N5_AD8N_64
set_property PACKAGE_PIN AL21 [get_ports {ddr_dq_io[6]}]  ;# IO_L23P_T3U_N8_64
set_property PACKAGE_PIN AM21 [get_ports {ddr_dq_io[7]}]  ;# IO_L23N_T3U_N9_64

# ---- command / address ---------------------------------------------------------------
set_property PACKAGE_PIN AL25 [get_ports ddr_cke_o]       ;# IO_T3U_N12_64
set_property PACKAGE_PIN AU21 [get_ports ddr_cs_n_o]      ;# IO_L15P_T2L_N4_AD11P_64
set_property PACKAGE_PIN AV21 [get_ports ddr_ras_n_o]     ;# IO_L15N_T2L_N5_AD11N_64
set_property PACKAGE_PIN AU24 [get_ports ddr_cas_n_o]     ;# IO_L16P_T2U_N6_QBC_AD3P_64
set_property PACKAGE_PIN AV24 [get_ports ddr_we_n_o]      ;# IO_L16N_T2U_N7_QBC_AD3N_64
set_property PACKAGE_PIN AR23 [get_ports {ddr_ba_o[0]}]   ;# IO_L17P_T2U_N8_AD10P_64
set_property PACKAGE_PIN AR22 [get_ports {ddr_ba_o[1]}]   ;# IO_L17N_T2U_N9_AD10N_64
set_property PACKAGE_PIN AR24 [get_ports {ddr_a_o[0]}]    ;# IO_L18P_T2U_N10_AD2P_64
set_property PACKAGE_PIN AT24 [get_ports {ddr_a_o[1]}]    ;# IO_L18N_T2U_N11_AD2N_64
set_property PACKAGE_PIN AT21 [get_ports {ddr_a_o[2]}]    ;# IO_T2U_N12_64
set_property PACKAGE_PIN AW25 [get_ports {ddr_a_o[3]}]    ;# IO_L9P_T1L_N4_AD12P_64
set_property PACKAGE_PIN AY25 [get_ports {ddr_a_o[4]}]    ;# IO_L9N_T1L_N5_AD12N_64
set_property PACKAGE_PIN AY22 [get_ports {ddr_a_o[5]}]    ;# IO_L10P_T1U_N6_QBC_AD4P_64
set_property PACKAGE_PIN BA22 [get_ports {ddr_a_o[6]}]    ;# IO_L10N_T1U_N7_QBC_AD4N_64
set_property PACKAGE_PIN AY23 [get_ports {ddr_a_o[7]}]    ;# IO_L11N_T1U_N9_GC_64 (P = OSCCLKA[3], unused)
set_property PACKAGE_PIN AW22 [get_ports {ddr_a_o[8]}]    ;# IO_L12N_T1U_N11_GC_64 (P = OSCCLKA[2] clock input)
set_property PACKAGE_PIN BB21 [get_ports {ddr_a_o[9]}]    ;# IO_L8N_T1L_N3_AD5N_64
set_property PACKAGE_PIN BA21 [get_ports {ddr_a_o[10]}]   ;# IO_T1U_N12_64

# ---- static pins in bank 65 ------------------------------------------------------------
set_property PACKAGE_PIN BE19 [get_ports {ddr_a_o[11]}]   ;# IO_L3P_T0L_N4_AD15P_A26_65
set_property PACKAGE_PIN BF19 [get_ports {ddr_a_o[12]}]   ;# IO_L3N_T0L_N5_AD15N_A27_65
set_property PACKAGE_PIN BE18 [get_ports {ddr_a_o[13]}]   ;# IO_L4P_T0U_N6_DBC_AD7P_A24_65
set_property PACKAGE_PIN BE17 [get_ports ddr_odt_o]       ;# IO_L4N_T0U_N7_DBC_AD7N_A25_65
set_property PACKAGE_PIN BC20 [get_ports ddr_ls_oe_n_o]   ;# IO_L5P_T0U_N8_AD14P_A22_65
set_property PACKAGE_PIN BD20 [get_ports ddr_ls_dir_dq_o] ;# IO_L5N_T0U_N9_AD14N_A23_65
set_property PACKAGE_PIN BD18 [get_ports ddr_ls_dir_dqs_o] ;# IO_L6P_T0U_N10_AD6P_A20_65

# ---- I/O standard ----------------------------------------------------------------------
set ddr_ports [get_ports {ddr_ck_* ddr_cke_o ddr_cs_n_o ddr_ras_n_o ddr_cas_n_o ddr_we_n_o \
                          ddr_ba_o[*] ddr_a_o[*] ddr_odt_o ddr_dq_io[*] ddr_dqs_* ddr_ls_*}]
set_property IOSTANDARD LVCMOS18 $ddr_ports
set_property DRIVE 8             $ddr_ports
# Fast edges on the clocked DDR pins: the pads are unloaded balls, the read
# data of the emulator come back through them.
set_property SLEW FAST [get_ports {ddr_ck_* ddr_dq_io[*] ddr_dqs_*}]

# ---- Timing ------------------------------------------------------------------------------
# DQ/DQS are always driven by their ODDRE1 (T = 0 in a loopback build); the
# pin timing is fixed by the I/O tile. Clocks, read capture and the other DDR
# outputs: constr/mps4.xdc.
set_false_path -to [get_ports {ddr_dq_io[*] ddr_dqs_p_io ddr_dqs_n_io}]
