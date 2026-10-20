/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * System controller (docs/ip/sysctrl.md).
 */
#ifndef BOW_SYSCTRL_H_
#define BOW_SYSCTRL_H_

#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t CHIP_ID;   /* 0x00 R   */
  volatile uint32_t CLK_FREQ;  /* 0x04 R   */
  volatile uint32_t RST_CAUSE; /* 0x08 R/W1C */
  volatile uint32_t RST_CTRL;  /* 0x0C W   */
  volatile uint32_t BOOT_FLAG; /* 0x10 RW, survives system reset */
  volatile uint32_t BOOT_WAIT; /* 0x14 R   */
  volatile uint32_t BOOT_BAUD; /* 0x18 R   */
  volatile uint32_t BRK_CTRL;  /* 0x1C RW  */
} bow_sysctrl_regs_t;

#define SYSCTRL ((bow_sysctrl_regs_t *)BOW32_SYSCTRL_BASE)

#define SYSCTRL_RST_CAUSE_POR   (1u << 0)
#define SYSCTRL_RST_CAUSE_SW    (1u << 1)
#define SYSCTRL_RST_CAUSE_BREAK (1u << 2)

#define SYSCTRL_RST_KEY 0x52535421u /* "RST!" */

#define SYSCTRL_BRK_CTRL_EN (1u << 0)

/* BOOT_FLAG values understood by the boot ROM */
#define BOOT_FLAG_NONE   0x00000000u
#define BOOT_FLAG_LOADER 0x4C4F4144u /* "LOAD": stay in the UART loader */
#define BOOT_FLAG_APP    0x41505021u /* "APP!": boot the flash image now */

/* Request a system reset; does not return. */
static inline void __attribute__((noreturn)) bow_system_reset(uint32_t boot_flag) {
  SYSCTRL->BOOT_FLAG = boot_flag;
  SYSCTRL->RST_CTRL = SYSCTRL_RST_KEY;
  for (;;) {
  }
}

#endif /* BOW_SYSCTRL_H_ */
