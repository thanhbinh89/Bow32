/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MKV block cipher accelerator driver (docs/ip/mkv.md).
 */
#include "bow_mkv.h"

static uint32_t load_le32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void store_le32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)v;
  p[1] = (uint8_t)(v >> 8);
  p[2] = (uint8_t)(v >> 16);
  p[3] = (uint8_t)(v >> 24);
}

unsigned bow_mkv_rounds(unsigned block_bits, unsigned key_bits) {
  if (block_bits != 128 && block_bits != 256) return 0;
  if (key_bits == block_bits) return 6;
  if (2u * key_bits == 3u * block_bits) return 7;
  if (key_bits == 2u * block_bits) return 8;
  return 0;
}

bool bow_mkv_set_key(unsigned block_bits, unsigned key_bits, const uint8_t *key) {
  unsigned rounds = bow_mkv_rounds(block_bits, key_bits);
  if (rounds == 0) return false;
  MKV->CTRL = (block_bits == 256 ? MKV_CTRL_BLOCK256 : 0u) | MKV_CTRL_KLEN(rounds - 6u);
  for (unsigned i = 0; i < key_bits / 32u; i++) MKV->KEY[i] = load_le32(key + 4u * i);
  MKV->STATUS = MKV_ST_DONE | MKV_ST_ERR;
  MKV->CMD = MKV_CMD_KEY;
  uint32_t st;
  while ((st = MKV->STATUS) & MKV_ST_BUSY) {
  }
  return (st & (MKV_ST_KEY_VALID | MKV_ST_ERR | MKV_ST_FAULT)) == MKV_ST_KEY_VALID;
}

unsigned bow_mkv_block_bytes(void) {
  uint32_t st = MKV->STATUS;
  if (!(st & MKV_ST_KEY_VALID)) return 0;
  return (st & MKV_ST_WIDE) ? 32u : 16u;
}

/* Word aligned buffers are copied a word at a time (little endian core: the
 * byte order of the registers), others byte by byte. */
static void write_block(const uint8_t *in, unsigned words) {
  if (((uintptr_t)in & 3u) == 0) {
    const uint32_t *w = (const uint32_t *)__builtin_assume_aligned(in, 4);
    for (unsigned i = 0; i < words; i++) {
      uint32_t v;
      __builtin_memcpy(&v, w + i, 4);
      MKV->DIN[i] = v;
    }
  } else {
    for (unsigned i = 0; i < words; i++) MKV->DIN[i] = load_le32(in + 4u * i);
  }
}

static void read_block(uint8_t *out, unsigned words) {
  if (((uintptr_t)out & 3u) == 0) {
    uint32_t *w = (uint32_t *)__builtin_assume_aligned(out, 4);
    for (unsigned i = 0; i < words; i++) {
      uint32_t v = MKV->DOUT[i]; /* the first read waits for the result */
      __builtin_memcpy(w + i, &v, 4);
    }
  } else {
    for (unsigned i = 0; i < words; i++) store_le32(out + 4u * i, MKV->DOUT[i]);
  }
}

bool bow_mkv_ecb(bool decrypt, const uint8_t *in, uint8_t *out, size_t nblocks) {
  unsigned bytes = bow_mkv_block_bytes();
  uint32_t cmd = decrypt ? MKV_CMD_DEC : MKV_CMD_ENC;
  if (bytes == 0) return false;
  if (nblocks == 0) return true;
  write_block(in, bytes / 4u);
  for (size_t i = 0; i < nblocks; i++) {
    MKV->CMD = cmd;                                  /* copies DIN, starts */
    if (i + 1u < nblocks) write_block(in + (i + 1u) * bytes, bytes / 4u);
    read_block(out + i * bytes, bytes / 4u);
  }
  /* a fault zeroes the key schedule: every later block reads 0 as well */
  uint32_t st = MKV->STATUS;
  return (st & (MKV_ST_KEY_VALID | MKV_ST_FAULT)) == MKV_ST_KEY_VALID;
}

bool bow_mkv_encrypt(const uint8_t *in, uint8_t *out) { return bow_mkv_ecb(false, in, out, 1); }

bool bow_mkv_decrypt(const uint8_t *in, uint8_t *out) { return bow_mkv_ecb(true, in, out, 1); }

void bow_mkv_clear(void) {
  MKV->CMD = MKV_CMD_CLEAR;
  while (MKV->STATUS & MKV_ST_BUSY) {
  }
  MKV->STATUS = MKV_ST_DONE | MKV_ST_ERR | MKV_ST_FAULT;
}
