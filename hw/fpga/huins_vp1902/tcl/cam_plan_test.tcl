# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Test of the XPHY nibble plan rules of tcl/cam_plan.tcl (bow32_cam_plan_compute) with
# synthetic pin sets, in plain Tcl (no Vivado, no board data):
#
#   tclsh cam_plan_test.tcl          (make -C hw/fpga/huins_vp1902 test-plan)
#
#   * round trip: the pins of the synthetic plans of hw/fpga/common/dv/tb_bow_dphy_io_versal.sv
#     (plan 0 = the bow_dphy_io_versal defaults, 1, 2) and a 2 lane plan give back exactly
#     their generics (instance order: the strobe, then the other nibbles from the highest);
#   * every refusal: clock lane not on slice 0 or not an XCC pin, two banks, P/N swapped,
#     an N pad in another nibble, a nibble the strobe cannot reach (through an unused
#     nibble, from nibble 0, through an inter-nibble receiver), 5 nibbles, a missing port,
#     a pin that is not an XPIO nibble pin.
# Prints "cam_plan_test: PASS (<n> checks)" or the failures, exit code 1 on a failure.

set ::bow32_cam_plan_lib 1
source [file join [file dirname [file normalize [info script]]] cam_plan.tcl]

set n_checks 0
set n_fails  0
proc check {name cond {msg ""}} {
  incr ::n_checks
  if {!$cond} {
    incr ::n_fails
    puts "FAIL $name $msg"
  }
}

# pin set of a plan (bank, instance order strobe first): dict port -> {bank nibble slice xcc}
proc pins_of {bank numnib phys role lnib lsl lanes} {
  set strobe -1
  for {set i 0} {$i < $numnib} {incr i} {
    if {(($role >> (2 * $i)) & 3) == 0} {
      set strobe $i
    }
  }
  set sp [expr {($phys >> (4 * $strobe)) & 15}]
  set pi [dict create mipi_clk_p_i [list $bank $sp 0 1] mipi_clk_n_i [list $bank $sp 1 0]]
  for {set l 0} {$l < $lanes} {incr l} {
    set i [expr {($lnib >> (2 * $l)) & 3}]
    set n [expr {($phys >> (4 * $i)) & 15}]
    set s [expr {($lsl >> (3 * $l)) & 7}]
    dict set pi "mipi_data_p_i\[$l\]" [list $bank $n $s 0]
    dict set pi "mipi_data_n_i\[$l\]" [list $bank $n [expr {$s + 1}] 0]
  }
  return $pi
}

proc generics_of {numnib phys role src lnib lsl} {
  return [format "DphyNumNib=%d DphyNibPhys=16'h%04x DphyNibRole=8'h%02x DphyNibSrc=8'h%02x\
                  DphyLaneNib=8'h%02x DphyLaneSlice=12'h%03x" $numnib $phys $role $src $lnib $lsl]
}

# ---- round trip: {NumNib NibPhys NibRole NibSrc LaneNib LaneSlice lanes}
foreach {name p} {
  tb_plan0   {4 0x2564 0x98 0x00 0xd8 0x422 4}
  tb_plan1   {2 0x0067 0x04 0x00 0x11 0x520 4}
  tb_plan2   {4 0x6784 0x98 0x3c 0x39 0x910 4}
  two_lanes  {2 0x0023 0x04 0x00 0x04 0x022 2}
} {
  lassign $p numnib phys role src lnib lsl lanes
  set plan [bow32_cam_plan_compute [pins_of 700 $numnib $phys $role $lnib $lsl $lanes]]
  set want [regsub -all {\s+} [generics_of $numnib $phys $role $src $lnib $lsl] " "]
  set got  [expr {[dict exists $plan generics] ? [dict get $plan generics] : "-"}]
  check "round trip $name" [expr {[dict get $plan errors] eq {} && $got eq $want}] \
    "([dict get $plan errors]) got '$got', want '$want'"
}
set plan [bow32_cam_plan_compute [pins_of 700 4 0x6784 0x98 0x39 0x910 4]]
check "words" [expr {[lindex [bow32_cam_plan_words $plan] 1] eq "n1 = nibble 8: inter-byte from n3"}] \
  [lindex [bow32_cam_plan_words $plan] 1]

# ---- refusals (pins of plan 0, then one change)
proc base {} {
  return [pins_of 700 4 0x2564 0x98 0xd8 0x422 4]
}
proc lane {pi l bank nib slice} {
  dict set pi "mipi_data_p_i\[$l\]" [list $bank $nib $slice 0]
  dict set pi "mipi_data_n_i\[$l\]" [list $bank $nib [expr {$slice + 1}] 0]
  return $pi
}
proc refused {name pi pattern} {
  set e [join [dict get [bow32_cam_plan_compute $pi] errors] " | "]
  check "refused $name" [expr {$e ne "" && [regexp -- $pattern $e]}] "<$e>"
}

set pi [lane [base] 0 700 4 0]
dict set pi mipi_clk_p_i {700 4 2 1}
dict set pi mipi_clk_n_i {700 4 3 0}
refused "clock lane on slice 2" $pi {mipi_clk_p_i is on slice 2 of nibble 4}
set pi [base]
dict set pi mipi_clk_p_i {700 4 0 0}
refused "clock lane not XCC" $pi {no XCC}
refused "two banks" [lane [base] 3 701 2 2] {mipi_data_p_i\[3\] is in bank 701}
set pi [base]
dict set pi {mipi_data_p_i[1]} {700 5 5 0}
dict set pi {mipi_data_n_i[1]} {700 5 4 0}
refused "P/N swapped" $pi {mipi_data_p_i\[1\] is on slice 5, an N side}
set pi [base]
dict set pi {mipi_data_n_i[2]} {700 7 1 0}
refused "N pad in another nibble" $pi {mipi_data_n_i\[2\] is not the N pad}
refused "through an unused nibble" [lane [base] 3 700 0 2] {nibble 0 \(lane 3\) does not get}
refused "5 nibbles" [lane [lane [base] 3 700 3 2] 0 700 8 2] {in 5 nibbles}
set pi [dict create mipi_clk_p_i {700 0 0 1} mipi_clk_n_i {700 0 1 0}]
foreach {l n s} {0 1 0  1 1 2  2 2 0  3 0 2} {
  set pi [lane $pi $l 700 $n $s]
}
refused "strobe nibble 0 has no inter-byte" $pi {nibble 2 \(lane 2\) does not get}
set pi [dict create mipi_clk_p_i {700 4 0 1} mipi_clk_n_i {700 4 1 0}]
foreach {l n s} {0 5 0  1 7 2  2 4 2  3 4 4} {
  set pi [lane $pi $l 700 $n $s]
}
refused "inter-nibble receiver forwards nothing" $pi {nibble 7 \(lane 1\) does not get}
set pi [base]
dict unset pi {mipi_data_n_i[2]}
refused "missing port" $pi {no PACKAGE_PIN for mipi_data_n_i\[2\]}
set pi [base]
dict set pi {mipi_data_p_i[1]} {700 -1 -1 0}
refused "not an XPIO nibble pin" $pi {mipi_data_p_i\[1\] is not on an XPIO nibble pin}

if {$n_fails} {
  puts "cam_plan_test: FAIL ($n_fails of $n_checks checks)"
  exit 1
}
puts "cam_plan_test: PASS ($n_checks checks)"
