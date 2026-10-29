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

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "implementation failed, see [get_property DIRECTORY [get_runs impl_1]]/runme.log"
}

# ---------------------------------------------------------------- reports
open_run impl_1
report_timing_summary -file [file join $out_dir timing_summary.rpt]
report_utilization    -file [file join $out_dir utilization.rpt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]

file copy -force [file join [get_property DIRECTORY [get_runs impl_1]] $top.bit] \
                 [file join $out_dir bow32_kv260_cam.bit]

puts "INFO: bitstream [file join $out_dir bow32_kv260_cam.bit]  (setup WNS = $wns ns)"
if {$wns < 0} {
  puts "CRITICAL WARNING: timing constraints are not met, see timing_summary.rpt"
}
