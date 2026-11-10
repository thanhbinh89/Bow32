# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Vivado build of Bow32 for the Huins MFP-VP1902-S (project mode, batch, no
# block design: Vivado adds a default PS wizard to the PL-only netlist and
# builds the PLM for the device image).
#
#   vivado -mode batch -source build.tcl -tclargs <out_dir> <rom_vmem> <pins_xdc> \
#     [flash_vmem] [jobs] [ddr_loopback] [hr_loopback] [clk_src] [card] [plan]
#
# pins_xdc: the PACKAGE_PIN lines written by tools/huins_pins.py (confidential,
# in the build directory). ddr_loopback / hr_loopback (card ram only): 0
# (default) = the card's DDR2 / HyperRAM, 1 = the on-chip emulators behind the
# same pads. clk_src: ref200 (default, the fixed 200 MHz board oscillator,
# constr/clk_ref200.xdc); site (the FMC+ site's PL clock) is refused for now,
# see constr/clk_site.xdc. card: ram (default, bow32_huins_vp1902_top with the
# FMC+_DDR2_HyperRam card) or cam (bow32_huins_vp1902_cam_top, the IMX274
# camera on the Huins camera adapter on FMC+01, docs/camera_huins.md). plan
# (card cam): the XPHY nibble plan that tcl/cam_plan.tcl derived from pins_xdc
# (default: pins_fmc<site>_xphy_plan.txt next to pins_xdc, as the Makefile names
# it; confidential, in the build directory); its generics go to the camera top.
# Normally called from hw/fpga/huins_vp1902/Makefile (`make fpga BOARD=huins_vp1902`,
# `make fpga BOARD=huins_vp1902 CARD=cam`).
# The project is kept in <out_dir>/vivado. Outputs in <out_dir>:
# bow32_huins_vp1902.pdi (ram) / bow32_huins_vp1902_cam.pdi (cam) and the reports below.

set script_dir [file dirname [file normalize [info script]]]
set board_dir  [file normalize [file join $script_dir ..]]
set repo_root  [file normalize [file join $board_dir .. .. ..]]

if {[llength $argv] < 3} {
  error "usage: build.tcl <out_dir> <rom_vmem> <pins_xdc> \[flash_vmem\] \[jobs\] \[ddr_loopback\] \[hr_loopback\] \[clk_src\] \[card\] \[plan\]"
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
set card         [arg 8 ram]
set plan_file    [file normalize [arg 9 [regsub {_[a-z0-9]+\.xdc$} $pins_xdc {_xphy_plan.txt}]]]

set part xcvp1902-vsva6865-2MP-e-S

# Per card: top, file list, project / image name, board XDCs (after the clock
# input), and the set_bus_skew constraints the board XDC has.
switch -- $card {
  ram {
    set top      bow32_huins_vp1902_top
    set flist    huins_vp1902.f
    set project  bow32_huins_vp1902
    set pdi_name bow32_huins_vp1902.pdi
    set xdcs     {huins_vp1902.xdc ddr_pads.xdc hyperram_pads.xdc}
    # set_bus_skew constraints expected in constr/huins_vp1902.xdc: the gray
    # pointers of the DDR read FIFO and of the three HyperRAM FIFOs.
    set bus_skew_count 8
  }
  cam {
    set top      bow32_huins_vp1902_cam_top
    set flist    huins_vp1902_cam.f
    set project  bow32_huins_vp1902_cam
    set pdi_name bow32_huins_vp1902_cam.pdi
    set xdcs     {huins_vp1902_cam.xdc cam_pads.xdc}
    # constr/huins_vp1902_cam.xdc: CSI-2 receiver 9 (pixel FIFO 2, byte clock
    # meter, LOG / RAW requests and acknowledges 4, DLYn load requests + taps,
    # DLYn tap readback), H.264 output FIFO 2
    set bus_skew_count 11
  }
  default { error "card must be ram or cam, not '$card'" }
}

if {![file exists $rom_vmem]} {
  error "boot ROM image $rom_vmem not found (run `make sw` first)"
}
if {![file exists $pins_xdc]} {
  error "pin constraints $pins_xdc not found (tools/huins_pins.py, see the Makefile)"
}
# Camera: the XPHY nibble plan of the pins (tcl/cam_plan.tcl, make plan CARD=cam): the
# Dphy* generics of the top, the bank and the nibbles of the XPHYs (checked after route)
set cam_generics ""
set cam_bank     ""
set cam_nibs     {}
if {$card eq "cam"} {
  if {![file exists $plan_file]} {
    error "XPHY nibble plan $plan_file not found (make plan CARD=cam, tcl/cam_plan.tcl)"
  }
  if {[file mtime $plan_file] < [file mtime $pins_xdc]} {
    error "XPHY nibble plan $plan_file is older than $pins_xdc (make plan CARD=cam)"
  }
  set fh [open $plan_file r]
  foreach line [split [read $fh] "\n"] {
    regexp {^generics\s+(.+\S)\s*$} $line -> cam_generics
    regexp {^bank\s+(\d+)\s*$} $line -> cam_bank
    regexp {^nibbles\s+([\d ]+\d)\s*$} $line -> cam_nibs
  }
  close $fh
  if {![regexp {^DphyNumNib=[1-4]( Dphy[A-Za-z]+=[0-9]+'h[0-9a-f]+){5}$} $cam_generics] ||
      $cam_bank eq "" || [llength $cam_nibs] < 1} {
    error "XPHY nibble plan $plan_file is incomplete (make plan CARD=cam)"
  }
  puts "INFO: XPHY nibble plan [file tail $plan_file]: bank $cam_bank, [llength $cam_nibs] XPHY\
        nibbles (generics of $top)"
}
foreach {name val} [list ddr_loopback $ddr_loopback hr_loopback $hr_loopback] {
  if {$val ne "0" && $val ne "1"} {
    error "$name must be 0 or 1, not '$val'"
  }
  if {$card ne "ram" && $val ne "0"} {
    error "$name only applies to the RAM card (CARD=ram), not to card '$card'"
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
if {$card eq "ram"} {
  source [file join $script_dir timing_checks.tcl]
} else {
  source [file join $script_dir timing_checks_cam.tcl]
  source [file join $script_dir cam_xphy.tcl]
}

# ---------------------------------------------------------------- project
create_project $project [file join $out_dir vivado] -part $part -force

# ---------------------------------------------------------------- sources
lassign [bow32_parse_f [file join $board_dir $flist]] rtl_files inc_dirs
set uniq_files {}
foreach f $rtl_files {
  if {[lsearch -exact $uniq_files $f] < 0} {
    lappend uniq_files $f
  }
}
add_files -norecurse $uniq_files
set_property include_dirs $inc_dirs [current_fileset]
set_property verilog_define {SYNTHESIS FPGA_XILINX} [current_fileset]

# The input clock first: the board XDC renames the clocks Vivado derives from
# it at the MMCM outputs.
set xdc_files [list [file join $board_dir constr clk_$clk_src.xdc]]
foreach x $xdcs {
  lappend xdc_files [file join $board_dir constr $x]
}
lappend xdc_files $pins_xdc
add_files -fileset constrs_1 -norecurse $xdc_files

# Memory images, the memory variants, the clock input and (camera) the XPHY nibble
# plan are parameters of the top level.
set generics "RomInitFile=\"$rom_vmem\""
if {$card eq "ram"} {
  append generics " DdrLoopback=1'b$ddr_loopback HrLoopback=1'b$hr_loopback"
} else {
  append generics " $cam_generics"
}
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

if {$card eq "ram"} {
  # MMCMs next to the card's pads, the input clock across the SLRs (tcl/pre_place.tcl)
  set_property STEPS.PLACE_DESIGN.TCL.PRE [file join $script_dir pre_place.tcl] [get_runs impl_1]
} else {
  # XPHY LOCs from the camera pins + nibble plan check (tcl/pre_opt_cam.tcl), the MMCM
  # and the SoC next to the camera, the input clock across the SLRs (tcl/pre_place_cam.tcl)
  set_property STEPS.OPT_DESIGN.TCL.PRE   [file join $script_dir pre_opt_cam.tcl]   [get_runs impl_1]
  set_property STEPS.PLACE_DESIGN.TCL.PRE [file join $script_dir pre_place_cam.tcl] [get_runs impl_1]
}
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
if {$card eq "ram"} {
  # The DDR / HyperRAM paths that the write phase knobs depend on (PHY -> ODDRE1).
  report_timing -from [get_clocks ddr_clk] -to [get_clocks {ddr_wclk ddr_wclk90}] \
    -delay_type min_max -max_paths 4 -file [file join $out_dir ddr_write_paths.rpt]
  report_timing -from [get_clocks hr_clk] -to [get_clocks hr_wclk] \
    -delay_type min_max -max_paths 4 -file [file join $out_dir hr_write_paths.rpt]
  # Clock periods, the constraint of every clock pair, check_timing; reports
  # ddr_dfi_paths.rpt, ddr_cdc_paths.rpt, cdc.rpt (tcl/timing_checks.tcl).
  set clk_failed [bow32_huins_timing_checks $out_dir]
} else {
  # Clock periods, clock pairs (all asynchronous groups), the byte clock source,
  # check_timing; reports dphy_paths.rpt, domain_paths.rpt, cdc.rpt
  # (tcl/timing_checks_cam.tcl).
  set clk_failed [bow32_huins_cam_timing_checks $out_dir]
}

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

# Pads in their I/O sites: every ODDRE1 (data and T) and IDDRE1 placed in the
# XPIO logic of a pin, and the expected number of T ODDRs (TFromOddr: DQ 8 +
# DQS 2 + HyperRAM DQ 8 + RWDS 1 in the RAM card build; the two I2C pads in
# the camera build).
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
if {$card eq "ram"} {
  set want_toddr [expr {($ddr_loopback ? 0 : 10) + ($hr_loopback ? 0 : 9)}]
} else {
  set want_toddr 2
}
if {$n_toddr != $want_toddr} {
  puts "CRITICAL WARNING: $n_toddr T ODDRs, expected $want_toddr (TFromOddr)"
  incr io_bad
}
set fh [open [file join $out_dir io_sites.rpt] w]
foreach c [lsort [get_cells -quiet -hierarchical -filter {REF_NAME == ODDRE1 || REF_NAME == IDDRE1}]] {
  puts $fh "[get_property LOC $c] [get_property BEL $c] $c"
}
if {$card eq "cam"} {
  # D-PHY: the XPHYs in the bank and nibbles of the plan (tcl/cam_plan.tcl) at the sites
  # of their pins, the strobe on the clock lane, the forwarding legal (tcl/cam_xphy.tcl);
  # the 40 capture flops (4 lanes + clock lane samples) with BLI TRUE in BLI sites.
  set xphys [bow32_cam_xphys u_dphy]
  foreach c $xphys {
    puts $fh "[get_property LOC $c] $c DQS_SRC=[get_property DQS_SRC $c]"
  }
  set nibs {}
  foreach c $xphys {
    set pads [bow32_cam_xphy_pads $c]
    set loc  [expr {[llength $pads] ? [bow32_cam_pin_loc [lindex $pads 0 2]] : {}}]
    if {[llength $loc] == 3} {
      lappend nibs [lindex $loc 1]
    }
  }
  if {[llength $xphys] != [llength $cam_nibs] ||
      [lsort -integer $nibs] ne [lsort -integer $cam_nibs]} {
    puts "CRITICAL WARNING: [llength $xphys] XPHYs in nibbles '[lsort -integer $nibs]', the plan\
          [file tail $plan_file] has [llength $cam_nibs] in nibbles '[lsort -integer $cam_nibs]'"
    incr io_bad
  }
  foreach e [bow32_cam_check_xphys u_dphy $cam_bank mipi_clk_p_i] {
    puts "CRITICAL WARNING: cam_xphy: $e"
    incr io_bad
  }
  set bli [get_cells -quiet -hierarchical -filter {BLI == TRUE && NAME =~ u_dphy/*}]
  set n_bli_site 0
  foreach c $bli {
    set s [get_property LOC $c]
    set t [expr {$s eq "" ? "" : [get_property SITE_TYPE [get_sites $s]]}]
    if {[string match "BLI*" $t]} {
      incr n_bli_site
    }
    puts $fh "$s $t $c"
  }
  if {[llength $bli] != 40 || $n_bli_site != 40} {
    puts "CRITICAL WARNING: [llength $bli] BLI capture flops, $n_bli_site in BLI sites, expected 40 (constr/huins_vp1902_cam.xdc)"
    incr io_bad
  }
  # Site VCCIO: banks 703..706 of FMC+01 share one supply (slide switch SW192, 1.2 V for
  # MIPI_DPHY, docs/camera_huins.md). Vivado checks the VCCO of each bank, not of a board
  # supply shared by several banks, so every port there must use a 1.2 V standard: the
  # 10 MIPI_DPHY pads and 5 control pins (bank 705) and PRSNT_M2C_L (bank 703).
  set n_site 0
  set banks {}
  foreach port [lsort [get_ports]] {
    set ball [get_property PACKAGE_PIN $port]
    if {$ball eq ""} {
      continue
    }
    set bank [get_property BANK [get_package_pins $ball]]
    lappend banks $bank
    if {$bank ni {703 704 705 706}} {
      continue
    }
    incr n_site
    set std [get_property IOSTANDARD $port]
    puts $fh "bank $bank $std $port"
    if {$std ni {MIPI_DPHY LVCMOS12}} {
      puts "CRITICAL WARNING: port $port in bank $bank (FMC+01 site VCCIO, SW192 = 1.2 V) has IOSTANDARD $std"
      incr io_bad
    }
  }
  if {$n_site != 16} {
    puts "CRITICAL WARNING: $n_site ports in banks 703..706, expected 16 (camera pads and PRSNT_M2C_L)"
    incr io_bad
  }
  puts "INFO: I/O banks used: [lsort -unique $banks] ($n_site ports on the FMC+01 site VCCIO, 1.2 V)"
}
close $fh

set pdi [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.pdi]]
if {[llength $pdi] != 1} {
  error "expected one device image in [get_property DIRECTORY [get_runs impl_1]], found: $pdi"
}
file copy -force [lindex $pdi 0] [file join $out_dir $pdi_name]
set ltx [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.ltx]]
foreach f $ltx {
  file copy -force $f $out_dir
}

if {$card eq "ram"} {
  set variant [expr {$ddr_loopback ? "DDR loopback" : "DDR card"}]
  append variant [expr {$hr_loopback ? ", HyperRAM loopback" : ", HyperRAM card"}]
} else {
  set variant "IMX274 camera on the FMC+01 adapter"
}
append variant ", clock $clk_src"
puts "INFO: device image [file join $out_dir $pdi_name] ($variant, setup WNS = $wns ns, hold WHS = $whs ns)"
if {!$timing_met} {
  puts "CRITICAL WARNING: timing constraints are not met (setup, hold or pulse width), see timing_summary.rpt"
}
if {$clk_failed} {
  puts "CRITICAL WARNING: $clk_failed clock / CDC checks failed (see above), the image may not work"
}
if {$io_bad} {
  puts "CRITICAL WARNING: $io_bad pad placement problems (see above and io_sites.rpt)"
}
