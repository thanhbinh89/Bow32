# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Vivado build of Bow32 for the Huins MFP-VP1902-S (project mode, batch, no
# block design: Vivado adds a default PS wizard to the PL-only netlist and
# builds the PLM for the device image).
#
#   vivado -mode batch -source build.tcl -tclargs <out_dir> <rom_vmem> <pins_xdc> \
#     [flash_vmem] [jobs] [ddr_loopback] [hr_loopback] [clk_src]
#
# pins_xdc: the PACKAGE_PIN lines written by tools/huins_pins.py (confidential,
# in the build directory). ddr_loopback / hr_loopback: 0 (default) = the
# card's DDR2 / HyperRAM, 1 = the on-chip emulators behind the same pads.
# clk_src: ref200 (default, the fixed 200 MHz board oscillator, constr/
# clk_ref200.xdc); site (the FMC+ site's PL clock) is refused for now, see
# constr/clk_site.xdc.
# Normally called from hw/fpga/huins_vp1902/Makefile (`make fpga BOARD=huins_vp1902`).
# The project is kept in <out_dir>/vivado. Outputs in <out_dir>:
# bow32_huins_vp1902.pdi and the reports below.

set script_dir [file dirname [file normalize [info script]]]
set board_dir  [file normalize [file join $script_dir ..]]
set repo_root  [file normalize [file join $board_dir .. .. ..]]

if {[llength $argv] < 3} {
  error "usage: build.tcl <out_dir> <rom_vmem> <pins_xdc> \[flash_vmem\] \[jobs\] \[ddr_loopback\] \[hr_loopback\] \[clk_src\]"
}
proc arg {i default} {
  global argv
  return [expr {[llength $argv] > $i && [lindex $argv $i] ne "" ? [lindex $argv $i] : $default}]
}
set out_dir      [file normalize [lindex $argv 0]]
set rom_vmem     [file normalize [lindex $argv 1]]
set pins_xdc     [file normalize [lindex $argv 2]]
set flash_vmem   [lindex $argv 3]
set jobs         [arg 4 2]
set ddr_loopback [arg 5 0]
set hr_loopback  [arg 6 $ddr_loopback]
set clk_src      [arg 7 ref200]

set part xcvp1902-vsva6865-2MP-e-S
set top  bow32_huins_vp1902_top

# set_bus_skew constraints expected in constr/huins_vp1902.xdc: the gray
# pointers of the DDR read FIFO and of the three HyperRAM FIFOs.
set bus_skew_count 8

if {![file exists $rom_vmem]} {
  error "boot ROM image $rom_vmem not found (run `make sw` first)"
}
if {![file exists $pins_xdc]} {
  error "pin constraints $pins_xdc not found (tools/huins_pins.py, see the Makefile)"
}
foreach {name val} [list ddr_loopback $ddr_loopback hr_loopback $hr_loopback] {
  if {$val ne "0" && $val ne "1"} {
    error "$name must be 0 or 1, not '$val'"
  }
}
# MMCM input: period and VCO multiplier of each clock source (VCO 3200 MHz)
switch -- $clk_src {
  ref200  { set clk_period 5.0;  set vco_mult 16 }
  site    {
    # constr/clk_site.xdc: the AC-coupled site clock needs an internal DC
    # bias whose DC_BIAS code is not verified, and the clock module runs at
    # 16 MHz, not the 100 MHz assumed here
    error "clk_src site is not usable yet (no verified input bias, clock module at 16 MHz,\
           see constr/clk_site.xdc): use ref200"
  }
  default { error "clk_src must be ref200, not '$clk_src'" }
}

source [file join $repo_root hw fpga common tcl filelist.tcl]
source [file join $script_dir timing_checks.tcl]

# ---------------------------------------------------------------- project
create_project bow32_huins_vp1902 [file join $out_dir vivado] -part $part -force

# ---------------------------------------------------------------- sources
lassign [bow32_parse_f [file join $board_dir huins_vp1902.f]] rtl_files inc_dirs
set uniq_files {}
foreach f $rtl_files {
  if {[lsearch -exact $uniq_files $f] < 0} {
    lappend uniq_files $f
  }
}
add_files -norecurse $uniq_files
set_property include_dirs $inc_dirs [current_fileset]
set_property verilog_define {SYNTHESIS FPGA_XILINX} [current_fileset]

# The input clock first: constr/huins_vp1902.xdc renames the clocks Vivado
# derives from it at the MMCM outputs.
add_files -fileset constrs_1 -norecurse [list \
  [file join $board_dir constr clk_$clk_src.xdc] \
  [file join $board_dir constr huins_vp1902.xdc] \
  [file join $board_dir constr ddr_pads.xdc] \
  [file join $board_dir constr hyperram_pads.xdc] \
  $pins_xdc]

# Memory images, the memory variants and the clock input are parameters of
# the top level.
set generics "RomInitFile=\"$rom_vmem\" DdrLoopback=1'b$ddr_loopback HrLoopback=1'b$hr_loopback"
append generics " ClkInPeriodNs=$clk_period VcoMult=$vco_mult"
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

# MMCMs next to the card's pads, the input clock across the SLRs (tcl/pre_place.tcl)
set_property STEPS.PLACE_DESIGN.TCL.PRE [file join $script_dir pre_place.tcl] [get_runs impl_1]
launch_runs impl_1 -to_step write_device_image -jobs $jobs
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
# Clock periods, the constraint of every clock pair, check_timing; reports
# ddr_dfi_paths.rpt, ddr_cdc_paths.rpt, cdc.rpt (tcl/timing_checks.tcl).
set clk_failed [bow32_huins_timing_checks $out_dir]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set fh [open [file join $out_dir timing_summary.rpt] r]
set timing_met [regexp {All user specified timing constraints are met} [read $fh]]
close $fh

# Gray coded buses (set_bus_skew): one "Slack (MET)" per constraint.
set skew [report_bus_skew -return_string]
set fh [open [file join $out_dir bus_skew.rpt] w]
puts $fh $skew
close $fh
set skew_met [regexp -all {Slack \(MET\)} $skew]
if {[regexp {Slack \(VIOLATED\)} $skew] || $skew_met != $bus_skew_count} {
  puts "CRITICAL WARNING: bus skew violated or not constrained ($skew_met of $bus_skew_count met), see bus_skew.rpt"
}

# The DDR / HyperRAM pads must be in their I/O sites: every ODDRE1 (data and
# T) and IDDRE1 placed in the XPIO logic of a pin; and the expected number of
# T ODDRs (TFromOddr: DQ 8 + DQS 2 + HyperRAM DQ 8 + RWDS 1 in the card build).
set io_bad 0
set n_toddr 0
foreach c [get_cells -quiet -hierarchical -filter {REF_NAME == ODDRE1 || REF_NAME == IDDRE1}] {
  set site [get_property LOC $c]
  if {![string match "XPIOLOGIC*" $site]} {
    puts "CRITICAL WARNING: $c is placed at '$site', not in an XPIO logic site"
    incr io_bad
  }
  if {[string match "*u_toddr*" $c]} {
    incr n_toddr
  }
}
set want_toddr [expr {($ddr_loopback ? 0 : 10) + ($hr_loopback ? 0 : 9)}]
if {$n_toddr != $want_toddr} {
  puts "CRITICAL WARNING: $n_toddr T ODDRs, expected $want_toddr (TFromOddr)"
  incr io_bad
}
set fh [open [file join $out_dir io_sites.rpt] w]
foreach c [lsort [get_cells -quiet -hierarchical -filter {REF_NAME == ODDRE1 || REF_NAME == IDDRE1}]] {
  puts $fh "[get_property LOC $c] [get_property BEL $c] $c"
}
close $fh

set pdi [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.pdi]]
if {[llength $pdi] != 1} {
  error "expected one device image in [get_property DIRECTORY [get_runs impl_1]], found: $pdi"
}
file copy -force [lindex $pdi 0] [file join $out_dir bow32_huins_vp1902.pdi]
set ltx [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.ltx]]
foreach f $ltx {
  file copy -force $f $out_dir
}

set variant [expr {$ddr_loopback ? "DDR loopback" : "DDR card"}]
append variant [expr {$hr_loopback ? ", HyperRAM loopback" : ", HyperRAM card"}]
append variant ", clock $clk_src"
puts "INFO: device image [file join $out_dir bow32_huins_vp1902.pdi] ($variant, setup WNS = $wns ns, hold WHS = $whs ns)"
if {!$timing_met} {
  puts "CRITICAL WARNING: timing constraints are not met (setup, hold or pulse width), see timing_summary.rpt"
}
if {$clk_failed} {
  puts "CRITICAL WARNING: $clk_failed clock / CDC checks failed (see above), the image may not work"
}
if {$io_bad} {
  puts "CRITICAL WARNING: $io_bad pad placement problems (see above and io_sites.rpt)"
}
