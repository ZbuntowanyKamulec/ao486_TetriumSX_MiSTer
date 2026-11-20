# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Byte sieve of Eratosthenes (BYTE magazine style), 8190 flags, 10 iterations
.intel_syntax noprefix
.code16
.org 0x100
start:
    mov  si, 10                 # iterations
iter:
    mov  di, offset flags
    mov  cx, 8191
    mov  al, 1
    rep  stosb                  # flags[] = 1
    xor  dx, dx                 # count
    xor  bx, bx                 # i
outer:
    cmp  byte ptr [flags+bx], 0
    je   next
    mov  ax, bx
    add  ax, ax
    add  ax, 3                  # prime = i+i+3
    mov  di, bx
    add  di, ax                 # k = i + prime
inner:
    cmp  di, 8190
    ja   done_k
    mov  byte ptr [flags+di], 0
    add  di, ax
    jmp  inner
done_k:
    inc  dx
next:
    inc  bx
    cmp  bx, 8190
    jbe  outer
    dec  si
    jnz  iter
    mov  [result], dx
    hlt
result: .word 0
flags:  .space 8192
