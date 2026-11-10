# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Pre-opt_design hook of the Huins camera build (CARD=cam; tcl/build.tcl:
# STEPS.OPT_DESIGN.TCL.PRE of impl_1), with the netlist and the constraints loaded.
#
# Every XPHY of the D-PHY (u_dphy, bow_dphy_io_versal) gets the LOC of the nibble its
# pins are in (DRC AVAL-314: Vivado places only the XPHYs of AMD's IP), and the nibble
# plan of the netlist (the Dphy* generics of the top, from tcl/cam_plan.tcl) is checked
# again, independently, against the placed pins and the AM010 forwarding rules
# (tcl/cam_xphy.tcl): every XPHY in the bank of the clock lane (the FMC+01 camera
# adapter: bank 705), the clock lane on slice 0 of the strobe XPHY. A plan that does not
# fit stops the build here, with the reason, instead of in route_design ("[Route 35-7]
# unroutable pins").

source [file join [file dirname [file normalize [info script]]] cam_xphy.tcl]

set clk_loc [bow32_cam_pin_loc [get_property PACKAGE_PIN [get_ports -quiet mipi_clk_p_i]]]
set bank    [expr {[llength $clk_loc] == 3 ? [lindex $clk_loc 0] : "(none)"}]
set n_xphy  [llength [bow32_cam_xphys u_dphy]]
set n_loc   [bow32_cam_loc_xphys u_dphy]
set errs    [bow32_cam_check_xphys u_dphy $bank mipi_clk_p_i]
foreach e $errs {
  puts "ERROR: cam_xphy: $e"
}
if {[llength $errs] || $n_xphy == 0 || $n_loc != $n_xphy} {
  error "pre_opt_cam: the XPHY nibble plan of u_dphy does not fit the camera pins ($n_loc of\
         $n_xphy XPHYs placed, [llength $errs] errors above; the plan generics come from\
         tcl/cam_plan.tcl, make plan CARD=cam; FMC_SITE must be 1: the Huins camera adapter\
         on FMC+01, bank 705)"
}
puts "INFO: pre_opt_cam: $n_loc XPHYs placed at their pins, nibble plan fits bank $bank"
