# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# protected mode, same privilege: INT n through 16/32-bit interrupt / trap gates, IRET,
# exceptions with / without error codes (handlers log the error code and resume at
# the address in [resume]), far CALL / RET (n) between 32- and 16-bit code.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.macro gate off, sel, acc        # (handler offsets below 64 KB)
    .word \off
    .word \sel
    .byte 0, \acc
    .word 0
.endm
.macro try lbl                      # the next instruction may fault: resume at lbl
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
    int  0x30                       # 32-bit interrupt gate
    int  0x31                       # 32-bit trap gate
    int  0x32                       # 16-bit interrupt gate (16-bit handler)
    sti
    int  0x31                       # IF stays set through the trap gate
    cli
    # far calls
    call fword ptr [fp32]
    .byte 0x9A                      # call far 0x20:f16 (ptr16:32)
    .long f16
    .word 0x20
    push 0x11111111
    push 0x22222222
    .byte 0x9A
    .long f32n
    .word 0x08
    # exceptions
    try  1f
    mov  ax, 0x3B                   # not present: #NP(38)
    mov  ds, ax
1:  try  1f
    mov  ax, 0x500                  # beyond the GDT limit: #GP(500)
    mov  es, ax
1:  try  1f
    xor  ax, ax                     # null SS: #GP(0)
    mov  ss, ax
1:  try  1f
    mov  ax, 0x28                   # limit 0FFF
    mov  fs, ax
    mov  eax, fs:[0xFFE]            # #GP(0)
1:  try  1f
    mov  ax, 0x30                   # read-only
    mov  gs, ax
    mov  gs:[0], eax                # #GP(0)
1:  try  1f
    mov  ax, 0x50                   # execute-only code into DS: #GP(50)
    mov  ds, ax
1:  try  1f
    xor  ecx, ecx
    div  ecx                        # #DE
1:  try  1f
    ud2                             # #UD
1:  try  1f
    xor  ax, ax
    mov  es, ax
    mov  eax, es:[0]                # null segment: #GP(0)
1:  try  1f
    mov  ax, 0x40                   # stack segment not present: #SS(40)
    mov  ss, ax
1:  try  1f
    mov  esp, 0x0FFE                # 16-bit stack (0x48) with ESP near the limit
    mov  ax, 0x48
    mov  ss, ax
    push eax                        # #SS(0)
1:  mov  ax, 0x10
    mov  ss, ax
    mov  esp, 0xF000
    pushfd
    pop  eax
    or   eax, 0x200
    push eax
    popfd                           # IF = 1
    pushfd
    popfd
    cli
    mov  eax, [log]
    mov  ebx, [log+4]
    hlt

f32:
    mov  eax, 0x32
    retf
f32n:
    mov  eax, [esp+8]
    add  eax, [esp+12]
    retf 8
h30:
    inc  dword ptr [cnt]
    iretd
h31:
    add  dword ptr [cnt], 0x100
    pushfd
    pop  dword ptr [flg]
    iretd
# exception handlers: log (vector, error code), resume
hec:                                # with an error code
    push eax
    push ebx
    mov  ebx, [logp]
    mov  eax, [esp+8]
    mov  [ebx], eax
    add  dword ptr [logp], 4
    mov  eax, [resume]
    mov  [esp+12], eax
    pop  ebx
    pop  eax
    add  esp, 4
    iretd
hnoec:
    push eax
    mov  eax, [resume]
    mov  [esp+4], eax
    pop  eax
    iretd
.code16
f16:
    mov  ax, 0x1616
    .byte 0x66, 0xCB                # retf (32-bit) back to 32-bit code
h32:                                # 16-bit gate, 16-bit code segment
    add  word ptr [cnt+2], 1
    iret

.align 4
resume: .long 0
logp:   .long 0
cnt:    .long 0
flg:    .long 0
fp32:   .long f32
        .word 0x08
log:    .fill 16, 4, 0
gdtr:   .word 0x57
        .long 0x10A00
idtr:   .word 0x33 * 8 - 1
        .long 0x10800

.org 0x800
idt:
    gate hnoec, 0x08, 0x8E                         # 0 #DE
    .quad 0, 0, 0, 0, 0
    gate hnoec, 0x08, 0x8E                         # 6 #UD
    .quad 0, 0, 0, 0
    gate hec, 0x08, 0x8E                           # 11 #NP
    gate hec, 0x08, 0x8E                           # 12 #SS
    gate hec, 0x08, 0x8E                           # 13 #GP
    .fill 0x30 - 14, 8, 0
    gate h30, 0x08, 0x8E                           # 30 32-bit interrupt gate
    gate h31, 0x08, 0x8F                           # 31 32-bit trap gate
    gate h32, 0x20, 0x86                           # 32 16-bit interrupt gate
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32 4 GB
    desc 0x60000, 0xFFFF, 0x92, 0          # 18 (spare)
    desc 0x10000, 0xFFFF, 0x9A, 0          # 20 code16
    desc 0x20000, 0x0FFF, 0x92, 0          # 28 data, limit 0FFF
    desc 0x10000, 0xFFFF, 0x90, 0          # 30 read-only
    desc 0x30000, 0xFFFF, 0x12, 0          # 38 not present
    desc 0x30000, 0xFFFF, 0x12, 0          # 40 not present (stack)
    desc 0x40000, 0x0FFF, 0x92, 0          # 48 16-bit stack, limit 0FFF
    desc 0x10000, 0xFFFF, 0x98, 4          # 50 execute-only code
