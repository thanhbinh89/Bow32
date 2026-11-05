/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The LiteDRAM CSR map that bow_litedram.c relies on (generated csr.csv of
 * both cores, offsets from BOW32_DDR_CTRL_BASE). Included after a generated
 * csr.h by bow_litedram.c (DDR2 core headers) and bow_litedram_ddr3.c: the
 * build fails if a regenerated core moves a register (the first and last
 * register of each block and the DFII phase stride are checked).
 */
#ifndef BOW_LITEDRAM_CSRMAP_H_
#define BOW_LITEDRAM_CSRMAP_H_

#define BOW_LD_CSR_AT(name, off) \
  _Static_assert(CSR_##name##_ADDR == CSR_BASE + (off), "LiteDRAM CSR map: " #name)

BOW_LD_CSR_AT(DDRCTRL_INIT_DONE, 0x0000L);
BOW_LD_CSR_AT(DDRCTRL_INIT_ERROR, 0x0004L);
BOW_LD_CSR_AT(SDRAM_DFII_CONTROL, 0x0800L);
BOW_LD_CSR_AT(SDRAM_DFII_PI0_COMMAND, 0x0804L);
BOW_LD_CSR_AT(SDRAM_DFII_PI0_COMMAND_ISSUE, 0x0808L);
BOW_LD_CSR_AT(SDRAM_DFII_PI0_ADDRESS, 0x080CL);
BOW_LD_CSR_AT(SDRAM_DFII_PI0_BADDRESS, 0x0810L);
BOW_LD_CSR_AT(SDRAM_DFII_PI0_WRDATA, 0x0814L);
BOW_LD_CSR_AT(SDRAM_DFII_PI0_RDDATA, 0x0818L);
BOW_LD_CSR_AT(SDRAM_DFII_PI1_COMMAND, 0x081CL);
BOW_LD_CSR_AT(SDRAM_DFII_PI3_RDDATA, 0x0860L);
BOW_LD_CSR_AT(SDRAM_CHECKER_RESET, 0x1000L);
BOW_LD_CSR_AT(SDRAM_CHECKER_ERRORS, 0x1020L);
BOW_LD_CSR_AT(SDRAM_GENERATOR_RESET, 0x1800L);
BOW_LD_CSR_AT(SDRAM_GENERATOR_TICKS, 0x181CL);

#endif /* BOW_LITEDRAM_CSRMAP_H_ */
