/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * CRC-32 (IEEE 802.3, same as zlib.crc32 / binascii.crc32 in Python).
 */
#ifndef BOW_CRC32_H_
#define BOW_CRC32_H_

#include <stdint.h>

/* Incremental use: crc = bow_crc32_update(0, a, n); crc = bow_crc32_update(crc, b, m); */
uint32_t bow_crc32_update(uint32_t crc, const void *data, uint32_t len);

static inline uint32_t bow_crc32(const void *data, uint32_t len) {
  return bow_crc32_update(0, data, len);
}

#endif /* BOW_CRC32_H_ */
