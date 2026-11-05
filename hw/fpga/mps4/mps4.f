// Bow32 for the Arm MPS4: SoC + Xilinx primitives + DDR clocks and pads +
// board top.

-F ../../top/bow32_top.f
-F ../common/prim_xilinx.f
../common/rtl/bow_ddr_clk_xusp.sv
../common/rtl/bow_ddr_io_xilinx.sv
rtl/bow32_mps4_top.sv
