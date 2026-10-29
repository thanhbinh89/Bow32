# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Block design "bow32_cam": the Xilinx IP around Bow32 for the camera build.
#
#   zynq_ultra_ps_e   pl_clk0 = 100 MHz, pl_resetn0 (no AXI interface)
#   clk_wiz           clk_out1 200 MHz: D-PHY reference (dphy_clk_200M) + video
#                     clk_out2  50 MHz: Bow32 SoC + AXI4-Lite of the receiver
#   proc_sys_reset    one per clock domain
#   mipi_csi2_rx      AMD MIPI CSI-2 RX Subsystem: 2 lanes, 912 Mbit/s/lane
#                     (IMX219), RAW10, 1 pixel per clock, all virtual channels
#
# External ports (names fixed: bow32_kv260_cam_top.sv connects to them):
#   sys_clk sys_resetn vid_clk vid_resetn
#   mipi_phy_if_raspi  D-PHY pins            (constr/kv260_cam.xdc)
#   cam_axis           RAW10 AXI4-Stream     -> Bow32 ISP
#   csi_axil           AXI4-Lite registers   <- Bow32 AXI4-Lite window
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

# Set optional IP parameters one by one: their names change between Vivado
# versions, a missing one only gives a warning.
proc set_optional {cell params} {
  foreach {name value} $params {
    if {[catch {set_property CONFIG.$name $value $cell} err]} {
      puts "WARNING: [get_property NAME $cell]: parameter $name not set ($err)"
    }
  }
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
set clk [create_bd_cell -type ip -vlnv [latest_ip xilinx.com:ip:clk_wiz:*] clk_wiz_0]
set_property -dict [list \
  CONFIG.PRIM_SOURCE                {No_buffer} \
  CONFIG.PRIM_IN_FREQ               {100.000} \
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

# ------------------------------------------------- MIPI CSI-2 RX subsystem
set csi [create_bd_cell -type ip -vlnv [latest_ip xilinx.com:ip:mipi_csi2_rx_subsystem:*] mipi_csi2_rx]

# Essential parameters: an error here stops the build.
set_property -dict [list \
  CONFIG.CMN_NUM_LANES  {2} \
  CONFIG.CMN_NUM_PIXELS {1} \
  CONFIG.CMN_PXL_FORMAT {RAW10} \
  CONFIG.CMN_VC         {All} \
  CONFIG.DPY_LINE_RATE  {912} \
] $csi

# Same values as AMD's KV260 camera platforms. The pin location parameters
# exist up to Vivado 2023/2024; newer versions take the pins from the XDC
# (constr/kv260_cam.xdc has them in any case).
set_optional $csi {
  C_DPHY_LANES            2
  C_HS_LINE_RATE          912
  SupportLevel            1
  CSI_BUF_DEPTH           4096
  C_CSI_FILTER_USERDATATYPE false
  C_EN_CSI_V2_0           false
  DPY_EN_REG_IF           true
  C_HS_SETTLE_NS          145
  C_STRETCH_LINE_RATE     1500
  HP_IO_BANK_SELECTION    66
  CLK_LANE_IO_LOC         D7
  CLK_LANE_IO_LOC_NAME    IO_L13P_T2L_N0_GC_QBC_66
  DATA_LANE0_IO_LOC       E5
  DATA_LANE0_IO_LOC_NAME  IO_L14P_T2L_N2_GC_66
  DATA_LANE1_IO_LOC       G6
  DATA_LANE1_IO_LOC_NAME  IO_L15P_T2L_N4_AD11P_66
}

connect_bd_net [get_bd_pins $clk/clk_out1] [get_bd_pins $csi/dphy_clk_200M]
connect_bd_net [get_bd_pins $clk/clk_out1] [get_bd_pins $csi/video_aclk]
connect_bd_net [get_bd_pins $clk/clk_out2] [get_bd_pins $csi/lite_aclk]
connect_bd_net [get_bd_pins $rst_vid/peripheral_aresetn] [get_bd_pins $csi/video_aresetn]
connect_bd_net [get_bd_pins $rst_sys/peripheral_aresetn] [get_bd_pins $csi/lite_aresetn]

# --------------------------------------------------------- external ports
proc export_pin {pin name} {
  make_bd_pins_external $pin
  set_property NAME $name [get_bd_ports -of_objects [get_bd_nets -of_objects $pin]]
}
proc export_intf {pin name} {
  make_bd_intf_pins_external $pin
  set_property NAME $name [get_bd_intf_ports -of_objects [get_bd_intf_nets -of_objects $pin]]
}

export_pin  [get_bd_pins $clk/clk_out2]               sys_clk
export_pin  [get_bd_pins $clk/clk_out1]               vid_clk
export_pin  [get_bd_pins $rst_sys/peripheral_aresetn] sys_resetn
export_pin  [get_bd_pins $rst_vid/peripheral_aresetn] vid_resetn
export_intf [get_bd_intf_pins $csi/mipi_phy_if]       mipi_phy_if_raspi
export_intf [get_bd_intf_pins $csi/video_out]         cam_axis
export_intf [get_bd_intf_pins $csi/csirxss_s_axi]     csi_axil

# Clock frequencies and clock association of the exported interfaces.
set_optional [get_bd_intf_ports cam_axis] {FREQ_HZ 200000000}
set_optional [get_bd_intf_ports csi_axil] {FREQ_HZ 50000000}
set_optional [get_bd_ports vid_clk] {ASSOCIATED_BUSIF cam_axis}
set_optional [get_bd_ports sys_clk] {ASSOCIATED_BUSIF csi_axil}

# The receiver registers are the only slave of the external AXI4-Lite port.
assign_bd_address

validate_bd_design
save_bd_design

set bd_file [get_files $bd_name.bd]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper

# Port list of the wrapper, to compare with bow32_kv260_cam_top.sv if the
# synthesis reports an unknown port (names can differ between IP versions).
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
