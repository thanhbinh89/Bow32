/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * UART loader: receives framed commands on UART0 and programs the flash.
 * Protocol: sw/common/include/bow32_boot_proto.h, docs/boot.md.
 */
#include "loader.h"

#include "bow32.h"
#include "bow32_boot_proto.h"

#define BYTE_TIMEOUT_MS 200u

static uint8_t frame[BOOT_MAX_PAYLOAD + 8];
static uint32_t byte_timeout;

/* ---------------------------------------------------------------- helpers */

static uint32_t get32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void put32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)v;
  p[1] = (uint8_t)(v >> 8);
  p[2] = (uint8_t)(v >> 16);
  p[3] = (uint8_t)(v >> 24);
}

/* Returns the next byte, or -1 after `timeout` cycles (0 = wait forever). */
static int rx_byte(uint32_t timeout) {
  uint32_t start = bow_cycles();
  for (;;) {
    int c = bow_uart_getc_nb(UART0);
    if (c >= 0) return c;
    if (timeout && (uint32_t)(bow_cycles() - start) >= timeout) return -1;
  }
}

static bool in_region(uint32_t addr, uint32_t len, uint32_t base, uint32_t size) {
  return addr >= base && len <= size && addr - base <= size - len;
}

/* Memory that READ and CRC may access: ROM, flash and SRAM. */
static bool readable(uint32_t addr, uint32_t len) {
  return in_region(addr, len, BOW32_ROM_BASE, BOW32_ROM_SIZE) ||
         in_region(addr, len, BOW32_FLASH_BASE, BOW32_FLASH_SIZE) ||
         in_region(addr, len, BOW32_SRAM_BASE, BOW32_SRAM_SIZE);
}

static void send_response(uint8_t status, const uint8_t *payload, uint32_t len) {
  uint8_t hdr[3] = {status, (uint8_t)len, (uint8_t)(len >> 8)};
  uint8_t crc_bytes[4];
  uint32_t crc = bow_crc32_update(0, hdr, sizeof(hdr));
  crc = bow_crc32_update(crc, payload, len);
  put32(crc_bytes, crc);

  bow_uart_putc(UART0, (char)BOOT_SOF_RSP);
  bow_uart_write(UART0, hdr, sizeof(hdr));
  bow_uart_write(UART0, payload, len);
  bow_uart_write(UART0, crc_bytes, sizeof(crc_bytes));
}

/*
 * Receive one request into `frame` (CMD, LEN[2], PAYLOAD). Returns the
 * payload length, or -1 if the frame was dropped (timeout, length or CRC
 * error; an error response has already been sent where it makes sense).
 */
static int recv_request(bool sof_seen) {
  if (!sof_seen) {
    while (rx_byte(0) != BOOT_SOF_REQ) {
    }
  }
  for (int i = 0; i < 3; i++) {
    int c = rx_byte(byte_timeout);
    if (c < 0) return -1;
    frame[i] = (uint8_t)c;
  }
  uint32_t len = (uint32_t)frame[1] | ((uint32_t)frame[2] << 8);
  if (len > BOOT_MAX_PAYLOAD) {
    send_response(BOOT_ERR_LEN, 0, 0);
    return -1;
  }
  for (uint32_t i = 0; i < len + 4; i++) {
    int c = rx_byte(byte_timeout);
    if (c < 0) return -1;
    frame[3 + i] = (uint8_t)c;
  }
  if (bow_crc32(frame, 3 + len) != get32(&frame[3 + len])) {
    send_response(BOOT_ERR_CRC, 0, 0);
    return -1;
  }
  return (int)len;
}

/* --------------------------------------------------------------- commands */

static void cmd_info(void) {
  uint8_t out[32];
  put32(&out[0], SYSCTRL->CHIP_ID);
  put32(&out[4], BOW32_ROM_VERSION);
  put32(&out[8], BOW32_FLASH_BASE);
  put32(&out[12], FLASH_CTRL->SIZE);
  put32(&out[16], FLASH_CTRL->PAGE_SIZE);
  put32(&out[20], BOOT_MAX_DATA);
  put32(&out[24], BOW32_SRAM_BASE);
  put32(&out[28], BOW32_SRAM_SIZE);
  send_response(BOOT_OK, out, sizeof(out));
}

static void cmd_erase(const uint8_t *p, uint32_t len) {
  if (len != 8) {
    send_response(BOOT_ERR_LEN, 0, 0);
    return;
  }
  uint32_t addr = get32(p), size = get32(p + 4);
  bow_flash_status_t st;
  bow_flash_unlock();
  if (size == 0xFFFFFFFFu) {
    st = bow_flash_mass_erase();
  } else {
    st = bow_flash_erase(addr, size);
  }
  bow_flash_lock();
  send_response(st == BOW_FLASH_OK ? BOOT_OK
                : st == BOW_FLASH_ERR_RANGE ? BOOT_ERR_ARG : BOOT_ERR_FLASH, 0, 0);
}

static void cmd_write(const uint8_t *p, uint32_t len) {
  if (len < 4 || len - 4 > BOOT_MAX_DATA) {
    send_response(BOOT_ERR_LEN, 0, 0);
    return;
  }
  bow_flash_unlock();
  bow_flash_status_t st = bow_flash_program(get32(p), p + 4, len - 4);
  bow_flash_lock();
  send_response(st == BOW_FLASH_OK ? BOOT_OK
                : st == BOW_FLASH_ERR_RANGE ? BOOT_ERR_ARG : BOOT_ERR_FLASH, 0, 0);
}

static void cmd_read(const uint8_t *p, uint32_t len) {
  if (len != 8) {
    send_response(BOOT_ERR_LEN, 0, 0);
    return;
  }
  uint32_t addr = get32(p), size = get32(p + 4);
  if (size > BOOT_MAX_DATA || !readable(addr, size)) {
    send_response(BOOT_ERR_ARG, 0, 0);
    return;
  }
  send_response(BOOT_OK, (const uint8_t *)(uintptr_t)addr, size);
}

static void cmd_crc(const uint8_t *p, uint32_t len) {
  if (len != 8) {
    send_response(BOOT_ERR_LEN, 0, 0);
    return;
  }
  uint32_t addr = get32(p), size = get32(p + 4);
  if (!readable(addr, size)) {
    send_response(BOOT_ERR_ARG, 0, 0);
    return;
  }
  uint8_t out[4];
  put32(out, bow_crc32((const void *)(uintptr_t)addr, size));
  send_response(BOOT_OK, out, sizeof(out));
}

static void __attribute__((noreturn)) cmd_reset(uint32_t boot_flag) {
  send_response(BOOT_OK, 0, 0);
  bow_uart_flush(UART0);
  bow_system_reset(boot_flag);
}

/* ------------------------------------------------------------------- main */

void loader_run(bool sof_seen) {
  byte_timeout = BYTE_TIMEOUT_MS * (SYSCTRL->CLK_FREQ / 1000u);
  for (;;) {
    int len = recv_request(sof_seen);
    sof_seen = false;
    if (len < 0) continue;
    const uint8_t *payload = &frame[3];
    switch (frame[0]) {
      case BOOT_CMD_INFO:  cmd_info(); break;
      case BOOT_CMD_ERASE: cmd_erase(payload, (uint32_t)len); break;
      case BOOT_CMD_WRITE: cmd_write(payload, (uint32_t)len); break;
      case BOOT_CMD_READ:  cmd_read(payload, (uint32_t)len); break;
      case BOOT_CMD_CRC:   cmd_crc(payload, (uint32_t)len); break;
      case BOOT_CMD_BOOT:  cmd_reset(BOOT_FLAG_APP);
      case BOOT_CMD_RESET: cmd_reset(BOOT_FLAG_NONE);
      default:             send_response(BOOT_ERR_CMD, 0, 0); break;
    }
  }
}

bool loader_wait_for_host(uint32_t ms) {
  uint32_t timeout = ms * (SYSCTRL->CLK_FREQ / 1000u);
  uint32_t start = bow_cycles();
  while ((uint32_t)(bow_cycles() - start) < timeout) {
    if (bow_uart_getc_nb(UART0) == (int)BOOT_SOF_REQ) return true;
  }
  return false;
}
