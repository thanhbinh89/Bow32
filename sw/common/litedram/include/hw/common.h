/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Stand-in for LiteX's <hw/common.h>: the CSR accessors and cdelay() that
 * the generated LiteDRAM headers (csr.h, sdram_phy.h of
 * hw/ip/ddr/litedram/generated/<core>/include/generated) call. Only on the
 * include path of the LiteDRAM glue files of sw/apps/ddr.
 *
 * The CSRs are 32 bit words (CONFIG_CSR_DATA_WIDTH 32) at CSR_BASE =
 * BOW32_DDR_CTRL_BASE, the ddr_ctrl slot of bow_ddr; every glue file
 * defines CSR_BASE before it includes a generated header. The accesses go
 * through bow_ld_csr_read / bow_ld_csr_write (bow_litedram.c): bus-error
 * safe (a failed access counts in bow_ld_csr_faults instead of trapping)
 * and traced while bow_ld_init runs the init sequence.
 *
 * cdelay(i) (LiteX: i iterations of a CPU loop) waits i x 25 ns here.
 */
#ifndef BOW_LD_HW_COMMON_H_
#define BOW_LD_HW_COMMON_H_

#include <stdint.h>

#ifndef CSR_BASE
#error "define CSR_BASE (BOW32_DDR_CTRL_BASE) before including a LiteDRAM header"
#endif

#define CSR_ACCESSORS_DEFINED

uint32_t bow_ld_csr_read(uint32_t addr);
void bow_ld_csr_write(uint32_t addr, uint32_t value);

static inline void csr_write_simple(unsigned long v, unsigned long a) {
  bow_ld_csr_write((uint32_t)a, (uint32_t)v);
}

static inline unsigned long csr_read_simple(unsigned long a) {
  return bow_ld_csr_read((uint32_t)a);
}

void cdelay(int i);

#endif /* BOW_LD_HW_COMMON_H_ */
