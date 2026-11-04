/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MKV block cipher accelerator driver (docs/ip/mkv.md).
 *
 * MKV (draft TCVN XXXX:2024): MKV-128 with 128 / 192 / 256 bit keys, MKV-256
 * with 256 / 384 / 512 bit keys. Blocks and keys are byte strings in the
 * order of the standard.
 *
 *   if (!bow_mkv_set_key(128, 256, key)) { ... unknown version ... }
 *   bow_mkv_encrypt(pt, ct);                  // one block
 *   bow_mkv_ecb(false, buf, buf, n);          // n blocks
 *   bow_mkv_clear();                          // forget the key
 */
#ifndef BOW_MKV_H_
#define BOW_MKV_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t ID;       /* 0x000 R   0x4D4B5601 */
  volatile uint32_t INFO;     /* 0x004 R   [0] MKV-128 [1] MKV-256 [15:8] cycles per round */
  volatile uint32_t CTRL;     /* 0x008 RW  MKV_CTRL_* (version of the next KEY command) */
  volatile uint32_t CMD;      /* 0x00C W   one MKV_CMD_* per write */
  volatile uint32_t STATUS;   /* 0x010 R/W1C MKV_ST_* */
  volatile uint32_t IRQ_EN;   /* 0x014 RW  MKV_ST_DONE | MKV_ST_ERR */
  volatile uint32_t CYCLES;   /* 0x018 R   cycles of the last command (CMD write -> result) */
  uint32_t reserved0[9];
  volatile uint32_t KEY[16];  /* 0x040 W   master key, byte b in KEY[b / 4] bits 8 * (b % 4) */
  volatile uint32_t DIN[8];   /* 0x080 RW  input block, same byte order */
  uint32_t reserved1[8];
  volatile uint32_t DOUT[8];  /* 0x0C0 R   output block */
} bow_mkv_regs_t;

_Static_assert(__builtin_offsetof(bow_mkv_regs_t, KEY) == 0x040, "MKV KEY offset");
_Static_assert(__builtin_offsetof(bow_mkv_regs_t, DIN) == 0x080, "MKV DIN offset");
_Static_assert(__builtin_offsetof(bow_mkv_regs_t, DOUT) == 0x0C0, "MKV DOUT offset");

#define MKV ((bow_mkv_regs_t *)BOW32_MKV_BASE)

#define MKV_ID_VALUE 0x4D4B5601u

#define MKV_CTRL_BLOCK256 (1u << 0)                   /* else MKV-128 */
#define MKV_CTRL_KLEN(n)  (((uint32_t)(n) & 3u) << 1) /* 0: k = l, 1: k = 3l/2, 2: k = 2l */

/* Writes to CTRL / CMD / KEY and reads of DOUT wait while a command runs. */
#define MKV_CMD_KEY   (1u << 0) /* key schedule from KEY (CTRL: version) */
#define MKV_CMD_ENC   (1u << 1) /* encrypt DIN -> DOUT */
#define MKV_CMD_DEC   (1u << 2) /* decrypt DIN -> DOUT */
#define MKV_CMD_CLEAR (1u << 3) /* zero KEY, DIN, DOUT and the round keys */

#define MKV_ST_BUSY      (1u << 0)
#define MKV_ST_KEY_VALID (1u << 1)
#define MKV_ST_DONE      (1u << 2) /* W1C */
#define MKV_ST_ERR       (1u << 3) /* W1C: a command was refused */
#define MKV_ST_WIDE      (1u << 4) /* key schedule of MKV-256 */
#define MKV_ST_ROUNDS(st) (((st) >> 8) & 15u)

static inline bool bow_mkv_present(void) { return MKV->ID == MKV_ID_VALUE; }

/* Rounds of MKV-<block_bits> with a key of key_bits (Table 1), 0: no such version. */
unsigned bow_mkv_rounds(unsigned block_bits, unsigned key_bits);

/* Key schedule (waits for its end, 8R + 1 cycles). False for a version the
 * standard does not have or when the IP refuses the command. */
bool bow_mkv_set_key(unsigned block_bits, unsigned key_bits, const uint8_t *key);

/* Block size of the current key schedule: 16 or 32 bytes (0: no key). */
unsigned bow_mkv_block_bytes(void);

/* One block, any alignment, in == out allowed. Needs a key schedule. */
void bow_mkv_encrypt(const uint8_t *in, uint8_t *out);
void bow_mkv_decrypt(const uint8_t *in, uint8_t *out);

/* n blocks (ECB): the next block goes into DIN while the engine works. */
void bow_mkv_ecb(bool decrypt, const uint8_t *in, uint8_t *out, size_t nblocks);

/* Zero the key registers, DIN, DOUT and the round keys (waits). */
void bow_mkv_clear(void);

#endif /* BOW_MKV_H_ */
