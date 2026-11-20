# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# string / block operations: memcpy, memset, memcmp, strlen, checksum
.intel_syntax noprefix
.code16
.org 0x100
start:
    mov  bp, 8
rep_lp:
    mov  si, offset src
    mov  cx, 2048
    xor  ax, ax
f1: mov  [si], ax
    add  ax, 0x0101
    add  si, 2
    loop f1
    mov  si, offset src         # memcpy 4 KB with movsw
    mov  di, offset dst
    mov  cx, 2048
    cld
    rep  movsw
    mov  si, offset src         # memcmp
    mov  di, offset dst
    mov  cx, 4096
    repe cmpsb
    mov  [cmpres], cx
    mov  di, offset dst         # memset
    mov  cx, 1024
    mov  ax, 0x2020
    rep  stosw
    mov  byte ptr [dst+1500], 0
    mov  di, offset dst         # strlen via scasb
    mov  cx, 0xFFFF
    xor  al, al
    repne scasb
    not  cx
    dec  cx
    mov  [slen], cx
    mov  si, offset src         # checksum via lodsw
    mov  cx, 2048
    xor  bx, bx
ck: lodsw
    add  bx, ax
    adc  bx, 0
    loop ck
    mov  [csum], bx
    dec  bp
    jnz  rep_lp
    hlt
cmpres: .word 0
slen:   .word 0
csum:   .word 0
src: .space 4096
dst: .space 4096
