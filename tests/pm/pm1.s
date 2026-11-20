# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# protected mode, no faults: segment loads (GDT / LDT, null, RPL, read-only, expand-down,
# conforming code as data), LLDT / LTR / SLDT / STR, far JMP between 32- and 16-bit code,
# POP Sreg, LDS / LSS / LFS, 16- and 32-bit stacks.  The image is loaded at 1000:0000.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.code16
.org 0x100
start:
    cli
    lgdt [gdtr]
    mov  eax, cr0
    or   al, 1
    mov  cr0, eax
    .byte 0x66, 0xEA
    .long pm32
    .word 0x08
.code32
pm32:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  esp, 0xFFF0
    mov  eax, 0x12345678
    mov  [buf], eax
    push eax
    pop  ebx
    mov  ax, 0x18                 # 16-bit data at 0x20000, limit 0FFF, not yet accessed
    mov  fs, ax
    mov  dword ptr fs:[0x10], 0xCAFEBABE
    mov  ecx, fs:[0x10]
    mov  ax, 0x20                 # expand-down at 0x30000 (valid 1000-FFFF)
    mov  gs, ax
    mov  word ptr gs:[0x2000], 0x5555
    add  cx, gs:[0x2000]
    mov  ax, 0x40                 # read-only data
    mov  es, ax
    mov  edx, es:[buf]
    mov  ax, 0x48                 # conforming readable code as data
    mov  es, ax
    mov  esi, es:[buf]
    xor  eax, eax                 # null selectors
    mov  es, ax
    mov  ax, 3
    mov  gs, ax
    mov  ax, 0x28
    lldt ax
    mov  ax, 0x0C                 # LDT entry 1: data at 0x50000
    mov  fs, ax
    mov  dword ptr fs:[0x100], 0x11223344
    mov  ax, 0x17                 # LDT entry 2: DPL 3 data, RPL 3
    mov  es, ax
    mov  edi, es:[0]
    mov  ax, 0x30
    ltr  ax
    sldt bx
    str  bp
    mov  ax, 0x10
    mov  es, ax
    push ds
    pop  gs
    lds  esi, fword ptr [ptr1]
    lfs  edi, fword ptr [ptr1]
    lss  esp, fword ptr [ptr2]    # 16-bit stack at 0x40000
    push 0x7777
    push ds
    pop  es
    pop  ax
    .byte 0xEA                    # jmp far 0038:pm16 (16-bit code)
    .long pm16
    .word 0x38
.code16
pm16:
    mov  ax, 0x10
    mov  ds, ax
    mov  bx, [buf]
    mov  word ptr [buf+4], 0xBEEF
    push cs
    pop  ax
    mov  ax, 0x50
    mov  ss, ax
    mov  sp, 0x8000
    push 0x1234
    pop  dx
    jmp  far ptr cs:[fptr16]      # memory far pointer, 16-bit
pm16b:
    .byte 0x66, 0xEA              # back to 32-bit code
    .long pm32b
    .word 0x08
.code32
pm32b:
    mov  ax, 0x10
    mov  ss, ax
    mov  esp, 0xFF00
    jmp  fword ptr [fptr32]
pm32c:
    mov  eax, [buf]
    mov  ebx, [buf+4]
    hlt

.org 0x800
ldt:
    .quad 0
    desc 0x50000, 0xFFFF, 0x92, 0          # 0C
    desc 0x50000, 0xFFFF, 0xF2, 0          # 14 DPL 3
gdtr:
    .word gdt_end - gdt - 1
    .long 0x10000 + 0xA00
ptr1:
    .long buf
    .word 0x10
ptr2:
    .long 0x9000
    .word 0x50
fptr16:
    .word pm16b
    .word 0x38
fptr32:
    .long pm32c
    .word 0x08
.align 4
buf:
    .long 0, 0, 0, 0
.org 0x900
tss:
    .fill 0x68, 1, 0
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32 4 GB
    desc 0x20000, 0x0FFF, 0x92, 0          # 18 data16, limit 0FFF
    desc 0x30000, 0x0FFF, 0x96, 0          # 20 expand-down
    desc 0x10800, 0x17, 0x82, 0      # 28 LDT
    desc 0x10900, 0x67, 0x89, 0      # 30 TSS32
    desc 0x10000, 0xFFFF, 0x9A, 0          # 38 code16
    desc 0x10000, 0xFFFF, 0x90, 0          # 40 read-only data
    desc 0x10000, 0xFFFF, 0x9E, 4          # 48 conforming readable code
    desc 0x40000, 0xFFFF, 0x92, 0          # 50 16-bit stack
gdt_end:
