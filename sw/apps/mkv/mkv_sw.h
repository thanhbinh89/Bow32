/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Software implementation of the MKV block cipher (draft TCVN XXXX:2024),
 * written from the standard to check the Bow32 MKV IP on the board. Plain C,
 * byte by byte, the same structure as the text (and the same two
 * corrections as tools/mkv/mkv_model.py, see docs/ip/mkv.md).
 */
#ifndef MKV_SW_H_
#define MKV_SW_H_

#include <stdbool.h>
#include <stdint.h>

#define MKV_SW_MAX_ROUNDS 8

typedef struct {
  unsigned n;      /* block bytes: 16 (MKV-128) or 32 (MKV-256) */
  unsigned rounds; /* R */
  /* half-round keys h[0..2R] = K_0^L, K_1^L, K_1^R, ..., K_R^R (= K_post) */
  uint8_t h[2 * MKV_SW_MAX_ROUNDS + 1][32];
} mkv_sw_ctx_t;

/* Key schedule; false for a version the standard does not have. */
bool mkv_sw_set_key(mkv_sw_ctx_t *ctx, unsigned block_bits, unsigned key_bits, const uint8_t *key);
void mkv_sw_encrypt(const mkv_sw_ctx_t *ctx, const uint8_t *in, uint8_t *out);
void mkv_sw_decrypt(const mkv_sw_ctx_t *ctx, const uint8_t *in, uint8_t *out);

#endif /* MKV_SW_H_ */
