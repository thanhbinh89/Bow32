/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * AMD MIPI CSI-2 RX Subsystem driver (see csi2rx.h).
 */
#include "csi2rx.h"

#include "bow32.h"

static inline uint32_t rd(uint32_t off) { return BOW_REG32(CSI2RX_BASE + off); }
static inline void wr(uint32_t off, uint32_t v) { BOW_REG32(CSI2RX_BASE + off) = v; }

bool csi2rx_probe(uint32_t *lanes) {
  uint32_t pcr;
  if (!bow_probe_read32(CSI2RX_BASE + CSI_PCR, &pcr)) return false;
  *lanes = (pcr & 3u) + 1u;
  return true;
}

bool csi2rx_start(bool enable) {
  /* Same sequence as the Linux driver: soft reset, wait until the core
   * reports that the reset is over, release it, enable. */
  wr(CSI_CCR, CSI_CCR_SOFTRESET);
  uint32_t t0 = bow_cycles(), limit = bow_clk_hz() / 100u; /* 10 ms */
  while (rd(CSI_CSR) & CSI_CSR_RIPCD) {
    if ((uint32_t)(bow_cycles() - t0) > limit) return false;
  }
  wr(CSI_CCR, 0);
  wr(CSI_ISR, 0xFFFFFFFFu);
  if (enable) wr(CSI_CCR, CSI_CCR_ENABLE);
  return true;
}

void csi2rx_print_status(void) {
  uint32_t isr = rd(CSI_ISR), csr = rd(CSI_CSR), inf1 = rd(CSI_VCXINF1R(0));
  bow_printf("csi2rx: ccr=%08x pcr=%08x csr=%08x (packets %u) isr=%08x\n", rd(CSI_CCR),
             rd(CSI_PCR), csr, csr >> 16, isr);
  bow_printf("        clk lane %08x  lane0 %08x  lane1 %08x\n", rd(CSI_CLKINFR), rd(CSI_DLXINFR(0)),
             rd(CSI_DLXINFR(1)));
  bow_printf("        vc0: %u lines, %u bytes/line, data type %02x\n", inf1 >> 16, inf1 & 0xFFFFu,
             rd(CSI_VCXINF2R(0)) & 0x3Fu);
  if (isr & CSI_ISR_FR) bow_printf("        frame received\n");
  if (isr & CSI_ISR_ERRORS) bow_printf("        errors: %04x (see PG232 ISR)\n", isr & CSI_ISR_ERRORS);
  wr(CSI_ISR, isr);
}
