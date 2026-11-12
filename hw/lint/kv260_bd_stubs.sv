// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Port-only stubs of the block design wrappers that Vivado generates for the KV260 builds
// (hw/fpga/kv260/tcl/ps_bd.tcl: bow32_ps_wrapper; hw/fpga/kv260_cam/tcl/cam_bd.tcl:
// bow32_cam_wrapper), for the Verilator lint of the KV260 tops in `make lint`. Lint only:
// the outputs are left undriven. The ports are the ones of the block design ports the
// Tcl scripts create.

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */

// Zynq UltraScale+ PS: PL clock 0 (100 MHz) and its reset
module bow32_ps_wrapper (
  output wire pl_clk0,
  output wire pl_resetn0
);
endmodule

// PS + clk_wiz + two proc_sys_reset: SoC clock / reset, video clock / reset
module bow32_cam_wrapper (
  output wire sys_clk,
  output wire sys_resetn,
  output wire vid_clk,
  output wire vid_resetn
);
endmodule

/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
