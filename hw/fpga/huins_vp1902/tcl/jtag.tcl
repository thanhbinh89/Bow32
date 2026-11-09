# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Load the Bow32 device image into the Huins MFP-VP1902-S over its USB JTAG
# (Digilent JTAG-SMT3 on the front panel; boot mode switch SW1 = JTAG, all
# levers OFF, set with the power off).
#
#   vivado -mode batch -source jtag.tcl -tclargs <pdi> [hw_server_url] [cable_serial]
#
# hw_server_url: default localhost:3121 (a local hw_server is started when
# none runs). cable_serial: the Digilent serial (e.g. 210357B8AC4E) when
# several cables are attached; else the only target with an xcvp1902.

if {[llength $argv] < 1} {
  error "usage: jtag.tcl <pdi> \[hw_server_url\] \[cable_serial\]"
}
set pdi    [file normalize [lindex $argv 0]]
set url    [expr {[llength $argv] > 1 && [lindex $argv 1] ne "" ? [lindex $argv 1] : "localhost:3121"}]
set serial [expr {[llength $argv] > 2 ? [lindex $argv 2] : ""}]

if {![file exists $pdi]} {
  error "device image $pdi not found"
}

open_hw_manager
connect_hw_server -url $url

set targets [get_hw_targets -quiet]
if {$serial ne ""} {
  set targets [lsearch -all -inline $targets "*$serial*"]
}
if {[llength $targets] == 0} {
  error "no JTAG target on $url[expr {$serial ne "" ? " with serial $serial" : ""}] (cable plugged in, board powered on?)"
}

set dev ""
foreach t $targets {
  open_hw_target $t
  set devs [get_hw_devices -quiet xcvp1902*]
  if {[llength $devs] > 0} {
    set dev [lindex $devs 0]
    puts "INFO: target $t, device $dev"
    break
  }
  puts "INFO: target $t has no xcvp1902 ([get_hw_devices -quiet]), skipped"
  close_hw_target
}
if {$dev eq ""} {
  error "no xcvp1902 on [join $targets {, }]: is the board powered on (the JTAG chain needs the board's 1.8 V)?"
}

current_hw_device $dev
set_property PROGRAM.FILE $pdi $dev
program_hw_devices $dev
refresh_hw_device -quiet $dev
puts "INFO: programmed $dev with $pdi"

close_hw_target
disconnect_hw_server
close_hw_manager
