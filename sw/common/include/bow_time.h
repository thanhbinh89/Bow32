/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Time keeping based on the mcycle CSR (no timer peripheral needed).
 */
#ifndef BOW_TIME_H_
#define BOW_TIME_H_

#include <stdint.h>

#include "bow32_csr.h"
#include "bow_sysctrl.h"

static inline uint32_t bow_cycles(void) { return CSR_READ(mcycle); }

static inline uint32_t bow_clk_hz(void) { return SYSCTRL->CLK_FREQ; }

/* Busy wait. Accurate to a few cycles; max ~85 s at 50 MHz. */
static inline void bow_delay_cycles(uint32_t cycles) {
  uint32_t start = bow_cycles();
  while ((uint32_t)(bow_cycles() - start) < cycles) {
  }
}

static inline void bow_delay_us(uint32_t us) { bow_delay_cycles(us * (bow_clk_hz() / 1000000u)); }

static inline void bow_delay_ms(uint32_t ms) { bow_delay_cycles(ms * (bow_clk_hz() / 1000u)); }

#endif /* BOW_TIME_H_ */
