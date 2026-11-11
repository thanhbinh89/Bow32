# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Clock and CDC checks of the Huins camera build (CARD=cam) on an open design
# constrained by constr/huins_vp1902_cam.xdc (tcl/build.tcl runs them after
# implementation):
#
#   source timing_checks_cam.tcl
#   set failed [bow32_huins_cam_timing_checks <out_dir>]
#
# Every failed check prints a CRITICAL WARNING; the result is their number.
#   * clock periods: the XDC uses fixed numbers (clk_in 5 ns, clk_sys 20 ns,
#     clk_vid 5 ns, dphy_hs_clk 1.389 ns, dphy_byte_clk 4 x 1.389 ns,
#     dphy_pll_clk 1500 MHz);
#   * the byte clock is defined on exactly one pin, the FIFO_WR_CLK of the strobe
#     XPHY (the one with DQS_SRC LOCAL), and reaches the receiver through the
#     BUFGCE u_dphy/u_byte_bufg;
#   * every clock pair with paths between two different clocks is an
#     asynchronous clock group crossing (report_clock_interaction, column
#     Inter-Clock Constraints "Asynchronous Groups"): a "Timed" pair is a path
#     the XDC forgot. The receiver's crossings must exist in both directions
#     (clk_sys <-> clk_vid, clk_sys <-> dphy_byte_clk, clk_vid <-> dphy_byte_clk):
#     a missing one means the camera path was optimised away;
#   * check_timing: no unclocked or multiply clocked register, no constant or
#     pulse width clock problem, no unconstrained internal endpoint, no
#     generated clock problem, no loop, no partial I/O delay;
#   * report_cdc: every critical finding (CDC-1, -4, -7, -10 .. -14) is one of the
#     reviewed kinds of bow32_huins_cam_cdc_known below (first full build,
#     2026-11-10); anything else is a new crossing to review.
# Reports in <out_dir>: dphy_paths.rpt (worst setup and hold paths: XPHY Q -> capture
# flops, byte clock -> XPHY (FIFO_RDEN), clk_vid -> XPHY delay control, the byte
# domain), domain_paths.rpt (worst setup and hold paths of clk_vid and clk_sys),
# cdc.rpt (report_cdc -details).

# The reviewed CDC findings of the camera build: returns why a critical report_cdc row
# (id, from pin, to pin) is expected, "" for an unknown one. The CSI-2 receiver and the
# D-PHY cross only through synchronisers, gray coded buses (set_bus_skew) and dual clock
# RAMs (CDC-3 / CDC-6 / CDC-15), apart from the byte clock gate below; the other
# critical findings are the SoC's own, the same as on the KV260 (vid and sys clocks
# asynchronous there too):
#   CDC-1 / CDC-4   ISP / H.264 configuration registers (clk_sys) read directly in
#                   clk_vid: quasi-static, written while the block is idle
#   CDC-13 / CDC-14 the same for the ISP colour matrices (DSP inputs) and the capture
#                   scale (RAM address)
#   CDC-10          reset synchroniser CLR pins (an AND of reset levels: a glitch can
#                   only assert the reset early, the release is synchronised); the
#                   H.264 STATUS.BUSY synchroniser input is an OR of video domain flops
#                   (pre-existing, hw/ip/h264: a glitch can make one read show idle)
#   CDC-11          CSI-2 lane enables that are always equal (lanes 0 and 1; lanes 2
#                   and 3 with 4 lanes): synthesis merges their flops, so one lane_en_q
#                   flop feeds two synchronisers; quasi-static (they change only while
#                   the receiver is disabled)
#   CDC-13          the byte clock gate: BUFGCE CE from the clock lane state machine
#                   (clk_vid), changes only while the clock lane is static (false path)
# The receiver's rows follow its cells when the receiver's hierarchy changes
# (docs/ip/mipi_rx_arch.md, section 10): a pin path is split at its first instance named
# u_csi2rx, the receiver (bow_mipi_rx in bow32_top, bow_csi2rx up to step 1; anywhere
# above it), and the part below it must be one of the known places of the cell: the
# register file in u_regs of the controller (u_csi2rx/u_regs from step 2, u_regs before),
# the D-PHY cells in u_dphy_rx (from step 1) or right below the receiver (before). A
# CDC-11 row needs the lane enable flop and the synchroniser in the same receiver. The
# other ends keep their exact paths (u_dphy is the board level D-PHY I/O).
# tcl/timing_checks_cam_test.tcl (make test-cdc) checks every path form and the rows that
# must stay unreviewed, on paths written in the test: a later step that moves these cells
# again (a new hierarchy level) shows up in the build's own CDC check, as unreviewed rows,
# not in test-cdc.
proc bow32_huins_cam_rx_split {path} {
  # {receiver below} of a pin path, {} without an instance named u_csi2rx
  set parts [split $path /]
  set i [lsearch -exact $parts u_csi2rx]
  if {$i < 0} {
    return {}
  }
  return [list [join [lrange $parts 0 $i] /] [join [lrange $parts [expr {$i + 1}] end] /]]
}

proc bow32_huins_cam_cdc_known {id from to} {
  switch -- $id {
    CDC-1 - CDC-4 {
      if {[regexp {^u_soc/u_(isp|h264)/u_regs/} $from] && [regexp {^u_soc/u_(isp|h264)/} $to]} {
        return "$id ISP / H.264 configuration, quasi-static (clk_sys -> clk_vid)"
      }
    }
    CDC-10 {
      if {[regexp {/u_[a-z]*rst/sync_q_reg\[0\]/CLR$} $to]} {
        return "CDC-10 reset synchroniser CLR pins"
      }
      if {$to eq {u_soc/u_h264/u_sync_busy/sync_q_reg[0]/D}} {
        return "CDC-10 H.264 STATUS.BUSY (pre-existing, not camera specific)"
      }
    }
    CDC-11 {
      lassign [bow32_huins_cam_rx_split $from] rx_from below_from
      lassign [bow32_huins_cam_rx_split $to] rx_to below_to
      if {$rx_from ne "" && $rx_from eq $rx_to &&
          [regexp {^(u_csi2rx/)?u_regs/lane_en_q_reg\[\d+\]/C$} $below_from] &&
          [regexp {^(u_dphy_rx/)?u_sync_vcfg/g_bit\[\d+\]\.u_sync/sync_q_reg\[0\]/D$} $below_to]} {
        return "CDC-11 CSI-2 lane enables (merged flop of equal enables, quasi-static)"
      }
    }
    CDC-13 - CDC-14 {
      if {[regexp {^u_soc/u_isp/u_regs/} $from] && [regexp {^u_soc/u_isp/} $to]} {
        return "$id ISP coefficients / capture scale, quasi-static (clk_sys -> clk_vid)"
      }
      lassign [bow32_huins_cam_rx_split $from] rx_from below_from
      if {$rx_from ne "" && [regexp {^(u_dphy_rx/)?u_lp_clk/ce_q_reg/C$} $below_from] &&
          $to eq {u_dphy/u_byte_bufg/CE}} {
        return "CDC-13 byte clock gate (BUFGCE CE)"
      }
    }
  }
  return ""
}

proc bow32_huins_cam_timing_checks {out_dir} {
  set failed 0

  # ---- periods
  foreach {name period} [list clk_in 5.000 clk_sys 20.000 clk_vid 5.000 dphy_hs_clk 1.389 \
                              dphy_byte_clk [expr {4 * 1.389}] dphy_pll_clk 0.667] {
    set clk [get_clocks -quiet $name]
    if {[llength $clk] != 1} {
      puts "CRITICAL WARNING: clock $name not found (constr/huins_vp1902_cam.xdc)"
      incr failed
    } elseif {abs([get_property PERIOD $clk] - $period) > 0.001} {
      puts "CRITICAL WARNING: clock $name has a period of [get_property PERIOD $clk] ns,\
            constr/huins_vp1902_cam.xdc assumes $period ns"
      incr failed
    }
  }

  # ---- byte clock source: the strobe XPHY's FIFO_WR_CLK, through u_dphy/u_byte_bufg
  set src [get_property -quiet SOURCE_PINS [get_clocks -quiet dphy_byte_clk]]
  set strobe [get_cells -quiet -hierarchical -filter {REF_NAME == XPHY && NAME =~ u_dphy/* && DQS_SRC == LOCAL}]
  if {[llength $src] != 1 || [llength $strobe] != 1 ||
      [lindex $src 0] ne "[lindex $strobe 0]/FIFO_WR_CLK"} {
    puts "CRITICAL WARNING: dphy_byte_clk is defined on '$src', expected the FIFO_WR_CLK\
          pin of the strobe XPHY '$strobe'"
    incr failed
  }
  set bufg_clk [get_clocks -quiet -of_objects [get_pins -quiet u_dphy/u_byte_bufg/O]]
  if {[get_property -quiet NAME $bufg_clk] ne "dphy_byte_clk"} {
    puts "CRITICAL WARNING: the byte clock BUFGCE u_dphy/u_byte_bufg carries '$bufg_clk',\
          not dphy_byte_clk"
    incr failed
  }

  # ---- constraint of every clock pair with paths
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
    if {$got ne "Asynchronous Groups"} {
      puts "CRITICAL WARNING: paths from $from to $to are '$got', expected 'Asynchronous Groups'\
            (constr/huins_vp1902_cam.xdc), see clock_interaction.rpt"
      incr failed
    }
  }
  foreach pair {{clk_sys clk_vid} {clk_vid clk_sys} {clk_sys dphy_byte_clk} {dphy_byte_clk clk_sys}
                {clk_vid dphy_byte_clk} {dphy_byte_clk clk_vid}} {
    if {$pair ni $seen} {
      puts "CRITICAL WARNING: no paths from [lindex $pair 0] to [lindex $pair 1]: the CSI-2\
            receiver crossings are missing (optimised away?)"
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

  # ---- reports. Setup (max) and hold (min) separately: with -delay_type min_max,
  # -max_paths N reports the N worst of both together, i.e. only hold paths here.
  set rpt [file join $out_dir dphy_paths.rpt]
  file delete -force $rpt
  set xphy [get_cells -quiet -hierarchical -filter {REF_NAME == XPHY && NAME =~ u_dphy/*}]
  foreach d {max min} {
    report_timing -from $xphy -to [get_cells -quiet -hierarchical -filter {BLI == TRUE}] \
      -delay_type $d -max_paths 4 -file $rpt -append
    report_timing -to $xphy -from [get_clocks dphy_byte_clk] -delay_type $d -max_paths 4 \
      -file $rpt -append
    report_timing -to $xphy -from [get_clocks clk_vid] -delay_type $d -max_paths 4 \
      -file $rpt -append
    report_timing -from [get_clocks dphy_byte_clk] -to [get_clocks dphy_byte_clk] -delay_type $d \
      -max_paths 8 -file $rpt -append
  }
  set rpt [file join $out_dir domain_paths.rpt]
  file delete -force $rpt
  foreach d {max min} {
    foreach clk {clk_vid clk_sys} {
      report_timing -from [get_clocks $clk] -to [get_clocks $clk] -delay_type $d \
        -max_paths 8 -file $rpt -append
    }
  }
  foreach clk {dphy_byte_clk clk_vid clk_sys} {
    foreach d {setup hold} {
      set p [get_timing_paths -quiet -$d -from [get_clocks $clk] -to [get_clocks $clk] \
               -max_paths 1 -nworst 1]
      puts "INFO: worst $d slack within $clk: [expr {$p eq "" ? "no path" : [get_property SLACK $p]}]"
    }
  }

  # ---- CDC: every critical finding must be a reviewed kind (bow32_huins_cam_cdc_known)
  report_cdc -details -file [file join $out_dir cdc.rpt]
  set counts [dict create]
  set known  [dict create]
  foreach line [split [report_cdc -details -return_string] "\n"] {
    if {![regexp {^\s*\d+\s+(CDC-\d+)\s} $line -> id]} {
      continue
    }
    dict incr counts $id
    if {$id ni {CDC-1 CDC-4 CDC-7 CDC-10 CDC-11 CDC-12 CDC-13 CDC-14}} {
      continue
    }
    set words [regexp -all -inline {\S+} $line]
    set from  [lindex $words end-1]
    set to    [lindex $words end]
    set why   [bow32_huins_cam_cdc_known $id $from $to]
    if {$why eq ""} {
      puts "CRITICAL WARNING: $id from $from to $to is not a reviewed crossing\
            (tcl/timing_checks_cam.tcl), see cdc.rpt"
      incr failed
    } else {
      dict incr known $why
    }
  }
  dict for {id n} $counts {
    puts "INFO: report_cdc $id: $n"
  }
  dict for {why n} $known {
    puts "INFO: report_cdc reviewed: $why: $n"
  }

  return $failed
}
