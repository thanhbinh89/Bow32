// Bow32 HyperRAM IP (needs common.f and bus.f): HyperBus master (window with
// read / write buffers, registers, controller, BIST, PHY). bow_hyperram_dev is
// the synthesizable HyperRAM emulator of the loopback FPGA build and of the
// system simulation; only a board top or a testbench instantiates it.
rtl/bow_hyperram_pkg.sv
rtl/bow_hyperram_bist.sv
rtl/bow_hyperram_phy.sv
rtl/bow_hyperram_ctrl.sv
rtl/bow_hyperram_win.sv
rtl/bow_hyperram_regs.sv
rtl/bow_hyperram.sv
rtl/bow_hyperram_stub.sv
rtl/bow_hyperram_dev.sv
