# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# recursive fibonacci, C calling convention with BP frames
.intel_syntax noprefix
.code16
.org 0x100
start:
    mov  ax, 21
    push ax
    call fib
    add  sp, 2
    mov  [result], ax
    hlt
fib:                            # int fib(int n)
    push bp
    mov  bp, sp
    push si
    mov  ax, [bp+4]
    cmp  ax, 2
    jl   small
    dec  ax
    push ax
    call fib
    add  sp, 2
    mov  si, ax
    mov  ax, [bp+4]
    sub  ax, 2
    push ax
    call fib
    add  sp, 2
    add  ax, si
small:
    pop  si
    pop  bp
    ret
result: .word 0
