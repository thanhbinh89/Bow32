/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MKV block cipher accelerator driver (docs/ip/mkv.md).
 *
 * MKV (TCVN 14263:2024): MKV-128 with 128 / 192 / 256 bit keys, MKV-256
 * with 256 / 384 / 512 bit keys (R = 7 / 8 / 9 rounds). Blocks and keys are
 * byte strings in the order of the standard.
 *
 *   if (!bow_mkv_selftest()) { ... IP broken: do not use it ... }   // once, at boot
 *   if (!bow_mkv_set_key(128, 256, key)) { ... bow_mkv_error() ... }
 *   bow_mkv_wipe(key, sizeof(key));           // the key is in the IP now
 *   if (!bow_mkv_encrypt(pt, ct)) { ... }     // one block
 *   if (!bow_mkv_ecb(false, buf, buf, n)) { ... }   // n blocks
 *   bow_mkv_clear();                          // forget the key
 *
 * Every function that returns false leaves the reason in bow_mkv_error().
 * No key can be loaded before bow_mkv_selftest() has passed.
 *
 * The IP does every command twice and checks it (fault detection). After a
 * fault (MKV_ST_FAULT) it has dropped the result and zeroed the key: every
 * call returns false until bow_mkv_clear() and a new bow_mkv_set_key(). A
 * fault is a hardware attack or a broken chip: report it, do not retry in a
 * loop. The IP counts the faults since power-on and locks itself at its limit
 * (MKV_ST_LOCKED, until the next power-on reset).
 *
 * Not reentrant: an interrupt handler must not use the IP while the main
 * program does.
 */
#ifndef BOW_MKV_H_
#define BOW_MKV_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t ID;       /* 0x000 R   0x4D4B5602 (version 2: TCVN 14263:2024) */
  volatile uint32_t INFO;     /* 0x004 R   MKV_INFO_* */
  volatile uint32_t CTRL;     /* 0x008 RW  MKV_CTRL_* (version of the next KEY command, modes) */
  volatile uint32_t CMD;      /* 0x00C W   one MKV_CMD_* per write (+ MKV_CMD_TEST) */
  volatile uint32_t STATUS;   /* 0x010 R/W1C MKV_ST_* */
  volatile uint32_t IRQ_EN;   /* 0x014 RW  MKV_ST_DONE | MKV_ST_ERR | MKV_ST_FAULT */
  volatile uint32_t CYCLES;   /* 0x018 R   cycles of the last command (CMD write -> result) */
  uint32_t reserved0[9];
  volatile uint32_t KEY[16];  /* 0x040 W   master key, byte b in KEY[b / 4] bits 8 * (b % 4), zeroed when KEY ends */
  volatile uint32_t DIN[8];   /* 0x080 W   input block, same byte order, zeroed when ENC / DEC start */
  uint32_t reserved1[8];
  volatile uint32_t DOUT[8];  /* 0x0C0 R   output block, zeroed by KEY, 0 unless checked */
} bow_mkv_regs_t;

/* A read of CMD / KEY / DIN, a write of ID / INFO / CYCLES / DOUT and the
 * reserved words answer with a bus error (load / store access fault). */

_Static_assert(__builtin_offsetof(bow_mkv_regs_t, KEY) == 0x040, "MKV KEY offset");
_Static_assert(__builtin_offsetof(bow_mkv_regs_t, DIN) == 0x080, "MKV DIN offset");
_Static_assert(__builtin_offsetof(bow_mkv_regs_t, DOUT) == 0x0C0, "MKV DOUT offset");

#define MKV ((bow_mkv_regs_t *)BOW32_MKV_BASE)

#define MKV_ID_VALUE 0x4D4B5602u  /* version 1 (0x...01): cipher of the draft */

#define MKV_INFO_MKV128          (1u << 0)
#define MKV_INFO_MKV256          (1u << 1)
#define MKV_INFO_FAULT_DETECTION (1u << 2) /* every command done twice and checked */
#define MKV_INFO_RK_CODE         (1u << 3) /* round keys with an address bound code */
#define MKV_INFO_LOCKOUT         (1u << 4) /* fault counter, LOCKED, fatal alert */
#define MKV_INFO_TEST            (1u << 5) /* MKV_CMD_TEST */
#define MKV_INFO_NOSTALL         (1u << 6) /* MKV_CTRL_NOSTALL */
#define MKV_INFO_KEY_LOCK        (1u << 7) /* MKV_CTRL_KEY_LOCK, MKV_CTRL_NO_ENC / NO_DEC */
#define MKV_INFO_CYCLES(info)    (((info) >> 8) & 0xFFu)  /* cycles per round of ENC / DEC */
#define MKV_INFO_FAULT_LIMIT(info) (((info) >> 16) & 15u) /* faults that lock the IP */

#define MKV_CTRL_BLOCK256 (1u << 0)                   /* else MKV-128 */
#define MKV_CTRL_KLEN(n)  (((uint32_t)(n) & 3u) << 1) /* 0: k = l, 1: k = 3l/2, 2: k = 2l */
#define MKV_CTRL_VERSION  (MKV_CTRL_BLOCK256 | MKV_CTRL_KLEN(3))
#define MKV_CTRL_NOSTALL  (1u << 3) /* busy: accesses do not wait, they are dropped (ERR) / read 0 */
#define MKV_CTRL_KEY_LOCK (1u << 4) /* write 1: key, version and policy fixed until reset */
#define MKV_CTRL_NO_DEC   (1u << 5) /* use policy: DEC refused */
#define MKV_CTRL_NO_ENC   (1u << 6) /* use policy: ENC refused */

/* Without NOSTALL, writes to CTRL / CMD / KEY and reads of DOUT wait while a
 * command runs. */
#define MKV_CMD_KEY   (1u << 0) /* key schedule from KEY (CTRL: version), needs all k / 32
                                   KEY words written since the last KEY / CLEAR; 16R + 2 cycles */
#define MKV_CMD_ENC   (1u << 1) /* encrypt DIN -> DOUT, 4R + 4 cycles (with the check) */
#define MKV_CMD_DEC   (1u << 2) /* decrypt DIN -> DOUT, 4R + 4 cycles */
#define MKV_CMD_CLEAR (1u << 3) /* zero KEY, DIN, DOUT and the round keys (read back), 65 cycles */
#define MKV_CMD_TEST  (1u << 4) /* with KEY / ENC / DEC: corrupt the check, must end in FAULT */

#define MKV_ST_BUSY      (1u << 0)
#define MKV_ST_KEY_VALID (1u << 1)
#define MKV_ST_DONE      (1u << 2) /* W1C */
#define MKV_ST_ERR       (1u << 3) /* W1C: a command or a write was refused */
#define MKV_ST_WIDE      (1u << 4) /* key schedule of MKV-256 */
#define MKV_ST_FAULT     (1u << 5) /* W1C: fault detected, result dropped, key zeroed */
#define MKV_ST_LOCKED    (1u << 6) /* too many faults: only CLEAR works until power-on reset */
#define MKV_ST_ALERT     (1u << 7) /* W1C: the IP locked itself (fatal alert, CPU NMI) */
#define MKV_ST_ROUNDS(st) (((st) >> 8) & 15u)
#define MKV_ST_FAULTS(st) (((st) >> 12) & 15u) /* faults since power-on (TEST not counted) */

typedef enum {
  MKV_OK = 0,
  MKV_E_VERSION,   /* no such version of the standard */
  MKV_E_SELFTEST,  /* bow_mkv_selftest() has not passed */
  MKV_E_NO_KEY,    /* no key schedule in the IP */
  MKV_E_REFUSED,   /* the IP refused a command (ERR): policy, KEY_LOCK, ... */
  MKV_E_FAULT,     /* fault detected: result dropped, key wiped */
  MKV_E_LOCKED,    /* the IP locked itself: unusable until power-on reset */
  MKV_E_ABSENT,    /* no MKV IP of this version (ID) */
} bow_mkv_err_t;

static inline bool bow_mkv_present(void) { return MKV->ID == MKV_ID_VALUE; }

/* Reason of the last false return of a bow_mkv_* function. */
bow_mkv_err_t bow_mkv_error(void);
const char *bow_mkv_error_name(bow_mkv_err_t e);

/* Power-on self-test: the Annex A known answer of each version, encryption
 * and decryption, then a TEST of KEY, ENC and DEC, each of which must be
 * caught by the fault detection. Leaves no key in the IP. Until it passes,
 * bow_mkv_set_key() refuses to load a key. */
bool bow_mkv_selftest(void);

/* Rounds of MKV-<block_bits> with a key of key_bits (Table 1), 0: no such version. */
unsigned bow_mkv_rounds(unsigned block_bits, unsigned key_bits);

/* Key schedule (waits for its end, 16R + 2 cycles). False for a version the
 * standard does not have, when the IP refuses the command or after a fault.
 * The caller should wipe its copy of the key afterwards (bow_mkv_wipe). */
bool bow_mkv_set_key(unsigned block_bits, unsigned key_bits, const uint8_t *key);

/* Block size of the current key schedule: 16 or 32 bytes (0: no key). */
unsigned bow_mkv_block_bytes(void);

/* One block, any alignment, in == out allowed. Needs a key schedule. False
 * without a key schedule, if the IP refuses it or after a fault (out is
 * then 0). */
bool bow_mkv_encrypt(const uint8_t *in, uint8_t *out);
bool bow_mkv_decrypt(const uint8_t *in, uint8_t *out);

/* n blocks (ECB): the next block goes into DIN while the engine works.
 * False as above, for the whole call. */
bool bow_mkv_ecb(bool decrypt, const uint8_t *in, uint8_t *out, size_t nblocks);

/* Zero the key registers, DIN, DOUT and the round keys (waits), clear
 * DONE / ERR / FAULT. Works when the IP is locked. */
void bow_mkv_clear(void);

/* Accesses during a command: wait on the bus (false, default) or not
 * (true: the driver then polls BUSY). */
void bow_mkv_set_nostall(bool nostall);

/* Fix the loaded key until the next reset (KEY_LOCK), optionally allowing
 * only encryption or only decryption with it. */
void bow_mkv_lock_key(bool allow_enc, bool allow_dec);

/* Zero a buffer that held a key (not optimized away). */
void bow_mkv_wipe(void *p, size_t n);

#endif /* BOW_MKV_H_ */
