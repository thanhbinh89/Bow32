// Bow32 for the Huins MFP-VP1902 (Versal Premium xcvp1902): SoC + Xilinx
// primitives + Versal DDR and HyperRAM clocks + pads + board top.

-F ../../top/bow32_top.f
-F ../common/prim_xilinx.f
../common/rtl/bow_ddr_clk_versal.sv
../common/rtl/bow_ddr_io_xilinx.sv
../common/rtl/bow_hyperram_clk_versal.sv
../common/rtl/bow_hyperram_io_xilinx.sv
rtl/bow32_huins_vp1902_top.sv
