# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Vivado build of Bow32 + camera (MIPI CSI-2 RX) for the Kria KV260
# (project mode, batch).
#
#   vivado -mode batch -source build.tcl -tclargs <out_dir> <rom_vmem> [flash_vmem] [jobs]
#
# Normally called from hw/fpga/kv260_cam/Makefile (`make fpga BOARD=kv260_cam`).
# The project is kept in <out_dir>/vivado and can be opened in the GUI.

set script_dir [file dirname [file normalize [info script]]]
set board_dir  [file normalize [file join $script_dir ..]]
set repo_root  [file normalize [file join $board_dir .. .. ..]]

if {[llength $argv] < 2} {
  error "usage: build.tcl <out_dir> <rom_vmem> \[flash_vmem\] \[jobs\]"
}
set out_dir    [file normalize [lindex $argv 0]]
set rom_vmem   [file normalize [lindex $argv 1]]
set flash_vmem [lindex $argv 2]
set jobs       [expr {[llength $argv] > 3 ? [lindex $argv 3] : 4}]

set part xck26-sfvc784-2LV-c
set top  bow32_kv260_cam_top

if {![file exists $rom_vmem]} {
  error "boot ROM image $rom_vmem not found (run `make sw` first)"
}

source [file join $repo_root hw fpga common tcl filelist.tcl]
source [file join $repo_root hw fpga common tcl bus_skew_checks.tcl]

# ---------------------------------------------------------------- project
create_project bow32_kv260_cam [file join $out_dir vivado] -part $part -force

set board_parts [get_board_parts -quiet -latest_file_version *kv260_som*]
if {[llength $board_parts] > 0} {
  set_property board_part [lindex $board_parts 0] [current_project]
  puts "INFO: board part [lindex $board_parts 0]"
} else {
  puts "WARNING: KV260 board files not installed, the PS is created without board preset"
}

# ---------------------------------------------------------------- sources
lassign [bow32_parse_f [file join $board_dir kv260_cam.f]] rtl_files inc_dirs
add_files -norecurse $rtl_files
set_property include_dirs $inc_dirs [current_fileset]
set_property verilog_define {SYNTHESIS FPGA_XILINX} [current_fileset]

# Pins of the base build (UART, GPIO, camera enable, I2C, fan) + MIPI pins
add_files -fileset constrs_1 -norecurse [file join $board_dir .. kv260 constr kv260.xdc]
add_files -fileset constrs_1 -norecurse [file join $board_dir constr kv260_cam.xdc]

# Memory images are passed as string parameters of the top level.
set generics "RomInitFile=\"$rom_vmem\""
if {$flash_vmem ne ""} {
  append generics " FlashInitFile=\"[file normalize $flash_vmem]\""
}
set_property generic $generics [current_fileset]

source [file join $script_dir cam_bd.tcl]

set_property top $top [current_fileset]
update_compile_order -fileset sources_1

# ------------------------------------------------------------------ build
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "synthesis failed, see [get_property DIRECTORY [get_runs synth_1]]/runme.log"
}

# The 200 MHz video clock has only a few tens of ps of setup slack after routing (H.264
# macroblock arithmetic, 15..18 logic levels), and any RTL change elsewhere in the SoC
# moves it: with the default directives the 4-lane CSI-2 receiver RTL (2026-11-10) ended
# at -0.040 ns. The Explore directives of place, physical optimisation and route close it
# (+0.065 ns from the same netlist). Post-route physical optimisation as well (the
# receiver of PR #17 missed by 26 ps without it).
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE    Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE    Explore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "implementation failed, see [get_property DIRECTORY [get_runs impl_1]]/runme.log"
}

# ---------------------------------------------------------------- reports
open_run impl_1
report_timing_summary    -file [file join $out_dir timing_summary.rpt]
report_utilization       -file [file join $out_dir utilization.rpt]
# Clock domain crossings of the CSI-2 receiver (constr/kv260_cam.xdc)
report_clocks            -file [file join $out_dir clocks.rpt]
report_clock_interaction -file [file join $out_dir clock_interaction.rpt]
check_timing -verbose    -file [file join $out_dir check_timing.rpt]
report_methodology       -file [file join $out_dir methodology.rpt]
report_drc               -file [file join $out_dir drc.rpt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
# Setup, hold and pulse width together: the summary has one verdict line
set fh [open [file join $out_dir timing_summary.rpt] r]
set timing_met [regexp {All user specified timing constraints are met} [read $fh]]
close $fh

# Gray coded buses and the delay codes (set_bus_skew): one "Slack (MET)" per
# constraint. A constraint whose cells are not found (renamed RTL) is missing
# from the report, so count them: 10 set_bus_skew lines in
# constr/kv260_cam.xdc (CSI-2 receiver 7, DLYn codes + OWN into the adapter
# 1, H.264 output FIFO 2).
set skew [report_bus_skew -return_string]
set fh [open [file join $out_dir bus_skew.rpt] w]
puts $fh $skew
close $fh
set skew_met [regexp -all {Slack \(MET\)} $skew]
if {[regexp {Slack \(VIOLATED\)} $skew] || $skew_met != 10} {
  puts "CRITICAL WARNING: bus skew violated or not constrained ($skew_met met), see bus_skew.rpt"
}
# The cells of every constraint (hw/fpga/common/tcl/bus_skew_checks.tcl): the
# CSI-2 receiver's selectors match on the tail of cell names
# (constr/kv260_cam.xdc); the delay code synchronisers are in the adapter
set skew_bad [bow32_bus_skew_checks $skew {u_soc/u_csi2rx/ u_soc/u_h264/u_out/ u_dphy/u_dly/}]
foreach p $skew_bad {
  puts "CRITICAL WARNING: bus skew $p"
}
puts "INFO: bus skew cells: [llength $skew_bad] problems in $skew_met constraints"

# The placer lists the members of every CLOCK_DELAY_GROUP: both D-PHY clock
# nets (HS clock and byte clock) must be in it.
set clock_info [file join [get_property DIRECTORY [get_runs impl_1]] clockInfo.txt]
if {[file exists $clock_info]} {
  file copy -force $clock_info [file join $out_dir clockInfo.txt]
  set fh [open $clock_info r]
  set txt [read $fh]
  close $fh
  if {![regexp {The following 2 clock nets belong to CLOCK_DELAY_GROUP bow_dphy_rx_clk} $txt]} {
    puts "CRITICAL WARNING: CLOCK_DELAY_GROUP bow_dphy_rx_clk does not hold the 2 D-PHY clock nets"
  }
} else {
  puts "CRITICAL WARNING: $clock_info not found, CLOCK_DELAY_GROUP bow_dphy_rx_clk not checked"
}

file copy -force [file join [get_property DIRECTORY [get_runs impl_1]] $top.bit] \
                 [file join $out_dir bow32_kv260_cam.bit]

puts "INFO: bitstream [file join $out_dir bow32_kv260_cam.bit]  (setup WNS = $wns ns, hold WHS = $whs ns)"
if {!$timing_met} {
  puts "CRITICAL WARNING: timing constraints are not met (setup, hold or pulse width), see timing_summary.rpt"
}
