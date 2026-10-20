// Bow32 file list for the vendored lowRISC Ibex core (git submodule).
//
// Paths are relative to this file (use `verilator -F`, or the Tcl filelist
// reader in hw/fpga/common/tcl). Technology-specific primitives (prim_buf,
// prim_flop, prim_clock_gating, ...) are NOT listed here; add exactly one of:
//   - lowrisc_ibex_prim_generic.f      (simulation / lint)
//   - ../fpga/common/prim_xilinx.f     (Xilinx FPGA synthesis)
//
// When upgrading Ibex, regenerate the list with:
//   fusesoc --cores-root lowrisc_ibex run --target=default --setup \
//           --tool=verilator lowrisc:ibex:ibex_top
// and compare with the generated .vc file (see docs/ip_upgrade.md).

+incdir+lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl
+incdir+lowrisc_ibex/vendor/lowrisc_ip/dv/sv/dv_utils

// ---- Packages -------------------------------------------------------------
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_util_pkg.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_mubi_pkg.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_pkg.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_cipher_pkg.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_count_pkg.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_ram_1p_pkg.sv
lowrisc_ibex/rtl/ibex_pkg.sv
lowrisc_ibex/rtl/ibex_cheriot_pkg.sv

// ---- Technology independent primitives ------------------------------------
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_22_16_dec.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_22_16_enc.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_28_22_dec.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_28_22_enc.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_39_32_dec.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_39_32_enc.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_64_57_dec.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_64_57_enc.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_hamming_22_16_dec.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_hamming_22_16_enc.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_hamming_39_32_dec.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_hamming_39_32_enc.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_lfsr.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_subst_perm.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_prince.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_count.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_fifo_sync_cnt.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_fifo_sync.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_ram_1p_adv.sv
lowrisc_ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_ram_1p_scr.sv
lowrisc_ibex/vendor/pulp_common_cells/rtl/stream_fork.sv
lowrisc_ibex/vendor/pulp_common_cells/rtl/stream_join_dynamic.sv

// ---- Ibex core --------------------------------------------------------------
lowrisc_ibex/rtl/ibex_alu.sv
lowrisc_ibex/rtl/ibex_branch_predict.sv
lowrisc_ibex/rtl/ibex_cheriot_ex.sv
lowrisc_ibex/rtl/ibex_compressed_decoder.sv
lowrisc_ibex/rtl/ibex_controller.sv
lowrisc_ibex/rtl/ibex_counter.sv
lowrisc_ibex/rtl/ibex_csr.sv
lowrisc_ibex/rtl/ibex_cs_registers.sv
lowrisc_ibex/rtl/ibex_decoder.sv
lowrisc_ibex/rtl/ibex_dummy_instr.sv
lowrisc_ibex/rtl/ibex_ex_block.sv
lowrisc_ibex/rtl/ibex_fetch_fifo.sv
lowrisc_ibex/rtl/ibex_icache.sv
lowrisc_ibex/rtl/ibex_id_stage.sv
lowrisc_ibex/rtl/ibex_if_stage.sv
lowrisc_ibex/rtl/ibex_load_store_unit.sv
lowrisc_ibex/rtl/ibex_multdiv_fast.sv
lowrisc_ibex/rtl/ibex_multdiv_slow.sv
lowrisc_ibex/rtl/ibex_pmp.sv
lowrisc_ibex/rtl/ibex_prefetch_buffer.sv
lowrisc_ibex/rtl/ibex_wb_stage.sv
lowrisc_ibex/rtl/ibex_core.sv
lowrisc_ibex/rtl/ibex_register_file_ff.sv
lowrisc_ibex/rtl/ibex_register_file_fpga.sv
lowrisc_ibex/rtl/ibex_register_file_latch.sv
lowrisc_ibex/rtl/ibex_trvk.sv
lowrisc_ibex/rtl/ibex_lockstep.sv
lowrisc_ibex/rtl/ibex_top.sv
