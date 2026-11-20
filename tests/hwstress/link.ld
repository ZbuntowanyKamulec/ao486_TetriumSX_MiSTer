/* SPDX-License-Identifier: GPL-3.0-or-later
   Copyright (C) 2026 ZbuntowanyKamulec */
/* stress kernel at 10000h: entry.o first (MBR jumps to 1000:0000) */
ENTRY(_start)
SECTIONS
{
  . = 0x10000;
  .text : { entry.o(.text) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) }
  .cfg : { *(.cfg) }
  __bss_start = .;
  .bss : { *(.bss .bss.* COMMON) }
  __bss_end = .;
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
