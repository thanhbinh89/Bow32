/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Note: while an erase runs the flash stalls the bus, so this code may run
 * from flash; it then simply waits until the operation has finished.
 */
#include "bow_flash.h"

#include <stdbool.h>

static bool in_flash(uint32_t addr, uint32_t len) {
  return addr >= BOW32_FLASH_BASE && len <= BOW32_FLASH_SIZE &&
         addr - BOW32_FLASH_BASE <= BOW32_FLASH_SIZE - len;
}

static bow_flash_status_t wait_done(void) {
  uint32_t st;
  while ((st = FLASH_CTRL->STATUS) & FLASH_STATUS_BUSY) {
  }
  FLASH_CTRL->STATUS = st & (FLASH_STATUS_EOP | FLASH_STATUS_ERRORS);
  return (st & FLASH_STATUS_ERRORS) ? BOW_FLASH_ERR_PROG : BOW_FLASH_OK;
}

void bow_flash_unlock(void) { FLASH_CTRL->KEY = FLASH_UNLOCK_KEY; }

void bow_flash_lock(void) { FLASH_CTRL->CTRL = FLASH_CTRL_LOCK; }

bow_flash_status_t bow_flash_erase(uint32_t addr, uint32_t len) {
  if (len == 0 || !in_flash(addr, len)) return BOW_FLASH_ERR_RANGE;
  uint32_t page = FLASH_CTRL->PAGE_SIZE;
  uint32_t first = addr & ~(page - 1);
  uint32_t last = (addr + len - 1) & ~(page - 1);
  for (uint32_t a = first; a <= last; a += page) {
    FLASH_CTRL->ADDR = a;
    FLASH_CTRL->CTRL = FLASH_CTRL_PER | FLASH_CTRL_STRT;
    bow_flash_status_t st = wait_done();
    FLASH_CTRL->CTRL = 0;
    if (st != BOW_FLASH_OK) return st;
  }
  return BOW_FLASH_OK;
}

bow_flash_status_t bow_flash_mass_erase(void) {
  FLASH_CTRL->CTRL = FLASH_CTRL_MER | FLASH_CTRL_STRT;
  bow_flash_status_t st = wait_done();
  FLASH_CTRL->CTRL = 0;
  return st;
}

bow_flash_status_t bow_flash_program(uint32_t addr, const void *data, uint32_t len) {
  if ((addr & 3u) || (len & 3u) || !in_flash(addr, len)) return BOW_FLASH_ERR_RANGE;
  const uint8_t *src = data;
  volatile uint32_t *dst = (volatile uint32_t *)(uintptr_t)addr;
  bow_flash_status_t st = BOW_FLASH_OK;

  FLASH_CTRL->CTRL = FLASH_CTRL_PG;
  for (uint32_t i = 0; i < len / 4; i++, src += 4) {
    /* Source may be unaligned (e.g. inside a UART frame buffer). */
    uint32_t w = (uint32_t)src[0] | ((uint32_t)src[1] << 8) | ((uint32_t)src[2] << 16) |
                 ((uint32_t)src[3] << 24);
    dst[i] = w;
    if ((st = wait_done()) != BOW_FLASH_OK) break;
    if (dst[i] != w) {
      st = BOW_FLASH_ERR_VERIFY;
      break;
    }
  }
  FLASH_CTRL->CTRL = 0;
  return st;
}
