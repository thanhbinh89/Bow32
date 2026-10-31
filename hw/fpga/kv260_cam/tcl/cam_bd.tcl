# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Block design "bow32_cam": the Xilinx IP around Bow32 for the camera build.
#
#   zynq_ultra_ps_e   pl_clk0 = 100 MHz, pl_resetn0 (no AXI interface)
#   clk_wiz           clk_out1 200 MHz: video clock (ISP, D-PHY state machines)
#                     clk_out2  50 MHz: Bow32 SoC
#   proc_sys_reset    one per clock domain
#
# There is no vendor MIPI IP: the D-PHY pins go straight to bow_dphy_io_xusp
# and the Bow32 CSI-2 receiver in the RTL (rtl/bow32_kv260_cam_top.sv).
#
# External ports (names fixed: bow32_kv260_cam_top.sv connects to them):
#   sys_clk sys_resetn vid_clk vid_resetn
# The port list of the generated wrapper is written to bd_ports.txt.
#
# Sourced by build.tcl inside an open project.

set bd_name bow32_cam

create_bd_design $bd_name

proc latest_ip {pattern} {
  set v [lindex [lsort -dictionary [get_ipdefs -all $pattern]] end]
  if {$v eq ""} {
    error "IP $pattern not found in this Vivado installation"
  }
  puts "INFO: using $v"
  return $v
}

# ------------------------------------------------------------------- PS
set ps [create_bd_cell -type ip -vlnv [latest_ip xilinx.com:ip:zynq_ultra_ps_e:*] zynq_ultra_ps_e_0]
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

# --------------------------------------------------------------- clocks
# The input frequency is propagated from pl_clk0 (99.999 MHz with the
# 33.333 MHz PS reference): an explicit 100.000 fails validate_bd_design.
# The outputs are then 199.998 MHz and 49.9995 MHz. Keep VidClkHz in
# rtl/bow32_kv260_cam_top.sv equal to clk_out1: the CSI-2 driver derives the
# D-PHY timings (settle, clock miss) from it (CSI2RX INFO).
set clk [create_bd_cell -type ip -vlnv [latest_ip xilinx.com:ip:clk_wiz:*] clk_wiz_0]
set_property -dict [list \
  CONFIG.PRIM_SOURCE                {No_buffer} \
  CONFIG.NUM_OUT_CLKS               {2} \
  CONFIG.CLKOUT1_USED               {true} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.CLKOUT2_USED               {true} \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {50.000} \
  CONFIG.USE_LOCKED                 {true} \
  CONFIG.USE_RESET                  {true} \
  CONFIG.RESET_TYPE                 {ACTIVE_LOW} \
] $clk

connect_bd_net [get_bd_pins $ps/pl_clk0]    [get_bd_pins $clk/clk_in1]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $clk/resetn]

set rst_vlnv [latest_ip xilinx.com:ip:proc_sys_reset:*]
set rst_vid [create_bd_cell -type ip -vlnv $rst_vlnv rst_vid]
set rst_sys [create_bd_cell -type ip -vlnv $rst_vlnv rst_sys]
foreach {r c} [list $rst_vid clk_out1 $rst_sys clk_out2] {
  connect_bd_net [get_bd_pins $clk/$c]        [get_bd_pins $r/slowest_sync_clk]
  connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $r/ext_reset_in]
  connect_bd_net [get_bd_pins $clk/locked]    [get_bd_pins $r/dcm_locked]
}

# --------------------------------------------------------- external ports
# make_bd_pins_external silently skips a pin that is already connected
# (Vivado 2025.2), so the port is created and connected explicitly.
# validate_bd_design propagates the clock frequencies to the ports.
proc export_pin {pin name} {
  set port [create_bd_port -dir [get_property DIR $pin] -type [get_property TYPE $pin] $name]
  if {[llength [list_property $port CONFIG.POLARITY]]} {
    set_property CONFIG.POLARITY [get_property CONFIG.POLARITY $pin] $port
  }
  connect_bd_net $pin $port
}

export_pin [get_bd_pins $clk/clk_out2]               sys_clk
export_pin [get_bd_pins $clk/clk_out1]               vid_clk
export_pin [get_bd_pins $rst_sys/peripheral_aresetn] sys_resetn
export_pin [get_bd_pins $rst_vid/peripheral_aresetn] vid_resetn

validate_bd_design
save_bd_design

set bd_file [get_files $bd_name.bd]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper

# Port list of the wrapper, to compare with bow32_kv260_cam_top.sv if the
# synthesis reports an unknown port.
set fh [open $wrapper r]
set lines [split [read $fh] "\n"]
close $fh
set fh [open [file join [get_property DIRECTORY [current_project]] .. bd_ports.txt] w]
foreach line $lines {
  if {[regexp {^\s*(input|output|inout)\M} $line]} {
    puts $fh [string trim $line]
  }
}
close $fh
