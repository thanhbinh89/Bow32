/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The LiteDRAM DDR3 core of bow_ddr (hw/ip/ddr/litedram/generated/ddr3: a
 * MT41K64M16, x16, DLL-off CL 6 CWL 6, BL8, 128 MiB; simulation only): its
 * JEDEC init sequence (init_sequence() of the generated sdram_phy.h: RESET#
 * release, CKE high, MR2, MR3, MR1 (DLL off), MR0, ZQCL) and its
 * parameters for bow_litedram.c. Compiled with the DDR3 core's include
 * directory (sw/apps/ddr/Makefile). bow_litedram.c uses the DDR2 core's
 * csr.h: bow_litedram_csrmap.h checks that this core has the same map.
 */
#include "bow32_memmap.h"

#define CSR_BASE BOW32_DDR_CTRL_BASE
#include <generated/sdram_phy.h>
#include <generated/soc.h>

#include "bow_litedram.h"
#include "bow_litedram_csrmap.h"

#if !defined(SDRAM_PHY_DDR3) || !defined(SDRAM_PHY_BOWDDRPHY)
#error "bow_litedram_ddr3.c needs the headers of hw/ip/ddr/litedram/generated/ddr3"
#endif

static void ddr3_init_sequence(void) { init_sequence(); }

const bow_ld_core_t bow_ld_core_ddr3 = {
    .name = "DDR3",
    .ddr3 = true,
    .databits = SDRAM_PHY_DATABITS,
    .phases = SDRAM_PHY_PHASES,
    .cl = SDRAM_PHY_CL,
    .cwl = SDRAM_PHY_CWL,
    .rdphase = SDRAM_PHY_RDPHASE,
    .wrphase = SDRAM_PHY_WRPHASE,
    .mem_bytes = (uint32_t)SDRAM_PHY_SUPPORTED_MEMORY,
    .ctrl_hz = CONFIG_CLOCK_FREQUENCY,
    /* TRefi of generated/ddr3/litedram_ddr3_pkg.sv: 7.8 us rounded down to
     * whole 32 ns cycles = 7.78 us (tools/tests/test_bow32_ddr.py compares) */
    .trefi_cycles = 243,
    .init_sequence = ddr3_init_sequence,
};
