// Bow32 + camera for the Huins MFP-VP1902 (Versal Premium xcvp1902, CARD=cam): SoC +
// Xilinx primitives + Versal D-PHY receive I/O + camera clocks + board top.

-F ../../top/bow32_top.f
-F ../common/prim_xilinx.f
../common/rtl/bow_dphy_io_versal.sv
rtl/bow32_huins_vp1902_cam_clk.sv
rtl/bow32_huins_vp1902_cam_top.sv
