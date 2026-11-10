# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# XPHY placement of the Huins camera build (bow_dphy_io_versal, CARD=cam), on an open
# design with the pin constraints loaded:
#
#   source cam_xphy.tcl
#   bow32_cam_loc_xphys <hier>                       -> number of XPHYs given a LOC
#   bow32_cam_check_xphys <hier> <bank> <clk_port>   -> list of errors
#
# Vivado does not place hand-instantiated XPHYs (DRC AVAL-314 XPHY_needs_LOC: only the
# XPHYs of AMD's IP are placed by opt_design), so each one gets the XPHY site of the
# XPIO nibble tile that holds the pins on its DATAIN (followed through the IBUFDS_DPHY to
# the port, its package pin and IOB site). And no DRC checks the strobe forwarding: a plan
# that does not fit the pins passes opt_design and place_design and fails in route_design
# with "[Route 35-7] ... unroutable pins" (CLK_TO_* -> CLK_FROM_OTHER_XPHY). So the check
# reads the forwarding from the netlist and the nibble of every XPHY from the pin
# functions (PIN_FUNC ..._N<nibble>P<slice>_<bank>), and applies the AM010 XP clocking
# rules:
#   * the pins of one XPHY are in one nibble, DATAIN[s] on NIBBLESLICE s;
#   * the strobe XPHY (DQS_SRC LOCAL) has the clock lane on DATAIN[0], which is <clk_port>
#     on slice 0 of a nibble of <bank>;
#   * an inter-nibble receiver (PCLK_NIBBLE_IN from another XPHY) is the pair partner of
#     its source (nibbles 0-1, 2-3, 4-5, 6-7), an inter-byte receiver (CLK_FROM_OTHER_XPHY
#     from CLK_TO_LOWER / CLK_TO_UPPER) sits 2 below / above its source (6 -> 8 lower);
#   * every XPHY is in <bank>; a placed XPHY (LOC) is in the tile of its pins.
# No ball number is printed: ports, banks, nibbles and sites only.

# Driver pin of the net on a pin (through the hierarchy), "" if none.
proc bow32_cam_driver {pin} {
  set n [get_nets -quiet -of_objects [get_pins -quiet $pin]]
  if {$n eq ""} {
    return ""
  }
  return [lindex [get_pins -quiet -leaf -of_objects [get_nets -quiet -segments $n] \
                    -filter {DIRECTION == OUT}] 0]
}

# The pads on the DATAIN pins of an XPHY: list of {slice port package_pin} (one per
# DATAIN driven by an IBUFDS_DPHY HSRX_O whose I pad is a port with a package pin)
proc bow32_cam_xphy_pads {xphy} {
  set r {}
  for {set s 0} {$s < 6} {incr s} {
    set drv [bow32_cam_driver $xphy/DATAIN\[$s\]]
    if {$drv eq "" || [get_property REF_PIN_NAME $drv] ne "HSRX_O"} {
      continue
    }
    set ib   [get_cells -of_objects $drv]
    set port [get_ports -quiet -of_objects [get_nets -quiet -segments \
                [get_nets -quiet -of_objects [get_pins $ib/I]]]]
    if {[llength $port] != 1} {
      continue
    }
    lappend r [list $s $port [get_property PACKAGE_PIN $port]]
  }
  return $r
}

# {bank nibble slice} of a package pin from its pin function, {} if it has none
proc bow32_cam_pin_loc {pkg} {
  set pp [get_package_pins -quiet $pkg]
  if {$pkg eq "" || [llength $pp] != 1} {
    return {}
  }
  if {![regexp {_N(\d)P(\d)_} [get_property PIN_FUNC $pp] -> nib slice]} {
    return {}
  }
  return [list [get_property BANK $pp] $nib $slice]
}

# XPHY site of the nibble tile of a package pin, "" if none
proc bow32_cam_xphy_site {pkg} {
  set iob  [get_sites -quiet -of_objects [get_package_pins -quiet $pkg]]
  set tile [get_tiles -quiet -of_objects $iob]
  set xs   [get_sites -quiet -of_objects $tile -filter {SITE_TYPE == XPHY}]
  return [expr {[llength $xs] == 1 ? $xs : ""}]
}

proc bow32_cam_xphys {hier} {
  return [lsort [get_cells -quiet -hierarchical -filter "REF_NAME == XPHY && NAME =~ $hier/*"]]
}

# LOC every XPHY under <hier> at the XPHY site of its pins; returns the number placed.
proc bow32_cam_loc_xphys {hier} {
  set n_ok 0
  foreach c [bow32_cam_xphys $hier] {
    set site ""
    foreach p [bow32_cam_xphy_pads $c] {
      set site [bow32_cam_xphy_site [lindex $p 2]]
      if {$site ne ""} {
        break
      }
    }
    if {$site eq ""} {
      puts "CRITICAL WARNING: cam_xphy: no XPHY site found for $c (pins without PACKAGE_PIN?)"
      continue
    }
    set_property LOC $site $c
    puts "INFO: cam_xphy: LOC $c -> $site (clock region [get_property CLOCK_REGION [get_sites $site]])"
    incr n_ok
  }
  return $n_ok
}

# Plan check, see the header; returns the list of errors (empty: the plan fits the pins).
proc bow32_cam_check_xphys {hier bank clk_port} {
  set errs {}
  set xphys [bow32_cam_xphys $hier]
  if {[llength $xphys] == 0} {
    return [list "no XPHY under $hier"]
  }
  # nibble of every XPHY from its pads
  set nib [dict create]
  foreach c $xphys {
    set pads [bow32_cam_xphy_pads $c]
    if {[llength $pads] == 0} {
      lappend errs "$c: no pad on its DATAIN pins"
      continue
    }
    set where {}
    foreach p $pads {
      lassign $p s port pkg
      set loc [bow32_cam_pin_loc $pkg]
      if {$loc eq ""} {
        lappend errs "$c: port $port has no package pin with a nibble pin function"
        continue
      }
      lassign $loc b n sl
      if {$sl != $s} {
        lappend errs "$c: port $port is on slice $sl of its nibble but drives DATAIN\[$s\]"
      }
      lappend where [list $b $n]
      if {$b != $bank} {
        lappend errs "$c: port $port is in bank $b, the camera plan is for bank $bank"
      }
    }
    if {[llength [lsort -unique $where]] > 1} {
      lappend errs "$c: its pads are in several nibbles: [lsort -unique $where]"
    } elseif {[llength $where] > 0} {
      dict set nib $c [lindex $where 0]
      puts "INFO: cam_xphy: $c in bank [lindex $where 0 0] nibble [lindex $where 0 1]\
            ([llength $pads] pads, DQS_SRC [get_property DQS_SRC $c])"
    }
    # a placed XPHY must sit in the tile of its pins
    set loc [get_property LOC $c]
    if {$loc ne ""} {
      set want [bow32_cam_xphy_site [lindex $pads 0 2]]
      if {$loc ne $want} {
        lappend errs "$c: placed at $loc, the XPHY of its pins is $want"
      }
    }
  }
  # strobe: the clock lane on DATAIN[0] of the DQS_SRC LOCAL nibble
  set strobes {}
  foreach c $xphys {
    if {[get_property DQS_SRC $c] eq "LOCAL"} {
      lappend strobes $c
    }
  }
  if {[llength $strobes] != 1} {
    lappend errs "expected one strobe XPHY (DQS_SRC LOCAL), found [llength $strobes]: $strobes"
  } else {
    set sc [lindex $strobes 0]
    set p0 [lsearch -inline -index 0 [bow32_cam_xphy_pads $sc] 0]
    if {$p0 eq "" || [lindex $p0 1] ne $clk_port} {
      lappend errs "strobe $sc: DATAIN\[0\] is not the clock lane port $clk_port"
    }
    set cl [bow32_cam_pin_loc [get_property PACKAGE_PIN [get_ports -quiet $clk_port]]]
    if {[llength $cl] != 3 || [lindex $cl 0] != $bank || [lindex $cl 2] != 0} {
      lappend errs "clock lane $clk_port is on bank/nibble/slice '$cl', not on slice 0 of a\
                    nibble of bank $bank"
    }
  }
  # forwarding rules
  foreach c $xphys {
    if {![dict exists $nib $c]} {
      continue
    }
    lassign [dict get $nib $c] b n
    set src_p [bow32_cam_driver $c/PCLK_NIBBLE_IN]
    set src_b [bow32_cam_driver $c/CLK_FROM_OTHER_XPHY]
    if {$src_p ne "" && [get_property REF_PIN_NAME $src_p] eq "PCLK_NIBBLE_OUT"} {
      set sc [get_cells -of_objects $src_p]
      if {[dict exists $nib $sc]} {
        lassign [dict get $nib $sc] sb sn
        if {$sb != $b || $n == 8 || $sn != ($n ^ 1)} {
          lappend errs "$c (bank $b N$n): inter-nibble strobe from bank $sb N$sn, not its pair partner"
        }
      }
    }
    if {$src_b ne "" && [get_property REF_PIN_NAME $src_b] in {CLK_TO_LOWER CLK_TO_UPPER}} {
      set sc  [get_cells -of_objects $src_b]
      set dir [get_property REF_PIN_NAME $src_b]
      if {[dict exists $nib $sc]} {
        lassign [dict get $nib $sc] sb sn
        if {$n < 4} {
          set want_n [expr {$n + 2}]; set want_dir CLK_TO_LOWER
        } elseif {$n == 8} {
          set want_n 6; set want_dir CLK_TO_LOWER
        } else {
          set want_n [expr {$n - 2}]; set want_dir CLK_TO_UPPER
        }
        if {$sb != $b || $sn != $want_n || $dir ne $want_dir} {
          lappend errs "$c (bank $b N$n): inter-byte strobe $dir from bank $sb N$sn,\
                        AM010 allows only $want_dir from N$want_n of the same bank"
        }
      }
    }
  }
  return $errs
}
