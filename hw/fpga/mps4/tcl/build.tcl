# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Vivado build of Bow32 for the Arm MPS4 (project mode, batch, no block
# design).
#
#   vivado -mode batch -source build.tcl -tclargs <out_dir> <rom_vmem> [flash_vmem] [jobs] [ddr_loopback] [hr_loopback]
#
# ddr_loopback: 1 (default) = DDR pads on unconnected balls + on-chip DRAM
# emulator (constr/ddr_loopback.xdc), 0 = FMC+ DDR2 card (constr/ddr_card.xdc).
# hr_loopback: the same for the HyperRAM (constr/hyperram_loopback.xdc, on-chip
# HyperRAM emulator / constr/hyperram_card.xdc, the card's S80KS2562); default:
# ddr_loopback.
# Normally called from hw/fpga/mps4/Makefile (`make fpga BOARD=mps4` at the top).
# The project is kept in <out_dir>/vivado and can be opened in the GUI.
# Outputs in <out_dir>: bow32_mps4.bit and the reports below.

set script_dir [file dirname [file normalize [info script]]]
set board_dir  [file normalize [file join $script_dir ..]]
set repo_root  [file normalize [file join $board_dir .. .. ..]]

if {[llength $argv] < 2} {
  error "usage: build.tcl <out_dir> <rom_vmem> \[flash_vmem\] \[jobs\] \[ddr_loopback\] \[hr_loopback\]"
}
set out_dir      [file normalize [lindex $argv 0]]
set rom_vmem     [file normalize [lindex $argv 1]]
set flash_vmem   [lindex $argv 2]
set jobs         [expr {[llength $argv] > 3 && [lindex $argv 3] ne "" ? [lindex $argv 3] : 4}]
set ddr_loopback [expr {[llength $argv] > 4 && [lindex $argv 4] ne "" ? [lindex $argv 4] : 1}]
set hr_loopback  [expr {[llength $argv] > 5 && [lindex $argv 5] ne "" ? [lindex $argv 5] : $ddr_loopback}]

set part xcvu13p-fhga2104-1-e
set top  bow32_mps4_top

# set_bus_skew constraints expected in the XDC files (each one is reported as
# one "Slack (MET)" line by report_bus_skew): the gray pointers of the DDR
# read FIFO and of the three HyperRAM FIFOs (read FIFO, command and response
# FIFOs of the window; constr/mps4.xdc). The other DDR crossings (clk_sys <->
# ddr_sys, ddr_clk) are handshakes without gray coded buses.
set bus_skew_count 8

if {![file exists $rom_vmem]} {
  error "boot ROM image $rom_vmem not found (run `make sw` first)"
}
if {$ddr_loopback ne "0" && $ddr_loopback ne "1"} {
  error "ddr_loopback must be 0 or 1, not '$ddr_loopback'"
}
if {$hr_loopback ne "0" && $hr_loopback ne "1"} {
  error "hr_loopback must be 0 or 1, not '$hr_loopback'"
}

source [file join $repo_root hw fpga common tcl filelist.tcl]
source [file join $script_dir timing_checks.tcl]

# ---------------------------------------------------------------- project
create_project bow32_mps4 [file join $out_dir vivado] -part $part -force

# ---------------------------------------------------------------- sources
lassign [bow32_parse_f [file join $board_dir mps4.f]] rtl_files inc_dirs
# A file listed twice is added once.
set uniq_files {}
foreach f $rtl_files {
  if {[lsearch -exact $uniq_files $f] < 0} {
    lappend uniq_files $f
  }
}
add_files -norecurse $uniq_files
set_property include_dirs $inc_dirs [current_fileset]
set_property verilog_define {SYNTHESIS FPGA_XILINX} [current_fileset]

add_files -fileset constrs_1 -norecurse [file join $board_dir constr mps4.xdc]
if {$ddr_loopback} {
  add_files -fileset constrs_1 -norecurse [file join $board_dir constr ddr_loopback.xdc]
} else {
  add_files -fileset constrs_1 -norecurse [file join $board_dir constr ddr_card.xdc]
}
if {$hr_loopback} {
  add_files -fileset constrs_1 -norecurse [file join $board_dir constr hyperram_loopback.xdc]
} else {
  add_files -fileset constrs_1 -norecurse [file join $board_dir constr hyperram_card.xdc]
}

# Memory images and the DDR variant are parameters of the top level.
set generics "RomInitFile=\"$rom_vmem\" DdrLoopback=1'b$ddr_loopback HrLoopback=1'b$hr_loopback"
if {$flash_vmem ne ""} {
  append generics " FlashInitFile=\"[file normalize $flash_vmem]\""
}
set_property generic $generics [current_fileset]

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
report_timing_summary    -file [file join $out_dir timing_summary.rpt]
report_utilization       -file [file join $out_dir utilization.rpt]
report_utilization -slr  -file [file join $out_dir utilization_slr.rpt]
report_clocks            -file [file join $out_dir clocks.rpt]
report_clock_interaction -file [file join $out_dir clock_interaction.rpt]
report_clock_utilization -file [file join $out_dir clock_utilization.rpt]
check_timing -verbose    -file [file join $out_dir check_timing.rpt]
report_methodology       -file [file join $out_dir methodology.rpt]
report_drc               -file [file join $out_dir drc.rpt]
report_io                -file [file join $out_dir io.rpt]
# The DDR / HyperRAM paths that the write phase knobs depend on (PHY -> ODDRE1).
report_timing -from [get_clocks ddr_clk] -to [get_clocks {ddr_wclk ddr_wclk90}] \
  -delay_type min_max -max_paths 4 -file [file join $out_dir ddr_write_paths.rpt]
report_timing -from [get_clocks hr_clk] -to [get_clocks hr_wclk] \
  -delay_type min_max -max_paths 4 -file [file join $out_dir hr_write_paths.rpt]
# Clock periods, the constraint of every clock pair (the DFI ddr_sys <->
# ddr_clk timed, the asynchronous pairs under max delay), check_timing;
# reports ddr_dfi_paths.rpt, ddr_cdc_paths.rpt, cdc.rpt (tcl/timing_checks.tcl).
set clk_failed [bow32_mps4_timing_checks $out_dir]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
# Setup, hold and pulse width together: the summary has one verdict line
set fh [open [file join $out_dir timing_summary.rpt] r]
set timing_met [regexp {All user specified timing constraints are met} [read $fh]]
close $fh

# Gray coded buses (set_bus_skew): one "Slack (MET)" per constraint. A
# constraint whose cells are not found (renamed RTL) is missing from the
# report, so count them against bus_skew_count.
set skew [report_bus_skew -return_string]
set fh [open [file join $out_dir bus_skew.rpt] w]
puts $fh $skew
close $fh
set skew_met [regexp -all {Slack \(MET\)} $skew]
if {[regexp {Slack \(VIOLATED\)} $skew] || $skew_met != $bus_skew_count} {
  puts "CRITICAL WARNING: bus skew violated or not constrained ($skew_met of $bus_skew_count met), see bus_skew.rpt"
}

# The DDR pads must be in their IOBs: every ODDRE1 (OSERDESE3 after
# synthesis) and IDDRE1 placed in a pin's I/O bitslice (anything else would
# break the pin timing contract).
set io_bad 0
foreach c [get_cells -quiet -hierarchical -filter {REF_NAME == OSERDESE3 || REF_NAME == IDDRE1}] {
  set site [get_property LOC $c]
  if {![string match "BITSLICE_*" $site]} {
    puts "CRITICAL WARNING: $c is placed at '$site', not in an I/O bitslice"
    incr io_bad
  }
}

file copy -force [file join [get_property DIRECTORY [get_runs impl_1]] $top.bit] \
                 [file join $out_dir bow32_mps4.bit]

set variant [expr {$ddr_loopback ? "DDR loopback" : "DDR card"}]
append variant [expr {$hr_loopback ? ", HyperRAM loopback" : ", HyperRAM card"}]
puts "INFO: bitstream [file join $out_dir bow32_mps4.bit] ($variant, setup WNS = $wns ns, hold WHS = $whs ns)"
if {!$timing_met} {
  puts "CRITICAL WARNING: timing constraints are not met (setup, hold or pulse width), see timing_summary.rpt"
}
if {$clk_failed} {
  puts "CRITICAL WARNING: $clk_failed clock / CDC checks failed (see above), the bitstream may not work"
}
