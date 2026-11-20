# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# "compiled C"-like mix: struct array processing with locals in memory,
# function calls, multiply, divide, near indirect calls through a table
.intel_syntax noprefix
.code16
.org 0x100
start:
    mov  word ptr [seed], 1234
    mov  cx, 400
main_lp:
    push cx
    call rnd
    mov  bx, ax
    and  bx, 3
    shl  bx, 1
    call word ptr [ftab+bx]
    pop  cx
    loop main_lp
    hlt

rnd:                            # seed = seed*25173 + 13849
    push bp
    mov  bp, sp
    mov  ax, [seed]
    mov  dx, 25173
    mul  dx
    add  ax, 13849
    mov  [seed], ax
    pop  bp
    ret

f_sum:                          # sum of an 8-entry struct field
    push bp
    mov  bp, sp
    sub  sp, 4
    mov  word ptr [bp-2], 0
    mov  word ptr [bp-4], 0
fs1:
    mov  bx, [bp-4]
    mov  ax, bx
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1                  # sizeof(struct)=8
    mov  ax, [recs+bx+2]
    add  [bp-2], ax
    inc  word ptr [bp-4]
    cmp  word ptr [bp-4], 8
    jl   fs1
    mov  ax, [bp-2]
    add  [total], ax
    mov  sp, bp
    pop  bp
    ret

f_upd:                          # recs[i].a += recs[i].b ; recs[i].c = a/b
    push bp
    mov  bp, sp
    push si
    mov  si, offset recs
    mov  cx, 8
fu1:
    mov  ax, [si]
    add  ax, [si+2]
    mov  [si], ax
    xor  dx, dx
    mov  bx, [si+2]
    or   bx, 1
    div  bx
    mov  [si+4], ax
    add  si, 8
    loop fu1
    pop  si
    pop  bp
    ret

f_str:                          # copy name field and count chars
    push si
    push di
    mov  si, offset name
    mov  di, offset name2
    xor  cx, cx
fstr1:
    lodsb
    stosb
    inc  cx
    test al, al
    jnz  fstr1
    add  [total], cx
    pop  di
    pop  si
    ret

f_mat:                          # tiny 3x3 matrix-vector multiply
    push si
    push di
    xor  si, si
    mov  di, offset vout
fm1:
    xor  bx, bx
    xor  cx, cx
fm2:
    mov  ax, [mat+si]
    imul word ptr [vin+bx]
    add  cx, ax
    add  si, 2
    add  bx, 2
    cmp  bx, 6
    jb   fm2
    mov  [di], cx
    add  di, 2
    cmp  si, 18
    jb   fm1
    pop  di
    pop  si
    ret

ftab:  .word f_sum, f_upd, f_str, f_mat
seed:  .word 0
total: .word 0
recs:  .word 1,2,3,4, 5,6,7,8, 9,10,11,12, 13,14,15,16
       .word 17,18,19,20, 21,22,23,24, 25,26,27,28, 29,30,31,32
name:  .ascii "Hello, pipelined 8086 world"
       .byte 0
name2: .space 32
mat:   .word 1,2,3, 4,5,6, 7,8,9
vin:   .word 3,2,1
vout:  .space 6
