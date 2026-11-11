# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Synopsys Formality, RTL against RTL: bow_csi2rx of a reference commit (before the
# D-PHY was split out) against bow_csi2rx of this tree (bow_dphy_rx inside, step 1 of
# docs/ip/mipi_rx_arch.md section 10), in one parameter configuration per run.
#
#   fm_shell -file equiv.tcl -x "set cfg <name>; set ref_root <dir>; set impl_root <dir>"
#
# Normally run by the Makefile next to this file (make equiv). ref_root holds the
# reference tree (git archive of the reference commit), impl_root this tree; both are
# read through the same .f file lists as every other flow. Reports in the current
# directory. The run passes ("EQUIV <cfg>: PASS ...", exit code 0) only when the
# verification succeeds with every compare point matched and verified: no unmatched,
# failing, aborted or unverified point, no black box instance, no user match, no
# constant, no don't-verify point. The only setup beyond reading and elaborating is one
# compare rule: the ports of bow_csi2rx do not change and the moved flops keep their
# names one level down (u_dphy_rx/...), so the rule maps them back for matching by name.
# The memories (pixel FIFO, LOG and RAW RAMs) are read as registers, not black boxes.

# Configurations: the parameter sets of the builds that instantiate bow_csi2rx
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

# File lists: the same .f files as every other flow (hw/fpga/common/tcl/filelist.tcl)
source [file join $impl_root hw fpga common tcl filelist.tcl]
proc flist {root lists} {
  set files {}
  foreach f $lists {
    lassign [bow32_parse_f [file join $root $f]] fl inc
    lappend files {*}$fl
  }
  return $files
}
set ref_files  [flist $ref_root  {hw/ip/common/common.f hw/ip/bus/bus.f hw/ip/csi2rx/csi2rx.f}]
set impl_files [flist $impl_root {hw/ip/common/common.f hw/ip/bus/bus.f hw/ip/dphy_rx/dphy_rx.f
                                  hw/ip/csi2rx/csi2rx.f}]

# ---- setup
# SYNTHESIS is defined while reading (hdlin_define_synthesis_macro, default true): the
# simulation-only initial blocks of bow_csi2rx are left out, as in synthesis. The
# initial block of bow_ram_sdp (RAM contents 0 in simulation) is ignored with a
# warning (FMR_VLOG-101) on both sides.
set_app_var hdlin_error_on_duplicate_design true

read_sverilog -r -12 -work_library WORK $ref_files
set_top r:/WORK/bow_csi2rx -parameter $params

read_sverilog -i -12 -work_library WORK $impl_files
set_top i:/WORK/bow_csi2rx -parameter $params

set_compare_rule $impl -from {u_dphy_rx/} -to {}

report_designs             > designs.rpt
report_black_boxes         > black_boxes.rpt
report_compare_rules $impl > compare_rules.rpt

# ---- match and verify
match
report_unmatched_points    > unmatched.rpt
report_matched_points      > matched.rpt
report_user_matches        > user_matches.rpt
report_constants           > constants.rpt
report_dont_verify_points  > dont_verify.rpt
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
set summary "$total compare points matched and passing ($port ports, $dff flops), 0 unmatched,\
             0 failing / aborted / unverified, no black box, user match or constant; not\
             compared: $creg constant registers, $unread unread flops"
if {$ok && [llength $bad] == 0} {
  puts "EQUIV $cfg: PASS: $summary"
  exit 0
}
puts "EQUIV $cfg: FAIL: [join $bad {; }]"
exit 1
