/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Flash example: keeps a boot counter in the last flash page.
 *
 * The page is used as an append-only log of 32 bit records: each boot
 * programs the next erased word (0xFFFFFFFF) with the new count. Only when
 * the page is full it is erased - the usual way to store data in NOR flash
 * with few erase cycles. Press 'r' on UART0 to reset the SoC and see the
 * counter grow (the flash keeps its content across SoC resets).
 */
#include "bow32.h"

#define LOG_PAGE (BOW32_FLASH_BASE + BOW32_FLASH_SIZE - 1024u)
#define LOG_WORDS (1024u / 4u)

int main(void) {
  bow_uart_init(UART0, SYSCTRL->BOOT_BAUD);
  bow_printf("\nflash_demo: page %08x, page size %u bytes\n", LOG_PAGE, FLASH_CTRL->PAGE_SIZE);

  volatile const uint32_t *log = (volatile const uint32_t *)LOG_PAGE;
  uint32_t i = 0, last = 0;
  while (i < LOG_WORDS && log[i] != 0xFFFFFFFFu) last = log[i++];

  uint32_t count = last + 1;
  bow_flash_unlock();
  if (i == LOG_WORDS) {
    bow_printf("log page full -> erase\n");
    if (bow_flash_erase(LOG_PAGE, 1024) != BOW_FLASH_OK) bow_printf("erase failed\n");
    i = 0;
  }
  bow_flash_status_t st = bow_flash_program(LOG_PAGE + 4 * i, &count, sizeof(count));
  bow_flash_lock();

  bow_printf("boot count = %u (record %u, %s)\n", count, i, st == BOW_FLASH_OK ? "ok" : "ERROR");

  /* Programming can only clear bits: show what happens when we try to set one. */
  bow_flash_unlock();
  uint32_t ones = 0xFFFFFFFFu;
  st = bow_flash_program(LOG_PAGE + 4 * i, &ones, sizeof(ones));
  bow_flash_lock();
  bow_printf("re-programming 0xFFFFFFFF over it -> %s (expected: error, flash bits only go 1->0)\n",
             st == BOW_FLASH_OK ? "ok" : "error");

  bow_printf("press 'r' to reset\n");
  for (;;) {
    if (bow_uart_getc_nb(UART0) == 'r') {
      bow_uart_flush(UART0);
      bow_system_reset(BOOT_FLAG_APP);
    }
  }
}
