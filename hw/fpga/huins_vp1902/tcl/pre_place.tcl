# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Pre-placement hook of the Huins build (tcl/build.tcl: STEPS.PLACE_DESIGN.TCL.PRE
# of impl_1), with the netlist and the constraints loaded.
#
# The xcvp1902 has four SLRs, and the clock input may sit in another SLR than
# the card's pads (CLK_SRC = ref200: the 200 MHz input is in bank 718 = SLR3,
# the FMC+10 pads in banks 708..710 = SLR0). The four MMCMs of the DDR and
# HyperRAM clocks belong next to the pads: their outputs clock the PHY
# registers and the ODDR / IDDR of the pads, whose paths have quarter-period
# budgets (write phase uncertainty), while the MMCM input only has to arrive.
# So the MMCMs go into a Pblock on the SLR of the pads, and when the input
# comes from another SLR, the BUFG nets at the MMCM inputs (u_clk/u_clk_in_bufg,
# u_hr_clk/u_in_bufg, or one of them if opt_design merged the two) may leave
# the dedicated clock-capable route (CLOCK_DEDICATED_ROUTE FALSE: global clock
# routing across the SLRs to the MMCM inputs).

proc bow32_huins_slr_of_port {port} {
  set ball [get_property PACKAGE_PIN [get_ports $port]]
  set pin [get_package_pins -quiet $ball]
  if {$ball eq "" || [llength $pin] != 1} {
    error "pre_place: port $port has no package pin"
  }
  return [get_slrs -of_objects [get_iobanks [get_property BANK $pin]]]
}

set pad_slr [bow32_huins_slr_of_port {ddr_dq_io[0]}]
set clk_slr [bow32_huins_slr_of_port clk_p_i]
puts "INFO: pre_place: card pads in $pad_slr, clock input in $clk_slr"

set mmcms [get_cells {u_clk/u_mmcm_a u_clk/u_mmcm_b u_hr_clk/u_mmcm_h u_hr_clk/u_mmcm_r}]
if {[llength $mmcms] != 4} {
  error "pre_place: expected the four MMCMs of u_clk / u_hr_clk, found: $mmcms"
}
set pb [create_pblock pb_mem_mmcm]
resize_pblock $pb -add $pad_slr
add_cells_to_pblock $pb $mmcms
puts "INFO: pre_place: MMCMs [get_property NAME $mmcms] in Pblock pb_mem_mmcm ($pad_slr)"

if {$pad_slr ne $clk_slr} {
  # the nets at the MMCM inputs, whichever BUFG drives them (opt_design may
  # merge the two input BUFGs, which have the same driver)
  set clkin [get_nets -of_objects [get_pins -of_objects $mmcms -filter {REF_PIN_NAME == CLKIN1}]]
  if {[llength $clkin] == 0} {
    error "pre_place: no net at the CLKIN1 pins of the MMCMs"
  }
  set_property CLOCK_DEDICATED_ROUTE FALSE $clkin
  puts "INFO: pre_place: input clock from $clk_slr to the MMCMs in $pad_slr, CLOCK_DEDICATED_ROUTE FALSE on [get_property NAME $clkin]"
}
