// Bow32 DDR2/DDR3 IP (needs common.f and bus.f): the LiteDRAM controller
// cores (generated Verilog, hw/ip/ddr/litedram; bow_ddr instantiates the one
// selected by DdrMem), the DFI adapter, the Bow32 PHY and the bus bridges.
// bow_ddr_dev and bow_ddr_lb are the synthesizable DRAM emulator used by the
// loopback FPGA build and the simulations; a SoC without them still
// elaborates, since only the board top instantiates bow_ddr_lb.
litedram/generated/ddr2/litedram_ddr2_pkg.sv
litedram/generated/ddr3/litedram_ddr3_pkg.sv
litedram/generated/ddr2/litedram_ddr2.v
litedram/generated/ddr3/litedram_ddr3.v
rtl/bow_ddr_pkg.sv
rtl/bow_ddr_dfi.sv
rtl/bow_ddr_win.sv
rtl/bow_ddr_csr.sv
rtl/bow_ddr_regs.sv
rtl/bow_ddr_phy.sv
rtl/bow_ddr_dev.sv
rtl/bow_ddr_lb.sv
rtl/bow_ddr.sv
rtl/bow_ddr_stub.sv
