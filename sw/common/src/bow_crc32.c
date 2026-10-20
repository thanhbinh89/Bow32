/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bitwise CRC-32 (reflected polynomial 0xEDB88320). Small rather than fast:
 * about 50 cycles per byte, i.e. ~1 ms per KiB at 50 MHz.
 */
#include "bow_crc32.h"

uint32_t bow_crc32_update(uint32_t crc, const void *data, uint32_t len) {
  const uint8_t *p = data;
  crc = ~crc;
  while (len--) {
    crc ^= *p++;
    for (int i = 0; i < 8; i++) crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1u));
  }
  return ~crc;
}
