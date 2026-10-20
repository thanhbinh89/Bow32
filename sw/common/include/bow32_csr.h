/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * RISC-V machine mode CSR access helpers.
 */
#ifndef BOW32_CSR_H_
#define BOW32_CSR_H_

#include <stdint.h>

#define CSR_READ(csr)                                          \
  ({                                                           \
    uint32_t __v;                                              \
    __asm__ volatile("csrr %0, " #csr : "=r"(__v));            \
    __v;                                                       \
  })

#define CSR_WRITE(csr, val) __asm__ volatile("csrw " #csr ", %0" ::"rK"(val))
#define CSR_SET(csr, bits)  __asm__ volatile("csrs " #csr ", %0" ::"rK"(bits))
#define CSR_CLEAR(csr, bits) __asm__ volatile("csrc " #csr ", %0" ::"rK"(bits))

/* mstatus */
#define MSTATUS_MIE (1u << 3)

/* mie / mip: Ibex fast interrupts are bits 16..30 */
#define MIE_MSIE (1u << 3)
#define MIE_MTIE (1u << 7)
#define MIE_MEIE (1u << 11)
#define MIE_FAST(line) (1u << (16 + (line)))

/* mcause */
#define MCAUSE_IRQ_FLAG (1u << 31)
#define MCAUSE_CODE(c)  ((c) & 0x1Fu)

static inline void bow_irq_global_enable(void) { CSR_SET(mstatus, MSTATUS_MIE); }
static inline void bow_irq_global_disable(void) { CSR_CLEAR(mstatus, MSTATUS_MIE); }
static inline void bow_irq_fast_enable(unsigned line) { CSR_SET(mie, MIE_FAST(line)); }
static inline void bow_irq_fast_disable(unsigned line) { CSR_CLEAR(mie, MIE_FAST(line)); }

static inline void bow_wfi(void) { __asm__ volatile("wfi"); }

#endif /* BOW32_CSR_H_ */
