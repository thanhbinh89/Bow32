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
# Tops and hierarchy. The receiver's ports never change: bow_csi2rx up to step 1,
# bow_mipi_rx (the same ports and parameters) from step 2 on. The hierarchy of a tree is
# that of its step: 0 (before step 1, e.g. 3a1e780) flat bow_csi2rx; 1 (e.g. 35ef151)
# bow_csi2rx with bow_dphy_rx inside (u_dphy_rx); 2 bow_mipi_rx with bow_dphy_rx
# (u_dphy_rx) and the controller bow_csi2rx (u_csi2rx) side by side and no cell of its own.
# The implementation is a tree at step STEP (STEP=1 checks a tree of step 1, not this
# one); the step of the reference tree is read from its files (tree_step below).
#
# Names. Moved flops keep their names one level down per step. The rename rules of each
# step (step_rules below) map the names of a tree at that step to those of the step
# before; the rules of the steps between the reference and the implementation are compare
# rules on the implementation only, so the reference keeps its hierarchy: against a step 1
# reference, u_dphy_rx/ stays and only u_csi2rx/ goes, and a cell that moved between the
# D-PHY and the controller no longer matches by name. Matching through the names of
# attached nets is off. After matching, every matched pair, unread ones included, must
# have the reference's name once the rules are applied to the implementation's (names.rpt
# lists the pairs that do not): Formality reports pairs matched through net names as
# "matched by name" too, and a functional check cannot see synthesis attributes, so a
# synchroniser rebuilt from plain flops (no ASYNC_REG, cell names the XDC and the CDC
# review do not know) would otherwise pass.
#
# Blocks (step_blocks below). Each matched cell (every pair but ports) must sit in the same
# block on both sides when the reference has blocks (from step 1 on: the D-PHY u_dphy_rx/,
# the controller), and at step 2 in u_dphy_rx/ or u_csi2rx/, never in the wrapper itself.
# partition.rpt counts the pairs per block and lists the ones that break this. With a
# reference from before step 1 only the wrapper rule applies: the flat reference does
# not say which block a cell belongs to.
#
# The run passes ("EQUIV <cfg>: PASS ...", exit code 0) only when the verification
# succeeds with every compare point matched by name and verified: no unmatched, failing,
# aborted or unverified point, every matched pair with the reference's name and in its
# block, no black box instance, no user match, no constant, no don't-verify point. The
# memories (pixel FIFO, LOG and RAW RAMs) are read as registers, not black boxes.

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

# Steps of section 10 (a later step that moves cells again adds its entries):
#   step_top     the receiver's top in a tree at that step
#   step_rules   rename rules from that step's names to the step before: pairs {from to}
#                of literal strings (letters, digits, '_', '/'), each applied once per name
#                like a compare rule (sed s/from/to/)
#   step_blocks  the blocks of the receiver, pairs {block prefix} tried in order; a cell
#                whose name starts with no prefix is in the last block, or, when that has a
#                prefix too, in the wrapper (step 2: bow_mipi_rx holds no cell)
array set step_top {
  0 bow_csi2rx
  1 bow_csi2rx
  2 bow_mipi_rx
}
array set step_rules {
  1 {u_dphy_rx/ {}}
  2 {u_csi2rx/ {}}
}
array set step_blocks {
  0 {rx {}}
  1 {dphy u_dphy_rx/ ctrl {}}
  2 {dphy u_dphy_rx/ ctrl u_csi2rx/}
}
if {![info exists step]} {
  set step 2
}
if {$step < 1 || ![info exists step_top($step)]} {
  puts "EQUIV $cfg: unknown step $step ([lsort [array names step_rules]])"
  exit 1
}
# the step of a tree, from its files
proc tree_step {root} {
  if {[file exists [file join $root hw ip csi2rx rtl bow_mipi_rx.sv]]} {
    return 2
  }
  if {[file exists [file join $root hw ip dphy_rx dphy_rx.f]]} {
    return 1
  }
  return 0
}
set ref_step [tree_step $ref_root]
if {$ref_step > $step} {
  puts "EQUIV $cfg: the reference is a tree of step $ref_step, the implementation of step $step"
  exit 1
}
set impl_top $step_top($step)
set ref_top  $step_top($ref_step)
# the rules from the implementation's step down to the reference's
set rename_rules {}
for {set s $step} {$s > $ref_step} {incr s -1} {
  lappend rename_rules {*}$step_rules($s)
}
foreach {from to} $rename_rules {
  if {![regexp {^[A-Za-z0-9_/]+$} $from] || ![regexp {^[A-Za-z0-9_/]*$} $to]} {
    puts "EQUIV $cfg: rename rule '$from' -> '$to' is not a literal name part"
    exit 1
  }
}
# an implementation name as the reference names it
proc renamed {name} {
  foreach {from to} $::rename_rules {
    set i [string first $from $name]
    if {$i >= 0} {
      set name [string replace $name $i [expr {$i + [string length $from] - 1}] $to]
    }
  }
  return $name
}
# the block of a cell name in a tree at a step (wrapper: none of the blocks)
proc block_of {s name} {
  foreach {blk prefix} $::step_blocks($s) {
    if {$prefix eq {} || [string first $prefix $name] == 0} {
      return $blk
    }
  }
  return wrapper
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

# Matched pairs {ref impl} without the container and design (r:/WORK/<design>/<path>):
# the default list (compare points and inputs) and the unread points it leaves out
proc strip {name} {
  regsub {^[ri]:/[^/]+/[^/]+/} $name {} name
  return $name
}
proc matched_pairs {args} {
  set pairs [dict create]
  foreach st {{} {-status unread}} {
    foreach pair [report_matched_points {*}$st {*}$args -list] {
      lassign $pair r i
      dict set pairs [list [strip $r] [strip $i]] 1
    }
  }
  return [dict keys $pairs]
}

# Every matched pair with the reference's name once the rename rules are applied to the
# implementation's (the pairs that differ go to names.rpt), and every cell in its block
# (partition.rpt). Returns {pairs unread differing renamed outside}.
proc check_pairs {} {
  set pairs [matched_pairs]
  set n_unread [llength [report_matched_points -status unread -list]]
  set ports [dict create]
  foreach pair [matched_pairs -point_type port] {
    dict set ports $pair 1
  }
  set fn [open names.rpt w]
  set fp [open partition.rpt w]
  set bad 0
  set moved 0
  set outside 0
  set count [dict create]
  foreach pair $pairs {
    lassign $pair r i
    if {[renamed $i] ne $i} {
      incr moved
    }
    if {[renamed $i] ne $r} {
      incr bad
      puts $fn "ref $r <-> impl $i"
    }
    if {[dict exists $ports $pair]} {
      dict incr count port
      continue
    }
    set bi [block_of $::step $i]
    set br [block_of $::ref_step $r]
    dict incr count $bi
    if {$bi eq "wrapper" || ($::ref_step > 0 && $br ne $bi)} {
      incr outside
      puts $fp "ref $r ($br) <-> impl $i ($bi)"
    }
  }
  set n [llength $pairs]
  puts $fn "$n matched pairs ($n_unread unread), $moved renamed by the rules ($::rename_rules),\
            $bad with different names"
  set per {}
  dict for {k v} $count {
    lappend per "$k $v"
  }
  puts $fp "$n matched pairs by block of the implementation ([join [lsort $per] {, }]),\
            $outside outside their block (reference step $::ref_step, implementation step\
            $::step)"
  close $fn
  close $fp
  return [list $n $n_unread $bad $moved $outside]
}
lassign [check_pairs] n_pairs n_unread n_name_diff n_moved n_outside
set n_method {}
foreach m {name user topology function} {
  lappend n_method [llength [matched_pairs -method $m]]
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
# names: the reference's after the rename rules, every pair matched by name
if {$n_pairs == 0 || $n_name_diff != 0} {
  lappend bad "$n_name_diff of $n_pairs matched pairs with different names (names.rpt)"
}
lassign $n_method by_name by_user by_topo by_func
if {$by_name != $n_pairs || $by_user + $by_topo + $by_func != 0} {
  lappend bad "matched pairs by name $by_name of $n_pairs, by user / topology / function\
               $by_user / $by_topo / $by_func"
}
# blocks: every cell in its block, none in the wrapper
if {$n_outside != 0} {
  lappend bad "$n_outside of $n_pairs matched pairs outside their block (partition.rpt)"
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
set blocks [lindex [split [slurp partition.rpt] "\n"] end-1]
regexp {\(([^)]*)\)} $blocks -> blocks
if {$ref_step > 0} {
  set blocks "in the reference's blocks ($blocks)"
} else {
  set blocks "in the blocks ($blocks; the flat reference has none to compare)"
}
set summary "step $ref_step -> $step, $ref_top -> $impl_top: $total compare points matched\
             and passing ($port ports, $dff flops), 0 unmatched, 0 failing / aborted /\
             unverified, $n_pairs matched pairs ($n_unread unread) with the reference's names\
             ($n_moved through the rename rules) and $blocks, no black box, user match or\
             constant; not compared: $creg constant registers, $unread unread flops"
if {$ok && [llength $bad] == 0} {
  puts "EQUIV $cfg: PASS: $summary"
  exit 0
}
puts "EQUIV $cfg: FAIL: [join $bad {; }]"
exit 1
