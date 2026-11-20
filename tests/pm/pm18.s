# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Protected-mode far transfers that keep CS (predicted without a redirect, verified in E:
# same selector, the descriptor as last loaded): trained far CALL / RETF and far JMP to
# the code segment already in CS, far JMPs alternating between two selectors with the
# same descriptor (CS changes), then the trained far JMP once more after the
# descriptor's D bit was set in memory: the code behind it must run as 32-bit code (E's
# descriptor compare has to redirect the front end).  The image is loaded at 1000:0000.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.code16
.org 0x100
start:
    cli
    lgdt [gdtr]
    mov  eax, cr0
    or   al, 1
    mov  cr0, eax
    .byte 0xEA
    .word pm16, 0x08
pm16:
    mov  ax, 0x10
    mov  ds, ax
    mov  ss, ax
    mov  sp, 0xFFF0
    # far CALL / RETF to the same CS (trained after the first rounds)
    xor  si, si
    mov  cx, 40
1:  .byte 0x9A
    .word fnf, 0x08
    loop 1b
    # push cs / near call / RETF
    mov  cx, 40
2:  push cs
    call fnf
    loop 2b
    # CS alternates between two selectors with the same descriptor: always redirected
    mov  cx, 20
3:  .byte 0xEA
    .word 4f, 0x18
4:  mov  ax, cs
    add  di, ax
    .byte 0xEA
    .word 5f, 0x08
5:  mov  ax, cs
    add  di, ax
    loop 3b
    # trained far JMP to the same CS; before the last one the descriptor becomes 32-bit
    mov  ecx, 40
top:
    cmp  cx, 1
    jne  6f
    or   byte ptr [gdt + 8 + 6], 0x40
6:  .byte 0xEA
    .word lbl, 0x08
lbl:
    .byte 0xB8, 0x01, 0x00, 0x90, 0x90    # mov ax, 1; nop; nop  |  mov eax, 90900001
    loop top                              # (32-bit after the last JMP: ECX = 1 -> 0)
    hlt

fnf:
    inc  si
    retf

    .p2align 3
gdtr:
    .word gdt_end - gdt - 1
    .long 0x10000 + gdt
    .p2align 3
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9B, 0          # 08 code16 (accessed)
    desc 0x10000, 0xFFFF, 0x93, 0          # 10 data16
    desc 0x10000, 0xFFFF, 0x9B, 0          # 18 code16, same descriptor as 08
gdt_end:
