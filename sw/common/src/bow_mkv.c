/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MKV block cipher accelerator driver (docs/ip/mkv.md).
 */
#include "bow_mkv.h"

#include "bow_mkv_kat.h"

static bow_mkv_err_t last_err;
static bool post_ok; /* bow_mkv_selftest() passed */

static bool fail(bow_mkv_err_t e) {
  last_err = e;
  return false;
}

bow_mkv_err_t bow_mkv_error(void) { return last_err; }

const char *bow_mkv_error_name(bow_mkv_err_t e) {
  switch (e) {
    case MKV_OK:         return "ok";
    case MKV_E_VERSION:  return "no such version";
    case MKV_E_SELFTEST: return "self-test not passed";
    case MKV_E_NO_KEY:   return "no key schedule";
    case MKV_E_REFUSED:  return "command refused";
    case MKV_E_FAULT:    return "fault detected";
    case MKV_E_LOCKED:   return "IP locked (power-on reset needed)";
    case MKV_E_ABSENT:   return "IP not present";
  }
  return "?";
}

/* Reason of a failed command, from STATUS */
static bool fail_status(uint32_t st) {
  if (st & MKV_ST_LOCKED) return fail(MKV_E_LOCKED);
  if (st & MKV_ST_FAULT) return fail(MKV_E_FAULT);
  if (st & MKV_ST_ERR) return fail(MKV_E_REFUSED);
  return fail(MKV_E_NO_KEY);
}

/* A locked IP with a permanent fault may never be idle again: bounded. */
static uint32_t wait_idle(void) {
  uint32_t st = MKV->STATUS;
  for (unsigned i = 0; (st & MKV_ST_BUSY) && i < 100000u; i++) st = MKV->STATUS;
  return st;
}

static bool nostall(void) { return (MKV->CTRL & MKV_CTRL_NOSTALL) != 0; }

/* Always inlined: as calls they make write_block / read_block save registers
 * on every block, ~25 cycles a block of ECB (measured on the board). */
static inline __attribute__((always_inline)) uint32_t load_le32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline __attribute__((always_inline)) void store_le32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)v;
  p[1] = (uint8_t)(v >> 8);
  p[2] = (uint8_t)(v >> 16);
  p[3] = (uint8_t)(v >> 24);
}

static bool equal(const uint8_t *a, const uint8_t *b, unsigned n) {
  uint8_t d = 0;
  for (unsigned i = 0; i < n; i++) d |= (uint8_t)(a[i] ^ b[i]);
  return d == 0;
}

void bow_mkv_wipe(void *p, size_t n) {
  volatile uint8_t *v = (volatile uint8_t *)p;
  while (n--) *v++ = 0;
}

unsigned bow_mkv_rounds(unsigned block_bits, unsigned key_bits) {
  if (block_bits != 128 && block_bits != 256) return 0;
  if (key_bits == block_bits) return 7;
  if (2u * key_bits == 3u * block_bits) return 8;
  if (key_bits == 2u * block_bits) return 9;
  return 0;
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
      uint32_t v = MKV->DOUT[i]; /* the first read waits for the result (no NOSTALL) */
      __builtin_memcpy(w + i, &v, 4);
    }
  } else {
    for (unsigned i = 0; i < words; i++) store_le32(out + 4u * i, MKV->DOUT[i]);
  }
}

/* Key schedule without the self-test gate (the self-test uses it). */
static bool load_key(unsigned block_bits, unsigned key_bits, const uint8_t *key) {
  unsigned rounds = bow_mkv_rounds(block_bits, key_bits);
  if (rounds == 0) return fail(MKV_E_VERSION);
  uint32_t st = wait_idle();
  if (st & MKV_ST_LOCKED) return fail(MKV_E_LOCKED);
  bool ns = nostall();
  /* keep NOSTALL / KEY_LOCK / the policy; a new version (or the first key
   * word) makes the IP wipe the old key schedule, the key words may be
   * written meanwhile */
  MKV->CTRL = (MKV->CTRL & ~MKV_CTRL_VERSION) | (block_bits == 256 ? MKV_CTRL_BLOCK256 : 0u) |
              MKV_CTRL_KLEN(rounds - 7u);
  MKV->STATUS = MKV_ST_DONE | MKV_ST_ERR;
  for (unsigned i = 0; i < key_bits / 32u; i++) MKV->KEY[i] = load_le32(key + 4u * i);
  if (ns) wait_idle();
  MKV->CMD = MKV_CMD_KEY;
  st = wait_idle();
  if ((st & (MKV_ST_KEY_VALID | MKV_ST_ERR | MKV_ST_FAULT)) == MKV_ST_KEY_VALID) return true;
  return fail_status(st);
}

bool bow_mkv_set_key(unsigned block_bits, unsigned key_bits, const uint8_t *key) {
  if (bow_mkv_rounds(block_bits, key_bits) == 0) return fail(MKV_E_VERSION);
  if (!post_ok) return fail(MKV_E_SELFTEST);
  return load_key(block_bits, key_bits, key);
}

unsigned bow_mkv_block_bytes(void) {
  uint32_t st = MKV->STATUS;
  if (!(st & MKV_ST_KEY_VALID)) return 0;
  return (st & MKV_ST_WIDE) ? 32u : 16u;
}

bool bow_mkv_ecb(bool decrypt, const uint8_t *in, uint8_t *out, size_t nblocks) {
  uint32_t st = MKV->STATUS;
  if (st & (MKV_ST_LOCKED | MKV_ST_FAULT) || !(st & MKV_ST_KEY_VALID)) return fail_status(st);
  unsigned bytes = (st & MKV_ST_WIDE) ? 32u : 16u;
  uint32_t cmd = decrypt ? MKV_CMD_DEC : MKV_CMD_ENC;
  bool ns = nostall();
  if (nblocks == 0) return true;
  MKV->STATUS = MKV_ST_DONE | MKV_ST_ERR; /* ERR of this call only (FAULT is never cleared here) */
  write_block(in, bytes / 4u);
  for (size_t i = 0; i < nblocks; i++) {
    if (ns) wait_idle();
    MKV->CMD = cmd;                                  /* copies DIN, starts */
    if (i + 1u < nblocks) write_block(in + (i + 1u) * bytes, bytes / 4u);
    if (ns) wait_idle();
    read_block(out + i * bytes, bytes / 4u);
  }
  /* a refused command or a fault anywhere in the call: ERR / FAULT stay set;
   * a fault also zeroes the key schedule, every later block reads 0 */
  st = MKV->STATUS;
  if ((st & (MKV_ST_KEY_VALID | MKV_ST_ERR | MKV_ST_FAULT | MKV_ST_LOCKED)) == MKV_ST_KEY_VALID) return true;
  return fail_status(st);
}

bool bow_mkv_encrypt(const uint8_t *in, uint8_t *out) { return bow_mkv_ecb(false, in, out, 1); }

bool bow_mkv_decrypt(const uint8_t *in, uint8_t *out) { return bow_mkv_ecb(true, in, out, 1); }

void bow_mkv_clear(void) {
  if (nostall()) wait_idle();
  MKV->CMD = MKV_CMD_CLEAR;
  wait_idle();
  MKV->STATUS = MKV_ST_DONE | MKV_ST_ERR | MKV_ST_FAULT;
}

void bow_mkv_set_nostall(bool on) {
  wait_idle();
  uint32_t c = MKV->CTRL; /* KEY_LOCK reads 1 when set: writing it back changes nothing */
  MKV->CTRL = on ? (c | MKV_CTRL_NOSTALL) : (c & ~MKV_CTRL_NOSTALL);
}

void bow_mkv_lock_key(bool allow_enc, bool allow_dec) {
  wait_idle();
  uint32_t c = MKV->CTRL & ~(MKV_CTRL_NO_ENC | MKV_CTRL_NO_DEC);
  if (!allow_enc) c |= MKV_CTRL_NO_ENC;
  if (!allow_dec) c |= MKV_CTRL_NO_DEC;
  MKV->CTRL = c | MKV_CTRL_KEY_LOCK; /* the policy is taken with the lock */
}

/* A TEST command (corrupted second pass) must end with FAULT: no DONE, no
 * result, no key schedule, not counted as a fault, not LOCKED. */
static bool test_detection(uint32_t cmd, const uint8_t *key) {
  if (!load_key(128, 128, key)) return false;
  if (cmd == MKV_CMD_KEY) {
    for (unsigned w = 0; w < 4; w++) MKV->KEY[w] = load_le32(key + 4u * w);
  } else {
    write_block(bow_mkv_kat[0].pt, 4);
  }
  if (nostall()) wait_idle(); /* the new key words wipe the old key schedule */
  MKV->STATUS = MKV_ST_DONE | MKV_ST_ERR | MKV_ST_FAULT;
  MKV->CMD = cmd | MKV_CMD_TEST;
  uint32_t st = wait_idle();
  bool ok = (st & (MKV_ST_FAULT | MKV_ST_DONE | MKV_ST_ERR | MKV_ST_KEY_VALID | MKV_ST_LOCKED)) == MKV_ST_FAULT;
  for (unsigned i = 0; i < 8; i++) ok = ok && MKV->DOUT[i] == 0;
  bow_mkv_clear();
  return ok ? true : fail((st & MKV_ST_LOCKED) ? MKV_E_LOCKED : MKV_E_FAULT);
}

bool bow_mkv_selftest(void) {
  post_ok = false;
  if (!bow_mkv_present()) return fail(MKV_E_ABSENT);
  uint32_t st = wait_idle();
  if (st & MKV_ST_LOCKED) return fail(MKV_E_LOCKED);
  unsigned faults = MKV_ST_FAULTS(st);
  uint8_t key[64], out[32];
  for (unsigned i = 0; i < sizeof(key); i++) key[i] = (uint8_t)i; /* the key of Annex A */
  bool ok = true;
  /* 1. the known answer of each version, both directions */
  for (unsigned v = 0; ok && v < sizeof(bow_mkv_kat) / sizeof(bow_mkv_kat[0]); v++) {
    const bow_mkv_kat_t *t = &bow_mkv_kat[v];
    unsigned n = t->block_bits / 8u;
    ok = load_key(t->block_bits, t->key_bits, key);
    if (ok && !(bow_mkv_encrypt(t->pt, out) && equal(out, t->ct, n))) ok = fail(MKV_E_FAULT);
    if (ok && !(bow_mkv_decrypt(t->ct, out) && equal(out, t->pt, n))) ok = fail(MKV_E_FAULT);
  }
  /* 2. the fault detection sees a corrupted second pass of each command */
  if (ok) ok = test_detection(MKV_CMD_KEY, key);
  if (ok) ok = test_detection(MKV_CMD_ENC, key);
  if (ok) ok = test_detection(MKV_CMD_DEC, key);
  bow_mkv_clear();
  st = MKV->STATUS;
  if (ok && (MKV_ST_FAULTS(st) != faults || (st & MKV_ST_LOCKED))) ok = fail(MKV_E_LOCKED);
  bow_mkv_wipe(out, sizeof(out));
  if (!ok) return false;
  post_ok = true;
  last_err = MKV_OK;
  return true;
}
