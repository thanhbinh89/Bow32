/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Default trap handling. crt0.S saves the caller saved registers and calls
 * bow_trap_handler(); the value it returns is written back to mepc.
 *
 * Applications override the weak bow_irq_fast_handler() to handle the
 * peripheral interrupts (line numbers: BOW32_IRQ_FAST_* in bow32_memmap.h).
 *
 * bow_probe_read32/write32 (bow_probe.h) arm a flag; a load/store access
 * fault while it is armed skips the faulting instruction instead of stopping.
 */
#include "bow32.h"

#define MCAUSE_LOAD_FAULT  5u
#define MCAUSE_STORE_FAULT 7u

static volatile uint32_t probe_armed, probe_fault;

bool bow_probe_read32(uint32_t addr, uint32_t *value) {
  probe_fault = 0;
  probe_armed = 1;
  uint32_t v = *(volatile uint32_t *)(uintptr_t)addr;
  probe_armed = 0;
  if (probe_fault) return false;
  *value = v;
  return true;
}

bool bow_probe_write32(uint32_t addr, uint32_t value) {
  probe_fault = 0;
  probe_armed = 1;
  *(volatile uint32_t *)(uintptr_t)addr = value;
  probe_armed = 0;
  return !probe_fault;
}

__attribute__((weak)) void bow_irq_fast_handler(unsigned line) {
  /* Nobody handles this line: mask it to avoid an interrupt storm. */
  bow_irq_fast_disable(line);
  bow_printf("\n[trap] unhandled fast irq %u, masked\n", line);
}

__attribute__((weak)) void bow_exception_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
  static const char *const names[] = {
      "instr misaligned", "instr access fault", "illegal instr", "breakpoint",
      "load misaligned",  "load access fault",  "store misaligned", "store access fault",
      "ecall U",          "ecall S",            "reserved",       "ecall M",
  };
  const char *name = mcause < sizeof(names) / sizeof(names[0]) ? names[mcause] : "?";
  bow_printf("\n[trap] exception %u (%s) mepc=%08x mtval=%08x\n", mcause, name, mepc, mtval);
  for (;;) bow_wfi();
}

uint32_t bow_trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
  if (mcause & MCAUSE_IRQ_FLAG) {
    uint32_t code = MCAUSE_CODE(mcause);
    if (code >= 16 && code < 31) {
      bow_irq_fast_handler(code - 16);
    } else {
      bow_printf("\n[trap] unexpected interrupt %u\n", code);
    }
    return mepc;
  }
  if (probe_armed && (mcause == MCAUSE_LOAD_FAULT || mcause == MCAUSE_STORE_FAULT)) {
    /* Skip the access: 2 byte compressed or 4 byte instruction. */
    uint16_t insn = *(const volatile uint16_t *)(uintptr_t)mepc;
    probe_armed = 0;
    probe_fault = 1;
    return mepc + (((insn & 3u) == 3u) ? 4u : 2u);
  }
  bow_exception_handler(mcause, mepc, mtval);
  return mepc;
}
