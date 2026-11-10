# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Pre-placement hook of the Huins camera build (CARD=cam; tcl/build.tcl:
# STEPS.PLACE_DESIGN.TCL.PRE of impl_1), with the netlist and the constraints loaded.
#
# The xcvp1902 has four SLRs: the camera pins (bank 705) are in SLR0, the 200 MHz clock
# input (bank 718), the UARTs (bank 408) in SLR3, the LEDs (bank 812) in SLR2. The
# receiver's byte domain (180 MHz) starts at the XPHY capture flops and the video domain
# (200 MHz: CSI-2 output, ISP, H.264) follows it, so the MMCM and the whole SoC go into a
# Pblock on the SLR of the camera pins; the board I/O of the other SLRs is asynchronous
# (false paths). The D-PHY itself (u_dphy) is fixed by its pins and XPHY LOCs.
# When the clock input is in another SLR, its three nets may leave the dedicated clock
# routes (the overrides the Vivado-routed PHY probe and the RAM card build needed):
#   * the input pin -> the two input BUFGs (u_clk/u_in_bufg, u_clk/u_xpll_bufg):
#     CLOCK_DEDICATED_ROUTE FALSE (placer rule rule_gclkio_bufg);
#   * u_clk/u_in_bufg -> MMCM CLKIN1 (MMCM in the camera SLR): FALSE, as the RAM card build;
#   * u_clk/u_xpll_bufg -> XPLL CLKIN of the D-PHY bank: ANY_CMT_REGION (rule
#     rule_bufg_xpll_1load: a BUFG with an input pin driver and a single XPLL load must
#     otherwise share the XPLL's clock region); FALSE if opt_design merged the two BUFGs.

proc bow32_huins_cam_slr_of_port {port} {
  set ball [get_property PACKAGE_PIN [get_ports $port]]
  set pin [get_package_pins -quiet $ball]
  if {$ball eq "" || [llength $pin] != 1} {
    error "pre_place_cam: port $port has no package pin"
  }
  return [get_slrs -of_objects [get_iobanks [get_property BANK $pin]]]
}

set cam_slr [bow32_huins_cam_slr_of_port mipi_clk_p_i]
set clk_slr [bow32_huins_cam_slr_of_port clk_p_i]
puts "INFO: pre_place_cam: camera pins in $cam_slr, clock input in $clk_slr"

set mmcm [get_cells -quiet u_clk/u_mmcm]
set soc  [get_cells -quiet u_soc]
if {[llength $mmcm] != 1 || [llength $soc] != 1} {
  error "pre_place_cam: expected the MMCM u_clk/u_mmcm and the SoC u_soc, found: $mmcm $soc"
}
set pb [create_pblock pb_cam]
resize_pblock $pb -add $cam_slr
add_cells_to_pblock $pb [list $mmcm $soc]
puts "INFO: pre_place_cam: u_clk/u_mmcm and u_soc in Pblock pb_cam ($cam_slr)"

if {$cam_slr ne $clk_slr} {
  set xpll [get_cells -quiet -hierarchical -filter {REF_NAME == XPLL && NAME =~ u_dphy/*}]
  if {[llength $xpll] != 1} {
    error "pre_place_cam: expected one XPLL in u_dphy, found: $xpll"
  }
  set in_net   [get_nets -of_objects [get_pins u_clk/u_clk_ibuf/O]]
  set mmcm_net [get_nets -of_objects [get_pins u_clk/u_mmcm/CLKIN1]]
  set xpll_net [get_nets -of_objects [get_pins $xpll/CLKIN]]
  set_property CLOCK_DEDICATED_ROUTE FALSE $in_net
  set_property CLOCK_DEDICATED_ROUTE FALSE $mmcm_net
  if {$xpll_net eq $mmcm_net} {
    puts "INFO: pre_place_cam: one BUFG drives the MMCM and the XPLL ($xpll_net): FALSE"
  } else {
    set_property CLOCK_DEDICATED_ROUTE ANY_CMT_REGION $xpll_net
  }
  puts "INFO: pre_place_cam: input clock from $clk_slr: CLOCK_DEDICATED_ROUTE FALSE on\
        [get_property NAME $in_net] and [get_property NAME $mmcm_net],\
        [get_property CLOCK_DEDICATED_ROUTE $xpll_net] on [get_property NAME $xpll_net]"
}
