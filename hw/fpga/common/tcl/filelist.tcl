# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Read Bow32 file lists (.f) from Tcl, with the same semantics as
# `verilator -F`: every relative path is relative to the file list that
# contains it. Supported lines:
#   // comment
#   -F <other.f>      (nested list; -f is treated the same way)
#   +incdir+<dir>
#   <source file>
#
# Usage:
#   lassign [bow32_parse_f path/to/list.f] files incdirs

proc bow32_parse_f {path} {
  set path [file normalize $path]
  set dir  [file dirname $path]
  set files   {}
  set incdirs {}

  set fh [open $path r]
  set lines [split [read $fh] "\n"]
  close $fh

  foreach line $lines {
    set line [string trim [regsub {//.*$} $line ""]]
    if {$line eq ""} {
      continue
    }
    if {[regexp {^-[fF]\s+(\S+)$} $line -> sub]} {
      lassign [bow32_parse_f [file join $dir $sub]] sub_files sub_incdirs
      lappend files {*}$sub_files
      lappend incdirs {*}$sub_incdirs
    } elseif {[regexp {^\+incdir\+(\S+)$} $line -> inc]} {
      lappend incdirs [file normalize [file join $dir $inc]]
    } else {
      lappend files [file normalize [file join $dir $line]]
    }
  }
  return [list $files [lsort -unique $incdirs]]
}
