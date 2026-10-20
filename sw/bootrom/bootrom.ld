/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Boot ROM linker script. Code and constants in ROM, data/bss/stack in SRAM
 * (the application re-initialises the SRAM after the ROM jumps to it).
 */

INCLUDE bow32_memory.ld

OUTPUT_ARCH(riscv)
ENTRY(_rom_reset)

__stack_size = 0x800;

SECTIONS
{
  .vectors ORIGIN(ROM) :
  {
    KEEP(*(.vectors))
  } > ROM

  .text :
  {
    KEEP(*(.text.start))
    *(.text .text.*)
  } > ROM

  .rodata : ALIGN(4)
  {
    *(.rodata .rodata.* .srodata .srodata.*)
  } > ROM

  .data : ALIGN(4)
  {
    __data_start = .;
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    __data_end = .;
  } > SRAM AT > ROM
  __data_load = LOADADDR(.data);

  .bss (NOLOAD) : ALIGN(4)
  {
    __bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > SRAM

  __global_pointer$ = __data_start + 0x800;
  __stack_top = ORIGIN(SRAM) + LENGTH(SRAM);

  ASSERT(SIZEOF(.vectors) == 0x84, "ROM vector table must be 32 entries + reset vector")
  ASSERT(__bss_end + __stack_size <= __stack_top, "ROM: SRAM overflow")

  /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment) }
}
