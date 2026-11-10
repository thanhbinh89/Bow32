# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# HyperRAM pads of the Huins build: the S80KS2562 of the FMC+_DDR2_HyperRam
# card behind its TXV0108 level shifters (default FMC+10: XPIO banks 708 and
# 710 at the site VADJ, 1.5 V). The same pads in the loopback build
# (HR_LOOPBACK=1: OE# held at 1, the shifters isolated).
# PACKAGE_PIN lines: generated (tools/huins_pins.py, constr/pins.txt).

set hr_ports [get_ports {hr_ck_* hr_cs_n_o hr_rst_n_o hr_dq_io[*] hr_rwds_io hr_ls_*}]
set_property IOSTANDARD LVCMOS15 $hr_ports
# CK, DQ, RWDS: 8 mA fast edges into the shifter B ports.
set_property DRIVE 8   [get_ports {hr_ck_* hr_dq_io[*] hr_rwds_io}]
set_property SLEW FAST [get_ports {hr_ck_* hr_dq_io[*] hr_rwds_io}]
# DQ / RWDS: weak pull-down (the TXV0108 data inputs must stay at a valid
# level while the FPGA releases them: channel reset, configuration).
set_property PULLTYPE PULLDOWN [get_ports {hr_dq_io[*] hr_rwds_io}]

# ---- Timing -----------------------------------------------------------------------------------
# DQ / RWDS data and output enables: ODDRE1 (data and T) in the XPIO site of
# each pad, fixed pin timing.
set_false_path -from [get_cells -hierarchical -filter {NAME =~ u_hr_io/* && REF_NAME == ODDRE1}] \
               -to [get_ports {hr_dq_io[*] hr_rwds_io}]
