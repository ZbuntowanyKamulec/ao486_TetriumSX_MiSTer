# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# self-modifying code idioms (store, then a jump, then the modified code runs)
.intel_syntax noprefix
.code16
.org 0x100
start:
    xor  si, si                 # checksum
# 1: patch the immediate of an instruction inside a loop
    mov  cx, 200
p1: .byte 0xB8                  # mov ax, imm16
p1i: .word 0
    add  si, ax
    mov  [p1i], cx              # next iteration loads cx
    jmp  short p1n
p1n:
    loop p1
# 2: generate "mov ax, imm16 / ret" into a buffer and call it
    mov  cx, 100
p2: mov  byte ptr [buf], 0xB8
    mov  [buf+1], cx
    mov  byte ptr [buf+3], 0xC3
    call buf
    add  si, ax
    loop p2
# 3: patch a conditional branch displacement (jz taken, alternating target)
    mov  cx, 64
p3: mov  al, cl
    and  al, 1
    mov  ah, al
    add  al, al
    add  al, ah                 # displacement 0 or 3
    mov  [p3d], al
    jmp  short p3j
p3j: cmp  ax, ax
    .byte 0x74                  # jz rel8
p3d: .byte 0
    add  si, 3                  # 3 bytes, skipped when displacement = 3
    inc  si
    loop p3
# 4: write code into a line that was never fetched, then jump to it
    mov  word ptr [far1], 0xC681    # add si, imm16
    mov  word ptr [far1+2], 0x1234
    mov  byte ptr [far1+4], 0xC3    # ret
    call far1
    mov  [result], si
    hlt
result: .word 0
buf:  .fill 16, 1, 0x90
.balign 64
      .fill 64, 1, 0x90
far1: .fill 16, 1, 0x90
