# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Check of the RAM data paths of a two clock FIFO (bow_fifo_async) on an open, timed design
# (tcl/build.tcl of the Huins camera build, hw/fpga/kv260_cam/ooc/rx_ooc.tcl):
#
#   source fifo_ram_checks.tcl
#   set problems [bow32_fifo_ram_paths <fifo instance name pattern> <name>]
#
# A FIFO in LUTRAM is written on its write clock and read through its read register
# (u_ram/rdata_o_reg) on the read clock, so the written data reach that register over fabric
# paths between the two clocks. A clock group leaves them unbounded (in Vivado it takes
# precedence over set_max_delay); the camera XDCs give them a data path limit of one read
# clock period instead (set_max_delay -datapath_only, review of step 7 of
# docs/ip/mipi_rx_arch.md: the lane merge FIFO u_csi2rx/u_lane_merge/u_cdc_fifo), as the DDR /
# HyperRAM PHY FIFOs have. The check: every bit of the read register is reached from the
# FIFO's RAM, each worst path carries such a limit and meets it. Prints one INFO line
# (endpoints, limit, worst slack, longest data path) and returns one line per problem, an
# empty list when the paths are timed and met.

proc bow32_fifo_ram_paths {fifo name} {
  set ram [get_cells -quiet -hierarchical \
             -filter "NAME =~ $fifo/u_ram/* && IS_PRIMITIVE && REF_NAME =~ RAM*"]
  set rd  [get_cells -quiet -hierarchical -filter "NAME =~ $fifo/u_ram/rdata_o_reg*"]
  if {[llength $ram] == 0 || [llength $rd] == 0} {
    return [list "$name: [llength $ram] RAM cells, [llength $rd] read register bits ($fifo/u_ram)"]
  }
  set paths [get_timing_paths -quiet -from $ram -to $rd -max_paths [expr {4 * [llength $rd]}] \
               -nworst 1 -unique_pins]
  set problems {}
  set ends {}
  set limits {}
  set worst {}
  set dmax 0.0
  foreach p $paths {
    set exc   [get_property EXCEPTION $p]
    set slack [get_property SLACK $p]
    set end   [get_property ENDPOINT_PIN $p]
    lappend ends $end
    if {![regexp {^MaxDelay Path ([0-9.]+)ns -datapath_only} $exc -> lim]} {
      lappend problems "$name: RAM path to $end not bounded by a data path limit\
                        (exception '$exc')"
      continue
    }
    lappend limits $lim
    if {$slack eq "" || $slack < 0} {
      lappend problems "$name: RAM path to $end: slack '$slack' ns"
    }
    if {$slack ne "" && ($worst eq "" || $slack < $worst)} {
      set worst $slack
    }
    set d [get_property DATAPATH_DELAY $p]
    if {$d > $dmax} {
      set dmax $d
    }
  }
  set ends [lsort -unique $ends]
  if {[llength $ends] != [llength $rd]} {
    lappend problems "$name: the RAM paths reach [llength $ends] of [llength $rd] read register bits"
  }
  puts "INFO: $name RAM -> read register: [llength $ends] of [llength $rd] bits timed, limit\
        [lsort -unique $limits] ns (data path only), worst slack $worst ns, longest data path\
        [format %.3f $dmax] ns"
  return $problems
}
