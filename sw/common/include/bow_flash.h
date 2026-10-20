/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Internal flash driver (docs/ip/flash.md).
 */
#ifndef BOW_FLASH_H_
#define BOW_FLASH_H_

#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t KEY;       /* 0x00 W  */
  volatile uint32_t CTRL;      /* 0x04 RW */
  volatile uint32_t ADDR;      /* 0x08 RW */
  volatile uint32_t STATUS;    /* 0x0C R/W1C */
  volatile uint32_t SIZE;      /* 0x10 R  */
  volatile uint32_t PAGE_SIZE; /* 0x14 R  */
} bow_flash_regs_t;

#define FLASH_CTRL ((bow_flash_regs_t *)BOW32_FLASH_CTRL_BASE)

#define FLASH_UNLOCK_KEY 0xB032F1A5u

#define FLASH_CTRL_PG    (1u << 0)
#define FLASH_CTRL_PER   (1u << 1)
#define FLASH_CTRL_MER   (1u << 2)
#define FLASH_CTRL_EOPIE (1u << 4)
#define FLASH_CTRL_STRT  (1u << 8)
#define FLASH_CTRL_LOCK  (1u << 31)

#define FLASH_STATUS_BUSY   (1u << 0)
#define FLASH_STATUS_EOP    (1u << 1)
#define FLASH_STATUS_WRPERR (1u << 2)
#define FLASH_STATUS_PGERR  (1u << 3)
#define FLASH_STATUS_ERRORS (FLASH_STATUS_WRPERR | FLASH_STATUS_PGERR)

typedef enum {
  BOW_FLASH_OK = 0,
  BOW_FLASH_ERR_RANGE = -1,   /* address outside flash or misaligned */
  BOW_FLASH_ERR_PROG = -2,    /* WRPERR/PGERR reported by the controller */
  BOW_FLASH_ERR_VERIFY = -3,  /* read back mismatch */
} bow_flash_status_t;

void bow_flash_unlock(void);
void bow_flash_lock(void);
/* Erase every page touched by [addr, addr + len). Flash must be unlocked. */
bow_flash_status_t bow_flash_erase(uint32_t addr, uint32_t len);
bow_flash_status_t bow_flash_mass_erase(void);
/* Program len bytes (multiple of 4) at addr (word aligned). Must be unlocked. */
bow_flash_status_t bow_flash_program(uint32_t addr, const void *data, uint32_t len);

#endif /* BOW_FLASH_H_ */
