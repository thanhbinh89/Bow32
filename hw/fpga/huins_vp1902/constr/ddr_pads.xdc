# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# DDR2 pads of the Huins build: the FMC+_DDR2_HyperRam card (ISSI IS43DR86400E
# x8 DDR2 behind TI TXV0108 level shifters) on an FMC+ site (default FMC+10:
# XPIO banks 708 (DQ / DQS), 709 (CK, command, address) and 710 (DIR / OE),
# powered by the site VADJ, slide switch SW196 at 1.5 V). The same pads in the
# loopback build (DDR_LOOPBACK=1: the shifters stay isolated).
# PACKAGE_PIN lines: generated (tools/huins_pins.py, constr/pins.txt).

# ---- I/O standard: XPIO at VADJ 1.5 V (LVCMOS18 does not exist on XPIO) --------------------
set ddr_ports [get_ports {ddr_ck_* ddr_cke_o ddr_cs_n_o ddr_ras_n_o ddr_cas_n_o ddr_we_n_o \
                          ddr_ba_o[*] ddr_a_o[*] ddr_odt_o ddr_dq_io[*] ddr_dqs_* ddr_ls_*}]
set_property IOSTANDARD LVCMOS15 $ddr_ports
# CK, DQ, DQS: 8 mA fast edges into the shifter B ports (as on the MPS4).
set_property DRIVE 8   [get_ports {ddr_ck_* ddr_dq_io[*] ddr_dqs_*}]
set_property SLEW FAST [get_ports {ddr_ck_* ddr_dq_io[*] ddr_dqs_*}]

# ---- Timing -----------------------------------------------------------------------------------
# DQ / DQS data and output enables: an ODDRE1 for the data and one for T
# (u_toddr*, TFromOddr) in the XPIO site of each pad, fixed pin timing. The
# PHY -> ODDRE1 paths are timed in constr/huins_vp1902.xdc (write phase
# uncertainty).
set_false_path -from [get_cells -hierarchical -filter {NAME =~ u_ddr_io/* && REF_NAME == ODDRE1}] \
               -to [get_ports {ddr_dq_io[*] ddr_dqs_p_io ddr_dqs_n_io}]
