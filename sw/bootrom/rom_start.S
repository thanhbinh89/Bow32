/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Boot ROM start-up. Ibex starts at boot_addr + 0x80 with mtvec = boot_addr
 * (vectored), so the ROM begins with the 32 entry vector table followed by
 * the reset vector at offset 0x80.
 */

  .section .vectors, "ax"
  .option push
  .option norvc
  .globl _rom_vectors
_rom_vectors:
  .rept 32
  j     rom_trap_entry
  .endr
  /* offset 0x80: reset vector */
  j     _rom_reset
  .option pop

  .section .text.start, "ax"
  .globl _rom_reset
_rom_reset:
  .option push
  .option norelax
  la    gp, __global_pointer$
  .option pop
  la    sp, __stack_top

  /* .data: ROM -> SRAM */
  la    a0, __data_load
  la    a1, __data_start
  la    a2, __data_end
1:
  bgeu  a1, a2, 2f
  lw    t0, 0(a0)
  sw    t0, 0(a1)
  addi  a0, a0, 4
  addi  a1, a1, 4
  j     1b
2:
  la    a1, __bss_start
  la    a2, __bss_end
3:
  bgeu  a1, a2, 4f
  sw    zero, 0(a1)
  addi  a1, a1, 4
  j     3b
4:
  call  rom_main
5:
  wfi
  j     5b

/* Interrupts stay disabled in the ROM, so only exceptions get here. */
rom_trap_entry:
  csrr  a0, mcause
  csrr  a1, mepc
  csrr  a2, mtval
  call  rom_trap
6:
  wfi
  j     6b
