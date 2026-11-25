# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Probe macros (included first): descriptors, gates, printing (PS text, PH value) through lib.s
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
# print a string literal
.macro PS text
    push esi
    mov  esi, offset 8f
    call puts
    pop  esi
    jmp  9f
8:  .asciz "\text"
9:
.endm
# print a value as 8 hex digits and a space
.macro PH val
    push eax
    mov  eax, \val
    call puthex
    pop  eax
.endm
