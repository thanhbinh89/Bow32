/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * LiteDRAM controller glue of bow_ddr v2 (bow_litedram.h): CSR access,
 * DFII software sections, power-up and the generated JEDEC init sequence,
 * read calibration with the raw capture of the Bow32 PHY (port of the v1
 * driver: the DFII replaces its manual command register), write phase scan
 * and closing checks with the LiteDRAM BIST, hand-over. The numbered steps
 * follow the sequence described in docs/ip/ddr.md (section "Khởi tạo, hiệu
 * chỉnh và bàn giao"; its numbering differs). The BIST
 * runs follow the CSR sequence of LiteX's liblitedram (bist.c).
 */
#include "bow32_memmap.h"

#define CSR_BASE BOW32_DDR_CTRL_BASE
#include <generated/sdram_phy.h>

#include "bow_litedram.h"
#include "bow_litedram_csrmap.h"
#include "bow_printf.h"
#include "bow_probe.h"
#include "bow_time.h"

/* From the DDR2 core's headers above only what both cores share is used:
 * the CSR map (bow_litedram_csrmap.h checks it for both) and the DFII bits.
 * Values of the core in use come from its bow_ld_core_t. */

#define RD(reg)    BOW_DDR_RD(reg)
#define WR(reg, v) BOW_DDR_WR(reg, v)

#define DFII_SW (DFII_CONTROL_CKE | DFII_CONTROL_ODT | DFII_CONTROL_RESET_N)
#define DFII_HW (DFII_CONTROL_SEL | DFII_SW)
_Static_assert(DFII_SW == BOW_LD_DFII_SW && DFII_HW == BOW_LD_DFII_HW &&
                   DFII_CONTROL_SEL == BOW_LD_DFII_SEL,
               "DFII control bits");

/* DRAM commands as DFII command bits ({RAS, CAS, WE} as on the pins, CS) */
#define CMD_PINS BOW_LD_CMD_PINS
#define CMD_MRS  BOW_LD_CMD_MRS
#define CMD_REF  BOW_LD_CMD_REF
#define CMD_PRE  BOW_LD_CMD_PRE
#define CMD_ACT  BOW_LD_CMD_ACT
#define CMD_WR   BOW_LD_CMD_WR
#define CMD_RD   BOW_LD_CMD_RD
#define CMD_ZQ   BOW_LD_CMD_ZQ
#define A10      BOW_LD_A10
_Static_assert(CMD_PINS == (DFII_COMMAND_RAS | DFII_COMMAND_CAS | DFII_COMMAND_WE | DFII_COMMAND_CS) &&
                   CMD_REF == (DFII_COMMAND_RAS | DFII_COMMAND_CAS | DFII_COMMAND_CS) &&
                   CMD_PRE == (DFII_COMMAND_RAS | DFII_COMMAND_WE | DFII_COMMAND_CS) &&
                   CMD_ACT == (DFII_COMMAND_RAS | DFII_COMMAND_CS) &&
                   CMD_WR == (DFII_COMMAND_CAS | DFII_COMMAND_WE | DFII_COMMAND_CS | DFII_COMMAND_WRDATA) &&
                   CMD_RD == (DFII_COMMAND_CAS | DFII_COMMAND_CS | DFII_COMMAND_RDDATA) &&
                   CMD_ZQ == (DFII_COMMAND_WE | DFII_COMMAND_CS) && BOW_LD_CMD_NOP == DFII_COMMAND_CS &&
                   BOW_LD_DFII_CKE == DFII_CONTROL_CKE,
               "DFII command bits");

/* the registers of phase n are those of phase 0 + n * PI_STRIDE */
#define PI_STRIDE (CSR_SDRAM_DFII_PI1_COMMAND_ADDR - CSR_SDRAM_DFII_PI0_COMMAND_ADDR)
_Static_assert(CSR_SDRAM_DFII_PI3_RDDATA_ADDR == CSR_SDRAM_DFII_PI0_RDDATA_ADDR + 3 * PI_STRIDE,
               "DFII phase stride");

#define READY_TIMEOUT_US 1000u
#define CAP_TIMEOUT_US   100u
#define QUIESCE_US       20u   /* > 2 tREFI: a refresh closed the rows of the bank machines */

static const bow_ld_core_t *core = &bow_ld_core_ddr2; /* of the last init */
static uint32_t wbytes = 8u;                          /* native word */
static uint32_t mem_bytes;                            /* DRAM size */
static bool inited;                                   /* JEDEC init done, DFII sections allowed */

/* ------------------------------------------------------------------- CSRs */
uint32_t bow_ld_csr_faults;

/* trace of the DFII writes of init_sequence() */
static struct {
  bool on;
  uint32_t n;
  uint32_t a[4], ba[4], cmd[4];   /* last address / baddress / command per phase */
  bow_ld_trace_t e[BOW_LD_TRACE_MAX];
} tr;

static void trace_write(uint32_t addr, uint32_t v) {
  const uint32_t pi0 = (uint32_t)CSR_SDRAM_DFII_PI0_COMMAND_ADDR;
  if (addr == (uint32_t)CSR_SDRAM_DFII_CONTROL_ADDR) {
    if (tr.n < BOW_LD_TRACE_MAX) tr.e[tr.n++] = (bow_ld_trace_t){.kind = 'c', .cmd = (uint8_t)v};
    return;
  }
  if (addr < pi0 || addr >= pi0 + 4u * (uint32_t)PI_STRIDE) return;
  uint32_t ph = (addr - pi0) / (uint32_t)PI_STRIDE;
  uint32_t reg = addr - ph * (uint32_t)PI_STRIDE;  /* the phase 0 register */
  if (reg == (uint32_t)CSR_SDRAM_DFII_PI0_ADDRESS_ADDR) {
    tr.a[ph] = v;
  } else if (reg == (uint32_t)CSR_SDRAM_DFII_PI0_BADDRESS_ADDR) {
    tr.ba[ph] = v;
  } else if (reg == (uint32_t)CSR_SDRAM_DFII_PI0_COMMAND_ADDR) {
    tr.cmd[ph] = v;
  } else if (reg == (uint32_t)CSR_SDRAM_DFII_PI0_COMMAND_ISSUE_ADDR && tr.n < BOW_LD_TRACE_MAX) {
    tr.e[tr.n++] = (bow_ld_trace_t){.kind = 'x', .phase = (uint8_t)ph, .cmd = (uint8_t)tr.cmd[ph],
                                    .ba = (uint8_t)tr.ba[ph], .a = (uint16_t)tr.a[ph]};
  }
}

uint32_t bow_ld_csr_read(uint32_t addr) {
  uint32_t v;
  if (bow_probe_read32(addr, &v)) return v;
  bow_ld_csr_faults++;
  return 0;
}

void bow_ld_csr_write(uint32_t addr, uint32_t value) {
  if (!bow_probe_write32(addr, value)) bow_ld_csr_faults++;
  if (tr.on) trace_write(addr, value);
}

bool bow_ld_csr_ok(void) {
  uint32_t v;
  return bow_probe_read32((uint32_t)CSR_DDRCTRL_INIT_DONE_ADDR, &v);
}

/* LiteX: i iterations of a CPU loop (25 .. 40 ns on its usual CPUs). The
 * generated sequences assume >= 10 ns per count (DDR3: 50000 for the 500 us
 * from RESET# high to CKE high); 25 ns keeps the 200 counts after the ZQCL
 * at 5 us (tZQinit = 512 nCK = 4.1 us at 125 MHz). */
void cdelay(int i) {
  if (i <= 0) return;
  bow_delay_cycles((uint32_t)(((uint64_t)(uint32_t)i * bow_clk_hz() + 39999999u) / 40000000u));
}

/* ---------------------------------------------------------------- helpers */
static bool fail(bool verbose, const char *what) {
  if (verbose) bow_printf("ddr: %s\n", what);
  return false;
}

static void wait_us(uint32_t us) { bow_delay_us(us + us / 16u + 2u); } /* clock tolerance */

static void wait_ck(uint32_t n) {
  uint32_t hz = RD(CLK_HZ);
  bow_delay_us((uint32_t)(((uint64_t)n * 1000000u + hz - 1u) / (hz ? hz : 1u)) + 1u);
}

const bow_ld_core_t *bow_ld_core(const bow_ddr_info_t *info) {
  return info->ddr3 ? &bow_ld_core_ddr3 : &bow_ld_core_ddr2;
}

bool bow_ld_inited(void) { return inited; }

uint32_t bow_ld_dfii_control(void) { return sdram_dfii_control_read(); }

/* ------------------------------------------------------------------- DFII */
static uint32_t sw_t0, sw_max;  /* cycles: start of the open section, longest section */

void bow_ld_dfii_cmd(uint32_t ph, uint32_t cmd, uint32_t ba, uint32_t a) {
  unsigned long o = ph * PI_STRIDE;
  csr_write_simple(a, CSR_SDRAM_DFII_PI0_ADDRESS_ADDR + o);
  csr_write_simple(ba, CSR_SDRAM_DFII_PI0_BADDRESS_ADDR + o);
  csr_write_simple(cmd, CSR_SDRAM_DFII_PI0_COMMAND_ADDR + o);
  csr_write_simple(1, CSR_SDRAM_DFII_PI0_COMMAND_ISSUE_ADDR + o);
}

/* native word (of the last init) <-> the four phases: phase n = bytes
 * n q .. n q + q - 1, q = W / 4 */
void bow_ld_dfii_wrdata(const uint8_t *b) {
  uint32_t q = wbytes / 4u;
  for (uint32_t ph = 0; ph < 4u; ph++) {
    uint32_t v = 0;
    for (uint32_t j = 0; j < q; j++) v |= (uint32_t)b[ph * q + j] << (8u * j);
    csr_write_simple(v, CSR_SDRAM_DFII_PI0_WRDATA_ADDR + ph * PI_STRIDE);
  }
}

void bow_ld_dfii_rddata(uint8_t *b) {
  uint32_t q = wbytes / 4u;
  for (uint32_t ph = 0; ph < 4u; ph++) {
    uint32_t v = (uint32_t)csr_read_simple(CSR_SDRAM_DFII_PI0_RDDATA_ADDR + ph * PI_STRIDE);
    for (uint32_t j = 0; j < q; j++) b[ph * q + j] = (uint8_t)(v >> (8u * j));
  }
}

/* Software section: the controller's refresher no longer reaches the DRAM.
 * refresh: PREA + REF first (the DRAM was refreshed just now, whatever the
 * refresher was doing). Keep it short, no print until bow_ld_sw_end. */
void bow_ld_sw_begin(bool refresh) {
  csr_write_simple(DFII_SW, CSR_SDRAM_DFII_CONTROL_ADDR);
  sw_t0 = bow_cycles();
  bow_delay_us(1); /* tRFC / tZQCS of a command the controller just issued */
  if (refresh) {
    bow_ld_dfii_cmd(0, CMD_PRE, 0, A10); /* PREA */
    bow_ld_dfii_cmd(0, CMD_REF, 0, 0);
    bow_delay_us(1); /* tRFC */
  }
}

void bow_ld_sw_end(void) {
  csr_write_simple(DFII_HW, CSR_SDRAM_DFII_CONTROL_ADDR);
  uint32_t d = bow_cycles() - sw_t0;
  if (d > sw_max) sw_max = d;
}

uint32_t bow_ld_sw_max_us(void) {
  uint32_t mhz = bow_clk_hz() / 1000000u;
  return sw_max / (mhz ? mhz : 1u);
}

void bow_ld_sw_max_clear(void) { sw_max = 0; }

bool bow_ld_burst_write(uint32_t ba, uint32_t row, uint32_t col, const uint8_t *burst) {
  uint32_t f = bow_ld_csr_faults;
  if (!inited) return false;
  bow_ld_dfii_wrdata(burst); /* the wrdata registers reach the DFI with the WR */
  bow_ld_sw_begin(true);
  bow_ld_dfii_cmd(0, CMD_ACT, ba, row);
  bow_ld_dfii_cmd(core->wrphase, CMD_WR, ba, col);
  bow_ld_dfii_cmd(0, CMD_PRE, ba, 0);
  bow_ld_sw_end();
  return bow_ld_csr_faults == f;
}

bool bow_ld_burst_read(uint32_t ba, uint32_t row, uint32_t col, uint8_t *burst, bool cap) {
  uint32_t f = bow_ld_csr_faults;
  if (!inited || (cap && !bow_ddr_cap_arm())) return false;
  bow_ld_sw_begin(true);
  bow_ld_dfii_cmd(0, CMD_ACT, ba, row);
  bow_ld_dfii_cmd(core->rdphase, CMD_RD, ba, col);
  bow_delay_us(1); /* the DFII latches the read data (read latency) in software control */
  bow_ld_dfii_cmd(0, CMD_PRE, ba, 0);
  bow_ld_sw_end();
  if (burst) bow_ld_dfii_rddata(burst);
  bool ok = !cap || bow_ddr_cap_wait(CAP_TIMEOUT_US);
  return ok && bow_ld_csr_faults == f;
}

/* --------------------------------------------------------------- bring-up */
bool bow_ld_stop(void) {
  uint32_t ctrl = RD(CTRL);
  inited = false;
  if (bow_ld_csr_ok()) {
    uint32_t dfii = sdram_dfii_control_read();
    bool ready = ddrctrl_init_done_read() && !ddrctrl_init_error_read();
    bool running = (ctrl & DDR_CTRL_EN) && (dfii & (DFII_CONTROL_SEL | DFII_CONTROL_CKE));
    ddrctrl_init_done_write(0);
    ddrctrl_init_error_write(0);
    if (running) {                 /* close the rows before CKE drops */
      if (ready) bow_delay_us(QUIESCE_US);
      csr_write_simple(DFII_SW, CSR_SDRAM_DFII_CONTROL_ADDR);
      bow_delay_us(1);
      bow_ld_dfii_cmd(0, CMD_PRE, 0, A10);
    }
    sdram_dfii_control_write(0);
  }
  return bow_ddr_set_ctrl(ctrl & ~DDR_CTRL_EN);
}

uint32_t bow_ld_init_trace(const bow_ld_trace_t **t) {
  *t = tr.e;
  return tr.n;
}

static char *put_str(char *p, const char *s) {
  while (*s) *p++ = *s++;
  return p;
}

static char *put_hex(char *p, uint32_t v, unsigned digits) {
  static const char hex[] = "0123456789abcdef";
  while (digits--) *p++ = hex[(v >> (4u * digits)) & 15u];
  return p;
}

void bow_ld_trace_str(const bow_ld_trace_t *e, char *buf) {
  static const char *const ctl[4] = {"SEL", "CKE", "ODT", "RESET_N"};
  char *p = buf;
  if (e->kind == 'c') {
    bool first = true;
    *p++ = '{';
    for (unsigned i = 0; i < 4u; i++) {
      if (!((e->cmd >> i) & 1u)) continue;
      if (!first) *p++ = ' ';
      p = put_str(p, ctl[i]);
      first = false;
    }
    if (first) *p++ = '-';
    *p++ = '}';
  } else {
    switch (e->cmd & CMD_PINS) {
      case CMD_MRS:
        p = put_str(p, "MR");
        *p++ = (char)('0' + (e->ba & 7u));
        *p++ = '=';
        p = put_hex(p, e->a, 4);
        break;
      case CMD_REF: p = put_str(p, "REF"); break;
      case CMD_PRE:
        if (e->a & A10) {
          p = put_str(p, "PREA");
        } else {
          p = put_str(p, "PRE");
          *p++ = (char)('0' + (e->ba & 7u));
        }
        break;
      case CMD_ACT:
        p = put_str(p, "ACT");
        *p++ = (char)('0' + (e->ba & 7u));
        break;
      case CMD_WR & CMD_PINS: p = put_str(p, "WR"); break;
      case CMD_RD & CMD_PINS: p = put_str(p, "RD"); break;
      case CMD_ZQ: p = put_str(p, (e->a & A10) ? "ZQCL" : "ZQCS"); break;
      case BOW_LD_CMD_NOP: p = put_str(p, "NOP"); break;
      default:
        *p++ = '?';
        p = put_hex(p, e->cmd, 2);
        break;
    }
    if (e->phase) {
      p = put_str(p, "@p");
      *p++ = (char)('0' + (e->phase & 3u));
    }
  }
  *p = '\0';
}

static void print_trace(void) {
  char buf[24];
  int col = bow_printf("ddr: init sequence:");
  for (uint32_t i = 0; i < tr.n; i++) {
    bow_ld_trace_str(&tr.e[i], buf);
    int len = 0;
    while (buf[len]) len++;
    if (col + 1 + len > 96) col = bow_printf("\nddr:  ") - 1;
    col += bow_printf(" %s", buf);
  }
  bow_puts("\n");
}

bool bow_ld_init(const bow_ddr_config_t *c, bool verbose) {
  bow_ddr_info_t info;
  if (!bow_ddr_probe(&info)) return fail(verbose, "init: no DDR IP (or the stub)");
  const bow_ld_core_t *k = bow_ld_core(&info);
  if (k->databits != info.dq_bits || (1u << info.mem_log2) != k->mem_bytes) {
    if (verbose) {
      bow_printf("ddr: init: INFO %08x (x%u, %u MiB) does not match the LiteDRAM %s core (x%u, %u MiB)\n",
                 info.info, info.dq_bits, (1u << info.mem_log2) >> 20, k->name, k->databits,
                 k->mem_bytes >> 20);
    }
    return false;
  }
  if (c->ddr3 != k->ddr3 || c->rl != k->cl || c->wl != k->cwl) {
    if (verbose) {
      bow_printf("ddr: init: configuration %s RL %u WL %u, the LiteDRAM core is %s CL %u CWL %u\n",
                 c->ddr3 ? "DDR3" : "DDR2", c->rl, c->wl, k->name, k->cl, k->cwl);
    }
    return false;
  }
  if (c->rl < (uint32_t)c->rdir_lead + c->oe_pre) {
    return fail(verbose, "init: RL must be >= RDIR_LEAD + OE_PRE");
  }
  if (!bow_ddr_wait_clk(10)) {
    return fail(verbose, "init: DDR clock not running or link down (STATUS.CLK_OK = 0)");
  }
  uint32_t ctrl = bow_ddr_config_ctrl(c, &info), lat = bow_ddr_config_lat(c);
  if (verbose) {
    bow_printf("ddr: init %s (LiteDRAM core: CL %u CWL %u, controller %u Hz), CK %u Hz, CTRL %08x LAT %08x\n",
               k->name, k->cl, k->cwl, k->ctrl_hz, info.clk_hz, ctrl, lat);
    uint32_t ctrl_hz = info.clk_hz / 4u;
    if (ctrl_hz + ctrl_hz / 32u < k->ctrl_hz || ctrl_hz > k->ctrl_hz + k->ctrl_hz / 32u) {
      bow_printf("ddr: warning: CK / 4 = %u Hz, the core's timing and refresh assume %u Hz\n",
                 ctrl_hz, k->ctrl_hz);
    }
  }
  core = k;
  wbytes = info.word_bytes;
  mem_bytes = 1u << info.mem_log2;
  tr.n = 0;

  /* 1 a running DRAM stops (rows closed, CKE low), fresh controller state */
  if (!bow_ld_stop()) return fail(verbose, "init: APPLY refused (CTRL.EN = 0)");
  if (!bow_ddr_core_reset(true)) return fail(verbose, "init: APPLY refused (CTRL.CORE_RST)");
  bow_delay_us(2);
  if (!bow_ddr_core_reset(false)) return fail(verbose, "init: LiteDRAM CSRs do not answer after CORE_RST");
  WR(STATUS, DDR_ST_W1C);
  uint32_t f0 = bow_ld_csr_faults;
  /* 2 DFII software control: no command, CKE / ODT / RESET# low; PHY on */
  sdram_dfii_control_write(0);
  if (sdram_dfii_control_read() != 0 || bow_ld_csr_faults != f0) {
    return fail(verbose, "init: LiteDRAM dfii_control does not read back 0 (CSR bridge)");
  }
  WR(LAT, lat);
  if (!bow_ddr_set_ctrl(ctrl)) return fail(verbose, "init: APPLY refused (CTRL / LAT)");
  /* 3 power-up: DDR2 200 us of CK with CKE low; DDR3 200 us with RESET#
   * low (the sequence then waits 500 us between RESET# and CKE high) */
  wait_us(200);
  /* 4 the JEDEC sequence of the core, then tZQinit (DDR3 ZQCL 512 nCK) /
   * tDLLK (DDR2 200 nCK after the DLL reset) */
  tr.on = true;
  k->init_sequence();
  tr.on = false;
  wait_ck(1024);
  /* 5 hardware control: the controller refreshes, the window stays blocked
   * until the hand-over (ddrctrl init_done) */
  sdram_dfii_control_write(DFII_HW);
  uint32_t st = RD(STATUS);
  if (verbose) print_trace();
  if (bow_ld_csr_faults != f0 || (st & (DDR_ST_CSR_ERR | DDR_ST_CMD_ERR))) {
    if (verbose) bow_printf("ddr: init: CSR access failed (STATUS %08x)\n", st);
    return false;
  }
  inited = true;
  if (verbose) bow_puts("ddr: init done, LiteDRAM refresh on (DFII hardware control), not handed over\n");
  return true;
}

bool bow_ld_handover(bool ok) {
  if (inited) {                    /* rows closed: the bank machines start with every bank closed */
    /* an open native port (a failed check after the hand-over: cal_abort,
     * calw) is blocked first, so that no window access runs beside the
     * DFII section and the controller's rows are closed by a refresh */
    bow_ld_quiesce(NULL);
    bow_ld_sw_begin(false);
    bow_ld_dfii_cmd(0, CMD_PRE, 0, A10);
    bow_ld_sw_end();
  } else {
    ok = false;
  }
  ddrctrl_init_error_write(ok ? 0u : 1u);
  ddrctrl_init_done_write(1);
  if (!ok) return false;
  uint32_t start = bow_cycles(), limit = READY_TIMEOUT_US * (bow_clk_hz() / 1000000u);
  while (!(RD(STATUS) & DDR_ST_READY)) {
    if ((uint32_t)(bow_cycles() - start) > limit) return false;
  }
  return true;
}

void bow_ld_quiesce(bool *was_ready) {
  if (was_ready) *was_ready = (RD(STATUS) & DDR_ST_READY) != 0;
  if (ddrctrl_init_done_read() && !ddrctrl_init_error_read()) { /* native port open */
    ddrctrl_init_done_write(0);
    bow_delay_us(QUIESCE_US);
  }
}

bool bow_ld_release(bool was_ready) { return !was_ready || bow_ld_handover(true); }

/* ------------------------------------------------------------ calibration */
#define CAL_MAX_POINTS 512u

static int8_t cal_map[CAL_MAX_POINTS];

/* Training pattern P (x8 beats); x16 lanes carry P on the low byte and ~P
 * on the high byte. Column 0 holds P, column 8 ~P. */
static const uint8_t cal_p[8] = {0xA5, 0x5A, 0xF0, 0x0F, 0xC3, 0x3C, 0x96, 0x69};

static void cal_burst(uint8_t d[16], bool x16, bool inv) {
  for (uint32_t i = 0; i < 8u; i++) {
    uint8_t v = inv ? (uint8_t)~cal_p[i] : cal_p[i];
    if (x16) {
      d[2u * i] = v;
      d[2u * i + 1u] = (uint8_t)~v;
    } else {
      d[i] = v;
    }
  }
}

/* Beat offset of P in the raw capture (beat 2i = rise of CAP[i], 2i+1 =
 * fall): smallest p in 0..56 with B[p..p+7] = P, -1 when absent. */
static int cal_find(uint32_t dq) {
  uint16_t b[64];
  uint32_t mask = dq == 16u ? 0xFFFFu : 0xFFu;
  for (uint32_t i = 0; i < 32u; i++) {
    uint32_t c = RD(CAP[i]);
    b[2u * i] = (uint16_t)(c & mask);
    b[2u * i + 1u] = (uint16_t)((c >> dq) & mask);
  }
  for (int p = 0; p <= 56; p++) {
    uint32_t j = 0;
    for (; j < 8u; j++) {
      uint32_t want = cal_p[j];
      if (dq == 16u) want |= (uint32_t)(uint8_t)~cal_p[j] << 8;
      if (b[p + (int)j] != want) break;
    }
    if (j == 8u) return p;
  }
  return -1;
}

/* ACT, RD with raw capture, PRE of bank 0 row 0: found(p), -1 absent, -2
 * no capture / CSR error */
static int cal_measure(uint32_t dq) {
  if (!bow_ld_burst_read(0, 0, 0, NULL, true)) return -2;
  return cal_find(dq);
}

static char cal_char(int p) {
  static const char digits[] = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTU";
  return p < 0 ? '.' : digits[p];
}

/* "ddr: eye |...6666666....5555555..| phase 140 width 160 p 6" (64 points
 * per line); a point shows the beat offset p of the pattern, '.' none. */
static void cal_print(const int8_t *map, uint32_t npts, const bow_ld_cal_t *r, bool ok,
                      bool write) {
  char buf[65];
  uint32_t n = 0;
  bow_puts(write ? "ddr: write eye |" : "ddr: eye |");
  for (uint32_t i = 0; i < npts; i++) {
    buf[n++] = write ? (map[i] > 0 ? '#' : '.') : cal_char(map[i]);
    if (n == 64u || i + 1u == npts) {
      buf[n] = '\0';
      bow_puts(buf);
      n = 0;
      if (i + 1u < npts) bow_puts("\n          ");
    }
  }
  if (!ok) {
    bow_printf("| no eye (%u of %u points good)\n", r->good, npts);
  } else if (write) {
    bow_printf("| write phase %d width %u\n", r->wphase, r->wwidth);
  } else {
    bow_printf("| phase %d width %u p %d\n", r->phase, r->width, r->p);
  }
}

typedef struct {
  uint32_t dq, steps, step, npts;
  bool x16;
  bool synced;    /* the sweep re-synchronised the read FIFO (read latency may have moved) */
} cal_ctx_t;

static bool cal_fail(bow_ld_cal_t *r, bool verbose, const char *why) {
  r->err = why;
  if (verbose) bow_printf("ddr: calibration failed: %s\n", why);
  return false;
}

/* a failed calibration: init_error = 1, the window stays blocked */
static bool cal_abort(bow_ld_cal_t *r, bool verbose, const char *why) {
  cal_fail(r, verbose, why);
  bow_ld_handover(false);
  return false;
}

/* Column 0 = P, column 8 = ~P through the read path of the PHY (RD_DLY /
 * RD_SLIP of LAT), the DFI adapter (read latency) and the DFII. NULL: ok,
 * else the reason. */
static const char *cal_verify(bool x16) {
  uint8_t want[16], got[16];
  bool ok = true, match = true;
  WR(STATUS, DDR_ST_RD_LATE | DDR_ST_RD_EXTRA);
  for (uint32_t c = 0; ok && c < 2u; c++) {
    cal_burst(want, x16, c != 0);
    ok = bow_ld_burst_read(0, 0, 8u * c, got, false);
    for (uint32_t i = 0; ok && i < wbytes; i++) match = match && got[i] == want[i];
  }
  uint32_t st = RD(STATUS);
  if (!ok) return "DFII read in the verification (CSR error)";
  if (st & DDR_ST_RD_LATE) return "RD_LATE: RD_DLY beyond the read latency of the DFI adapter";
  if (st & DDR_ST_RD_EXTRA) return "RD_EXTRA: read bursts without a read";
  if (!match) return "verification read differs from the pattern";
  return NULL;
}

bool bow_ld_eye_analyse(const int8_t *map, uint32_t n, uint32_t step, uint32_t steps,
                        bow_ld_cal_t *r) {
  /* Widest run of points with the same p. The sweep is cyclic: one CK
   * period later the FIFO delivers the data one stream cycle earlier, so a
   * run continues from the last point into point 0 when p(0) - 2 equals
   * the last p. */
  uint32_t best = 0, best_len = 0;
  for (uint32_t s = 0; s < n; s++) {
    int ps = map[s];
    if (ps < 0) continue;
    int prev = s ? map[s - 1u] : map[n - 1u] + 2;
    if (map[s ? s - 1u : n - 1u] >= 0 && prev == ps) continue; /* not a run start */
    uint32_t len = 1;
    while (len < n) {
      uint32_t j = s + len;
      int v = map[j % n];
      if (v < 0 || v - 2 * (int)(j / n) != ps) break;
      len++;
    }
    if (len > best_len) {
      best = s;
      best_len = len;
    }
  }
  r->width = best_len * step;
  bool eye = best_len > 0 && 5u * r->width >= steps;
  if (eye) {
    uint32_t last = best + best_len - 1u;
    int32_t ka = (int32_t)(best * step);
    int32_t kb = (int32_t)((last % n) * step + (last / n) * steps);
    int32_t kc = (ka + kb) / 2;
    r->p = map[best];
    if (kc >= (int32_t)steps) { /* back into the swept period: data one stream cycle later */
      kc -= (int32_t)steps;
      r->p += 2;
    }
    r->phase = kc;
  }
  return eye;
}

/* Steps 1..4: training pattern, sweep, widest eye. */
static bool cal_sweep(cal_ctx_t *k, uint32_t step, bool verbose, bow_ld_cal_t *r) {
  uint8_t burst[16];
  k->dq = DDR_INFO_DQ(RD(INFO));
  k->x16 = k->dq == 16u;
  k->steps = bow_ddr_ps_steps();
  if (!inited) return cal_fail(r, verbose, "DRAM not initialised (init)");
  if (k->steps == 0) return cal_fail(r, verbose, "PS_NOW reports 0 phase steps");
  if (step > k->steps / 8u) step = k->steps / 8u; /* at least 8 points */
  if (step == 0) step = 1;
  if (k->steps / step > CAL_MAX_POINTS) step = (k->steps + CAL_MAX_POINTS - 1u) / CAL_MAX_POINTS;
  k->step = step;
  k->npts = (k->steps + step - 1u) / step;
  r->step = step;
  r->npts = k->npts;
  if (RD(STATUS) & DDR_ST_BUSY) return cal_fail(r, verbose, "command channel busy");
  /* 1 read phase 0, FIFO synchronised there */
  k->synced = true;
  if (!bow_ddr_ps_goto_sync(0)) return cal_fail(r, verbose, "PS_GO / RFIFO_SYNC to phase 0");
  /* 2 P at column 0, ~P at column 8 of bank 0 row 0 */
  cal_burst(burst, k->x16, false);
  bool ok = bow_ld_burst_write(0, 0, 0, burst);
  cal_burst(burst, k->x16, true);
  ok = ok && bow_ld_burst_write(0, 0, 8, burst);
  if (!ok) return cal_fail(r, verbose, "DFII write of the training pattern (CSR error)");
  /* 3 sweep one CK period */
  r->good = 0;
  for (uint32_t i = 0; i < k->npts; i++) {
    if (!bow_ddr_ps_set((int32_t)(i * step))) return cal_fail(r, verbose, "PS_GO refused in the sweep");
    int f = cal_measure(k->dq);
    if (f == -2) return cal_fail(r, verbose, "no raw capture (CAP_DONE) or CSR error in the sweep");
    cal_map[i] = (int8_t)f;
    if (f >= 0) r->good++;
  }
  /* 4 widest eye */
  bool eye = bow_ld_eye_analyse(cal_map, k->npts, step, k->steps, r);
  if (verbose) cal_print(cal_map, k->npts, r, eye, false);
  if (!eye) return cal_fail(r, verbose, "no eye of 20 % of a CK period");
  return true;
}

bool bow_ld_eye(uint32_t step, bool verbose, bow_ld_cal_t *res) {
  cal_ctx_t k = {0};
  bow_ld_cal_t tmp;
  bool ready;
  uint8_t keep[2][16];
  if (!res) res = &tmp;
  *res = (bow_ld_cal_t){0};
  int32_t old = bow_ddr_ps_now();
  bow_ld_quiesce(&ready);
  /* a calibrated memory holds data: keep the two native words the training
   * pattern overwrites (window offsets 0 .. 2 * word - 1) */
  if (ready && !(bow_ld_burst_read(0, 0, 0, keep[0], false) &&
                 bow_ld_burst_read(0, 0, 8, keep[1], false))) {
    res->err = "DFII read of the words under the training pattern (CSR error)";
    if (verbose) bow_printf("ddr: eye: %s\n", res->err);
    bow_ld_release(ready);
    return false;
  }
  bool ok = cal_sweep(&k, step, verbose, res);
  /* back to the old phase (the sweep synchronised the FIFO at phase 0, as
   * bow_ld_calibrate does), then READY again if it was */
  int32_t lim = 2 * (int32_t)k.steps;
  bool back = k.steps == 0 || (old >= -lim && old <= lim ? bow_ddr_ps_set(old)
                                                         : bow_ddr_ps_goto_sync(old));
  if (!back && verbose) bow_puts("ddr: eye: could not restore the phase\n");
  /* the FIFO sync may move the read data by a stream cycle, and a phase that
   * could not be restored leaves the sweep's last point: a calibrated memory
   * gets the window back only when the pattern still reads right (also when
   * the sweep itself failed after the sync), then with its words restored */
  if (ready && (k.synced || !back)) {
    const char *why = back ? cal_verify(k.x16) : "read phase not restored";
    if (!why && !(bow_ld_burst_write(0, 0, 0, keep[0]) && bow_ld_burst_write(0, 0, 8, keep[1]))) {
      why = "DFII write back of the words under the training pattern (CSR error)";
    }
    if (why) {
      res->err = why;
      if (verbose) bow_printf("ddr: eye: %s, run cal again (window blocked)\n", why);
      return false;
    }
  }
  if (!bow_ld_release(ready)) {
    if (verbose) bow_puts("ddr: eye: STATUS.READY did not come back\n");
    return false;
  }
  return ok && back;
}

bool bow_ld_calibrate(uint32_t step, bool verbose, bow_ld_cal_t *res) {
  cal_ctx_t k;
  bow_ld_cal_t tmp;
  if (!res) res = &tmp;
  *res = (bow_ld_cal_t){0};
  res->wphase = bow_ddr_wps_now();
  bow_ld_quiesce(NULL);           /* the window stays blocked until the hand-over */
  WR(STATUS, DDR_ST_RD_LATE | DDR_ST_RD_EXTRA);
  if (!cal_sweep(&k, step, verbose, res)) return cal_abort(res, false, res->err);

  /* 5 centre of the eye, RD_DLY / RD_SLIP from the beat offset there */
  if (!bow_ddr_ps_set(res->phase)) return cal_abort(res, verbose, "PS_GO to the eye centre refused");
  int p = cal_measure(k.dq);
  if (p < 0) return cal_abort(res, verbose, "pattern not found at the eye centre");
  res->p = p;
  if ((p >> 1) < 4 || (p >> 1) - 4 > 31) return cal_abort(res, verbose, "RD_DLY out of 0..31");
  res->rd_dly = (uint32_t)(p >> 1) - 4u;
  res->rd_slip = (uint32_t)p & 1u;
  if (!bow_ddr_set_lat((RD(LAT) & ~DDR_LAT_RD_MASK) | DDR_LAT_RD_DLY(res->rd_dly) |
                       (res->rd_slip ? DDR_LAT_RD_SLIP : 0u))) {
    return cal_abort(res, verbose, "APPLY of RD_DLY refused");
  }
  /* verify: P / ~P through the normal read path */
  const char *why = cal_verify(k.x16);
  if (why) return cal_abort(res, verbose, why);

  /* 6 hand-over and a BIST check over the first 64 native words */
  if (!bow_ld_handover(true)) return cal_abort(res, verbose, "hand-over: STATUS.READY stays 0");
  bow_ld_bist_t b = {.base = 0, .length = 64u * wbytes, .random = true, .write = true, .read = true};
  bow_ld_bist_res_t br;
  bool bist = bow_ld_bist(&b, &br);
  res->bist_errors = br.errors;
  if (verbose) {
    bow_printf("ddr: read phase %d width %u p %d RD_DLY %u SLIP %u, BIST %u errors\n", res->phase,
               res->width, res->p, res->rd_dly, res->rd_slip, br.errors);
  }
  if (!bist) return cal_abort(res, verbose, "BIST check after the calibration");
  return true;
}

/* Check of a write phase over the first 64 native words: two BIST runs,
 * PRBS then counter data (a write that did not happen leaves the other data
 * set there and fails one of them). */
static bool wps_bist(bow_ld_bist_t *b) {
  b->random = true;
  bool pass = bow_ld_bist(b, NULL);
  b->random = false;
  return bow_ld_bist(b, NULL) && pass;
}

/* calw failed after its scan moved the write phase: back to the phase the
 * read calibration checked, with the same check there. If the move (a
 * PSDONE timeout can leave a partial step) or the check fails, block the
 * window (init_error): nothing reads window stores back, a bad write phase
 * would corrupt them silently. kept / blocked: the reason for each outcome
 * (CAL_WRITE_FAIL). */
static bool cal_write_fail(bow_ld_cal_t *r, bool verbose, int32_t old, bow_ld_bist_t *b,
                           const char *kept, const char *blocked) {
  bool back = bow_ddr_wps_set(old) && wps_bist(b);
  if (!back) bow_ld_handover(false);
  r->wphase = bow_ddr_wps_now();
  return cal_fail(r, verbose, back ? kept : blocked);
}

/* the kept / blocked arguments of cal_write_fail for one reason */
#define CAL_WRITE_FAIL(why)                    \
  "write phase: " why " (old phase kept)",     \
  "write phase: " why ", old phase fails too, run cal again (window blocked)"

bool bow_ld_cal_write(uint32_t step, bool verbose, bow_ld_cal_t *res) {
  bow_ld_cal_t tmp;
  if (!res) res = &tmp;
  res->err = NULL;
  if (DDR_INFO_PHY(RD(INFO)) == DDR_PHY_LOOPBACK) {
    return cal_fail(res, verbose, "write phase: not for the loopback emulator");
  }
  if (!bow_ddr_ready()) return cal_fail(res, verbose, "write phase: not READY (calibrate first)");
  uint32_t steps = bow_ddr_ps_steps();
  int32_t kk = (int32_t)(steps / 4u), old = bow_ddr_wps_now();
  if (step > (uint32_t)(2 * kk) / 8u) step = (uint32_t)(2 * kk) / 8u; /* at least 9 points */
  if (step == 0) step = 1;
  if ((uint32_t)(2 * kk) / step + 1u > CAL_MAX_POINTS) {
    step = ((uint32_t)(2 * kk) + CAL_MAX_POINTS - 2u) / (CAL_MAX_POINTS - 1u);
  }
  uint32_t npts = (uint32_t)(2 * kk) / step + 1u, best = 0, best_len = 0, good = 0;
  bow_ld_bist_t b = {.base = 0, .length = 64u * wbytes, .write = true, .read = true};
  for (uint32_t i = 0; i < npts; i++) {
    if (!bow_ddr_wps_set(-kk + (int32_t)(i * step))) {
      return cal_write_fail(res, verbose, old, &b, CAL_WRITE_FAIL("WPS_GO refused"));
    }
    bool pass = wps_bist(&b);
    cal_map[i] = (int8_t)(pass ? 1 : -1);
    if (pass) good++;
  }
  for (uint32_t s = 0; s < npts;) {
    if (cal_map[s] < 0) {
      s++;
      continue;
    }
    uint32_t a = s;
    while (s < npts && cal_map[s] > 0) s++;
    if (s - a > best_len) {
      best = a;
      best_len = s - a;
    }
  }
  res->good = good;
  res->wwidth = best_len * step;
  bool eye = best_len > 0 && 5u * res->wwidth >= (uint32_t)(2 * kk);
  if (eye) res->wphase = -kk + (int32_t)((2u * best + best_len - 1u) * step / 2u);
  if (verbose) cal_print(cal_map, npts, res, eye, true);
  if (!eye) return cal_write_fail(res, verbose, old, &b, CAL_WRITE_FAIL("passing range below 20 %"));
  if (!(bow_ddr_wps_set(res->wphase) && wps_bist(&b))) {
    return cal_write_fail(res, verbose, old, &b, CAL_WRITE_FAIL("BIST at the chosen phase"));
  }
  return true;
}

/* ------------------------------------------------------------------- BIST */
static uint32_t pow2_ceil(uint32_t v) {
  uint32_t p = 1;
  while (p < v) p <<= 1;
  return p;
}

/* 16 controller cycles per word (refresh, bank conflicts, window) + 10 ms */
static uint32_t bist_timeout_ms(uint32_t length) {
  uint32_t khz = RD(CLK_HZ) / 4000u;
  uint64_t cyc = (uint64_t)(length / wbytes) * 16u + 10000u;
  return (uint32_t)(cyc / (khz ? khz : 1u)) + 10u;
}

static bool bist_wait(unsigned long done, uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = timeout_ms * (bow_clk_hz() / 1000u), f = bow_ld_csr_faults;
  while (csr_read_simple(done) == 0) {
    if (bow_ld_csr_faults != f || (uint32_t)(bow_cycles() - start) > limit) return false;
  }
  return true;
}

/* Data PRBS31 or counter (random.data), sequential addresses (random.addr
 * = 0): word k at base + k W. end - base must be a power of two >= length
 * (the cores mask the address counter with end - base - 1). */
static bool bist_generate(const bow_ld_bist_t *b, uint32_t end, uint32_t tmo, uint32_t *ticks) {
  sdram_generator_reset_write(1);
  sdram_generator_random_write(b->random ? 1u : 0u);
  sdram_generator_base_write(b->base);
  sdram_generator_end_write(end);
  sdram_generator_length_write(b->length);
  sdram_generator_start_write(1);
  bool ok = bist_wait(CSR_SDRAM_GENERATOR_DONE_ADDR, tmo);
  *ticks = sdram_generator_ticks_read();
  if (!ok) sdram_generator_reset_write(1); /* stop it */
  return ok;
}

static bool bist_check(const bow_ld_bist_t *b, uint32_t end, uint32_t tmo, uint32_t *ticks,
                       uint32_t *errors) {
  sdram_checker_reset_write(1);
  sdram_checker_random_write(b->random ? 1u : 0u);
  sdram_checker_base_write(b->base);
  sdram_checker_end_write(end);
  sdram_checker_length_write(b->length);
  sdram_checker_start_write(1);
  bool ok = bist_wait(CSR_SDRAM_CHECKER_DONE_ADDR, tmo);
  *ticks = sdram_checker_ticks_read();
  *errors = sdram_checker_errors_read();
  if (!ok) sdram_checker_reset_write(1);
  return ok;
}

bool bow_ld_bist(const bow_ld_bist_t *b, bow_ld_bist_res_t *r) {
  bow_ld_bist_res_t tmp;
  if (!r) r = &tmp;
  *r = (bow_ld_bist_res_t){0};
  if (!inited || ((b->base | b->length) & (wbytes - 1u)) || b->length < wbytes ||
      b->length > (32u << 20) || b->base >= mem_bytes || b->length > mem_bytes - b->base) {
    return false;
  }
  uint32_t end = b->base + pow2_ceil(b->length), tmo = bist_timeout_ms(b->length);
  uint32_t f = bow_ld_csr_faults;
  bool ok = true;
  if (b->write) ok = bist_generate(b, end, tmo, &r->wr_ticks);
  if (ok && b->read) ok = bist_check(b, end, tmo, &r->rd_ticks, &r->errors);
  r->done = ok && bow_ld_csr_faults == f;
  return r->done && r->errors == 0;
}

uint32_t bow_ld_mbs100(uint32_t bytes, uint32_t ticks, uint32_t ck_hz) {
  if (ticks == 0) return 0;
  return (uint32_t)((uint64_t)bytes * (ck_hz / 4u) / ticks / 10000u);
}

/* Generator(31, n_state=31, taps=[27, 30]) of litedram/frontend/bist.py:
 * 31 shifts per word, new bit = !(s[27] ^ s[30]) into bit 0. */
static uint32_t prbs31(uint32_t s) {
  for (unsigned i = 0; i < 31u; i++) {
    uint32_t nv = ~((s >> 27) ^ (s >> 30)) & 1u;
    s = ((s << 1) | nv) & 0x7FFFFFFFu;
  }
  return s;
}

void bow_ld_gen_start(bow_ld_gen_t *g, bool random) {
  g->random = random;
  g->k = 0;
  g->o = random ? prbs31(0) : 0u;
}

void bow_ld_gen_next(bow_ld_gen_t *g) {
  g->k++;
  g->o = g->random ? prbs31(g->o) : (g->k & 0x7FFFFFFFu);
}

uint32_t bow_ld_gen_lane(const bow_ld_gen_t *g, uint32_t lane) {
  /* bit j of the native word = o[j mod 31], and 32 = 1 (mod 31) */
  uint64_t d = (uint64_t)g->o | ((uint64_t)g->o << 31);
  return (uint32_t)(d >> (lane % 31u));
}

/* ----------------------------------------------------------------- status */
void bow_ld_print_status(void) {
  bow_ddr_info_t info;
  uint32_t f = bow_ld_csr_faults;
  bow_ddr_probe(&info);
  uint32_t dfii = sdram_dfii_control_read();
  uint32_t done = ddrctrl_init_done_read(), err = ddrctrl_init_error_read();
  uint32_t gd = sdram_generator_done_read(), gt = sdram_generator_ticks_read();
  uint32_t cd = sdram_checker_done_read(), ct = sdram_checker_ticks_read();
  uint32_t ce = sdram_checker_errors_read();
  if (bow_ld_csr_faults != f) {
    bow_printf("  LiteDRAM: CSRs do not answer (STATUS %08x)\n", RD(STATUS));
    return;
  }
  bow_printf("  LiteDRAM %s core: dfii_control %02x (%s control), init_done %u init_error %u%s\n",
             bow_ld_core(&info)->name, dfii, (dfii & DFII_CONTROL_SEL) ? "hardware" : "software",
             done, err, inited ? "" : ", DRAM not initialised");
  bow_printf("  BIST: generator done %u ticks %u, checker done %u ticks %u errors %u\n", gd, gt, cd,
             ct, ce);
  bow_printf("  CSR faults %u, longest DFII software section %u us\n", bow_ld_csr_faults,
             bow_ld_sw_max_us());
}
