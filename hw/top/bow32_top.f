// Bow32 SoC RTL, technology independent.
//
// Add exactly one primitive implementation file list after this one:
//   ../vendor/lowrisc_ibex_prim_generic.f   simulation / lint
//   ../fpga/common/prim_xilinx.f            Xilinx FPGAs
//
// All paths are relative to the file that contains them (verilator -F).

-F ../vendor/lowrisc_ibex.f
-F ../ip/common/common.f
-F ../ip/bus/bus.f
-F ../ip/mem/mem.f
-F ../ip/flash/flash.f
-F ../ip/uart/uart.f
-F ../ip/sysctrl/sysctrl.f
-F ../ip/cpu/cpu.f

rtl/bow32_memmap_pkg.sv
rtl/bow32_top.sv
