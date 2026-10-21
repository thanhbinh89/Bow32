# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Load Bow32 into the PL of a running Kria K26 over JTAG (xsdb), as an
# alternative to `xmutil loadapp` that does not need Linux (U-Boot is enough).
#
#   xsdb jtag_load.tcl <bitstream> [jtag_cable_serial]
#
# Normally called from hw/fpga/kv260/Makefile (`make fpga-jtag` at the top).
#
# A load through PCAP (xmutil / fpga-manager -> PMU firmware xilfpga) also
# takes the PL out of reset; a plain JTAG load (Vivado "Program Device")
# does not. After the Kria boot firmware the CSU holds the PL PROG_B low and
# pl_resetn0 low, so the PL stays cleared or Bow32 stays in reset. This script
# does the missing steps around the JTAG configuration:
#   1. release PROG_B of the PL       (CSU.PCAP_PROG)
#   2. hold pl_resetn0 low            (EMIO GPIO 95 = GPIO bank 5 bit 31)
#   3. configure the PL over JTAG
#   4. power up the PL / remove the PS-PL isolation (psu_ps_pl_isolation_removal)
#   5. release pl_resetn0             -> the boot ROM prints its banner on UART0
# pl_clk0 must already run at 100 MHz (the Kria boot firmware sets it up).

lassign $argv bit serial
if {$bit eq "" || ![file exists $bit]} {
  error "usage: xsdb jtag_load.tcl <bitstream> \[jtag_cable_serial\]"
}

connect

# Several boards may share one hw_server: work on the cable of the K26.
set filter {name == "PSU"}
if {$serial ne ""} {
  append filter " && jtag_cable_serial == \"$serial\""
}
set psu [targets -target-properties -filter $filter]
if {[llength $psu] == 0} {
  error "no Kria K26 (PSU target) found: board powered, JTAG cable connected?"
} elseif {[llength $psu] > 1} {
  error "[llength $psu] Kria K26 boards found, give the JTAG cable serial (JTAG_SERIAL=...)"
}
set serial [dict get [lindex $psu 0] jtag_cable_serial]
puts "INFO: Kria K26 on JTAG cable $serial"

proc use {name} {
  targets -set -filter "name == \"$name\" && jtag_cable_serial == \"$::serial\""
}

use PSU

# pl_clk0 = IOPLL / DIVISOR0 / DIVISOR1 (CRL_APB.PL0_REF_CTRL), IOPLL from the
# 33.333 MHz PS reference clock of the K26.
set pl0   [mrd -force -value 0xFF5E00C0]
set iopll [mrd -force -value 0xFF5E0020]
if {(($pl0 >> 24) & 1) == 0} {
  error "pl_clk0 is stopped (PL0_REF_CTRL = [format 0x%08x $pl0]), load with xmutil instead"
}
if {($pl0 & 0x7) == 0} {
  set mhz [expr {33.333 * (($iopll >> 8) & 0x7F) / (1 + (($iopll >> 16) & 1)) \
                 / (($pl0 >> 8) & 0x3F) / (($pl0 >> 16) & 0x3F)}]
  puts [format "INFO: pl_clk0 = %.1f MHz" $mhz]
  if {abs($mhz - 100.0) > 1.0} {
    puts "WARNING: Bow32 expects 100 MHz, the UART baud rate will be wrong"
  }
}

# 1. PROG_B high: the PL can be configured.
mwr -force 0xFFCA3000 0x1

# 2. pl_resetn0 low: GPIO bank 5 bit 31 as output (DIRM_5, OEN_5), then
#    MASK_DATA_5_MSW with all mask bits set except the one of bit 31.
mwr -force 0xFF0A0344 [expr {[mrd -force -value 0xFF0A0344] | 0x80000000}]
mwr -force 0xFF0A0348 [expr {[mrd -force -value 0xFF0A0348] | 0x80000000}]
mwr -force 0xFF0A002C 0x7FFF0000

# 3. Configure the PL.
use PL
fpga -file $bit
puts "INFO: [fpga -state]"
use PSU

# 4. PL power-up request to the PMU, which also removes the PS-PL isolation.
mwr -force 0xFFD80118 0x00800000
mwr -force 0xFFD80120 0x00800000
for {set i 0} {[mrd -force -value 0xFFD80110] & 0x00800000} {incr i} {
  if {$i >= 100} {
    error "PMU did not complete the PL power-up request"
  }
  after 10
}

# 5. Release pl_resetn0.
mwr -force 0xFF0A002C 0x7FFF8000
puts "INFO: Bow32 is out of reset"

disconnect
