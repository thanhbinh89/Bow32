# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Test of the reviewed CDC list of the camera build (bow32_huins_cam_cdc_known in
# tcl/timing_checks_cam.tcl) in plain Tcl (no Vivado, no board data):
#
#   tclsh timing_checks_cam_test.tcl     (make -C hw/fpga/huins_vp1902 test-cdc)
#
#   * the CSI-2 receiver's rows (CDC-11 lane enables, CDC-13 byte clock gate) are accepted
#     with the D-PHY cells right below u_csi2rx (before the D-PHY was split out) and one
#     level down (u_csi2rx/u_dphy_rx/..., docs/ip/mipi_rx_arch.md section 10, step 1),
#     with the receiver in u_soc, below a further wrapper and at the top level;
#   * rows that are not accepted: other registers, other pins, the second synchroniser
#     stage, the data lane state machines, another clock buffer, other CDC ids, cells of
#     the same names outside u_csi2rx (another block, a D-PHY outside the receiver),
#     instance names that only end in u_csi2rx, the lane enable flop of one receiver
#     instance and the synchroniser of another;
#   * the SoC's own reviewed rows (ISP / H.264 configuration, reset synchronisers) still
#     match.
# Prints "timing_checks_cam_test: PASS (<n> checks)" or the failures, exit code 1 on a
# failure.

source [file join [file dirname [file normalize [info script]]] timing_checks_cam.tcl]

set n_checks 0
set n_fails  0
# expect: 1 = a reviewed row (non-empty reason), 0 = not reviewed
proc check {expect id from to} {
  incr ::n_checks
  set why [bow32_huins_cam_cdc_known $id $from $to]
  if {($why ne "") != $expect} {
    incr ::n_fails
    puts "FAIL [expr {$expect ? "not accepted" : "accepted"}]: $id from $from to $to ($why)"
  }
}

set gate u_dphy/u_byte_bufg/CE
# top: the path above the receiver (u_soc as today, a further wrapper, the top level);
# dphy: where the D-PHY cells are below u_csi2rx, before and after the split
foreach top {u_soc/ u_soc/u_cam/ {}} {
  foreach dphy {{} u_dphy_rx/} {
    set rx   "${top}u_csi2rx/$dphy"
    set regs "${top}u_csi2rx/u_regs"
    # CDC-11: one lane_en_q flop of the register file feeds two lane enable synchronisers
    foreach {q b} {0 29 1 30 4 31 4 32} {
      check 1 CDC-11 "$regs/lane_en_q_reg\[$q\]/C" \
                     "${rx}u_sync_vcfg/g_bit\[$b\].u_sync/sync_q_reg\[0\]/D"
    }
    check 0 CDC-11 "$regs/lane_en_q_reg\[1\]/C" \
                   "${rx}u_sync_vcfg/g_bit\[30\].u_sync/sync_q_reg\[1\]/D"
    check 0 CDC-11 "$regs/lane_en_q_reg\[1\]/C" \
                   "${rx}u_sync_vcfg/g_bit\[30\].u_sync/sync_q_reg\[0\]/CE"
    check 0 CDC-11 "$regs/dly_q_reg\[3\]/C" \
                   "${rx}u_sync_vcfg/g_bit\[30\].u_sync/sync_q_reg\[0\]/D"
    check 0 CDC-11 "$regs/lane_en_q_reg\[1\]/C" \
                   "${rx}u_sync_tap/g_bit\[30\].u_sync/sync_q_reg\[0\]/D"
    check 0 CDC-11 "${top}u_isp/u_regs/lane_en_q_reg\[1\]/C" \
                   "${rx}u_sync_vcfg/g_bit\[30\].u_sync/sync_q_reg\[0\]/D"
    check 0 CDC-11 "$regs/lane_en_q_reg\[1\]/Q" \
                   "${rx}u_sync_vcfg/g_bit\[30\].u_sync/sync_q_reg\[0\]/D"
    check 0 CDC-11 "$regs/lane_en_q_reg\[1\]/C" \
                   "${rx}xu_sync_vcfg/g_bit\[30\].u_sync/sync_q_reg\[0\]/D"
    check 0 CDC-12 "$regs/lane_en_q_reg\[1\]/C" \
                   "${rx}u_sync_vcfg/g_bit\[30\].u_sync/sync_q_reg\[0\]/D"
    # CDC-13: the clock lane state machine's gate flop drives the BUFGCE CE
    check 1 CDC-13 "${rx}u_lp_clk/ce_q_reg/C" $gate
    check 0 CDC-13 "${rx}u_lp_clk/ce_q_reg/C" u_dphy/u_hs_bufg/CE
    check 0 CDC-13 "${rx}u_lp_clk/ce_q_reg/C" u_soc/u_dphy/u_byte_bufg/CE
    check 0 CDC-13 "${rx}u_lp_clk/hs_en_q_reg/C" $gate
    check 0 CDC-13 "${rx}g_lp\[0\].u_lp/ce_q_reg/C" $gate
    check 0 CDC-13 "${rx}xu_lp_clk/ce_q_reg/C" $gate
    check 0 CDC-11 "${rx}u_lp_clk/ce_q_reg/C" $gate
    check 0 CDC-12 "${rx}u_lp_clk/ce_q_reg/C" $gate
  }
}
# the same cell names outside the receiver: another block, a D-PHY next to the receiver
check 0 CDC-13 {u_soc/u_h264/u_lp_clk/ce_q_reg/C} $gate
check 0 CDC-13 {u_soc/u_dphy_rx/u_lp_clk/ce_q_reg/C} $gate
check 0 CDC-11 {u_soc/u_csi2rx/u_regs/lane_en_q_reg[1]/C} \
               {u_soc/u_isp/u_sync_vcfg/g_bit[3].u_sync/sync_q_reg[0]/D}
check 0 CDC-11 {u_soc/u_csi2rx/u_regs/lane_en_q_reg[1]/C} \
               {u_soc/u_dphy_rx/u_sync_vcfg/g_bit[30].u_sync/sync_q_reg[0]/D}
# instance names that only end in u_csi2rx
check 0 CDC-13 {u_soc/xu_csi2rx/u_lp_clk/ce_q_reg/C} $gate
check 0 CDC-11 {u_soc/xu_csi2rx/u_regs/lane_en_q_reg[1]/C} \
               {u_soc/xu_csi2rx/u_sync_vcfg/g_bit[30].u_sync/sync_q_reg[0]/D}
# the lane enable flop of one receiver instance, the synchroniser of another
check 0 CDC-11 {x/u_csi2rx/u_regs/lane_en_q_reg[1]/C} \
               {u_soc/u_csi2rx/u_dphy_rx/u_sync_vcfg/g_bit[30].u_sync/sync_q_reg[0]/D}
check 0 CDC-11 {u_soc/u_csi2rx/u_regs/lane_en_q_reg[1]/C} \
               {u_csi2rx/u_sync_vcfg/g_bit[30].u_sync/sync_q_reg[0]/D}
check 0 CDC-11 {u_soc/u_csi2rx/u_regs/lane_en_q_reg[1]/C} \
               {u_soc/u_cam/u_csi2rx/u_dphy_rx/u_sync_vcfg/g_bit[30].u_sync/sync_q_reg[0]/D}
# the rest of the list is unchanged
check 1 CDC-1  {u_soc/u_isp/u_regs/gain_q_reg[3]/C} {u_soc/u_isp/u_awb/acc_q_reg[7]/D}
check 1 CDC-4  {u_soc/u_h264/u_regs/qp_q_reg[2]/C} {u_soc/u_h264/u_mb/x_q_reg[1]/D}
check 1 CDC-14 {u_soc/u_isp/u_regs/scale_q_reg[1]/C} {u_soc/u_isp/u_cap/addr_q_reg[3]/D}
check 1 CDC-10 {u_soc/u_h264/u_busy_q_reg/C} {u_soc/u_h264/u_sync_busy/sync_q_reg[0]/D}
check 1 CDC-10 {u_soc/u_csi2rx/u_regs/rx_on_q_reg/C} {u_soc/u_csi2rx/u_drst/sync_q_reg[0]/CLR}
check 0 CDC-1  {u_soc/u_csi2rx/u_regs/vc_q_reg[0]/C} {u_soc/u_csi2rx/u_packet/vc_q_reg[0]/D}
check 0 CDC-7  {u_soc/u_csi2rx/u_regs/lane_en_q_reg[1]/C} \
               {u_soc/u_csi2rx/u_sync_vcfg/g_bit[30].u_sync/sync_q_reg[0]/D}

if {$n_fails == 0} {
  puts "timing_checks_cam_test: PASS ($n_checks checks)"
} else {
  puts "timing_checks_cam_test: FAIL ($n_fails of $n_checks checks)"
  exit 1
}
