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
#
# Vivado cannot use a hw_server of an older Vivado ("ERROR: [Labtools
# 27-3366] Cannot support older hw_server version 2025.1"). On a shared
# machine the hw_server at localhost:3121 can be another user's (started by
# their Vivado session): the script then says so, names the hw_server
# processes on that port and the Vivado that matches them
# (docs/camera_huins.md section 5). It never stops or signals them.

# This Vivado session's log file: the -log of its command line (make jtag:
# jtag.log), else vivado.log; relative to the start directory
proc vivado_log {} {
  set log vivado.log
  if {![catch {open /proc/[pid]/cmdline} f]} {
    set cmd [split [string trimright [read $f] "\0"] "\0"]
    close $f
    set i [lsearch -exact $cmd -log]
    if {$i >= 0 && $i + 1 < [llength $cmd]} {
      set log [lindex $cmd [expr {$i + 1}]]
    }
  }
  return [file normalize $log]
}

# connect_hw_server failed (err): because the hw_server at url is of an
# older Vivado? The Tcl error only says "'connect_hw_server' failed due to
# earlier errors" (and get_msg_config -count read 0 for an error message ID
# in a test): the message line is looked for in the Vivado log, and a
# hw_server process on the port of a local url shows its version in its path.
proc older_hw_server {err url} {
  if {[regexp {27-3366|older hw_server} $err]} {
    return 1
  }
  if {![catch {open [vivado_log]} f]} {
    set text [read $f]
    close $f
    # the message line itself, not the echo of this script ("## ...")
    if {[regexp -line {^ERROR: \[Labtools 27-3366\]} $text]} {
      return 1
    }
  }
  foreach s [local_hw_servers $url] {
    set ver [lindex $s 3]
    if {$ver ne "" && ![catch {package vcompare $ver [version -short]} c] && $c < 0} {
      return 1
    }
  }
  return 0
}

# hw_server processes of this machine that listen on the port of url
# ([TCP:]host[:port], port 3121 by default; local hosts only): one
# {user pid executable version} per process, the version from the path
# (".../2025.1/Vivado/..."; "" if none)
proc local_hw_servers {url} {
  set hp [regsub -nocase {^tcp:} $url ""]
  set host $hp
  set port 3121
  regexp {^(.*):([0-9]+)$} $hp -> host port
  if {[lsearch -exact [list localhost 127.0.0.1 ::1 "" [info hostname]] $host] < 0} {
    return {}
  }
  # user:32: whole user names (procps cuts them at 8 characters otherwise)
  if {[catch {exec ps -eo user:32=,pid=,args=} ps] && [catch {exec ps -eo user=,pid=,args=} ps]} {
    return {}
  }
  set found {}
  foreach line [split $ps "\n"] {
    if {![regexp {^\s*(\S+)\s+([0-9]+)\s+((?:\S*/)?hw_server)(\s.*)?$} $line -> user pid exe rest]} {
      continue
    }
    set p 3121
    if {[regexp {(^|\s)-s\s+(\S+)} $rest -> - sarg]} {
      regexp {:([0-9]+)$} $sarg -> p
    }
    if {$p != $port} {
      continue
    }
    set ver ""
    regexp {/([0-9]{4}\.[0-9])/} $exe -> ver
    lappend found [list $user $pid $exe $ver]
  }
  return $found
}

# vivado (or vivado_lab) of the install that holds the hw_server executable,
# else this Vivado's install path with the version replaced; "" if none
proc matching_vivado {exe ver} {
  set dirs {}
  if {[regexp {^(.*/Vivado(_Lab)?)/} $exe -> d]} {
    lappend dirs $d
  }
  if {[info exists ::env(XILINX_VIVADO)] && $ver ne ""} {
    lappend dirs [string map [list [version -short] $ver] $::env(XILINX_VIVADO)]
  }
  foreach d $dirs {
    foreach v {vivado vivado_lab} {
      if {[file executable $d/bin/$v]} {
        return $d/bin/$v
      }
    }
  }
  return ""
}

proc hw_server_hint {url} {
  set me [version -short]
  set vivado ""
  set servers [local_hw_servers $url]
  puts "jtag: the hw_server at $url is of an older Vivado than this one ($me), which cannot"
  puts "jtag: use it: nothing was loaded. On a shared machine it is most likely another"
  puts "jtag: user's server, started by their Vivado:"
  foreach s $servers {
    lassign $s user pid exe ver
    # (not expr: it would turn " 2025.1" into a number)
    set name hw_server
    if {$ver ne ""} {
      append name " $ver"
      if {$vivado eq ""} {
        set vivado [matching_vivado $exe $ver]
      }
    }
    puts "jtag:   $name of user $user (pid $pid): $exe"
  }
  if {[llength $servers] == 0} {
    puts "jtag:   (no hw_server process on that port found on this machine)"
  }
  if {$vivado eq ""} {
    set vivado "<vivado of the hw_server's version>"
  }
  puts "jtag: Never stop or signal another user's hw_server, cs_server or xsdb. Wait until it"
  puts "jtag: exits, or, once the board's owner says the board is free, load as a client of"
  puts "jtag: that server with a Vivado of its version: the same make command with"
  puts "jtag:   VIVADO=$vivado"
  puts "jtag: or point it at a hw_server of Vivado $me elsewhere: HW_SERVER=<host:port>"
}

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
if {[catch {connect_hw_server -url $url} err]} {
  set info $::errorInfo
  if {[older_hw_server $err $url]} {
    hw_server_hint $url
    error "jtag: the hw_server at $url is older than Vivado [version -short] (see above)"
  }
  error $err $info
}

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
