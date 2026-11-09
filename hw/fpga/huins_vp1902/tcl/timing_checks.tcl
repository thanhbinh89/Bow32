# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Clock and CDC checks of the Huins VP1902 build on an open design constrained by
# constr/huins_vp1902.xdc (tcl/build.tcl runs them after implementation):
#
#   source timing_checks.tcl
#   set failed [bow32_huins_timing_checks <out_dir>]
#
# Every failed check prints a CRITICAL WARNING; the result is their number.
#   * clock periods: the exceptions of constr/huins_vp1902.xdc use fixed numbers
#     (clk_sys 20 ns, ddr_clk 7.5 ns, ddr_sys 30 ns, hr_clk 10 ns);
#   * each clock pair with paths between two different clocks has the
#     constraint the XDC means (report_clock_interaction, column
#     Inter-Clock Constraints): "Max Delay Datapath Only" between the
#     asynchronous pairs, "Timed" (no exception at all) for the DFI between
#     LiteDRAM and the PHY (ddr_sys <-> ddr_clk, both directions must have
#     paths) and for the PHY -> write clock ODDR paths (DDR and HyperRAM:
#     hr_clk -> hr_wclk). Any other pair is
#     unexpected: e.g. a path from ddr_sys to the write clocks, a DFI path
#     cut by an exception, a crossing that no max delay covers;
#   * check_timing: no unclocked or multiply clocked register, no constant
#     or pulse width clock problem, no unconstrained internal endpoint, no
#     generated clock problem, no loop, no partial I/O delay.
# Reports in <out_dir>: ddr_dfi_paths.rpt (ddr_sys <-> ddr_clk, setup and
# hold), ddr_cdc_paths.rpt (worst paths of each asynchronous pair),
# cdc.rpt (report_cdc -details).

proc bow32_huins_timing_checks {out_dir} {
  set failed 0

  # ---- periods
  foreach {name period} {clk_sys 20.000 ddr_clk 7.500 ddr_sys 30.000 hr_clk 10.000} {
    set clk [get_clocks -quiet $name]
    if {[llength $clk] != 1} {
      puts "CRITICAL WARNING: clock $name not found (constr/huins_vp1902.xdc)"
      incr failed
    } elseif {abs([get_property PERIOD $clk] - $period) > 0.001} {
      puts "CRITICAL WARNING: clock $name has a period of [get_property PERIOD $clk] ns,\
            constr/huins_vp1902.xdc assumes $period ns"
      incr failed
    }
  }

  # ---- constraint of every clock pair with paths
  set async "Max Delay Datapath Only"
  set want [dict create]
  foreach {a b} {clk_sys ddr_sys  clk_sys ddr_clk  clk_sys ddr_rd_clk
                 ddr_clk ddr_rd_clk  ddr_sys ddr_rd_clk
                 clk_sys hr_clk  clk_sys hr_rd_clk  hr_clk hr_rd_clk} {
    dict set want [list $a $b] $async
    dict set want [list $b $a] $async
  }
  foreach {a b} {ddr_sys ddr_clk  ddr_clk ddr_sys  ddr_clk ddr_wclk  ddr_clk ddr_wclk90
                 hr_clk hr_wclk} {
    dict set want [list $a $b] "Timed"
  }
  set clocks [get_property NAME [get_clocks]]
  set seen {}
  foreach line [split [report_clock_interaction -return_string] "\n"] {
    # columns are separated by two or more spaces
    set cols [regexp -all -inline {\S+(?: \S+)*} $line]
    if {[llength $cols] < 3} {
      continue
    }
    set from [lindex $cols 0]
    set to   [lindex $cols 1]
    if {$from ni $clocks || $to ni $clocks || $from eq $to} {
      continue
    }
    set got [lindex $cols end]
    lappend seen [list $from $to]
    if {![dict exists $want [list $from $to]]} {
      puts "CRITICAL WARNING: unexpected paths from $from to $to ($got), see clock_interaction.rpt"
      incr failed
    } elseif {$got ne [dict get $want [list $from $to]]} {
      puts "CRITICAL WARNING: paths from $from to $to are '$got', expected\
            '[dict get $want [list $from $to]]' (constr/huins_vp1902.xdc)"
      incr failed
    }
  }
  foreach pair {{ddr_sys ddr_clk} {ddr_clk ddr_sys}} {
    if {$pair ni $seen} {
      puts "CRITICAL WARNING: no timed path from [lindex $pair 0] to [lindex $pair 1]\
            (the DFI between LiteDRAM and the PHY)"
      incr failed
    }
  }

  # ---- check_timing (no_input_delay / no_output_delay: the board I/O is
  # asynchronous or has fixed pin timing, see constr/*.xdc)
  set ct [check_timing -verbose -return_string]
  foreach item {no_clock constant_clock pulse_width_clock unconstrained_internal_endpoints
                multiple_clock generated_clocks loops partial_input_delay partial_output_delay
                latch_loops} {
    if {![regexp "checking $item \\((\\d+)\\)" $ct -> n]} {
      puts "CRITICAL WARNING: check_timing has no '$item' result"
      incr failed
    } elseif {$n != 0} {
      puts "CRITICAL WARNING: check_timing $item ($n), see check_timing.rpt"
      incr failed
    }
  }

  # ---- reports
  set rpt [file join $out_dir ddr_dfi_paths.rpt]
  report_timing -from [get_clocks ddr_sys] -to [get_clocks ddr_clk] -delay_type min_max \
    -max_paths 4 -file $rpt
  report_timing -from [get_clocks ddr_clk] -to [get_clocks ddr_sys] -delay_type min_max \
    -max_paths 4 -file $rpt -append
  set rpt [file join $out_dir ddr_cdc_paths.rpt]
  file delete -force $rpt
  foreach {a b} {clk_sys ddr_sys  clk_sys ddr_clk  clk_sys ddr_rd_clk
                 ddr_clk ddr_rd_clk  ddr_sys ddr_rd_clk
                 clk_sys hr_clk  clk_sys hr_rd_clk  hr_clk hr_rd_clk} {
    report_timing -from [get_clocks $a] -to [get_clocks $b] -max_paths 2 -file $rpt -append
    report_timing -from [get_clocks $b] -to [get_clocks $a] -max_paths 2 -file $rpt -append
  }
  report_cdc -details -file [file join $out_dir cdc.rpt]

  # ---- CDC structure (report_cdc). Combinational logic in front of a
  # synchroniser (CDC-10) is expected only at the CLR pins of the reset
  # synchronisers (link / bridge / FIFO flush reset = AND of reset levels
  # that are flop or LOCKED outputs: only a release glitch is possible, which
  # the synchroniser filters); anywhere else, e.g. a status bit into the
  # per-bit synchronisers of bow_ddr_regs, it is an error. Not expected at
  # all (none in the design): CDC-11 (one launch flop fans out to several
  # synchronisers of a destination clock), CDC-12 (multi-clock fan-in to a
  # synchroniser), CDC-13 / CDC-14 (a 1-bit / multi-bit crossing ending on a
  # non-flop primitive, e.g. an SRL). One CDC-13 is expected: in the card
  # builds the DDR / HyperRAM data pads are inout ports without an input delay
  # (the read capture is calibrated at run time, the port -> IDDRE1 paths are
  # false paths in constr/huins_vp1902.xdc), so each pad -> IDDRE1 D path shows up as
  # a crossing from the "input port clock"; any other CDC-13 is an error.
  set n_rst 0
  set n_pad 0
  foreach line [split [report_cdc -details -return_string] "\n"] {
    if {[regexp {^\s*\d+\s+(CDC-1[01234])\s} $line -> id]} {
      set to [lindex $line end]
      set from [lindex $line end-1]
      if {$id eq "CDC-10" && [regexp {/(u_rst_[a-z_]+|u_wrst|u_rrst)/sync_q_reg\[0\]/CLR$} $to]} {
        incr n_rst
        continue
      }
      if {$id eq "CDC-13" && [regexp {^(ddr_(dq_io\[\d+\]|dqs_p_io)|hr_(dq_io\[\d+\]|rwds_io))$} $from] &&
          [regexp {^u_(ddr|hr)_io/g_(dq|dqs|rwds)[^/]*/?[^/]*u_iddr/D$} $to] &&
          [llength [get_ports -quiet $from]] == 1} {
        incr n_pad
        continue
      }
      puts "CRITICAL WARNING: $id ending at $to (see cdc.rpt)"
      incr failed
    }
  }
  puts "INFO: CDC-10 at reset synchroniser CLR pins (expected): $n_rst"
  puts "INFO: CDC-13 from data pads to their IDDRE1 (expected in card builds): $n_pad"

  return $failed
}
