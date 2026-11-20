# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Boot sector of the hardware stress image: loads NSECT sectors from LBA 1 to 1000:0000 with
# INT 13h CHS reads (geometry from AH=08h) and jumps there.  DL = boot drive.
.intel_syntax noprefix
.code16
.text
.globl _start
NSECT = 384                             # 192 KB: kernel 64 KB, wl16 64 KB, wl32 64 KB
_start:
    cli
    xor  ax, ax
    mov  ds, ax
    mov  ss, ax
    mov  sp, 0x7C00
    sti
    mov  [drive], dl
    mov  si, offset msg
    call puts
    mov  ah, 8
    mov  dl, [drive]
    xor  di, di
    mov  es, di
    int  0x13
    jc   fail
    and  cx, 0x3F
    mov  [spt], cx
    movzx ax, dh
    inc  ax
    mov  [heads], ax
    mov  word ptr [lba], 1
    mov  word ptr [dseg], 0x1000
1:  mov  ax, [lba]
    xor  dx, dx
    div  word ptr [spt]                 # ax = lba / spt, dx = lba % spt
    mov  cl, dl
    inc  cl                             # sector
    xor  dx, dx
    div  word ptr [heads]               # ax = cylinder, dx = head
    mov  dh, dl
    mov  ch, al
    shl  ah, 6
    or   cl, ah
    mov  dl, [drive]
    mov  bx, [dseg]
    mov  es, bx
    xor  bx, bx
    mov  byte ptr [tries], 4
2:  mov  ax, 0x0201
    push cx
    push dx
    int  0x13
    pop  dx
    pop  cx
    jnc  3f
    dec  byte ptr [tries]
    jz   fail
    xor  ax, ax
    int  0x13
    jmp  2b
3:  add  word ptr [dseg], 0x20
    inc  word ptr [lba]
    test byte ptr [lba], 31
    jnz  4f
    mov  al, '.'
    call putc
4:  cmp  word ptr [lba], NSECT + 1
    jb   1b
    mov  dl, [drive]
    .byte 0xEA                          # jmp 1000:0000
    .word 0, 0x1000
fail:
    mov  si, offset emsg
    call puts
5:  hlt
    jmp  5b
puts:
    lodsb
    test al, al
    jz   6f
    call putc
    jmp  puts
6:  ret
putc:
    mov  ah, 0x0E
    mov  bx, 7
    int  0x10
    ret
msg:  .asciz "hwstress: loading"
emsg: .asciz " disk error"
drive: .byte 0
tries: .byte 0
spt:   .word 0
heads: .word 0
lba:   .word 0
dseg:  .word 0
.org 510
.byte 0x55, 0xAA
