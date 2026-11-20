# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# bitwise CRC-16/CCITT over a 4 KB buffer, 4 passes
.intel_syntax noprefix
.code16
.org 0x100
start:
    # fill buffer with a pattern
    mov  di, offset buf
    mov  cx, 4096
    xor  ax, ax
fill:
    mov  [di], al
    add  al, 37
    xor  al, ah
    inc  ah
    inc  di
    loop fill
    mov  bp, 4
pass:
    mov  si, offset buf
    mov  cx, 4096
    mov  dx, 0xFFFF
byte_lp:
    lodsb
    xor  dh, al
    mov  bl, 8
bit_lp:
    shl  dx, 1
    jnc  nox
    xor  dx, 0x1021
nox:
    dec  bl
    jnz  bit_lp
    loop byte_lp
    dec  bp
    jnz  pass
    mov  [result], dx
    hlt
result: .word 0
buf: .space 4096
