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
# Tops and hierarchy. The receiver's ports do not change up to step 2: bow_csi2rx up to
# step 1, bow_mipi_rx (the same ports and parameters) from step 2 on. The hierarchy of a
# tree is that of its step: 0 (before step 1, e.g. 3a1e780) flat bow_csi2rx; 1 (e.g.
# 35ef151) bow_csi2rx with bow_dphy_rx inside (u_dphy_rx); 2 bow_mipi_rx with bow_dphy_rx
# (u_dphy_rx) and the controller bow_csi2rx (u_csi2rx) side by side and no cell of its own.
# Step 3 changed no RTL, step 4 the register map and the PHY ports (no equivalence: a tree of
# step 3 or 4 has the hierarchy of step 2, steps 3 and 4 rename nothing). Step 5 (the AFE
# interface) changed the ports again: its implementation top is bow_mipi_rx_s4.sv (next to
# this file), the receiver of the tree behind the ports of step 4, and its reference must
# be a tree of step 4 (e.g. 3d3985a); see "Step 5" below. The implementation is a tree at
# step STEP (STEP=1 checks a tree of step 1, not this one); the step of the reference tree
# is read from its files (tree_step below).
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
#
# Step 5. What step 5 changed by design is listed below (step_dont_verify, step_constants,
# step_moved, step_new) and is the only exception to these rules: the step 4 outputs whose
# function went into the AFE adapters or into des_rst are not compared (byte_rst_o, the
# ISERDESE3 reset; burst_rst_en_o, ~CTRL.DES_RST_DIS; dly_tap_o / dly_load_o, the load
# requests); AFE_CTRL.PD, a new register read at 0x014, is held at its FPGA reset value 0
# (the condition of the proof: with PD = 0 every register read is that of step 4); the
# reference cells of these functions have no counterpart (step_moved: the tap loads, the
# request counter, the ISERDESE3 reset synchroniser) and the new register file cells have
# none in the reference (step_new: PD, the synchroniser of the AFE's cal_done / cal_err,
# constant here); every other point must be matched by name and pass. The AFE outputs
# without a step 4 counterpart (des_rst, term_en, lprx_en, lane_pd, the delay codes and OWN
# as AFE ports, pd) are not compare points here: the checkers of the simulations
# (hw/ip/dphy_rx/dv/bow_afe_chk.sv) and the adapters' tests cover them.
#
# Step 6 (the D-PHY v1.x functions). The receiver as a whole is not equivalent to step 5 by
# design, whatever the new register bits hold: the D-PHY's configuration reaches its lp
# domain through the shadow registers and CMD.APPLY (step 5: a two flop synchroniser of
# every bit), its events reach the register file as gray counters (step 5: pulse
# synchronisers), the PPI errors are gray counters (step 5: pulses) and the register map
# grew (INFO[27], TIM1, TIM2, LANE_STOP, CNT_MISC, CNT_DSK[31:16]). Step 6 therefore proves
# the two parts whose function must not change while the new functions are off, each
# against the same module of a tree of step 5 (e.g. 1c76364), with the new inputs held at
# the values the D-PHY gives them after reset:
#   * the controller bow_csi2rx (configurations kv260 .. sim, the parameters bow_mipi_rx
#     gives it), cut at lp_err on both sides: the net "an LP error reached the controller"
#     (v1: the OR of the ErrControl* pulses; v1.x: the OR of the changes the new sampler
#     u_lperr sees in the gray counters) is a cut point, a free input of everything it
#     drives (lp_pend_q, ERR_STATUS.LP, the lost burst request lpl_* and its marking), which
#     is so proven for any LP error; the cut point itself is a don't-verify point (v1
#     pulses and v1.x gray counters cannot be compared cycle by cycle, and u_lperr has no
#     counterpart): the sampler is not proven here (gap: DV and mutants_ppi / mutants_rx /
#     mutants_dphy cover it). The new flop of the deskew count (dsk_last_q, the previous
#     RxSkewCalHS) is held at 0: the proof of the rising edge count for a pulse of one byte
#     clock, the RxSkewCalHS of v1 (dsk_last_q is 0 whenever such a pulse is 1);
#   * the lane state machine bow_dphy_lp, data lane (lp_data) and clock lane (lp_clk), with
#     the new inputs at the values of the reset configuration: HSRX_EARLY, CLK_MISS_OFF,
#     ULPS_EN, ESC_TMO, T_INIT 0, HS_TMO 2^20 (the watchdog of v1), no T_INIT or REINIT
#     pulse. The new states use the state values v1 left unused and go to Off without
#     ULPS_EN, as v1 did from those values, so every compare point is checked for every
#     state value, the unreachable ones included. The upper watchdog bits (tmr_hi_q) are
#     held at 0: with HS_TMO 2^20 the count restarts at 0 in every Hs and the watchdog
#     fires at 2^20 - 1, so they never leave their reset value (an invariant Formality's
#     combinational check cannot see); so is the clock lane's exit_wait_q (Exit ends in
#     WaitStop after a REINIT: set only with the REINIT pulse). The new flops (these bits,
#     the termination, the T_INIT flag, exit_wait_q, the escape decoder, the new event
#     pulses) have no counterpart, nor do the new ports.
# What step 6 changed is listed per part (step6_constants, step6_new); every other point
# must be matched by name and pass, as in the other steps. Not proven here: the D-PHY's
# register file and top (APPLY, gray event counters, the new registers), the PPI signals
# themselves: the D-PHY bench hw/ip/dphy_rx/dv and the receiver benches cover them.
#
# Step 7 (the CSI-2 controller on its own continuous clock csi_clk: a two clock FIFO right
# after the lane merge, everything after it on csi_clk, the pixel FIFO on one clock). The
# controller (bow_csi2rx) moved its packet layer, unpack, pixel FIFO, LOG and events from the
# byte clock to csi_clk: it is not equivalent to step 6, cycle by cycle or otherwise (the
# FIFO adds latency, the events leave on another clock), and is not compared (the receiver
# benches, the lane merge FIFO's unit test and the system tests cover it). Step 7 proves
# against a tree of step 6 (e.g. b832038), with every input free, no constant, cut or
# don't-verify point and every compare point matched by name and passing (the rules of steps
# 1 and 2):
#   * the digital D-PHY bow_dphy_rx as a whole (configurations kv260 .. sim, the parameters
#     bow_mipi_rx gives it: AfeKind 2 for huins, lp_clk = vid_clk, the CPU clock), with its
#     register file, RAW, AFE interface and PPI (step 7 changed nothing of it);
#   * the lane state machine bow_dphy_lp, data lane (lp_data) and clock lane (lp_clk);
#   * the blocks the controller moved to csi_clk unchanged (blk_*): bow_csi2_packet (2 and 4
#     bytes per word), bow_csi2_unpack (1 and 4), bow_csi2rx_out, bow_csi2_capture and the
#     register file bow_csi2rx_regs (the Huins configuration): the same function on the new
#     clock (what changed is bow_csi2rx's wiring, the lane merge with its FIFO and the pixel
#     FIFO, which the DV covers);
#   * the two clock FIFO bow_fifo_async (blk_afifo16: 41 bits x 16 as in the lane merge, the
#     DDR and HyperRAM PHYs; blk_afifo512: 33 bits x 512 as the H.264 output FIFO): step 7
#     put its pointer synchronisers into always blocks of their own, for the jitter model of
#     simulation builds (BOW_SYNC_JITTER, not defined here): the same flops, names and logic.

# Configurations: the parameter sets of the builds that instantiate the receiver
# (hw/top/rtl/bow32_top.sv, the board tops, sim/tb/tb_bow32.sv; sim: the KV260 system
# simulation's video clock, 8.3 ns since the review of step 7, 9.3 ns = 107 526 882 Hz before)
array set cfg_params {
  kv260   {Lanes = 2, PhyClkHz = 200000000, CpuClkHz = 50000000, HasPhy = 1, FifoDepth = 256, DlyVid = 0}
  huins   {Lanes = 4, PhyClkHz = 200000000, CpuClkHz = 50000000, HasPhy = 1, FifoDepth = 512, DlyVid = 1}
  lanes1  {Lanes = 1, PhyClkHz = 200000000, CpuClkHz = 50000000, HasPhy = 1, FifoDepth = 256, DlyVid = 0}
  nophy   {Lanes = 2, PhyClkHz = 50000000, CpuClkHz = 50000000, HasPhy = 0, FifoDepth = 256, DlyVid = 0}
  sim     {Lanes = 2, PhyClkHz = 120481928, CpuClkHz = 50000000, HasPhy = 1, FifoDepth = 256, DlyVid = 0}
  lp_data {ClockLane = 0}
  lp_clk  {ClockLane = 1}
  blk_packet2 {Bytes = 2}
  blk_packet4 {Bytes = 4}
  blk_unpack1 {Bytes = 1}
  blk_unpack4 {Bytes = 4}
  blk_out     {}
  blk_capture {}
  blk_regs    {Lanes = 4, PhyClkHz = 200000000, HasPhy = 1, FifoDepth = 512, DphyWin = 1}
  blk_afifo16  {Width = 41, Depth = 16}
  blk_afifo512 {Width = 33, Depth = 512}
}
# step 7, unchanged blocks (blk_*): the module of each configuration
array set blk_module {
  blk_packet2 bow_csi2_packet
  blk_packet4 bow_csi2_packet
  blk_unpack1 bow_csi2_unpack
  blk_unpack4 bow_csi2_unpack
  blk_out     bow_csi2rx_out
  blk_capture bow_csi2_capture
  blk_regs    bow_csi2rx_regs
  blk_afifo16  bow_fifo_async
  blk_afifo512 bow_fifo_async
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
  3 bow_mipi_rx
  4 bow_mipi_rx
  5 bow_mipi_rx_s4
  6 bow_csi2rx
  7 bow_dphy_rx
}
array set step_rules {
  1 {u_dphy_rx/ {}}
  2 {u_csi2rx/ {}}
  3 {}
  4 {}
  5 {u_mipi/ {}}
  6 {}
  7 {}
}
array set step_blocks {
  0 {rx {}}
  1 {dphy u_dphy_rx/ ctrl {}}
  2 {dphy u_dphy_rx/ ctrl u_csi2rx/}
  3 {dphy u_dphy_rx/ ctrl u_csi2rx/}
  4 {dphy u_dphy_rx/ ctrl u_csi2rx/}
  5 {dphy u_mipi/u_dphy_rx/ ctrl u_mipi/u_csi2rx/}
  6 {part {}}
  7 {part {}}
}
# Step 5 (see the header):
#   step_files        implementation files read after its file lists
#   step_ref_step     the step the reference tree must have
#   step_dont_verify  ports of both tops that are not compared (every bit)
#   step_constants    implementation cells held at a value: {cell value}
#   step_moved        reference cells without a counterpart (name prefixes)
#   step_new          implementation cells without a counterpart (name prefixes)
array set step_files       {5 {hw/ip/dphy_rx/fm/bow_mipi_rx_s4.sv}}
array set step_ref_step    {5 4 6 5 7 6}
array set step_dont_verify {5 {byte_rst_o burst_rst_en_o dly_tap_o dly_load_o}}
array set step_constants   {5 {u_mipi/u_dphy_rx/u_regs/pd_q_reg 0}}
array set step_moved {5 {u_dphy_rx/g_dly_byte. u_dphy_rx/g_dly_vid. u_dphy_rx/dly_load_o_reg
                         u_dphy_rx/dly_tap_o_reg u_dphy_rx/u_iserdes_rst/
                         u_dphy_rx/u_regs/dly_req_q_reg}}
array set step_new   {5 {u_mipi/u_dphy_rx/u_sync_cal/ u_mipi/u_dphy_rx/u_regs/pd_q_reg}}
# Step 6 (see the header), per part: ctrl (bow_csi2rx) or lp (bow_dphy_lp)
#   step6_top        the module compared (the same on both sides)
#   step6_constants  {side point value}: side ref, impl or both; point a port bit or a cell
#   step6_new        implementation cells and ports without a counterpart (name prefixes)
array set step6_top {ctrl bow_csi2rx lp bow_dphy_lp}
array set step6_new {
  ctrl {u_lperr/ dsk_last_q_reg}
  lp   {tmr_hi_q_reg term_q_reg pend_q_reg exit_wait_q_reg esc_sr_q_reg esc_cnt_q_reg
        esc_mark_q_reg ev_tmo_o ev_esc_o ev_esc_tmo_o ev_ulps_o ev_wake_o hsrx_early_i miss_off_i
        ulps_en_i hs_tmo_i esc_tmo_i tinit_i tinit_set_i force_wait_i term_en_o ulps_o
        ulps_act_o}
}
# step 6, part ctrl: the nets cut on both sides (cut points, not verified; see the header)
array set step6_cut {
  ctrl {lp_err}
  lp   {}
}
if {![info exists step]} {
  set step 2
}
if {$step < 1 || ![info exists step_top($step)]} {
  puts "EQUIV $cfg: unknown step $step ([lsort [array names step_rules]])"
  exit 1
}
if {[string match lp_* $cfg] && $step ni {6 7}} {
  puts "EQUIV $cfg: configuration $cfg is a part of steps 6 and 7 (STEP=6, STEP=7)"
  exit 1
}
if {[string match blk_* $cfg] && $step != 7} {
  puts "EQUIV $cfg: configuration $cfg is a part of step 7 (STEP=7)"
  exit 1
}
# the step of a tree, from its files (a tree of step 3 has the RTL of step 2)
proc tree_step {root} {
  if {[file exists [file join $root hw ip common rtl bow_fifo_ram.sv]]} {
    return 7
  }
  if {[file exists [file join $root hw ip csi2rx rtl bow_ppi_err_rx.sv]]} {
    return 6
  }
  if {[file exists [file join $root hw ip dphy_rx fm bow_mipi_rx_s4.sv]]} {
    return 5
  }
  if {[file exists [file join $root hw ip dphy_rx rtl bow_dphy_rx_regs.sv]]} {
    return 4
  }
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
if {[info exists step_ref_step($step)] && $ref_step != $step_ref_step($step)} {
  puts "EQUIV $cfg: step $step needs a reference tree of step $step_ref_step($step), not\
        $ref_step (REF=<a commit of step $step_ref_step($step)>)"
  exit 1
}
set impl_top $step_top($step)
set ref_top  $step_top($ref_step)
# step 6: one part, the same module on both sides; the controller with the parameters
# bow_mipi_rx gives it (its PPI lp clock is vid_clk_i)
set part {}
if {$step == 6} {
  set part [expr {[string match lp_* $cfg] ? "lp" : "ctrl"}]
  set impl_top $step6_top($part)
  set ref_top  $step6_top($part)
  if {$part eq "ctrl"} {
    regexp {PhyClkHz = (\d+)} $params -> phy_hz
    regsub {, DlyVid = \d+} $params {} params
    append params ", DphyWin = 1, PpiLpClkHz = $phy_hz"
  }
}
# step 7: one part, the same module on both sides (see the header): the D-PHY with the
# parameters bow_mipi_rx gives it, the lane state machine, or an unchanged block (of the
# controller, or the two clock FIFO)
if {$step == 7} {
  if {[string match lp_* $cfg]} {
    set part lp
    set impl_top bow_dphy_lp
  } elseif {[string match blk_* $cfg]} {
    set part blk
    set impl_top $blk_module($cfg)
  } else {
    set part dphy
    set impl_top bow_dphy_rx
    regexp {Lanes = (\d+)} $params -> lanes
    regexp {PhyClkHz = (\d+)} $params -> phy_hz
    regexp {CpuClkHz = (\d+)} $params -> cpu_hz
    regexp {DlyVid = (\d+)} $params -> versal
    set params "Lanes = $lanes, AfeKind = [expr {$versal ? 2 : 1}], LpClkHz = $phy_hz,\
                BusClkHz = $cpu_hz"
  }
  set ref_top $impl_top
}
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
if {[info exists step_files($step)]} {
  foreach f $step_files($step) {
    lappend impl_files [file join $impl_root $f]
  }
}

# ---- setup
# SYNTHESIS is defined while reading (hdlin_define_synthesis_macro, default true): the
# simulation-only initial blocks of bow_csi2rx are left out, as in synthesis. The
# initial block of bow_ram_sdp (RAM contents 0 in simulation) is ignored with a
# warning (FMR_VLOG-101) on both sides.
set_app_var hdlin_error_on_duplicate_design true
set_app_var name_match_based_on_nets false

read_sverilog -r -12 -work_library WORK $ref_files
if {$params eq {}} {
  set_top r:/WORK/$ref_top
} else {
  set_top r:/WORK/$ref_top -parameter $params
}

read_sverilog -i -12 -work_library WORK $impl_files
if {$params eq {}} {
  set_top i:/WORK/$impl_top
} else {
  set_top i:/WORK/$impl_top -parameter $params
}

foreach {from to} $rename_rules {
  set_compare_rule $impl -from $from -to $to
}

# step 5: the ports not compared and the implementation cells held at a value (header)
set n_dv_ports 0
if {[info exists step_dont_verify($step)]} {
  foreach p $step_dont_verify($step) {
    foreach d [list $ref $impl] {
      set objs [get_ports -quiet "$d/$p*"]
      if {[sizeof_collection $objs] == 0} {
        puts "EQUIV $cfg: no port $p in $d"
        exit 1
      }
      set_dont_verify_points -type port $objs
    }
    incr n_dv_ports [sizeof_collection [get_ports -quiet "$impl/$p*"]]
  }
}
# step 5 has cells without a counterpart on both sides: they must stay unmatched, not be
# paired by their function (Formality's signature analysis, after the name matching)
if {[info exists step_moved($step)]} {
  set_app_var signature_analysis_match_compare_points false
}
set n_constants 0
if {[info exists step_constants($step)]} {
  foreach {c v} $step_constants($step) {
    set_constant -type cell "$impl/$c" $v
    incr n_constants
  }
}
# step 6: {side point value}, see the header
set step6_constants {}
if {$step == 6 && $part eq "ctrl"} {
  lappend step6_constants impl dsk_last_q_reg 0
} elseif {$step == 6 && $part eq "lp"} {
  foreach p {hsrx_early_i miss_off_i ulps_en_i tinit_set_i force_wait_i} {
    lappend step6_constants impl $p 0
  }
  for {set b 0} {$b < 24} {incr b} {
    lappend step6_constants impl "hs_tmo_i\[$b\]" [expr {$b == 20}]
  }
  for {set b 0} {$b < 20} {incr b} {
    lappend step6_constants impl "tinit_i\[$b\]" 0
  }
  for {set b 0} {$b < 12} {incr b} {
    lappend step6_constants impl "esc_tmo_i\[$b\]" 0
  }
  # the upper watchdog bits: 0 from the reset on with HS_TMO 2^20 (the count restarts at 0
  # in every Hs and the watchdog fires at 2^20 - 1, before a carry into bit 20)
  for {set b 0} {$b < 4} {incr b} {
    lappend step6_constants impl "tmr_hi_q_reg\[$b\]" 0
  }
  # the clock lane's REINIT exit flag: set only with force_wait_i, held 0 here
  if {[regexp {ClockLane = 1} $params]} {
    lappend step6_constants impl exit_wait_q_reg 0
  }
}
# step 6: the cut nets, the same name on both sides, not verified themselves
set n_cuts 0
if {$step == 6} {
  foreach net $step6_cut($part) {
    foreach d [list $ref $impl] {
      if {[sizeof_collection [get_nets -quiet "$d/$net"]] != 1} {
        puts "EQUIV $cfg: no net $net in $d"
        exit 1
      }
      set_cutpoint -type net "$d/$net"
      set_dont_verify_points -type net "$d/$net"
    }
    incr n_cuts
  }
}
foreach {side pt v} $step6_constants {
  set designs [expr {$side eq "both" ? [list $ref $impl] : [list [set $side]]}]
  foreach d $designs {
    if {[sizeof_collection [get_ports -quiet "$d/$pt"]] == 1} {
      set_constant -type port "$d/$pt" $v
    } elseif {[sizeof_collection [get_cells -quiet "$d/$pt"]] == 1} {
      set_constant -type cell "$d/$pt" $v
    } else {
      puts "EQUIV $cfg: no port or cell $pt in $d"
      exit 1
    }
    incr n_constants
  }
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
    set br [block_of [expr {$::step in {6 7} ? $::step : $::ref_step}] $r]
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

# Unmatched points (step 5: only the cells listed in step_moved / step_new, counted per
# prefix in unmatched_known.rpt)
proc known_unmatched {} {
  set bad {}
  set count [dict create]
  set fh [open unmatched.rpt r]
  set txt [read $fh]
  close $fh
  foreach {- side name} [regexp -all -inline -line {^\s+(Ref|Impl)\s+\S+\s+(\S+)\s*$} $txt] {
    set n [strip $name]
    set lst [expr {$side eq "Ref" ? [list_or_empty step_moved] : [list_or_empty step_new]}]
    if {$::step == 6 && $side eq "Impl"} {
      set lst $::step6_new($::part)
    }
    set hit {}
    foreach prefix $lst {
      if {[string first $prefix $n] == 0} {
        set hit $prefix
        break
      }
    }
    if {$hit eq {}} {
      lappend bad "$side $n"
    } else {
      dict incr count "$side $hit"
    }
  }
  set fo [open unmatched_known.rpt w]
  dict for {k v} $count {
    puts $fo "$v $k"
  }
  foreach b $bad {
    puts $fo "NOT LISTED: $b"
  }
  close $fo
  return [list $count $bad]
}
proc list_or_empty {arr} {
  upvar #0 $arr a
  if {[info exists a($::step)]} {
    return $a($::step)
  }
  return {}
}
lassign [known_unmatched] unmatched_known unmatched_bad
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
  # steps 5 and 6: the listed exceptions are checked below instead
  if {$step in {5 6} && $rpt in {unmatched.rpt constants.rpt dont_verify.rpt}} {
    continue
  }
  if {![regexp $re [slurp $rpt]]} {
    lappend bad "$what ($rpt)"
  }
}
if {$step == 5} {
  if {[llength $unmatched_bad] != 0} {
    lappend bad "[llength $unmatched_bad] unmatched points not listed in step_moved /\
                 step_new (unmatched_known.rpt)"
  }
  set ncon [regexp -all -line {pd_q_reg} [slurp constants.rpt]]
  if {$n_constants != 1 || $ncon != 1} {
    lappend bad "user constants: $ncon in constants.rpt, $n_constants set (step 5: PD only)"
  }
}
if {$step == 6} {
  if {[llength $unmatched_bad] != 0} {
    lappend bad "[llength $unmatched_bad] unmatched points not listed in step6_new\
                 (unmatched_known.rpt)"
  }
  # every constant of the part once in constants.rpt (a line per point: its name, then the
  # value), nothing else; no don't-verify point
  set ctxt [slurp constants.rpt]
  set ncon [regexp -all -line {^\s+[01]\s+\S+\s+[ri]:/} $ctxt]
  if {$ncon != $n_constants} {
    lappend bad "user constants: $ncon in constants.rpt, $n_constants set (step6_constants)"
  }
  # don't-verify points: none, or (part ctrl) exactly the cut nets, as one matched cut point
  # each, the same name on both sides
  set dvtxt [slurp dont_verify.rpt]
  if {$n_cuts == 0} {
    if {![regexp {Don't verify points:\s+None} $dvtxt]} {
      lappend bad "don't-verify points (dont_verify.rpt)"
    }
  } else {
    set dv_names {}
    foreach {- name} [regexp -all -inline -line {^\s+\(\w+\)\s+([ri]:/\S+)\s*$} $dvtxt] {
      lappend dv_names $name
    }
    set dv_names [lsort -unique $dv_names]
    set want {}
    foreach net $step6_cut($part) {
      lappend want "$ref/$net" "$impl/$net"
    }
    if {$dv_names ne [lsort -unique $want]} {
      lappend bad "don't-verify points [join $dv_names {, }], want the cut nets [join [lsort -unique $want] {, }]\
                   (dont_verify.rpt)"
    }
    set cut_pairs [matched_pairs -point_type cut]
    if {[llength $cut_pairs] != $n_cuts} {
      lappend bad "[llength $cut_pairs] matched cut points, $n_cuts cut nets"
    }
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
# step 5: the don't-verify points are exactly the bits of the listed ports
set dv_port 0
regexp {Don't verify\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)} $st \
  -> dv_bbpin dv_loop dv_bbnet dv_cut dv_port dv_dff dv_lat dv_total
if {$step == 5 && (![info exists dv_total] || $dv_total != $n_dv_ports || $dv_port != $n_dv_ports)} {
  lappend bad "don't-verify points: [expr {[info exists dv_total] ? $dv_total : 0}] in status.rpt,\
               $n_dv_ports port bits listed"
}
# (no "Not Compared" section: no constant register and no unread flop, e.g. the clock lane
# state machine of step 6; a section with one of the two lines: the other is 0, e.g. the
# packet layer of step 7 has unread flops only, the clock lane constant registers only)
if {![regexp {Not Compared} $st]} {
  set creg 0
  set unread 0
} else {
  if {![regexp {Constant reg} $st]} {
    set creg 0
  }
  if {![regexp {Unread} $st]} {
    set unread 0
  }
}
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
if {$step == 6} {
  set per {}
  dict for {k v} $unmatched_known {
    lappend per "$k $v"
  }
  set held [expr {$part eq "ctrl" ?
    "dsk_last_q 0 (RxSkewCalHS a pulse, v1)" :
    "the new inputs at the reset configuration (HS_TMO 2^20, the rest 0), tmr_hi_q 0[expr {[regexp {ClockLane = 1} $params] ? {, exit_wait_q 0} : {}}]"}]
  set cut [expr {$n_cuts ? "cut on both sides at [join $step6_cut($part) {, }] (a free input\
               of the logic it drives; the cut point not verified)" :
               "no cut point or don't-verify point"}]
  set summary "step $ref_step -> $step, part $part ($impl_top on both sides): $total compare\
               points matched and passing ($port ports, $dff flops), 0 failing / aborted /\
               unverified, $n_pairs matched pairs ($n_unread unread) with the reference's\
               names, no black box or user match; $cut; held: $held\
               ($n_constants user constants); unmatched only the new cells and ports\
               ([join $per {, }]); not compared: $creg constant registers, $unread unread flops"
}
if {$step == 7} {
  set what [dict get {dphy {the D-PHY} lp {the lane state machine} blk {an unchanged block}} $part]
  set summary "step $ref_step -> $step, part $part ($what, $impl_top on both sides,\
               [expr {$params eq {} ? {default parameters} : $params}]): $total compare points\
               matched and passing ($port ports, $dff flops), 0 unmatched, 0 failing / aborted /\
               unverified, $n_pairs matched pairs ($n_unread unread) with the reference's names,\
               no black box, user match, constant, cut or don't-verify point; not compared: $creg\
               constant registers, $unread unread flops"
}
if {$step == 5} {
  set per {}
  dict for {k v} $unmatched_known {
    lappend per "$k $v"
  }
  set summary "step $ref_step -> $step, $ref_top -> $impl_top: $total compare points matched\
               and passing ($port ports, $dff flops), 0 failing / aborted / unverified,\
               $n_pairs matched pairs ($n_unread unread) with the reference's names ($n_moved\
               through the rename rules) and $blocks, no black box or user match; the\
               changes of step 5: not compared $n_dv_ports port bits\
               ($step_dont_verify($step)), PD held at 0 (1 user constant), unmatched only the\
               listed cells ([join $per {, }]); not compared: $creg constant registers,\
               $unread unread flops"
}
if {$ok && [llength $bad] == 0} {
  puts "EQUIV $cfg: PASS: $summary"
  exit 0
}
puts "EQUIV $cfg: FAIL: [join $bad {; }]"
exit 1
