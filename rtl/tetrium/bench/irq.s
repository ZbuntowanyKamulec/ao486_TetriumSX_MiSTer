# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# interrupt stress test (tb: -b -i N raises INTR every N cycles, INTA returns vector 8)
# The ISR is transparent, so registers and memory must match a run without
# interrupts; the counter and the stack live in the ignored window DS:F000-FFFF.
.intel_syntax noprefix
.code16
.org 0x100
start:
    xor  ax, ax
    mov  es, ax
    mov  word ptr es:[0x20], offset isr
    mov  es:[0x22], cs
    push ds
    pop  es
    sti
    mov  ax, 17
    push ax
    call fib
    add  sp, 2
    mov  [res], ax
    # string moves, interruptible mid-REP
    mov  si, offset src
    mov  di, 0x2000
    mov  cx, 1500
    cld
    rep  movsw
    mov  di, 0x4000
    mov  ax, 0x5aa5
    mov  cx, 700
    rep  stosw
    mov  si, 0x2000
    mov  di, 0x4000
    mov  cx, 300
    repe cmpsw
    mov  [res+2], cx
    # arithmetic loop with memory RMW
    mov  cx, 3000
    mov  bx, 0x6000
    xor  dx, dx
ar: mov  ax, cx
    mov  si, 7
    mul  si
    add  [bx], ax
    adc  [bx+2], dx
    xor  dx, dx
    div  si
    add  bx, 4
    and  bx, 0x6FFF
    shl  word ptr [bx], 1
    loop ar
    cli
    hlt
fib:
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
isr:
    push ax
    push bx
    mov  bx, 0xF000
    mov  ax, [bx]
    inc  ax
    mov  [bx], ax
    mov  [bx+2], sp
    pop  bx
    pop  ax
    iret
res: .word 0, 0
src: .fill 3000, 1, 0x3c
