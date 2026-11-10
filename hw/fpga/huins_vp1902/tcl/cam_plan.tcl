# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# XPHY nibble plan of the Huins camera build (CARD=cam), derived from the pins before
# synthesis:
#
#   vivado -mode batch -source cam_plan.tcl -tclargs <pins_xdc> <plan_out> [part]
#     (hw/fpga/huins_vp1902/Makefile: make plan CARD=cam, part of make pdi CARD=cam)
#
# The plan is the board half of bow_dphy_io_versal: the XPHY nibble and slice of every MIPI
# pair and how the clock lane (the strobe) reaches each nibble. On the Huins board it
# follows from the confidential pin map, so the repo holds none of it. This script reads
# the PACKAGE_PIN lines of the MIPI ports from <pins_xdc> (tools/huins_pins.py, build
# directory), opens an empty design on the part (link_design without a netlist: ~30 s,
# ~3 GB) and takes bank, nibble and slice of each pin from its package pin function
# (PIN_FUNC IO_L<n><P|N>_[GC_][XCC_]N<k>P<j>_..._<bank>). The rules are those of the plan
# check of bow_dphy_io_versal (AM010, XP clocking):
#   * all MIPI pairs in one XPIO bank (the strobe never leaves its bank);
#   * the clock lane P pad on NIBBLESLICE 0 of its nibble, an XCC pin; every N pad on the
#     slice after its P pad, in the same nibble (no P/N swap); data lane P pads on slice
#     0, 2 or 4;
#   * at most 4 nibbles (XPHY instances), each reached by the strobe through nibbles with
#     MIPI pins only: inter-nibble from the pair partner (nibbles 0-1, 2-3, 4-5, 6-7), or
#     inter-byte from the nibble 2 above (nibbles 0..3; 6 -> 8) or 2 below (4..7); only
#     the strobe nibble and inter-byte receivers forward. Breadth first from the strobe,
#     the pair partner before the inter-byte neighbours;
#   * instance 0 = the strobe nibble, then the other nibbles from the highest down.
# <plan_out> gets the generics of bow32_huins_vp1902_cam_top (tcl/build.tcl adds them), the
# bank and the nibbles (for the checks of tcl/build.tcl) and the plan in words. It is board
# data like the pin XDC: never commit or publish it; the console only gets a summary. A pin
# set the XPHYs cannot capture stops here, with the reason (port, nibble, slice). No ball
# number is printed.
#
# Sourced with ::bow32_cam_plan_lib set (a test without Vivado), it only defines the procs;
# bow32_cam_plan_compute needs no Vivado.

# Inter-byte source of a receiver at physical nibble p (bow_dphy_io_versal byte_src_phys).
proc bow32_cam_plan_byte_src {p} {
  if {$p < 4} {
    return [expr {$p + 2}]
  } elseif {$p == 8} {
    return 6
  }
  return [expr {$p - 2}]
}

# The plan of a pin set. pinfo: dict port -> {bank nibble slice xcc} (nibble / slice -1:
# not an XPIO nibble pin). Returns a dict: errors (a list, empty if the pins fit), and
# for a plan that fits: lanes, bank, order (the physical nibble of every instance), role
# and src (per instance: 0 strobe / 1 inter-nibble / 2 inter-byte, source instance),
# lane_inst and lane_slice (per lane) and generics (the cam top's Dphy* parameters).
proc bow32_cam_plan_compute {pinfo} {
  set errs {}
  set ports {mipi_clk_p_i mipi_clk_n_i}
  set lanes 0
  while {[dict exists $pinfo "mipi_data_p_i\[$lanes\]"]} {
    lappend ports "mipi_data_p_i\[$lanes\]" "mipi_data_n_i\[$lanes\]"
    incr lanes
  }
  if {$lanes < 1 || $lanes > 4} {
    lappend errs "$lanes data lanes (mipi_data_p_i\[0..\]), bow_dphy_io_versal takes 1..4"
  }
  foreach p $ports {
    if {![dict exists $pinfo $p]} {
      lappend errs "no PACKAGE_PIN for $p"
    } elseif {[lindex [dict get $pinfo $p] 1] < 0} {
      lappend errs "$p is not on an XPIO nibble pin (bank [lindex [dict get $pinfo $p] 0],\
                    no N<k>P<j> in its pin function): no XPHY can capture it"
    }
  }
  if {[llength $errs]} {
    return [dict create errors $errs]
  }

  # one bank, the bank of the clock lane
  lassign [dict get $pinfo mipi_clk_p_i] bank cnib csl cxcc
  foreach p $ports {
    set b [lindex [dict get $pinfo $p] 0]
    if {$b != $bank} {
      lappend errs "$p is in bank $b, the clock lane mipi_clk_p_i in bank $bank: the strobe\
                    never leaves its XPIO bank, all MIPI pairs must be in one bank"
    }
  }
  # the clock lane: NIBBLESLICE 0 of its nibble, an XCC pin
  if {$csl != 0} {
    lappend errs "the clock lane mipi_clk_p_i is on slice $csl of nibble $cnib: the strobe\
                  enters NIBBLESLICE 0 only (an XCC pin N<k>P0)"
  } elseif {!$cxcc} {
    lappend errs "the clock lane mipi_clk_p_i is on slice 0 of nibble $cnib, but its pin\
                  function has no XCC (not a strobe capable pin)"
  }
  # pairs: N on the slice after P, same nibble; data lane P on an even slice
  set pairs [list mipi_clk_p_i mipi_clk_n_i]
  for {set l 0} {$l < $lanes} {incr l} {
    lappend pairs "mipi_data_p_i\[$l\]" "mipi_data_n_i\[$l\]"
    set sl [lindex [dict get $pinfo "mipi_data_p_i\[$l\]"] 2]
    if {$sl % 2 != 0} {
      lappend errs "mipi_data_p_i\[$l\] is on slice $sl, an N side: P pads are on slice 0, 2\
                    or 4 (P/N swapped?)"
    }
  }
  foreach {pp np} $pairs {
    lassign [dict get $pinfo $pp] pb pn ps
    lassign [dict get $pinfo $np] nb nn ns
    if {$nb != $pb || $nn != $pn || $ns != $ps + 1} {
      lappend errs "$np is not the N pad of $pp (nibble $nn slice $ns, P on nibble $pn slice\
                    $ps): an N pad sits on the slice after its P pad, in the same nibble"
    }
  }
  if {[llength $errs]} {
    return [dict create errors $errs]
  }

  # nibbles: the strobe's and those of the data lanes
  set used [list $cnib]
  for {set l 0} {$l < $lanes} {incr l} {
    lappend used [lindex [dict get $pinfo "mipi_data_p_i\[$l\]"] 1]
  }
  set used [lsort -integer -unique $used]
  if {[llength $used] > 4} {
    return [dict create errors [list "the MIPI pairs are in [llength $used] nibbles\
      ([join $used {, }]), bow_dphy_io_versal has at most 4 XPHY instances"]]
  }

  # strobe forwarding, breadth first from the strobe nibble (pair partner first)
  set role [dict create $cnib 0]
  set srcn [dict create $cnib -1]
  set queue [list $cnib]
  while {[llength $queue]} {
    set x [lindex $queue 0]
    set queue [lrange $queue 1 end]
    if {[dict get $role $x] == 1} {
      continue                                ;# an inter-nibble receiver forwards nothing
    }
    set q [expr {$x ^ 1}]
    if {$x != 8 && $q in $used && ![dict exists $role $q]} {
      dict set role $q 1
      dict set srcn $q $x
      lappend queue $q
    }
    foreach q $used {
      if {![dict exists $role $q] && [bow32_cam_plan_byte_src $q] == $x} {
        dict set role $q 2
        dict set srcn $q $x
        lappend queue $q
      }
    }
  }
  foreach n $used {
    if {![dict exists $role $n]} {
      set who {}
      for {set l 0} {$l < $lanes} {incr l} {
        if {[lindex [dict get $pinfo "mipi_data_p_i\[$l\]"] 1] == $n} {
          lappend who "lane $l"
        }
      }
      lappend errs "nibble $n ([join $who {, }]) does not get the strobe of nibble $cnib through\
                    nibbles with MIPI pins (inter-nibble: pair partner; inter-byte: 2 above for\
                    nibbles 0..3, 6 -> 8, 2 below for 4..7; inter-nibble receivers forward nothing)"
    }
  }
  if {[llength $errs]} {
    return [dict create errors $errs]
  }

  # instances: the strobe nibble, then the others from the highest down
  set order [list $cnib]
  foreach n [lsort -integer -decreasing $used] {
    if {$n != $cnib} {
      lappend order $n
    }
  }
  set phys 0; set roles 0; set srcs 0; set lnib 0; set lsl 0
  set inst_role {}; set inst_src {}
  for {set i 0} {$i < [llength $order]} {incr i} {
    set n [lindex $order $i]
    set r [dict get $role $n]
    set s [expr {$r == 0 ? 0 : [lsearch -exact $order [dict get $srcn $n]]}]
    lappend inst_role $r
    lappend inst_src $s
    set phys  [expr {$phys  | ($n << (4 * $i))}]
    set roles [expr {$roles | ($r << (2 * $i))}]
    set srcs  [expr {$srcs  | ($s << (2 * $i))}]
  }
  set lane_inst {}; set lane_slice {}
  for {set l 0} {$l < $lanes} {incr l} {
    lassign [dict get $pinfo "mipi_data_p_i\[$l\]"] b n sl
    set i [lsearch -exact $order $n]
    lappend lane_inst $i
    lappend lane_slice $sl
    set lnib [expr {$lnib | ($i  << (2 * $l))}]
    set lsl  [expr {$lsl  | ($sl << (3 * $l))}]
  }
  set generics [format "DphyNumNib=%d DphyNibPhys=16'h%04x DphyNibRole=8'h%02x DphyNibSrc=8'h%02x\
                        DphyLaneNib=8'h%02x DphyLaneSlice=12'h%03x" \
                  [llength $order] $phys $roles $srcs $lnib $lsl]
  return [dict create errors {} lanes $lanes bank $bank order $order role $inst_role \
            src $inst_src lane_inst $lane_inst lane_slice $lane_slice \
            generics [regsub -all {\s+} $generics " "]]
}

# The plan in words (one line per instance and lane)
proc bow32_cam_plan_words {plan} {
  set names {"strobe (clock lane)" "inter-nibble" "inter-byte"}
  set lines {}
  set order [dict get $plan order]
  for {set i 0} {$i < [llength $order]} {incr i} {
    set r [lindex [dict get $plan role] $i]
    set what [lindex $names $r]
    if {$r != 0} {
      append what " from n[lindex [dict get $plan src] $i]"
    }
    lappend lines "n$i = nibble [lindex $order $i]: $what"
  }
  for {set l 0} {$l < [dict get $plan lanes]} {incr l} {
    lappend lines "data lane $l: n[lindex [dict get $plan lane_inst] $l] slice\
                   [lindex [dict get $plan lane_slice] $l]"
  }
  return $lines
}

# PACKAGE_PIN of the MIPI ports in a pin XDC of tools/huins_pins.py ("set_property
# PACKAGE_PIN <pin> [get_ports {<port>}]"): dict port -> package pin (kept in memory, never
# printed)
proc bow32_cam_plan_read_xdc {xdc} {
  set pins [dict create]
  set fh [open $xdc r]
  foreach line [split [read $fh] "\n"] {
    if {[regexp {^\s*set_property\s+PACKAGE_PIN\s+(\S+)\s+\[get_ports\s+\{([^\}]+)\}\]} \
           $line -> pkg port] && [string match mipi_* $port]} {
      dict set pins [string trim $port] $pkg
    }
  }
  close $fh
  return $pins
}

# Bank, nibble, slice and XCC of each pin from the package pin functions of the open
# design (link_design on the part): dict port -> {bank nibble slice xcc}
proc bow32_cam_plan_pininfo {pins} {
  set info [dict create]
  dict for {port pkg} $pins {
    set pp [get_package_pins -quiet $pkg]
    if {[llength $pp] != 1} {
      error "cam_plan: the PACKAGE_PIN of $port is not a package pin of the part"
    }
    set func [get_property PIN_FUNC $pp]
    if {![regexp {_N(\d)P(\d)_} $func -> nib sl]} {
      set nib -1
      set sl -1
    }
    dict set info $port [list [get_property BANK $pp] $nib $sl [regexp {(^|_)XCC(_|$)} $func]]
  }
  return $info
}

# Write the plan file (tcl/build.tcl reads the generics, bank and nibbles lines)
proc bow32_cam_plan_write {plan xdc out} {
  set fh [open $out w]
  puts $fh "# GENERATED by hw/fpga/huins_vp1902/tcl/cam_plan.tcl from [file tail $xdc]: the XPHY"
  puts $fh "# nibble plan of the camera pins, board data of the confidential Huins pin map:"
  puts $fh "# never commit or publish this file."
  puts $fh "generics [dict get $plan generics]"
  puts $fh "bank [dict get $plan bank]"
  puts $fh "nibbles [dict get $plan order]"
  foreach line [bow32_cam_plan_words $plan] {
    puts $fh "# $line"
  }
  close $fh
}

proc bow32_cam_plan_main {argv} {
  if {[llength $argv] < 2} {
    error "usage: cam_plan.tcl <pins_xdc> <plan_out> \[part\]"
  }
  lassign $argv xdc out part
  if {$part eq ""} {
    set part xcvp1902-vsva6865-2MP-e-S
  }
  file delete -force $out
  set pins [bow32_cam_plan_read_xdc $xdc]
  link_design -part $part -name cam_plan
  set plan [bow32_cam_plan_compute [bow32_cam_plan_pininfo $pins]]
  close_design
  set errs [dict get $plan errors]
  if {[llength $errs]} {
    foreach e $errs {
      puts "ERROR: cam_plan: $e"
    }
    error "cam_plan: the camera pins of [file tail $xdc] do not fit the XPHY strobe rules\
           ([llength $errs] errors above): no plan, no build"
  }
  bow32_cam_plan_write $plan $xdc $out
  # (the plan in words is in the file only: board data stays out of the console)
  puts "INFO: cam_plan: bank [dict get $plan bank], [llength [dict get $plan order]] XPHY\
        nibbles, [dict get $plan lanes] data lanes -> $out"
}

if {![info exists ::bow32_cam_plan_lib]} {
  bow32_cam_plan_main $argv
}
