# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Real-mode stack operands straddling offset FFFF (386 PRM table 14-1, SingleStepTests 80386
# 6660 / 61 / 6661): #SS (vector 12) from PUSHAD / PUSHA / PUSH r32 / POP / POPA / POPAD when
# a slot crosses the limit, POPA's (E)SP slot included; the slots before it are written /
# read (POPA keeps the registers popped before the fault); SP = 0 / FFFE wraps without a
# fault.  Last: PUSHA with SP = 5, its #SS frame crosses the limit too (#SS, #DF at the same
# SP): shutdown.  POPA overwrites every register, so the handler for an instruction of
# length N (vector 12 -> hN) skips it and counts in memory; ES = 0 (the vector table).
# The image is loaded at 1000:0000.
.intel_syntax noprefix
.code16
.org 0x100
.set resn, 0
.macro case sp, len, insn:vararg
    mov  word ptr es:[12*4], offset h\len
    mov  sp, \sp
    \insn
    mov  cs:[res + resn], sp
    .set resn, resn + 2
.endm
start:
    cli
    xor  ax, ax
    mov  es, ax
    mov  word ptr es:[12*4+2], 0x1000
    mov  word ptr es:[13*4], offset h13
    mov  word ptr es:[13*4+2], 0x1000
    mov  ax, 0x2000
    mov  ss, ax
    mov  eax, 0x11111111
    mov  ecx, 0x22222222
    mov  edx, 0x33333333
    mov  ebx, 0x44444444
    mov  ebp, 0x55555555
    mov  esi, 0x66666666
    mov  edi, 0x77777777
    case 6, 2, pushad
    case 9, 2, pushad
    case 0x1a, 2, pushad
    case 0, 2, pushad
    case 7, 1, pushaw
    case 2, 1, pushaw
    case 2, 2, push eax
    case 0xfff3, 1, popaw
    case 0xfff9, 1, popaw
    case 0xfff2, 2, popad
    case 0xfff9, 2, popad
    case 0xffff, 1, pop ax
    case 0xfffe, 1, popaw
    case 5, 1, pushaw
    hlt
h1: mov  bp, sp
    inc  word ptr [bp]
    inc  word ptr cs:[cnt]
    iret
h2: mov  bp, sp
    add  word ptr [bp], 2
    inc  word ptr cs:[cnt]
    iret
h13: inc  word ptr cs:[cnt + 2]
    hlt
    .p2align 2
cnt: .word 0, 0
res:
