# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Code segments whose base is not a multiple of 8 (base 10000h + k, k = 1..7), 32- and 16-bit:
# conditional / unconditional jumps, CALL / RET, LOOP, an indirect JMP, in lockstep.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
K   = 0x3000                            # current k (1..7), then the mode (0: 32-bit, 1: 16-bit)
MD  = 0x3004
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
    mov  esp, 0x2F000
    mov  dword ptr [MD], 0
    mov  dword ptr [K], 1
next:
    mov  eax, [K]
    # far jump to selector (18h + 8 (k - 1) + 38h mode), offset body - k
    mov  ebx, [MD]
    imul ebx, ebx, 0x38
    lea  ebx, [ebx + eax * 8 + 0x10]
    mov  ecx, offset body32
    cmp  dword ptr [MD], 0
    je   1f
    mov  ecx, offset body16
1:  sub  ecx, eax
    mov  [fptr], ecx
    mov  [fptr + 4], bx
    xor  edx, edx
    ljmp [fptr]
back:
    mov  ax, 0x10
    mov  ds, ax
    inc  dword ptr [K]
    cmp  dword ptr [K], 8
    jb   next
    mov  dword ptr [K], 1
    inc  dword ptr [MD]
    cmp  dword ptr [MD], 2
    jb   next
    hlt
.align 4
fptr: .long 0
      .word 0

.align 16
body32:
    mov  ecx, 40
1:  mov  eax, ecx
    and  eax, 3
    jz   2f
    cmp  eax, 2
    jne  3f
    call sub32
3:  jmp  4f
    .byte 0x90, 0x90, 0x90
2:  add  ebx, eax
4:  test ecx, 1
    jnz  5f
    nop
5:  test ecx, 4
    .byte 0x0F, 0x85                    # jnz near (rel32) over the padding
    .long 7f - 6f
6:  .fill 13, 1, 0x90
7:  loop 1b
    call sub32
    mov  eax, offset 8f
    sub  eax, [K]                       # the offset in this segment
    jmp  eax
    nop
8:  .byte 0xEA                          # jmp far 08:back
    .long back
    .word 0x08
sub32:
    inc  edx
    ret

.code16
.align 16
body16:
    mov  cx, 40
1:  mov  ax, cx
    and  ax, 3
    jz   2f
    cmp  ax, 2
    jne  3f
    call sub16
3:  jmp  4f
    .byte 0x90, 0x90, 0x90
2:  add  bx, ax
4:  test cx, 1
    jnz  5f
    nop
5:  test cx, 4
    jnz  6f
    .fill 5, 1, 0x90
6:  or   ax, ax
    jnz  7f
    inc  si
7:  loop 1b
    call sub16
    mov  ax, offset 8f
    sub  ax, [K]
    jmp  ax
    nop
8:  .byte 0x66, 0xEA
    .long back
    .word 0x08
sub16:
    inc  dx
    ret

.align 8
gdtr:   .word gdt_end - gdt - 1
        .long 0x10000 + gdt
.align 8
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4           # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC        # 10 data32
    .irp k, 1, 2, 3, 4, 5, 6, 7             # 18 .. 48: code32, base 10000h + k
    desc 0x10000 + \k, 0xFFFF, 0x9A, 4
    .endr
    .irp k, 1, 2, 3, 4, 5, 6, 7             # 50 .. 80: code16, base 10000h + k
    desc 0x10000 + \k, 0xFFFF, 0x9A, 0
    .endr
gdt_end:
