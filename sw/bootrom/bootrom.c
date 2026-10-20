/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bow32 boot ROM.
 *
 * Boot decision (docs/boot.md):
 *   1. reset caused by a UART0 BREAK          -> UART loader
 *   2. BOOT_FLAG == LOADER (set by firmware)  -> UART loader
 *   3. no valid image in flash                -> UART loader
 *   4. BOOT_FLAG == APP (set by loader BOOT)  -> start the image immediately
 *   5. otherwise wait BOOT_WAIT ms for a host request on UART0:
 *        request received -> UART loader, timeout -> start the image
 */
#include "bow32.h"
#include "bow32_image.h"
#include "loader.h"

static const char *check_image(const bow32_image_hdr_t *h) {
  if (h->magic != BOW32_IMAGE_MAGIC) return "no image";
  if (h->hdr_version != BOW32_IMAGE_HDR_VERSION) return "bad header version";
  if (h->size == 0 || h->size > BOW32_FLASH_SIZE - BOW32_IMAGE_HDR_SIZE) return "bad size";
  uint32_t payload = BOW32_FLASH_BASE + BOW32_IMAGE_HDR_SIZE;
  if (h->entry < payload || h->entry >= payload + h->size || (h->entry & 1u)) return "bad entry";
  if (bow_crc32((const void *)(uintptr_t)payload, h->size) != h->crc32) return "CRC mismatch";
  return 0;
}

void rom_main(void) {
  uint32_t cause = SYSCTRL->RST_CAUSE;
  uint32_t flag = SYSCTRL->BOOT_FLAG;
  SYSCTRL->RST_CAUSE = cause; /* W1C: start fresh for the next reset */
  SYSCTRL->BOOT_FLAG = BOOT_FLAG_NONE;

  bow_uart_init(UART0, SYSCTRL->BOOT_BAUD);
  bow_printf("\nBow32 boot ROM v%u.%u.%u  chip %08x  clk %u Hz  rst %x\n",
             BOW32_ROM_VERSION >> 16, (BOW32_ROM_VERSION >> 8) & 0xFFu, BOW32_ROM_VERSION & 0xFFu,
             SYSCTRL->CHIP_ID, SYSCTRL->CLK_FREQ, cause);

  const bow32_image_hdr_t *hdr = (const bow32_image_hdr_t *)BOW32_FLASH_BASE;
  const char *err = check_image(hdr);

  bool loader = true;
  bool sof_seen = false;
  if (cause & SYSCTRL_RST_CAUSE_BREAK) {
    bow_puts("boot: UART break\n");
  } else if (flag == BOOT_FLAG_LOADER) {
    bow_puts("boot: loader requested by firmware\n");
  } else if (err) {
    bow_printf("boot: flash image invalid (%s)\n", err);
  } else if (flag == BOOT_FLAG_APP) {
    loader = false;
  } else {
    uint32_t wait = SYSCTRL->BOOT_WAIT;
    bow_printf("boot: waiting %u ms for host\n", wait);
    sof_seen = loader_wait_for_host(wait);
    loader = sof_seen;
  }

  if (loader) {
    bow_puts("boot: UART loader ready\n");
    bow_uart_flush(UART0);
    loader_run(sof_seen);
  }

  bow_printf("boot: starting image @%08x (%u bytes)\n", hdr->entry, hdr->size);
  bow_uart_flush(UART0);
  ((void (*)(void))(uintptr_t)hdr->entry)();
}

void rom_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
  bow_printf("\nROM trap: mcause=%08x mepc=%08x mtval=%08x\n", mcause, mepc, mtval);
  for (;;) bow_wfi();
}
