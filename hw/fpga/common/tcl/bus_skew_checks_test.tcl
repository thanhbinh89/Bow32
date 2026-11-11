# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Test of bow32_bus_skew_checks (bus_skew_checks.tcl) in plain Tcl, without Vivado: a stand-in
# get_cells over a small synthetic netlist and report_bus_skew texts in Vivado's format.
#
#   tclsh bus_skew_checks_test.tcl     (python3 -m unittest discover -s tools/tests)
#
#   * constraints with plain selectors, with a list of two selectors per side and with
#     non-flop sources (as the XPHY readback) pass;
#   * flagged: a list whose source or destination selector matched nothing, a selector
#     that also takes cells outside the allowed hierarchies, fewer endpoints than
#     destination cells, a command that cannot be evaluated again, a report without
#     readable constraints.
# Prints "bus_skew_checks_test: PASS (<n> checks)" or the failures, exit code 1 on a failure.

source [file join [file dirname [file normalize [info script]]] bus_skew_checks.tcl]

# ---- synthetic netlist: cell name -> REF_NAME
set cells {}
foreach blk {u_soc/u_rx u_soc/u_rx/u_phy u_soc/u_other} {
  for {set b 0} {$b < 4} {incr b} {
    dict set cells "$blk/a_q_reg\[$b\]" FDCE
    dict set cells "$blk/u_sync_a/g_bit\[$b\].u_sync/sync_q_reg\[0\]" FDCE
    dict set cells "$blk/u_sync_a/g_bit\[$b\].u_sync/sync_q_reg\[1\]" FDCE
  }
  for {set b 0} {$b < 2} {incr b} {
    dict set cells "$blk/c_q_reg\[$b\]" FDRE
    dict set cells "$blk/u_sync_c/g_bit\[$b\].u_sync/sync_q_reg\[0\]" FDRE
  }
}
dict set cells u_io/u_phy0 XPHY
dict set cells u_io/u_phy1 XPHY

# Vivado name pattern (* and ?, brackets literal) -> string match pattern
proc glob_of {pat} {
  return [string map {[ \\[ ] \\] \\ \\\\} $pat]
}
# a -filter expression: terms "KEY =~ pattern" or "KEY == value", && within || alternatives
proc filter_ok {cell expr} {
  set ref [dict get $::cells $cell]
  foreach alt [split [string map {|| \x01} $expr] \x01] {
    set all 1
    foreach term [split [string map {&& \x01} $alt] \x01] {
      if {![regexp {^\s*(NAME|REF_NAME)\s*(=~|==)\s*(\S+)\s*$} $term -> key op val]} {
        error "stand-in get_cells: unknown filter term '$term'"
      }
      set v [expr {$key eq "NAME" ? $cell : $ref}]
      if {($op eq "==" && $v ne $val) || ($op eq "=~" && ![string match [glob_of $val] $v])} {
        set all 0
        break
      }
    }
    if {$all} {
      return 1
    }
  }
  return 0
}
# get_cells [-quiet] [-hierarchical] [-filter expr] [names or patterns]
proc get_cells {args} {
  set filter ""
  set pats {}
  for {set i 0} {$i < [llength $args]} {incr i} {
    set a [lindex $args $i]
    switch -- $a {
      -quiet - -hierarchical {}
      -filter { set filter [lindex $args [incr i]] }
      default { lappend pats {*}$a }
    }
  }
  set out {}
  foreach c [dict keys $::cells] {
    if {[llength $pats]} {
      set hit 0
      foreach p $pats {
        if {[string match [glob_of $p] $c]} {
          set hit 1
          break
        }
      }
      if {!$hit} {
        continue
      }
    }
    if {$filter eq "" || [filter_ok $c $filter]} {
      lappend out $c
    }
  }
  return $out
}

# ---- report_bus_skew text: one section per {command endpoints}
proc report {constraints} {
  set t "Bus Skew Report\n\n2. Bus Skew Report Per Constraint\n---------------------------------\n\n"
  set id 0
  foreach {cmd ep} $constraints {
    incr id
    append t "Id: $id\n$cmd\nRequirement: 5.000ns\nEndpoints: $ep\n\n"
    append t "Slack (MET) :             4.000ns  (requirement - actual skew)\n\n"
  }
  return $t
}

set n_checks 0
set n_fails  0
# expect: the problems, each as a regexp (in order); {} = none
proc check {what rpt expect} {
  incr ::n_checks
  set got [bow32_bus_skew_checks $rpt {u_soc/u_rx/ u_io/}]
  set ok [expr {[llength $got] == [llength $expect]}]
  foreach g $got e $expect {
    if {$ok && ![regexp -- $e $g]} {
      set ok 0
    }
  }
  if {!$ok} {
    incr ::n_fails
    puts "FAIL $what: got [llength $got] problems, expected [llength $expect]"
    foreach g $got {
      puts "  $g"
    }
  }
}

set plain {set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */u_rx/a_q_reg[*]}] -to [get_cells -hierarchical -filter {NAME =~ */u_rx/u_sync_a/g_bit[*].u_sync/sync_q_reg[0]}] 5.000}
set pair {set_bus_skew -from [list [get_cells -hierarchical -filter {NAME =~ */u_rx/a_q_reg[*]}] [get_cells -hierarchical -filter {NAME =~ */u_rx/c_q_reg[*]}]] -to [list [get_cells -hierarchical -filter {NAME =~ */u_rx/u_sync_a/g_bit[*].u_sync/sync_q_reg[0]}] [get_cells -hierarchical -filter {NAME =~ */u_rx/u_sync_c/g_bit[*].u_sync/sync_q_reg[0]}]] 5.000}
set nonff {set_bus_skew -from [get_cells -hierarchical -filter {REF_NAME == XPHY && NAME =~ u_io/*}] -to [get_cells -hierarchical -filter {NAME =~ */u_phy/u_sync_a/g_bit[*].u_sync/sync_q_reg[0]}] 5.000}
set exact {set_bus_skew -from [get_cells {u_soc/u_rx/u_phy/c_q_reg[*]}] -to [get_cells {u_soc/u_rx/u_phy/u_sync_c/g_bit[*].u_sync/sync_q_reg[0]}] 5.000}
check "good constraints" [report [list $plain 4 $pair 6 $nonff 4 $exact 2]] {}
check "no constraint" "Bus Skew Report\n" {}

set miss_from {set_bus_skew -from [list [get_cells -hierarchical -filter {NAME =~ */u_rx/a_q_reg[*]}] [get_cells -hierarchical -filter {NAME =~ */u_rx/zz_q_reg[*]}]] -to [list [get_cells -hierarchical -filter {NAME =~ */u_rx/u_sync_a/g_bit[*].u_sync/sync_q_reg[0]}] [get_cells -hierarchical -filter {NAME =~ */u_rx/u_sync_c/g_bit[*].u_sync/sync_q_reg[0]}]] 5.000}
check "source selector without cells" [report [list $miss_from 4]] \
  {{^constraint 1 \(4 -> 6 cells, 4 endpoints\): 2 destination cells without a path}
   {^constraint 1 .*: flop bus with 4 source and 6 destination flops}}
set miss_to {set_bus_skew -from [list [get_cells -hierarchical -filter {NAME =~ */u_rx/a_q_reg[*]}] [get_cells -hierarchical -filter {NAME =~ */u_rx/c_q_reg[*]}]] -to [list [get_cells -hierarchical -filter {NAME =~ */u_rx/u_sync_a/g_bit[*].u_sync/sync_q_reg[0]}] [get_cells -hierarchical -filter {NAME =~ */u_rx/u_sync_zz/g_bit[*].u_sync/sync_q_reg[0]}]] 5.000}
check "destination selector without cells" [report [list $plain 4 $miss_to 4]] \
  {{^constraint 2 \(6 -> 4 cells, 4 endpoints\): flop bus with 6 source and 4 destination flops}}
set tail {set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ */a_q_reg[*]}] -to [get_cells -hierarchical -filter {NAME =~ */u_sync_a/g_bit[*].u_sync/sync_q_reg[0]}] 5.000}
check "tail selector with cells of another block" [report [list $tail 12]] \
  {{^constraint 1 \(12 -> 12 cells, 12 endpoints\): 8 cells outside u_soc/u_rx/, u_io/ \(first u_soc/u_other/}}
check "destination without a path" [report [list $plain 3]] \
  {{^constraint 1 \(4 -> 4 cells, 3 endpoints\): 1 destination cells without a path}}
check "command that cannot be evaluated" [report [list {set_bus_skew -from [no_such_command] -to [get_cells x] 5.000} 1]] \
  {{^constraint 1: cannot evaluate}}
check "unreadable report" "Id: 1\nset_bus_skew\n\nSlack (MET) : 1.0ns\n" \
  {{^no constraint found}}

if {$n_fails == 0} {
  puts "bus_skew_checks_test: PASS ($n_checks checks)"
} else {
  puts "bus_skew_checks_test: FAIL ($n_fails of $n_checks checks)"
  exit 1
}
