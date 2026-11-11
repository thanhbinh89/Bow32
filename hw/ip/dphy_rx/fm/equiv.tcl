# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Synopsys Formality, RTL against RTL: the CSI-2 receiver of a reference commit against
# the receiver of this tree after a step of docs/ip/mipi_rx_arch.md section 10, in one
# parameter configuration per run.
#
#   fm_shell -file equiv.tcl -x "set cfg <name>; set step <n>; set ref_root <dir>;
#                                set impl_root <dir>"
#
# Normally run by the Makefile next to this file (make equiv STEP=<n>). ref_root holds the
# reference tree (git archive of the reference commit), impl_root this tree; both are
# read through the same .f file lists as every other flow, hw/ip/dphy_rx/dphy_rx.f
# included when the tree has it (a reference from step 1 on). Reports in the current
# directory.
#
# Tops. The receiver's ports never change: bow_csi2rx up to step 1, bow_mipi_rx (the same
# ports and parameters) from step 2 on. The reference top is the receiver of the
# reference tree (bow_mipi_rx when the tree has it), the implementation top that of the
# step (step_top below). step 1: bow_csi2rx with bow_dphy_rx inside (u_dphy_rx); step 2:
# bow_mipi_rx with bow_dphy_rx (u_dphy_rx) and the controller bow_csi2rx (u_csi2rx) side
# by side.
#
# Names. The moved flops keep their names one or more levels down. The rename rules of
# the step (step_rules below) map them back, as compare rules on both designs (a rule has
# no effect where the prefix does not occur, e.g. on a reference from before the split);
# matching through the names of attached nets is off. After matching, every matched pair
# must have the same name once the rules are applied (names.rpt lists the pairs that do
# not): Formality reports pairs matched through net names as "matched by name" too, and
# a functional check cannot see synthesis attributes, so a synchroniser rebuilt from plain
# flops (no ASYNC_REG, cell names the XDC and the CDC review do not know) would otherwise
# pass.
#
# The run passes ("EQUIV <cfg>: PASS ...", exit code 0) only when the verification
# succeeds with every compare point matched by name and verified: no unmatched, failing,
# aborted or unverified point, every matched pair with identical names, no black box
# instance, no user match, no constant, no don't-verify point. The memories (pixel FIFO,
# LOG and RAW RAMs) are read as registers, not black boxes.

# Configurations: the parameter sets of the builds that instantiate the receiver
# (hw/top/rtl/bow32_top.sv, the board tops, sim/tb/tb_bow32.sv)
array set cfg_params {
  kv260   {Lanes = 2, PhyClkHz = 200000000, CpuClkHz = 50000000, HasPhy = 1, FifoDepth = 256, DlyVid = 0}
  huins   {Lanes = 4, PhyClkHz = 200000000, CpuClkHz = 50000000, HasPhy = 1, FifoDepth = 512, DlyVid = 1}
  lanes1  {Lanes = 1, PhyClkHz = 200000000, CpuClkHz = 50000000, HasPhy = 1, FifoDepth = 256, DlyVid = 0}
  nophy   {Lanes = 2, PhyClkHz = 50000000, CpuClkHz = 50000000, HasPhy = 0, FifoDepth = 256, DlyVid = 0}
  sim     {Lanes = 2, PhyClkHz = 107526882, CpuClkHz = 50000000, HasPhy = 1, FifoDepth = 256, DlyVid = 0}
}
if {![info exists cfg_params($cfg)]} {
  puts "EQUIV $cfg: unknown configuration ([lsort [array names cfg_params]])"
  exit 1
}
set params $cfg_params($cfg)

# Steps of section 10: the implementation's top and the rename rules, pairs {from to} of
# literal strings (letters, digits, '_', '/'), each applied once per name like a compare
# rule (sed s/from/to/), to both designs. A later step that moves cells again adds its own
# entry. The implementation of a step is a tree at that step: STEP=1 checks a tree of
# step 1 (35ef151), not this one.
array set step_top {
  1 bow_csi2rx
  2 bow_mipi_rx
}
array set step_rules {
  1 {u_dphy_rx/ {}}
  2 {u_dphy_rx/ {} u_csi2rx/ {}}
}
if {![info exists step]} {
  set step 2
}
if {![info exists step_top($step)]} {
  puts "EQUIV $cfg: unknown step $step ([lsort [array names step_top]])"
  exit 1
}
set rename_rules $step_rules($step)
set impl_top     $step_top($step)
# the receiver of the reference tree
if {[file exists [file join $ref_root hw ip csi2rx rtl bow_mipi_rx.sv]]} {
  set ref_top bow_mipi_rx
} else {
  set ref_top bow_csi2rx
}
foreach {from to} $rename_rules {
  if {![regexp {^[A-Za-z0-9_/]+$} $from] || ![regexp {^[A-Za-z0-9_/]*$} $to]} {
    puts "EQUIV $cfg: rename rule '$from' -> '$to' is not a literal name part"
    exit 1
  }
}
proc renamed {name} {
  foreach {from to} $::rename_rules {
    set i [string first $from $name]
    if {$i >= 0} {
      set name [string replace $name $i [expr {$i + [string length $from] - 1}] $to]
    }
  }
  return $name
}

# File lists: the same .f files as every other flow (hw/fpga/common/tcl/filelist.tcl)
source [file join $impl_root hw fpga common tcl filelist.tcl]
proc flist {root} {
  set lists {hw/ip/common/common.f hw/ip/bus/bus.f}
  if {[file exists [file join $root hw ip dphy_rx dphy_rx.f]]} {
    lappend lists hw/ip/dphy_rx/dphy_rx.f
  }
  lappend lists hw/ip/csi2rx/csi2rx.f
  set files {}
  foreach f $lists {
    lassign [bow32_parse_f [file join $root $f]] fl inc
    lappend files {*}$fl
  }
  return $files
}
set ref_files  [flist $ref_root]
set impl_files [flist $impl_root]

# ---- setup
# SYNTHESIS is defined while reading (hdlin_define_synthesis_macro, default true): the
# simulation-only initial blocks of bow_csi2rx are left out, as in synthesis. The
# initial block of bow_ram_sdp (RAM contents 0 in simulation) is ignored with a
# warning (FMR_VLOG-101) on both sides.
set_app_var hdlin_error_on_duplicate_design true
set_app_var name_match_based_on_nets false

read_sverilog -r -12 -work_library WORK $ref_files
set_top r:/WORK/$ref_top -parameter $params

read_sverilog -i -12 -work_library WORK $impl_files
set_top i:/WORK/$impl_top -parameter $params

foreach {from to} $rename_rules {
  set_compare_rule $ref  -from $from -to $to
  set_compare_rule $impl -from $from -to $to
}

report_designs             > designs.rpt
report_black_boxes         > black_boxes.rpt
report_compare_rules $ref  > compare_rules.rpt
report_compare_rules $impl >> compare_rules.rpt

# ---- match and verify
match
report_unmatched_points    > unmatched.rpt
report_matched_points      > matched.rpt
report_user_matches        > user_matches.rpt
report_constants           > constants.rpt
report_dont_verify_points  > dont_verify.rpt

# Every matched pair (compare points and inputs) with the same name once the rename rules
# are applied; the pairs that differ go to names.rpt. Returns {pairs differing renamed}.
proc check_names {} {
  set fh [open names.rpt w]
  set n 0
  set bad 0
  set moved 0
  foreach pair [report_matched_points -list] {
    lassign $pair r i
    # strip the container and the design: r:/WORK/<design>/<path>
    regsub {^[ri]:/[^/]+/[^/]+/} $r {} r
    regsub {^[ri]:/[^/]+/[^/]+/} $i {} i
    incr n
    if {[renamed $i] ne $i} {
      incr moved
    }
    if {[renamed $r] ne [renamed $i]} {
      incr bad
      puts $fh "ref $r <-> impl $i"
    }
  }
  puts $fh "$n matched pairs, $moved renamed by the rules ($::rename_rules), $bad with different names"
  close $fh
  return [list $n $bad $moved]
}
lassign [check_names] n_pairs n_name_diff n_moved
proc count_method {m} {
  return [llength [report_matched_points -method $m -list]]
}
set n_method {}
foreach m {name user topology function} {
  lappend n_method [count_method $m]
}

set ok [verify]
report_status              > status.rpt
report_failing_points      > failing.rpt
report_aborted_points      > aborted.rpt
report_unverified_points   > unverified.rpt
report_not_compared_points > not_compared.rpt

# ---- checks on the reports
proc slurp {f} {
  set fh [open $f r]
  set t [read $fh]
  close $fh
  return $t
}
# each line: report, what it must say, what it means when it does not
set bad {}
foreach {rpt re what} {
  status.rpt       {Verification SUCCEEDED}             "verification not successful"
  unmatched.rpt    {No unmatched points\.}              "unmatched points"
  failing.rpt      {No failing compare points\.}        "failing points"
  aborted.rpt      {No aborted compare points\.}        "aborted points"
  unverified.rpt   {No unverified compare points\.}     "unverified points"
  user_matches.rpt {User matched points:\s+None}        "user matches"
  constants.rpt    {User Defined Constants:\s+None}     "user constants"
  dont_verify.rpt  {Don't verify points:\s+None}        "don't-verify points"
} {
  if {![regexp $re [slurp $rpt]]} {
    lappend bad "$what ($rpt)"
  }
}
# names: identical after the rename rules, every pair matched by name
if {$n_pairs == 0 || $n_name_diff != 0} {
  lappend bad "$n_name_diff of $n_pairs matched pairs with different names (names.rpt)"
}
lassign $n_method by_name by_user by_topo by_func
if {$by_name != $n_pairs || $by_user + $by_topo + $by_func != 0} {
  lappend bad "matched pairs by name $by_name of $n_pairs, by user / topology / function\
               $by_user / $by_topo / $by_func"
}
# black boxes: report_black_boxes lists the unlinked library modules too; none may have
# an instance in the designs
set n_bbox 0
foreach {- n} [regexp -all -inline {Instances\s*:\s*(\d+)} [slurp black_boxes.rpt]] {
  incr n_bbox $n
}
if {$n_bbox != 0} {
  lappend bad "$n_bbox black box instances (black_boxes.rpt)"
}
# counts of the result table
set st [slurp status.rpt]
regexp {Passing \(equivalent\)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)} $st \
  -> bbpin loop bbnet cut port dff lat total
regexp {Constant reg\s+(\d+)\s+(\d+)\s+(\d+)} $st -> creg_dff creg_lat creg
regexp {Unread\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)} $st \
  -> - - - - - unread_dff - unread
foreach v {total port dff creg unread} {
  if {![info exists $v]} {
    set $v ?
    lappend bad "no '$v' count in status.rpt"
  }
}
set summary "step $step, $ref_top -> $impl_top: $total compare points matched and passing\
             ($port ports, $dff flops), 0 unmatched, 0 failing / aborted / unverified,\
             $n_pairs matched pairs with identical names ($n_moved through the rename rules),\
             no black box, user match or constant; not compared: $creg constant registers,\
             $unread unread flops"
if {$ok && [llength $bad] == 0} {
  puts "EQUIV $cfg: PASS: $summary"
  exit 0
}
puts "EQUIV $cfg: FAIL: [join $bad {; }]"
exit 1
