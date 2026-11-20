# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# control transfers to an EIP beyond the code segment limit: #GP(0) at the transferring
# instruction, before any of its effects (near JMP / CALL / RET / Jcc, far JMP / CALL /
# RET / IRET, call gate, INT n); exception gates beyond the limit: #GP(EXT) after a
# benign exception (#UD), #DF after a contributory one (#DE).
# The code runs in selector 18 (limit 1FFF); every target is 3000.  Handlers log
# (vector << 16 | error code, pushed EIP) and resume at [resume].
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.macro gate off, sel, acc        # (offsets below 64 KB)
    .word \off
    .word \sel
    .byte 0, \acc
    .word 0
.endm
.macro try lbl                      # the next instruction faults: resume at lbl
    mov  dword ptr [resume], offset \lbl
.endm
.code16
.org 0x100
start:
    cli
    lgdt [gdtr]
    lidt [idtr]
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
    mov  esp, 0xF000
    mov  dword ptr [logp], offset log
    .byte 0xEA                      # into the code segment with limit 1FFF
    .long t18
    .word 0x18
t18:
    try  1f
    mov  eax, 0x3000
    jmp  eax                        # near indirect
1:  try  1f
    mov  eax, 0x3000
    call eax                        # nothing pushed
1:  try  1f
    push 0x3000
    ret                             # ESP not popped
1:  pop  eax
    try  1f
    .byte 0xE9                      # JMP rel32
    .long beyond - (. + 4)
1:  try  1f
    xor  eax, eax
    .byte 0x0F, 0x84                # JZ rel32, taken
    .long beyond - (. + 4)
1:  try  1f
    .byte 0xEA                      # far JMP 18:3000
    .long 0x3000
    .word 0x18
1:  try  1f
    .byte 0x9A                      # far CALL 18:3000
    .long 0x3000
    .word 0x18
1:  try  1f
    push 0x18
    push 0x3000
    retf
1:  add  esp, 8
    try  1f
    pushfd
    push 0x18
    push 0x3000
    iretd
1:  add  esp, 12
    try  1f
    .byte 0x9A                      # call gate 20 -> 18:3000
    .long 0
    .word 0x20
1:  try  1f
    int  0x40                       # gate -> 18:3000: #GP(0)
1:  try  1f
    ud2                             # #UD, its gate beyond the limit: #GP(1)
1:  try  1f
    xor  ecx, ecx
    div  ecx                        # #DE, its gate beyond the limit: #DF(0)
1:  .byte 0xEA                      # 16-bit code, limit 1FFF
    .long t28
    .word 0x28
.code16
t28:
    try  1f
    mov  ax, 0x3000
    jmp  ax                         # 16-bit near indirect
1:  try  1f
    push 0x3000
    ret                             # 16-bit near RET
1:  pop  ax
    .byte 0x66, 0xEA                # back to 18
    .long t18e
    .word 0x18
.code32
t18e:
    mov  eax, [log]
    mov  ebx, [log+4]
    mov  ecx, [logp]
    hlt

hgp:
    push eax
    push ebx
    mov  eax, [esp+8]
    or   eax, 0x0D0000
    jmp  hlog
hdf:
    push eax
    push ebx
    mov  eax, [esp+8]
    or   eax, 0x080000
hlog:
    mov  ebx, [logp]
    mov  [ebx], eax
    mov  eax, [esp+12]              # the pushed EIP
    mov  [ebx+4], eax
    add  dword ptr [logp], 8
    mov  eax, [resume]
    mov  [esp+12], eax
    pop  ebx
    pop  eax
    add  esp, 4
    iretd

.align 4
resume: .long 0
logp:   .long 0
log:    .fill 32, 4, 0
gdtr:   .word 0x2F
        .long 0x10A00
idtr:   .word 0x41 * 8 - 1
        .long 0x10C00
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32 4 GB
    desc 0x10000, 0x1FFF, 0x9A, 4          # 18 code32, limit 1FFF
    gate 0x3000, 0x18, 0x8C                # 20 32-bit call gate
    desc 0x10000, 0x1FFF, 0x9A, 0          # 28 code16, limit 1FFF
.org 0xC00
idt:
    gate 0x3000, 0x18, 0x8E                # 0 #DE
    .fill 5, 8, 0
    gate 0x3000, 0x18, 0x8E                # 6 #UD
    .fill 1, 8, 0
    gate hdf, 0x08, 0x8E                   # 8 #DF
    .fill 4, 8, 0
    gate hgp, 0x08, 0x8E                   # 13 #GP
    .fill 0x40 - 14, 8, 0
    gate 0x3000, 0x18, 0x8E                # 40
.org 0x3000
beyond:                                    # (beyond the limit of 18)
    hlt
