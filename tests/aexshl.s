# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# A-executed SHL r,1 / SHL r,imm (count 1-3): results feeding addresses right away,
# chains of A-executed ops, 16-bit forms keeping the upper half, 32-bit forms (66),
# counts that are not A-executed (0, 4, 33 = 1 masked, 34), byte forms.
# Real mode .COM, run in lockstep by tests/lock.sh
.intel_syntax noprefix
.code16
.org 0x100
start:
    mov  bp, 200
    mov  di, offset buf
    xor  ax, ax
    mov  cx, 512
fill: mov [di], ax
    add  ax, 0x0137
    add  di, 2
    loop fill
outer:
    mov  si, bp
    and  si, 63
    # 16-bit: r + r and scaled forms, consumer right behind
    mov  bx, si
    shl  bx, 1
    mov  ax, [bx + buf]
    mov  bx, si
    shl  bx, 2
    add  ax, [bx + buf]
    mov  bx, si
    shl  bx, 3
    xor  ax, [bx + buf]
    # chain: A-executed producers back to back
    mov  di, si
    shl  di, 1
    shl  di, 1
    inc  di
    shl  di, 1
    mov  dx, [di + buf]
    add  ax, dx
    # source pending in E (load / ALU) -> executed in E
    mov  bx, [buf + 2]
    and  bx, 15
    shl  bx, 2
    mov  cx, [bx + buf]
    add  ax, cx
    # counts that are not A-executed
    mov  bx, si
    shl  bx, 0
    add  ax, [bx + buf]
    mov  bx, si
    shl  bx, 4
    add  ax, [bx + buf]
    mov  bx, si
    .byte 0xC1, 0xE3, 0x21     # shl bx, 33 (count 1)
    add  ax, [bx + buf]
    mov  bx, si
    .byte 0xC1, 0xE3, 0x22     # shl bx, 34 (count 2)
    add  ax, [bx + buf]
    # 16-bit forms keep EBX[31:16]; result wraps at 16 bits
    mov  ebx, 0x12348001
    shl  bx, 1
    mov  [res], ebx
    mov  ebx, 0xABCDC003
    shl  bx, 2
    mov  [res + 4], ebx
    mov  ebx, 0x8000F00F
    shl  bx, 3
    mov  [res + 8], ebx
    # 32-bit forms
    mov  ecx, 0x40000001
    shl  ecx, 1
    mov  [res + 12], ecx
    mov  ecx, 0x7FFFFFFF
    shl  ecx, 3
    mov  [res + 16], ecx
    movzx esi, si
    mov  edx, esi
    shl  edx, 2
    add  ax, [edx + buf]
    shl  edx, 1
    add  ax, [edx + buf]
    # byte forms and other registers
    mov  bl, 0x81
    shl  bl, 1
    shl  bl, 2
    mov  [res + 20], bl
    mov  sp, sp
    mov  cx, si
    shl  cx, 1
    mov  dx, cx
    shl  dx, 2
    add  ax, dx
    pushf
    pop  dx
    mov  [res + 22], dx
    mov  [res + 24], ax
    dec  bp
    jnz  outer
    hlt
.align 4
res: .space 32
buf: .space 1024
