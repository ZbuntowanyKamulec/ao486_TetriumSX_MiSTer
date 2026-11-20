# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# V86 mode: IRETD to V86 (IOPL 3), real-mode style segment loads, INT n to a ring 0
# handler (data segments pushed, then null) and IRETD back, an I/O instruction refused by
# the TSS (#GP from V86, resumed by the ring 0 handler), the final INT halts at ring 0.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.macro gate off, sel, acc
    .word \off
    .word \sel
    .byte 0, \acc
    .word 0
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
    mov  ss, ax
    mov  esp, 0xF000
    mov  ax, 0x18
    ltr  ax
    push 0x0000                     # GS
    push 0x5000                     # FS
    push 0x3000                     # DS
    push 0x4000                     # ES
    push 0x7000                     # SS
    push 0xFFF0                     # SP
    push 0x00023002                 # EFLAGS: VM, IOPL 3
    push 0x1000                     # CS
    push offset v86
    iretd
.code16
v86:
    mov  ax, 0x6000
    mov  ds, ax
    mov  word ptr [0], 0x1234
    mov  bx, [0]
    push bx
    pop  cx
    mov  dx, ss
    cli
    sti
    int  0x21
    mov  si, ax
    in   al, 0x80                   # no I/O bitmap: #GP(0) to ring 0
    pushf
    pop  di
    int  0x22
.code32
h21:
    mov  eax, [esp+20]              # V86 SS from the frame
    shl  eax, 16
    mov  ax, [esp+24]               # V86 ES
    mov  bx, ds                     # null
    iretd
hgp:
    add  dword ptr [esp+4], 2       # skip IN AL, imm8
    add  esp, 0                     # (error code popped below)
    pop  eax
    iretd
h22:
    mov  ax, 0x10
    mov  ds, ax
    mov  eax, [esp+12]
    hlt
.align 4
gdtr:   .word 0x1F
        .long 0x10A00
idtr:   .word 0x23 * 8 - 1
        .long 0x10800
.org 0x700
tss:    .long 0, 0xE000, 0x10
        .fill 0x66 - 12, 1, 0
        .word 0x200                 # map base beyond the limit
.org 0x800
idt:
    .fill 13, 8, 0
    gate hgp, 0x08, 0x8E
    .fill 0x21 - 14, 8, 0
    gate h21, 0x08, 0xEE
    gate h22, 0x08, 0xEE
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x00000, 0xFFFFF, 0x92, 0xC       # 10 data32 4 GB, base 0
    desc 0x10700, 0x67, 0x89, 0            # 18 TSS32
