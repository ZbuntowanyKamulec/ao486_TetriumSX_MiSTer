# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# double fault (#GP through a not-present gate); was: INT n through 16/32-bit interrupt / trap gates, IRET,
# exceptions with / without error codes (handlers log the error code and resume at
# the address in [resume]), far CALL / RET (n) between 32- and 16-bit code.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.macro gate off, sel, acc        # (handler offsets below 64 KB)
    .word \off
    .word \sel
    .byte 0, \acc
    .word 0
.endm
.macro try lbl                      # the next instruction may fault: resume at lbl
    mov  dword ptr [resume], offset \lbl
.endm
.code16
.org 0x100
start:
    cli
    lgdt [gdtr]
    lidt [idtr]
    mov  eax, cr0
    or   al, 1
    mov  cr0, eax
    .byte 0x66, 0xEA
    .long pm32
    .word 0x08
.code32
pm32:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  esp, 0xF000
    mov  ax, 0x500                  # #GP(500); its gate is not present: #DF(0)
    mov  ds, ax
    hlt
hdf:
    pop  eax                        # error code 0
    mov  [log], eax
    mov  ebx, [esp]
    hlt
.align 4
log:    .long 0
gdtr:   .word 0x17
        .long 0x10A00
idtr:   .word 14 * 8 - 1
        .long 0x10800
.org 0x800
idt:
    .fill 8, 8, 0
    gate hdf, 0x08, 0x8E                           # 8 #DF
    .fill 4, 8, 0
    gate hdf, 0x08, 0x0E                           # 13 #GP: not present
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32 4 GB
