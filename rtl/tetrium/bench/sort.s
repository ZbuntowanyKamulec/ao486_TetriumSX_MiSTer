# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# bubble sort of 300 pseudo-random words
.intel_syntax noprefix
.code16
.org 0x100
start:
    mov  di, offset arr
    mov  cx, 300
    mov  ax, 12345
gen:
    mov  bx, ax
    shl  ax, 1
    shl  ax, 1
    add  ax, bx
    add  ax, 13849
    stosw
    loop gen
    mov  dx, 299                # passes
outer:
    mov  si, offset arr
    mov  cx, dx
    xor  bp, bp                 # swapped flag
inner:
    mov  ax, [si]
    mov  bx, [si+2]
    cmp  ax, bx
    jbe  noswap
    mov  [si], bx
    mov  [si+2], ax
    inc  bp
noswap:
    add  si, 2
    loop inner
    test bp, bp
    jz   sorted
    dec  dx
    jnz  outer
sorted:
    hlt
arr: .space 600
