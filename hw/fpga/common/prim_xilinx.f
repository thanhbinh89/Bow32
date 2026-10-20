// Technology dependent primitives for Xilinx FPGAs (used instead of
// hw/vendor/lowrisc_ibex_prim_generic.f).
//
// With SecureIbex = 0 the buffer/flop primitives have no security role, so
// the plain generic models are used (lowRISC's prim_xilinx versions add
// DONT_TOUCH, which only blocks optimisation here). Only the clock gate needs
// an FPGA specific implementation.

../../vendor/lowrisc_ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_buf.sv
../../vendor/lowrisc_ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_flop.sv
../../vendor/lowrisc_ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_clock_mux2.sv
../../vendor/lowrisc_ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_ram_1p.sv
rtl/prim_clock_gating.sv
