# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Block design "bow32_ps": the Zynq UltraScale+ processing system, used only
# as clock and reset source for the PL (pl_clk0 = 100 MHz, pl_resetn0).
# No AXI interface is enabled. Produces the RTL wrapper bow32_ps_wrapper.
#
# Sourced by build.tcl inside an open project.

set bd_name bow32_ps

create_bd_design $bd_name

# Pick the newest PS IP version this Vivado provides.
set ps_vlnv [lindex [lsort -dictionary [get_ipdefs -all xilinx.com:ip:zynq_ultra_ps_e:*]] end]
puts "INFO: using $ps_vlnv"
set ps [create_bd_cell -type ip -vlnv $ps_vlnv zynq_ultra_ps_e_0]

# With the KV260 board files the PS gets the board preset (DDR, MIO, ...).
# It does not matter for loading the bitstream from Linux, but makes the
# exported hardware (XSA) consistent with the board.
if {[get_property board_part [current_project]] ne ""} {
  apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} $ps
}

set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0                {0} \
  CONFIG.PSU__USE__M_AXI_GP1                {0} \
  CONFIG.PSU__USE__M_AXI_GP2                {0} \
  CONFIG.PSU__FPGA_PL0_ENABLE               {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
] $ps

create_bd_port -dir O -type clk pl_clk0
create_bd_port -dir O -type rst pl_resetn0
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports pl_resetn0]

connect_bd_net [get_bd_pins $ps/pl_clk0]    [get_bd_ports pl_clk0]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_ports pl_resetn0]

validate_bd_design
save_bd_design

set bd_file [get_files $bd_name.bd]
generate_target all $bd_file
add_files -norecurse [make_wrapper -files $bd_file -top]
