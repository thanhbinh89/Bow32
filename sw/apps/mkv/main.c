/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MKV demo and self-test: the Bow32 MKV block cipher IP (draft TCVN
 * XXXX:2024, docs/ip/mkv.md) against Annex A of the standard and against a
 * software MKV (mkv_sw.c). Shell on UART0, `h` for help.
 *
 *   test [quick] [seed]   self-test, ends with "mkv: PASS (n/n)" / "mkv: FAIL (k/n)"
 *   kat                   Annex A on the IP
 *   key <l> <hex>         key schedule of MKV-<l>, key size from the hex string
 *   enc <hex>, dec <hex>  one block -> "out <hex>" (tools/bow32_mkv.py)
 *   bench                 cycles of the IP and of the software
 */
#include "bow32.h"
#include "mkv_sw.h"
#include "mkv_vectors.h"

#define NUM_VECTORS (sizeof(mkv_vectors) / sizeof(mkv_vectors[0]))

static const char help[] =
    "  test [quick] [seed]  self-test: Annex A (software and IP), IP vs software on\n"
    "                       random keys / blocks, ECB, errors, CLEAR, interrupt\n"
    "  kat                  Annex A test vectors on the IP\n"
    "  key <l> <hex>        key schedule, l = 128 | 256, key of l, 3l/2 or 2l bits\n"
    "  enc <hex>            encrypt one block with the IP -> out <hex>\n"
    "  dec <hex>            decrypt one block with the IP -> out <hex>\n"
    "  bench                cycles: key schedule, one block, ECB (IP / software)\n"
    "  clear                CLEAR: forget the key\n"
    "  info  baud <rate>  rd <addr>  wr <addr> <val>\n";

static const unsigned versions[6][2] = {{128, 128}, {128, 192}, {128, 256},
                                        {256, 256}, {256, 384}, {256, 512}};

static mkv_sw_ctx_t sw; /* ~550 bytes: not on the stack */

/* ------------------------------------------------------------------ helpers */
static uint32_t rng_state = 1;

static uint32_t rng(void) { /* xorshift32 */
  uint32_t x = rng_state;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  return rng_state = x;
}

static void rng_fill(uint8_t *p, unsigned n) {
  for (unsigned i = 0; i < n; i++) p[i] = (uint8_t)(rng() >> 24);
}

static bool equal(const uint8_t *a, const uint8_t *b, unsigned n) {
  for (unsigned i = 0; i < n; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

static void print_hex(const uint8_t *p, unsigned n) {
  for (unsigned i = 0; i < n; i++) bow_printf("%02x", p[i]);
}

/* bow_printf has no left alignment */
static void print_left(const char *s, unsigned width) {
  unsigned n = 0;
  while (s[n]) n++;
  bow_puts(s);
  while (n++ < width) bow_puts(" ");
}

static const char *skip_spaces(const char *s) {
  while (*s == ' ') s++;
  return s;
}

static const char *parse_num(const char *s, uint32_t *v, bool hex) {
  uint32_t x = 0;
  const char *start;
  s = skip_spaces(s);
  if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
    hex = true;
    s += 2;
  }
  start = s;
  for (;; s++) {
    unsigned d;
    if (*s >= '0' && *s <= '9') d = (unsigned)(*s - '0');
    else if (hex && *s >= 'a' && *s <= 'f') d = (unsigned)(*s - 'a' + 10);
    else if (hex && *s >= 'A' && *s <= 'F') d = (unsigned)(*s - 'A' + 10);
    else break;
    x = x * (hex ? 16u : 10u) + d;
  }
  if (s == start) return NULL;
  *v = x;
  return s;
}

static int hex_digit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* hex string -> bytes, returns the number of bytes (0: bad / too long) */
static unsigned parse_hex(const char *s, uint8_t *out, unsigned max) {
  unsigned n = 0;
  s = skip_spaces(s);
  while (*s && *s != ' ') {
    int hi = hex_digit(s[0]), lo = hex_digit(s[1]);
    if (hi < 0 || lo < 0 || n == max) return 0;
    out[n++] = (uint8_t)(hi << 4 | lo);
    s += 2;
  }
  return n;
}

static const char *match(const char *line, const char *cmd) {
  const char *s = line;
  while (*cmd && *s == *cmd) s++, cmd++;
  if (*cmd != '\0' || (*s != '\0' && *s != ' ')) return NULL;
  return s;
}

/* ---------------------------------------------------------------- self-test */
static unsigned checks, failures;

static void check(bool ok, const char *what) {
  checks++;
  if (!ok) failures++;
  bow_printf("  [%2u] ", checks);
  print_left(what, 58);
  bow_printf(" %s\n", ok ? "ok" : "FAIL");
}

static bool fail_detail(const char *what, unsigned idx) {
  bow_printf("       %s %u\n", what, idx);
  return false;
}

static bool test_sw_annex_a(void) {
  bool ok = true;
  for (unsigned v = 0; v < NUM_VECTORS; v++) {
    const mkv_vector_t *t = &mkv_vectors[v];
    unsigned n = t->block_bits / 8u;
    uint8_t out[32];
    if (!mkv_sw_set_key(&sw, t->block_bits, t->key_bits, t->key) || sw.rounds != t->rounds) {
      ok = fail_detail("software key schedule refused, vector", v);
      continue;
    }
    for (unsigned i = 0; i <= 2u * t->rounds; i++) {
      if (!equal(sw.h[i], t->h + i * n, n)) ok = fail_detail("round key differs, vector", v);
    }
    mkv_sw_encrypt(&sw, t->pt, out);
    if (!equal(out, t->ct, n)) ok = fail_detail("ciphertext differs, vector", v);
    mkv_sw_decrypt(&sw, t->ct, out);
    if (!equal(out, t->pt, n)) ok = fail_detail("decryption differs, vector", v);
  }
  return ok;
}

static bool test_ip_annex_a(bool decrypt) {
  bool ok = true;
  for (unsigned v = 0; v < NUM_VECTORS; v++) {
    const mkv_vector_t *t = &mkv_vectors[v];
    unsigned n = t->block_bits / 8u;
    uint8_t out[32];
    if (!bow_mkv_set_key(t->block_bits, t->key_bits, t->key)) {
      ok = fail_detail("KEY refused, vector", v);
      continue;
    }
    uint32_t st = MKV->STATUS;
    if (MKV_ST_ROUNDS(st) != t->rounds || !!(st & MKV_ST_WIDE) != (t->block_bits == 256) ||
        MKV->CYCLES != 8u * t->rounds + 1u) {
      ok = fail_detail("STATUS / CYCLES of KEY wrong, vector", v);
    }
    if (decrypt) {
      bow_mkv_decrypt(t->ct, out);
      if (!equal(out, t->pt, n)) ok = fail_detail("plaintext differs, vector", v);
    } else {
      bow_mkv_encrypt(t->pt, out);
      if (!equal(out, t->ct, n)) ok = fail_detail("ciphertext differs, vector", v);
    }
    if (MKV->CYCLES != 2u * t->rounds + 2u) ok = fail_detail("CYCLES of ENC / DEC wrong, vector", v);
  }
  return ok;
}

/* IP vs software, `count` random keys per version, encryption + decryption */
static bool test_random(unsigned count) {
  bool ok = true;
  for (unsigned v = 0; v < 6; v++) {
    unsigned l = versions[v][0], k = versions[v][1], n = l / 8u;
    for (unsigned i = 0; i < count; i++) {
      uint8_t key[64], blk[32], ct[32], hw[32], ref[32];
      rng_fill(key, k / 8u);
      rng_fill(blk, n);
      if (!bow_mkv_set_key(l, k, key) || !mkv_sw_set_key(&sw, l, k, key)) {
        ok = fail_detail("key refused, version", v);
        continue;
      }
      bow_mkv_encrypt(blk, ct);
      mkv_sw_encrypt(&sw, blk, ref);
      if (!equal(ct, ref, n)) ok = fail_detail("encryption differs, version", v);
      bow_mkv_decrypt(blk, hw);          /* a random block as ciphertext */
      mkv_sw_decrypt(&sw, blk, ref);
      if (!equal(hw, ref, n)) ok = fail_detail("decryption differs, version", v);
      bow_mkv_decrypt(ct, hw);           /* D(E(x)) = x on the IP */
      if (!equal(hw, blk, n)) ok = fail_detail("D(E(x)) != x, version", v);
    }
  }
  return ok;
}

/* bow_mkv_ecb (DIN written while the IP works) vs single blocks, unaligned
 * and in-place buffers */
static bool test_ecb(void) {
  static uint8_t buf[8 * 32 + 1], ref[8 * 32];
  bool ok = true;
  for (unsigned v = 2; v < 6; v += 3) {     /* MKV-128/256 and MKV-256/512 */
    unsigned l = versions[v][0], k = versions[v][1], n = l / 8u;
    uint8_t key[64];
    rng_fill(key, k / 8u);
    if (!bow_mkv_set_key(l, k, key) || !mkv_sw_set_key(&sw, l, k, key)) return false;
    uint8_t *p = buf + 1;                   /* unaligned */
    rng_fill(p, 8u * n);
    for (unsigned b = 0; b < 8; b++) mkv_sw_encrypt(&sw, p + b * n, ref + b * n);
    bow_mkv_ecb(false, p, p, 8);            /* in place */
    if (!equal(p, ref, 8u * n)) ok = fail_detail("ECB encryption differs, version", v);
    bow_mkv_ecb(true, p, p, 8);
    for (unsigned b = 0; b < 8; b++) mkv_sw_decrypt(&sw, ref + b * n, ref + b * n);
    if (!equal(p, ref, 8u * n)) ok = fail_detail("ECB decryption differs, version", v);
  }
  return ok;
}

static bool wait_idle(void) {
  for (unsigned i = 0; i < 100000u; i++) {
    if (!(MKV->STATUS & MKV_ST_BUSY)) return true;
  }
  return false;
}

static bool test_errors(void) {
  bool ok = true;
  bow_mkv_clear();
  MKV->CMD = MKV_CMD_ENC;                   /* no key schedule */
  uint32_t st = MKV->STATUS;
  if (!(st & MKV_ST_ERR) || (st & (MKV_ST_BUSY | MKV_ST_DONE))) ok = fail_detail("ENC without key, STATUS", st);
  MKV->STATUS = MKV_ST_ERR;
  MKV->CTRL = MKV_CTRL_KLEN(3);             /* no such version */
  MKV->CMD = MKV_CMD_KEY;
  st = MKV->STATUS;
  if (!(st & MKV_ST_ERR) || (st & MKV_ST_BUSY)) ok = fail_detail("KEY with KLEN 3, STATUS", st);
  MKV->STATUS = MKV_ST_ERR;
  MKV->CMD = MKV_CMD_ENC | MKV_CMD_DEC;     /* two commands */
  st = MKV->STATUS;
  if (!(st & MKV_ST_ERR) || (st & MKV_ST_BUSY)) ok = fail_detail("two CMD bits, STATUS", st);
  MKV->STATUS = MKV_ST_ERR;
  if (bow_mkv_set_key(128, 160, mkv_vectors[0].key)) ok = fail_detail("driver took MKV-128/", 160);
  return ok;
}

static bool test_key_valid(void) {
  bool ok = true;
  const mkv_vector_t *t = &mkv_vectors[1];
  if (!bow_mkv_set_key(t->block_bits, t->key_bits, t->key)) return false;
  MKV->KEY[0] = 0;                          /* any key write */
  if (MKV->STATUS & MKV_ST_KEY_VALID) ok = fail_detail("KEY_VALID after a KEY write", 0);
  if (!bow_mkv_set_key(t->block_bits, t->key_bits, t->key)) return false;
  MKV->CTRL = MKV->CTRL;                    /* same version: stays valid */
  if (!(MKV->STATUS & MKV_ST_KEY_VALID)) ok = fail_detail("KEY_VALID lost on a CTRL rewrite", 0);
  MKV->CTRL = MKV_CTRL_BLOCK256 | MKV_CTRL_KLEN(1);
  uint32_t st = MKV->STATUS;
  if ((st & MKV_ST_KEY_VALID) || MKV_ST_ROUNDS(st) != 0) ok = fail_detail("CTRL change, STATUS", st);
  MKV->CMD = MKV_CMD_DEC;
  if (!(MKV->STATUS & MKV_ST_ERR)) ok = fail_detail("DEC after a CTRL change: no ERR", 0);
  MKV->STATUS = MKV_ST_ERR | MKV_ST_DONE;
  return ok;
}

static bool test_clear(void) {
  bool ok = true;
  const mkv_vector_t *t = &mkv_vectors[5];
  uint8_t out[32];
  if (!bow_mkv_set_key(t->block_bits, t->key_bits, t->key)) return false;
  bow_mkv_encrypt(t->pt, out);
  bow_mkv_clear();
  uint32_t st = MKV->STATUS;
  if ((st & MKV_ST_KEY_VALID) || MKV_ST_ROUNDS(st) != 0) ok = fail_detail("CLEAR, STATUS", st);
  if (MKV->CYCLES != 33u) ok = fail_detail("CLEAR, CYCLES", MKV->CYCLES);
  for (unsigned i = 0; i < 8; i++) {
    if (MKV->DOUT[i] != 0 || MKV->DIN[i] != 0) ok = fail_detail("CLEAR left data in DIN / DOUT word", i);
  }
  return ok;
}

/* the DONE / ERR interrupt reaches irq_fast[BOW32_IRQ_FAST_MKV] (seen in mip,
 * the interrupt itself stays disabled) */
static bool test_irq(void) {
  bool ok = true;
  const uint32_t bit = MIE_FAST(BOW32_IRQ_FAST_MKV);
  const mkv_vector_t *t = &mkv_vectors[0];
  uint8_t out[32];
  if (!bow_mkv_set_key(t->block_bits, t->key_bits, t->key)) return false;
  MKV->STATUS = MKV_ST_DONE | MKV_ST_ERR;
  MKV->IRQ_EN = MKV_ST_DONE;
  if (CSR_READ(mip) & bit) ok = fail_detail("irq pending before the command", 0);
  bow_mkv_encrypt(t->pt, out);
  if (!(CSR_READ(mip) & bit)) ok = fail_detail("no irq on DONE", 0);
  MKV->STATUS = MKV_ST_DONE;
  if (CSR_READ(mip) & bit) ok = fail_detail("irq after DONE was cleared", 0);
  MKV->IRQ_EN = MKV_ST_ERR;
  MKV->CMD = MKV_CMD_KEY | MKV_CMD_ENC;
  if (!(CSR_READ(mip) & bit)) ok = fail_detail("no irq on ERR", 0);
  MKV->STATUS = MKV_ST_ERR;
  MKV->IRQ_EN = 0;
  return ok;
}

/* CMD after KEY waits for the key schedule (bus stall), DOUT for the block */
static bool test_stall(void) {
  bool ok = true;
  const mkv_vector_t *t = &mkv_vectors[5];
  uint8_t out[32];
  if (!bow_mkv_set_key(t->block_bits, t->key_bits, t->key)) return false;
  for (unsigned i = 0; i < 8; i++) MKV->DIN[i] = (uint32_t)t->pt[4 * i] | (uint32_t)t->pt[4 * i + 1] << 8 |
                                                  (uint32_t)t->pt[4 * i + 2] << 16 | (uint32_t)t->pt[4 * i + 3] << 24;
  uint32_t t0 = bow_cycles();
  MKV->CMD = MKV_CMD_KEY;
  MKV->CMD = MKV_CMD_ENC;                   /* waits for the key schedule */
  uint32_t t1 = bow_cycles();
  for (unsigned i = 0; i < 8; i++) {
    uint32_t w = MKV->DOUT[i];              /* the first read waits for the block */
    for (unsigned b = 0; b < 4; b++) out[4 * i + b] = (uint8_t)(w >> (8 * b));
  }
  if (t1 - t0 < 8u * t->rounds) ok = fail_detail("CMD did not wait for the key schedule, cycles", t1 - t0);
  if (!equal(out, t->ct, 32)) ok = fail_detail("result read without polling differs", 0);
  ok = wait_idle() && ok;
  return ok;
}

static bool self_test(bool quick, uint32_t seed) {
  checks = failures = 0;
  rng_state = seed ? seed : 1;
  bow_printf("mkv: self-test (%s, seed %u)\n", quick ? "quick" : "full", rng_state);
  check(bow_mkv_present() && MKV->INFO == 0x203u, "IP present (ID, INFO)");
  check(test_sw_annex_a(), "software MKV vs Annex A (round keys, ct, decryption)");
  check(test_ip_annex_a(false), "IP vs Annex A: encryption (6 versions), STATUS, CYCLES");
  check(test_ip_annex_a(true), "IP vs Annex A: decryption (6 versions)");
  check(test_random(quick ? 1 : 20), quick ? "IP vs software: 1 random key per version, E/D/D(E)"
                                           : "IP vs software: 20 random keys per version, E/D/D(E)");
  check(test_ecb(), "ECB: next DIN during the block, unaligned, in place");
  check(test_errors(), "errors: ENC without key, KLEN 3, two commands");
  check(test_key_valid(), "KEY_VALID: KEY write, CTRL change");
  check(test_clear(), "CLEAR: key schedule, DIN, DOUT zeroed");
  check(test_irq(), "interrupt DONE / ERR on irq_fast[10]");
  check(test_stall(), "bus stall: CMD during KEY, DOUT during ENC");
  bow_mkv_clear();
  bow_printf("mkv: %s (%u/%u)\n", failures ? "FAIL" : "PASS", checks - failures, checks);
  return failures == 0;
}

/* ------------------------------------------------------------------ commands */
static void kat(void) {
  for (unsigned v = 0; v < NUM_VECTORS; v++) {
    const mkv_vector_t *t = &mkv_vectors[v];
    unsigned n = t->block_bits / 8u;
    uint8_t ct[32], pt[32];
    bool ok = bow_mkv_set_key(t->block_bits, t->key_bits, t->key);
    bow_mkv_encrypt(t->pt, ct);
    bow_mkv_decrypt(ct, pt);
    ok = ok && equal(ct, t->ct, n) && equal(pt, t->pt, n);
    bow_printf("%s MKV-%u/%u R=%u\n  key ", t->name, t->block_bits, t->key_bits, t->rounds);
    print_hex(t->key, t->key_bits / 8u);
    bow_printf("\n  pt  ");
    print_hex(t->pt, n);
    bow_printf("\n  ct  ");
    print_hex(ct, n);
    bow_printf("  %s\n", ok ? "ok" : "FAIL");
  }
  bow_mkv_clear();
}

static bool cmd_key(const char *a) {
  uint32_t l;
  uint8_t key[64];
  if (!(a = parse_num(a, &l, false))) return false;
  unsigned n = parse_hex(a, key, sizeof(key));
  if (n == 0 || !bow_mkv_set_key(l, 8u * n, key)) {
    bow_printf("error: no MKV-%u version with a %u bit key\n", l, 8u * n);
    return false;
  }
  bow_printf("key MKV-%u/%u R=%u (%u cycles)\n", l, 8u * n, MKV_ST_ROUNDS(MKV->STATUS), MKV->CYCLES);
  return true;
}

static bool cmd_crypt(const char *a, bool decrypt) {
  uint8_t in[32], out[32];
  unsigned bytes = bow_mkv_block_bytes();
  if (bytes == 0) {
    bow_printf("error: no key (key <l> <hex>)\n");
    return false;
  }
  if (parse_hex(a, in, sizeof(in)) != bytes) {
    bow_printf("error: block of %u bytes expected\n", bytes);
    return false;
  }
  if (decrypt) bow_mkv_decrypt(in, out);
  else         bow_mkv_encrypt(in, out);
  bow_printf("out ");
  print_hex(out, bytes);
  bow_printf("\n");
  return true;
}

static void bench(void) {
  static uint8_t buf[64 * 32];
  bow_printf("version       key schedule (cycles)    one block (cycles)   ECB, 64 blocks\n");
  bow_printf("                   IP         SW         IP         SW     cycles/block    KB/s\n");
  for (unsigned v = 0; v < 6; v++) {
    unsigned l = versions[v][0], k = versions[v][1], n = l / 8u;
    uint8_t key[64], out[32];
    rng_fill(key, k / 8u);
    rng_fill(buf, 64u * n);
    uint32_t t0 = bow_cycles();
    bow_mkv_set_key(l, k, key);
    uint32_t t1 = bow_cycles();
    mkv_sw_set_key(&sw, l, k, key);
    uint32_t t2 = bow_cycles();
    bow_mkv_encrypt(buf, out);
    uint32_t t3 = bow_cycles();
    mkv_sw_encrypt(&sw, buf, out);
    uint32_t t4 = bow_cycles();
    bow_mkv_ecb(false, buf, buf, 64);
    uint32_t t5 = bow_cycles();
    uint32_t per_block = (t5 - t4) / 64u;
    uint32_t kbs = n * (bow_clk_hz() / 1000u) / per_block;   /* 1 KB = 1000 bytes */
    bow_printf("MKV-%u/%3u  %8u %10u %10u %10u %16u %7u\n", l, k, t1 - t0, t2 - t1, t3 - t2, t4 - t3,
               per_block, kbs);
  }
  bow_mkv_clear();
}

static void info(void) {
  uint32_t st = MKV->STATUS;
  bow_printf("MKV ID %08x INFO %08x CTRL %08x STATUS %08x (busy %u key %u done %u err %u, R %u, %s)\n",
             MKV->ID, MKV->INFO, MKV->CTRL, st, st & 1u, (st >> 1) & 1u, (st >> 2) & 1u, (st >> 3) & 1u,
             MKV_ST_ROUNDS(st), (st & MKV_ST_WIDE) ? "MKV-256" : "MKV-128");
}

static bool execute(const char *line) {
  const char *a;
  uint32_t v, v2;

  if ((a = match(line, "h")) || (a = match(line, "help"))) {
    bow_puts(help);
    return true;
  }
  if ((a = match(line, "test"))) {
    bool quick = false;
    uint32_t seed = 1;
    a = skip_spaces(a);
    if (match(a, "quick")) {
      quick = true;
      a += 5;
    }
    parse_num(a, &seed, false);
    return self_test(quick, seed);
  }
  if ((a = match(line, "kat"))) {
    kat();
    return true;
  }
  if ((a = match(line, "key"))) return cmd_key(a);
  if ((a = match(line, "enc"))) return cmd_crypt(a, false);
  if ((a = match(line, "dec"))) return cmd_crypt(a, true);
  if ((a = match(line, "bench"))) {
    bench();
    return true;
  }
  if ((a = match(line, "clear"))) {
    bow_mkv_clear();
    return true;
  }
  if ((a = match(line, "info"))) {
    info();
    return true;
  }
  if ((a = match(line, "baud"))) {
    if (!parse_num(a, &v, false) || v < 1200) return false;
    bow_printf("ok, switching to %u baud\n", v);
    bow_uart_flush(UART0);
    bow_uart_init(UART0, v);
    bow_delay_ms(100);
    return true;
  }
  if ((a = match(line, "rd"))) {
    if (!parse_num(a, &v, true)) return false;
    if (!bow_probe_read32(v & ~3u, &v2)) {
      bow_printf("%08x: bus error\n", v & ~3u);
      return false;
    }
    bow_printf("%08x: %08x\n", v & ~3u, v2);
    return true;
  }
  if ((a = match(line, "wr"))) {
    if (!(a = parse_num(a, &v, true)) || !parse_num(a, &v2, true)) return false;
    if (!bow_probe_write32(v & ~3u, v2)) {
      bow_printf("%08x: bus error\n", v & ~3u);
      return false;
    }
    return true;
  }
  bow_printf("unknown command, h for help\n");
  return false;
}

/* --------------------------------------------------------------------- main */
int main(void) {
  static char line[192];
  unsigned len = 0;
  int prev = 0;

  bow_uart_init(UART0, SYSCTRL->BOOT_BAUD);
  bow_printf("\nBow32 MKV block cipher demo (draft TCVN XXXX:2024), type h for help\n");
  if (bow_mkv_present()) {
    bow_printf("mkv: Bow32 MKV IP, MKV-128 + MKV-256, %u cycles per round, %u MHz\n",
               (MKV->INFO >> 8) & 0xFFu, bow_clk_hz() / 1000000u);
  } else {
    bow_printf("mkv: IP not found (ID %08x)\n", MKV->ID);
  }

  bow_puts("> ");
  for (;;) {
    int c = bow_uart_getc_nb(UART0);
    if (c == '\n' && prev == '\r') {
      /* second half of a CR LF line ending */
    } else if (c == '\r' || c == '\n') {
      line[len] = '\0';
      bow_puts("\n");
      if (len != 0) bow_puts(execute(line) ? "ok\n" : "error\n");
      bow_puts("> ");
      len = 0;
    } else if ((c == '\b' || c == 0x7f) && len != 0) {
      len--;
      bow_uart_puts(UART0, "\b \b");
    } else if (c >= ' ' && c < 0x7f && len < sizeof(line) - 1) {
      line[len++] = (char)c;
      bow_uart_putc(UART0, (char)c);
    }
    if (c >= 0) prev = c;
  }
}
