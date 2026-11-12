# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Out-of-context check of the receiver part of the KV260 camera build (decision D1 of
# docs/ip/mipi_rx_arch.md: no KV260 bitstream and no KV260 board run during the migration
# steps, but its receiver must still implement). Normally run by the Makefile:
#
#   make -C hw/fpga/kv260_cam rx-ooc     (vivado in PATH)
#   vivado -mode batch -source rx_ooc.tcl -tclargs <repo> <out_dir>
#
# rx_ooc_top.sv (the receiver at u_soc/u_csi2rx, the UltraScale+ AFE adapter at u_dphy, on
# the MIPI pins of the board) is synthesised, placed and routed on the KV260 part with the
# receiver constraints of constr/kv260_cam.xdc as written (pins, clocks, CE false path,
# CLOCK_DELAY_GROUP, the receiver's set_bus_skew; the H.264 lines are left out: no cells
# here), the directives of tcl/build.tcl. Then the checks of tcl/build.tcl and of the camera
# builds, each one a line of <out_dir>/rx_ooc_result.txt; the last line is "RX_OOC: PASS"
# or "RX_OOC: FAIL (<n> checks)":
#   * timing met (setup, hold, pulse width);
#   * every set_bus_skew of the receiver met (as many as kv260_cam.xdc has without the H.264
#     lines), their cells right (hw/fpga/common/tcl/bus_skew_checks.tcl: in u_soc/u_csi2rx
#     or u_dphy/u_dly); the delay code constraint with 10 endpoints per lane;
#   * the CE false path finds both BUFGCE_DIV CE pins, the CLOCK_DELAY_GROUP has the two
#     D-PHY clock nets (also in the placer's clockInfo.txt);
#   * the ISERDESE3 RST, IDELAYE3 LOAD and CNTVALUEIN of every lane are driven by the
#     adapter's logic (u_dphy/u_dly);
#   * report_cdc: every critical row is one of the reviewed kinds (reset synchroniser CLR
#     pins, the merged lane enable flop, the byte clock gate, the HS receiver and (step 6)
#     termination enables and the data pins into the ISERDESE3), as in
#     tcl/timing_checks_cam.tcl of the Huins build.
# Reports in <out_dir>: timing_summary.rpt, bus_skew.rpt, cdc.rpt, clocks.rpt,
# clock_interaction.rpt, check_timing.rpt, methodology.rpt, util.rpt, rx_ooc_routed.dcp.

lassign $argv repo out
set repo [file normalize $repo]
set out  [file normalize $out]
file mkdir $out
cd $out
source [file join $repo hw fpga common tcl filelist.tcl]
source [file join $repo hw fpga common tcl bus_skew_checks.tcl]

set lanes 2
set files {}
foreach f {hw/ip/common/common.f hw/ip/bus/bus.f hw/ip/dphy_rx/dphy_rx.f hw/ip/csi2rx/csi2rx.f} {
  lassign [bow32_parse_f [file join $repo $f]] fl inc
  lappend files {*}$fl
}
lappend files [file join $repo hw fpga common rtl bow_dphy_dly_xusp.sv] \
              [file join $repo hw fpga common rtl bow_dphy_io_xusp.sv] \
              [file join $repo hw fpga kv260_cam ooc rx_ooc_top.sv]
read_verilog -sv $files
synth_design -top bow32_kv260_rx_ooc_top -part xck26-sfvc784-2LV-c -flatten_hierarchy rebuilt \
  -verilog_define SYNTHESIS -verilog_define FPGA_XILINX

# clk_sys (50 MHz) and clk_vid (200 MHz) are pins here, not clock capable ones (no LOC):
# general routing to their BUFG
create_clock -name clk_sys -period 20 [get_ports clk_sys]
create_clock -name clk_vid -period 5  [get_ports clk_vid]
set_property IOSTANDARD LVCMOS18 [get_ports {clk_sys clk_vid rst_n_pin led}]
set ibuf_out [get_nets -quiet -of_objects [get_pins -quiet -filter {DIRECTION == OUT} \
  -of_objects [get_cells -quiet -filter {REF_NAME =~ IBUF*} \
  -of_objects [get_nets -quiet {clk_sys clk_vid}]]]]
if {[llength $ibuf_out] > 0} {
  set_property CLOCK_DEDICATED_ROUTE FALSE $ibuf_out
}
set_false_path -from [get_ports rst_n_pin]
set_false_path -to [get_ports led]

# The receiver constraints of the board XDC: every line but the H.264 output FIFO ones
set fh [open [file join $repo hw fpga kv260_cam constr kv260_cam.xdc] r]
set txt [string map [list "\\\n" " "] [read $fh]]
close $fh
set keep {}
set n_skew 0
foreach line [split $txt "\n"] {
  if {[string match *u_h264* $line]} {
    continue
  }
  if {[regexp {^\s*set_bus_skew} $line]} {
    incr n_skew
  }
  lappend keep $line
}
set fx [open rx.xdc w]
puts $fx [join $keep "\n"]
close $fx
read_xdc rx.xdc

# as tcl/build.tcl
opt_design
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
phys_opt_design

report_timing_summary -file timing_summary.rpt
report_clocks -file clocks.rpt
report_clock_interaction -file clock_interaction.rpt
check_timing -verbose -file check_timing.rpt
report_methodology -file methodology.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file util.rpt

set res {}
set bad 0
proc result {ok line} {
  upvar res res bad bad
  lappend res "RX_OOC [expr {$ok ? {ok} : {FAIL}}]: $line"
  if {!$ok} {
    incr bad
  }
}

# ---- timing
set fh [open timing_summary.rpt r]
set met [regexp {All user specified timing constraints are met} [read $fh]]
close $fh
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set per {}
foreach clk [get_clocks] {
  set s [get_timing_paths -setup -from $clk -to $clk -max_paths 1 -nworst 1]
  set h [get_timing_paths -hold -from $clk -to $clk -max_paths 1 -nworst 1]
  if {$s ne ""} {
    lappend per "[get_property NAME $clk] [get_property SLACK $s] / [get_property SLACK $h]"
  }
}
result $met "timing met $met, WNS $wns ns, WHS $whs ns (setup / hold per clock: [join $per {, }])"

# ---- bus skew: every receiver constraint met, its cells right, the delay codes 10 / lane
set skew [report_bus_skew -return_string]
set fh [open bus_skew.rpt w]
puts $fh $skew
close $fh
set skew_met [regexp -all {Slack \(MET\)} $skew]
set skew_bad [regexp -all {Slack \(VIOLATED\)} $skew]
result [expr {$skew_met == $n_skew && $skew_bad == 0}] \
  "bus skew: $skew_met of $n_skew constraints met, $skew_bad violated"
set problems [bow32_bus_skew_checks $skew {u_soc/u_csi2rx/ u_dphy/u_dly/}]
result [expr {[llength $problems] == 0}] "bus skew cells: [llength $problems] problems"
foreach p $problems {
  lappend res "RX_OOC   $p"
}
set n_code -1
foreach {- id cmd n} [regexp -all -inline -line \
    {^Id: (\d+)\n(set_bus_skew .*)\nRequirement: .*\nEndpoints: (\d+)$} $skew] {
  lappend res "RX_OOC   bus skew $id: $n endpoints: [string range $cmd 0 120]"
  if {[string match *u_sync_code* $cmd]} {
    set n_code $n
  }
}
result [expr {$n_code == 10 * $lanes}] \
  "delay codes + OWN -> u_dphy/u_dly: $n_code endpoints (10 per lane: $lanes lanes)"

# ---- CE false path, CLOCK_DELAY_GROUP
set ce [get_pins -quiet {u_dphy/u_hs_bufg/CE u_dphy/u_byte_bufg/CE}]
result [expr {[llength $ce] == 2}] "CE false path pins: [lsort [get_property NAME $ce]]"
set cdg [get_nets -quiet -hierarchical -filter {CLOCK_DELAY_GROUP == bow_dphy_rx_clk}]
set ci ""
foreach f [glob -nocomplain clockInfo.txt */clockInfo.txt] {
  set fh [open $f r]
  append ci [read $fh]
  close $fh
}
result [expr {[llength $cdg] == 2 &&
              [regexp {The following 2 clock nets belong to CLOCK_DELAY_GROUP bow_dphy_rx_clk} $ci]}] \
  "CLOCK_DELAY_GROUP bow_dphy_rx_clk: [llength $cdg] nets ([lsort [get_property NAME $cdg]]),\
   clockInfo.txt: [expr {[regexp {2 clock nets belong to CLOCK_DELAY_GROUP bow_dphy_rx_clk} $ci] ? {both} : {not found}}]"

# ---- the adapter's logic drives the primitives
proc driver {pin} {
  set net [get_nets -quiet -of_objects [get_pins -quiet $pin]]
  return [get_property -quiet NAME [get_cells -quiet -of_objects \
    [get_pins -quiet -leaf -filter {DIRECTION == OUT} -of_objects $net]]]
}
for {set l 0} {$l < $lanes} {incr l} {
  set d0 [driver "u_dphy/g_lane\[$l\].u_iserdes/RST"]
  set d1 [driver "u_dphy/g_lane\[$l\].u_idelay/LOAD"]
  set d2 [driver "u_dphy/g_lane\[$l\].u_idelay/CNTVALUEIN\[0\]"]
  result [expr {$d0 eq {u_dphy/u_dly/u_iserdes_rst/sync_q_reg[1]} &&
                [string match {u_dphy/u_dly/load_q_reg*} $d1] &&
                [string match {u_dphy/u_dly/tap_ld_q_reg*} $d2]}] \
    "lane $l: ISERDESE3 RST <- $d0, IDELAYE3 LOAD <- $d1, CNTVALUEIN\[0\] <- $d2"
}

# ---- report_cdc: the critical rows are the reviewed kinds
proc cdc_known {id from to} {
  switch -- $id {
    CDC-10 {
      return [regexp {/u_[a-z]*rst/sync_q_reg\[0\]/CLR$} $to]
    }
    CDC-11 {
      return [expr {[regexp {/u_regs/lane_en_q_reg\[\d+\]/C$} $from] &&
                    [regexp {/u_sync_vcfg/g_bit\[\d+\]\.u_sync/sync_q_reg\[0\]/D$} $to]}]
    }
    CDC-13 {
      if {[regexp {/u_lp_clk/ce_q_reg/C$} $from] &&
          $to in {u_dphy/u_byte_bufg/CE u_dphy/u_hs_bufg/CE}} {
        return 1
      }
      # the HS receiver enable and, since step 6, the termination enable (its own flop:
      # HSRX_DISABLE = ~(hsrx_en | term_en), one pin of IBUFDS_DPHY for both; term_en only
      # while hsrx_en, both change in LP states only, bow_afe_chk) and the data pins (false
      # path: the capture is calibrated at run time) in front of the ISERDESE3
      return [expr {[regexp {^u_dphy/g_lane\[\d+\]\.u_iserdes/D$} $to] &&
                    ([regexp {/g_lp\[\d+\]\.u_lp/(hs_en|term)_q_reg/C$} $from] ||
                     [regexp {^mipi_phy_if_raspi_data_p\[\d+\]$} $from])}]
    }
  }
  return 0
}
set cdc [report_cdc -details -return_string]
set fh [open cdc.rpt w]
puts $fh $cdc
close $fh
set counts [dict create]
set unknown 0
foreach line [split $cdc "\n"] {
  if {[regexp {^\s*\d+\s+(CDC-\d+)\s} $line -> id]} {
    dict incr counts $id
    if {$id in {CDC-1 CDC-4 CDC-7 CDC-10 CDC-11 CDC-12 CDC-13 CDC-14}} {
      set w [regexp -all -inline {\S+} $line]
      set from [lindex $w end-1]
      set to [lindex $w end]
      if {![cdc_known $id $from $to]} {
        incr unknown
        lappend res "RX_OOC   CDC not reviewed: $id $from -> $to"
      }
    }
  }
}
set per {}
dict for {id n} $counts {
  lappend per "$id $n"
}
result [expr {$unknown == 0}] "report_cdc: $unknown critical rows not reviewed ([join [lsort $per] {, }])"

# ---- utilisation (report_utilization -hierarchical: Total LUTs, FFs) of the receiver, the
# D-PHY, the controller and the adapter's logic
set util {}
set ur [report_utilization -hierarchical -hierarchical_depth 3 -return_string]
foreach {name mod} {receiver bow_mipi_rx d-phy bow_dphy_rx controller bow_csi2rx
                    adapter bow_dphy_io_xusp adapter_logic bow_dphy_dly_xusp} {
  if {[regexp "\\|\\s+$mod\\s+\\|\\s+(\\d+)\\s+\\|\\s+\\d+\\s+\\|\\s+\\d+\\s+\\|\\s+\\d+\\s+\\|\\s+(\\d+)\\s+\\|" \
         $ur -> lut ff]} {
    lappend util "$name $lut LUT / $ff FF"
  }
}
lappend res "RX_OOC   utilisation: [join $util {, }]"

lappend res [expr {$bad == 0 ? "RX_OOC: PASS" : "RX_OOC: FAIL ($bad checks)"}]
set fo [open rx_ooc_result.txt w]
puts $fo [join $res "\n"]
close $fo
puts [join $res "\n"]
write_checkpoint -force rx_ooc_routed.dcp
