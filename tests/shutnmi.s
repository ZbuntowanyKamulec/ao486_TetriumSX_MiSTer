# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Shutdown left by NMI (DUT only, no 86Box lockstep: 86Box resets on a triple fault):
#   NMISHUT=1 build/sim/Vtetrium_core -b -con build/shutnmi.com   -> prints "NMI after shutdown"
# INT 40h beyond the IDT limit: #GP, #DF (also beyond), shutdown; the NMI gate (vector 2) is
# present: its handler writes the message at 2000:0000 and halts.
.intel_syntax noprefix
.code16
.org 0x100
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
    int  0x40
    hlt
hnmi:
    mov  esi, offset msg
    mov  edi, 0x10000
    mov  ecx, msgend - msg
    cld
    rep  movsb
    hlt
msg:    .ascii "NMI after shutdown\n"
        .byte 0
msgend:
.align 4
gdtr:   .word 0x17
        .long 0x10300
idtr:   .word 0x17
        .long 0x10280
.org 0x280
    .quad 0, 0
    .word hnmi, 0x08, 0x8E00, 0                # 2 NMI
.org 0x300
    .quad 0
    .word 0xFFFF, 0x0000, 0x9A01, 0x0040       # 08 code32, base 10000
    .word 0xFFFF, 0x0000, 0x9201, 0x00CF       # 10 data32, base 10000, 4 GB
