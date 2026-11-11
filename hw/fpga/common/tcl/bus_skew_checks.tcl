# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Checks of the set_bus_skew constraints of an open, timed design beyond their number
# and slack (tcl/build.tcl of the camera builds, after implementation):
#
#   source bus_skew_checks.tcl
#   set problems [bow32_bus_skew_checks [report_bus_skew -return_string] <allowed>]
#
# report_bus_skew lists every constraint as Vivado applied it (its set_bus_skew command,
# variables substituted) with its number of endpoints. The cell selections of each
# command are evaluated again in the open design; a constraint is a problem when
#   * a selection is empty, or selects a cell outside the hierarchies <allowed> (path
#     prefixes such as u_soc/u_csi2rx/): a selector by the tail of a cell name also
#     takes cells of the same name that a later change adds elsewhere;
#   * a destination cell has no path from the sources (fewer endpoints than destination
#     cells): part of the sources is missing, e.g. one selector of a list matched
#     nothing (Vivado only warns);
#   * sources and destinations are all flops, but not as many (one synchroniser flop per
#     bit): part of the destinations is missing, or a selector took extra cells.
# Returns one line per problem, an empty list when every constraint passes.
# bus_skew_checks_test.tcl tests it in plain tclsh (make test-tools).

# Stand-in for set_bus_skew while a reported command is evaluated: keeps its selections
proc bow32_bus_skew_capture {args} {
  set f [lsearch -exact $args -from]
  set t [lsearch -exact $args -to]
  set ::bow32_bus_skew_sel [list [lindex $args [expr {$f + 1}]] [lindex $args [expr {$t + 1}]]]
}

# The cell names of a selection: one collection, or a list of collections (one per
# selector)
proc bow32_bus_skew_names {sel} {
  set names {}
  foreach e $sel {
    foreach c $e {
      lappend names $c
    }
  }
  return [lsort -unique $names]
}

proc bow32_bus_skew_checks {report allowed} {
  set problems {}
  set n 0
  foreach {- id cmd endpoints} [regexp -all -inline -line \
      {^Id: (\d+)\n(set_bus_skew .*)\nRequirement: .*\nEndpoints: (\d+)$} $report] {
    incr n
    set ::bow32_bus_skew_sel {}
    if {![regsub {^set_bus_skew } $cmd {bow32_bus_skew_capture } eval_cmd] ||
        [catch {uplevel #0 $eval_cmd} err] || [llength $::bow32_bus_skew_sel] != 2} {
      lappend problems "constraint $id: cannot evaluate '$cmd' again"
      continue
    }
    lassign $::bow32_bus_skew_sel from_sel to_sel
    set from [bow32_bus_skew_names $from_sel]
    set to   [bow32_bus_skew_names $to_sel]
    set nf   [llength $from]
    set nt   [llength $to]
    set what "constraint $id ($nf -> $nt cells, $endpoints endpoints)"
    if {$nf == 0 || $nt == 0} {
      lappend problems "$what: empty selection, $cmd"
      continue
    }
    set outside {}
    foreach c [concat $from $to] {
      set in 0
      foreach p $allowed {
        if {[string first $p $c] == 0} {
          set in 1
          break
        }
      }
      if {!$in} {
        lappend outside $c
      }
    }
    if {[llength $outside]} {
      lappend problems "$what: [llength $outside] cells outside [join $allowed {, }]\
                        (first [lindex $outside 0]), $cmd"
    }
    if {$endpoints < $nt} {
      lappend problems "$what: [expr {$nt - $endpoints}] destination cells without a path\
                        from the sources, $cmd"
    }
    set ff_from [llength [get_cells -quiet -filter {REF_NAME =~ FD*} $from]]
    set ff_to   [llength [get_cells -quiet -filter {REF_NAME =~ FD*} $to]]
    if {$ff_from == $nf && $ff_to == $nt && $nf != $nt} {
      lappend problems "$what: flop bus with $nf source and $nt destination flops, $cmd"
    }
  }
  if {$n == 0 && [regexp {Slack \((MET|VIOLATED)\)} $report]} {
    lappend problems "no constraint found in the report_bus_skew text"
  }
  return $problems
}
