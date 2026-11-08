/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The LiteDRAM DDR2 core of bow_ddr (hw/ip/ddr/litedram/generated/ddr2:
 * the FMC card's IS43DR86400E, x8, CL 3, BL8, 64 MiB): its JEDEC init
 * sequence (init_sequence() of the generated sdram_phy.h: CKE high, PREA,
 * EMR3, EMR2, EMR1, MR with DLL reset, PREA, 2 x REF, MR, EMR1 OCD default,
 * OCD exit) and its parameters for bow_litedram.c. Compiled with the DDR2
 * core's include directory (sw/apps/ddr/Makefile).
 */
#include "bow32_memmap.h"

#define CSR_BASE BOW32_DDR_CTRL_BASE
#include <generated/sdram_phy.h>
#include <generated/soc.h>

#include "bow_litedram.h"

#if !defined(SDRAM_PHY_DDR2) || !defined(SDRAM_PHY_BOWDDRPHY)
#error "bow_litedram_ddr2.c needs the headers of hw/ip/ddr/litedram/generated/ddr2"
#endif

static void ddr2_init_sequence(void) { init_sequence(); }

const bow_ld_core_t bow_ld_core_ddr2 = {
    .name = "DDR2",
    .ddr3 = false,
    .databits = SDRAM_PHY_DATABITS,
    .phases = SDRAM_PHY_PHASES,
    .cl = SDRAM_PHY_CL,
    .cwl = SDRAM_PHY_CWL,
    .rdphase = SDRAM_PHY_RDPHASE,
    .wrphase = SDRAM_PHY_WRPHASE,
    .mem_bytes = (uint32_t)SDRAM_PHY_SUPPORTED_MEMORY,
    .ctrl_hz = CONFIG_CLOCK_FREQUENCY,
    /* TRefi of generated/ddr2/litedram_ddr2_pkg.sv: trefi_ns 3900 rounded
     * down to whole 30 ns cycles = 3.87 us (CTRL.REF_NORM: 7.74 us), compared
     * by tools/tests/test_bow32_ddr.py */
    .trefi_cycles = 129,
    .init_sequence = ddr2_init_sequence,
};
