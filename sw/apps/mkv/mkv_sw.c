/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Software MKV (TCVN 14263:2024), see mkv_sw.h. State of n bytes in the
 * order of the standard: sub-state c = bytes c*t .. c*t+t-1, t = n / 4.
 */
#include "mkv_sw.h"

#include "mkv_tables.h"

/* GF(2^8) / x^8 + x^5 + x^3 + x + 1: 0x02 generates the multiplicative group */
static uint8_t gf_exp[510], gf_log[256];
static bool gf_ready;

static void gf_init(void) {
  unsigned x = 1;
  for (unsigned i = 0; i < 255; i++) {
    gf_exp[i] = gf_exp[i + 255] = (uint8_t)x;
    gf_log[x] = (uint8_t)i;
    x <<= 1;
    if (x & 0x100u) x ^= 0x12Bu;
  }
  gf_ready = true;
}

static uint8_t gf_mul(uint8_t a, uint8_t b) {
  return (a == 0 || b == 0) ? 0 : gf_exp[gf_log[a] + gf_log[b]];
}

static void copy(uint8_t *d, const uint8_t *s, unsigned n) {
  for (unsigned i = 0; i < n; i++) d[i] = s[i];
}

static void add_key(uint8_t *x, const uint8_t *k, unsigned n) {
  for (unsigned i = 0; i < n; i++) x[i] ^= k[i];
}

static void sub_cells(uint8_t *x, unsigned n) {
  for (unsigned i = 0; i < n; i++) x[i] = mkv_sbox[x[i]];
}

static void inv_sub_cells(uint8_t *x, unsigned n) {
  for (unsigned i = 0; i < n; i++) x[i] = mkv_sbox_inv[x[i]];
}

/* MixWords: sub-state c rotated left by c * w / 4 bits (byte j <- byte
 * j + c * t / 4), then times M4 / M8. Inverse: times M4^-1 / M8^-1, then
 * rotated right. */
static void mix_words(uint8_t *x, unsigned n, bool inv) {
  unsigned t = n / 4u;
  uint8_t in[8], col[8];
  for (unsigned c = 0; c < 4; c++) {
    uint8_t *p = x + c * t;
    unsigned s = c * t / 4u;
    for (unsigned j = 0; j < t; j++) in[j] = inv ? p[j] : p[(j + s) % t];
    for (unsigned r = 0; r < t; r++) {
      uint8_t v = 0;
      for (unsigned k = 0; k < t; k++) {
        uint8_t m = (t == 4) ? (inv ? mkv_m4_inv[r][k] : mkv_m4[r][k])
                             : (inv ? mkv_m8_inv[r][k] : mkv_m8[r][k]);
        v ^= gf_mul(m, in[k]);
      }
      col[r] = v;
    }
    for (unsigned j = 0; j < t; j++) p[inv ? (j + s) % t : j] = col[j];
  }
}

/* y_c = XOR of the three other sub-states */
static void x_words(uint8_t *x, unsigned n) {
  unsigned t = n / 4u;
  for (unsigned j = 0; j < t; j++) {
    uint8_t s = x[j] ^ x[t + j] ^ x[2 * t + j] ^ x[3 * t + j];
    for (unsigned c = 0; c < 4; c++) x[c * t + j] ^= s;
  }
}

/* F(k0 || k1, x) = XWords(SubCells(MixWords(SubCells(x ^ k0)) ^ k1)) */
static void round_f(uint8_t *x, const uint8_t *k0, const uint8_t *k1, unsigned n) {
  add_key(x, k0, n);
  sub_cells(x, n);
  mix_words(x, n, false);
  add_key(x, k1, n);
  sub_cells(x, n);
  x_words(x, n);
}

static void inv_round_f(uint8_t *x, const uint8_t *k0, const uint8_t *k1, unsigned n) {
  x_words(x, n);
  inv_sub_cells(x, n);
  add_key(x, k1, n);
  mix_words(x, n, true);
  inv_sub_cells(x, n);
  add_key(x, k0, n);
}

static const uint8_t zero[32];

/* x <- G(G(x ^ Const^half_l ^ <v>_l)), G(x) = F(0, x): <v>_l has v in the
 * last byte (clause 5.5) */
static void schedule_f(uint8_t *x, unsigned v, unsigned half, unsigned n) {
  uint8_t c[32];
  copy(c, n == 32u ? mkv_const256[half] : mkv_const128[half], n);
  c[n - 1] ^= (uint8_t)v;
  round_f(x, c, zero, n);
  round_f(x, zero, zero, n);
}

bool mkv_sw_set_key(mkv_sw_ctx_t *ctx, unsigned block_bits, unsigned key_bits, const uint8_t *key) {
  unsigned n = block_bits / 8u, w = n / 4u;
  uint8_t kl[32], kr[32], a[32], b[32];

  if (block_bits != 128 && block_bits != 256) return false;
  if (key_bits == block_bits) ctx->rounds = 7;
  else if (2u * key_bits == 3u * block_bits) ctx->rounds = 8;
  else if (key_bits == 2u * block_bits) ctx->rounds = 9;
  else return false;
  if (!gf_ready) gf_init();
  ctx->n = n;

  /* K_int = K^0 || K^1 = k0 .. k7 | k0 .. k5 ~k2 ~k3 | k0 .. k3 ~k0 .. ~k3
   * (words of w bytes) */
  copy(kl, key, n);
  if (key_bits == 2u * block_bits) {
    copy(kr, key + n, n);
  } else if (2u * key_bits == 3u * block_bits) {
    copy(kr, key + n, 2u * w);
    for (unsigned i = 0; i < 2u * w; i++) kr[2u * w + i] = (uint8_t)~key[2u * w + i];
  } else {
    for (unsigned i = 0; i < n; i++) kr[i] = (uint8_t)~key[i];
  }
  copy(ctx->h[0], kl, n);

  /* update i = 1..R (clause 5.5, then SWAP): K^0 <- G(G(K^1 ^ Const^1 ^ <2i>)),
   * K^1 <- G(G(K^0 ^ Const^0 ^ <2i - 1>)) ^ the new K^0; h[2i - 1] = K^0,
   * h[2i] = K^1 */
  for (unsigned i = 1; i <= ctx->rounds; i++) {
    copy(a, kr, n);
    schedule_f(a, 2u * i, 1u, n);
    copy(b, kl, n);
    schedule_f(b, 2u * i - 1u, 0u, n);
    copy(kl, a, n);
    copy(kr, a, n);
    add_key(kr, b, n);
    copy(ctx->h[2u * i - 1u], kl, n);
    copy(ctx->h[2u * i], kr, n);
  }
  return true;
}

void mkv_sw_encrypt(const mkv_sw_ctx_t *ctx, const uint8_t *in, uint8_t *out) {
  uint8_t x[32];
  unsigned n = ctx->n;
  copy(x, in, n);
  for (unsigned r = 0; r < ctx->rounds; r++) round_f(x, ctx->h[2 * r], ctx->h[2 * r + 1], n);
  add_key(x, ctx->h[2 * ctx->rounds], n);
  copy(out, x, n);
}

void mkv_sw_decrypt(const mkv_sw_ctx_t *ctx, const uint8_t *in, uint8_t *out) {
  uint8_t x[32];
  unsigned n = ctx->n;
  copy(x, in, n);
  add_key(x, ctx->h[2 * ctx->rounds], n);
  for (unsigned r = ctx->rounds; r-- > 0;) inv_round_f(x, ctx->h[2 * r], ctx->h[2 * r + 1], n);
  copy(out, x, n);
}
