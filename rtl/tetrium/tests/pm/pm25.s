# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# a fault of IN / OUT / INS / OUTS comes before the port access (the lockstep compares every
# OUT byte; the I/O handled by a faulting instruction would be done again after the restart):
# #PF on the OUTS source (not present, crossing a page, in the middle of a REP), on the INS
# destination (not present, read-only with WP), an instruction breakpoint on IN / OUT / INS /
# OUTS, #AC on OUTS / INS at CPL 3.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.macro gate off, sel, acc
    .word \off
    .word \sel
    .byte 0, \acc
    .word 0
.endm
.macro unmap pg
    mov  dword ptr es:[0x21000 + (\pg) * 4], 0
    invlpg es:[(\pg) * 4096]
.endm
.macro fixg pg, val                 # the next access faults on page pg: map it to val
    mov  dword ptr gs:[fixa], 0x21000 + (\pg) * 4
    mov  dword ptr gs:[fixv], \val
.endm
.macro try lbl                      # the next instruction faults: resume at lbl
    mov  dword ptr [resume], offset \lbl
.endm
.macro fix pg, val                  # the next access faults on page pg: map it to val
    mov  dword ptr [fixa], 0x21000 + (\pg) * 4
    mov  dword ptr [fixv], \val
.endm
.macro logr r                       # append a register to the log
    mov  ebx, [logp]
    mov  [ebx], \r
    add  dword ptr [logp], 4
.endm
PT = 0x21000
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
    mov  ss, ax
    mov  esp, 0xF000
    mov  ax, 0x28
    mov  es, ax
    mov  fs, ax
    mov  ax, 0x38
    ltr  ax
    mov  dword ptr [logp], offset log
    # page directory 20000 (one table, 21000), pages 0-3F identity (user, writable)
    mov  edi, 0x20000
    mov  ecx, 2048
    xor  eax, eax
    cld
    rep  stosd
    mov  dword ptr es:[0x20000], PT + 7
    mov  edi, PT
    mov  eax, 7
    mov  ecx, 0x40
1:  stosd
    add  eax, 0x1000
    loop 1b
    mov  dword ptr es:[PT + 0x30*4], 0               # not present (demand paging -> 31000)
    mov  dword ptr es:[PT + 0x32*4], 0x32005         # read-only
    mov  dword ptr es:[PT + 0x33*4], 0x33003         # supervisor only
    mov  dword ptr es:[PT + 0x34*4], 0x35007         # alias of 35000
    mov  dword ptr es:[PT + 0x37*4], 0               # not present
    mov  dword ptr es:[PT + 0x38*4], 0x38005         # read-only
    mov  dword ptr es:[PT + 0x39*4], 0               # not present (code -> 35000)
    mov  dword ptr es:[0x31010], 0x12345678
    mov  dword ptr es:[0x36100], 0x36363636
    mov  dword ptr es:[0x36FFC], 0x0C0B0A09
    mov  dword ptr es:[0x37000], 0x44332211
    mov  dword ptr es:[0x37FFC], 0x99887766
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  1f
1:
    mov  dx, 0x300
    mov  ax, 0x28
    mov  ds, ax                     # (flat DS for OUTS; the program's data through GS)
    mov  ax, 0x10
    mov  gs, ax
    mov  dword ptr es:[0x31010], 0x12345678
    mov  dword ptr es:[0x31FFC], 0x55667788
    mov  ebp, 2                     # second pass: the D-cache holds the sources
pass:
    # OUTS from a not-present page: mapped, restarted
    unmap 0x30
    fixg 0x30, 0x31007
    mov  esi, 0x30010
    outsb
    unmap 0x30
    fixg 0x30, 0x31007
    mov  esi, 0x30010
    outsw
    unmap 0x30
    fixg 0x30, 0x31007
    mov  esi, 0x30010
    outsd
    # crossing into it
    unmap 0x37
    fixg 0x37, 0x37007
    mov  esi, 0x36FFE
    outsd
    # in the middle of a REP, uncached page
    unmap 0x37
    fixg 0x37, 0x37017
    mov  esi, 0x36FF9
    mov  ecx, 12
    rep  outsb
    unmap 0x37
    fixg 0x37, 0x37007
    mov  esi, 0x36FF8
    mov  ecx, 4
    rep  outsd
    # stores and OUTs right around it
    unmap 0x30
    fixg 0x30, 0x31007
    mov  esi, 0x30010
    out  dx, al
    mov  byte ptr es:[0x31010], 0x9A
    outsb
    out  dx, al
    # INS to a not-present page: mapped, restarted
    unmap 0x30
    fixg 0x30, 0x31007
    mov  edi, 0x30020
    insb
    unmap 0x30
    fixg 0x30, 0x31007
    mov  edi, 0x30024
    insd
    unmap 0x37
    fixg 0x37, 0x37007
    mov  edi, 0x36FFC
    mov  ecx, 3
    rep  insd
    # INS to a read-only page with WP: #PF, not done
    mov  eax, cr0
    or   eax, 0x10000
    mov  cr0, eax
    mov  edi, 0x32000
    mov  dword ptr gs:[resume], offset 1f
    insd
1:  mov  eax, cr0
    and  eax, ~0x10000
    mov  cr0, eax
    dec  ebp
    jnz  pass
    # instruction breakpoints on the I/O instructions
    mov  esi, 0x31010
    mov  edi, 0x31020
    mov  eax, 0x10000 + offset b0
    mov  dr0, eax
    mov  eax, 0x10000 + offset b1
    mov  dr1, eax
    mov  eax, 0x10000 + offset b2
    mov  dr2, eax
    mov  eax, 0x10000 + offset b3
    mov  dr3, eax
    mov  eax, 0xFF
    mov  dr7, eax
    mov  eax, 0xCAFEF00D
b0: out  dx, al
    nop
b1: in   al, dx
    nop
b2: outsd
    nop
b3: insd
    xor  eax, eax
    mov  dr7, eax
    mov  eax, [0x31020]
    mov  ax, 0x10
    mov  ds, ax
    # #AC at CPL 3, IOPL 3
    mov  eax, cr0
    or   eax, 0x40000
    mov  cr0, eax
    push 0x23                       # SS
    push 0xC000
    push 0x43002                    # EFLAGS: AC, IOPL 3
    push 0x1B                       # CS
    push offset ring3
    iretd
ring3:
    mov  ax, 0x2B
    mov  ds, ax
    mov  es, ax
    mov  dx, 0x304
    mov  esi, 0x31011
    outsd
    call acon
    mov  esi, 0x31013
    outsw
    call acon
    mov  edi, 0x31021
    insd
    call acon
    mov  edi, 0x31021
    mov  ecx, 3
    rep  insd
    int  0x31
acon:
    pushfd
    or   dword ptr [esp], 0x40000
    popfd
    ret

hdb:                                # #DB: RF set, resumed
    push eax
    mov  eax, dr6
    mov  [0x1F000], eax             # (log by the pushed EIP / DR6: compared as stores)
    mov  eax, [esp+4]
    mov  [0x1F004], eax
    xor  eax, eax
    mov  dr6, eax
    or   dword ptr [esp+12], 0x10000
    pop  eax
    iretd
hac:                                # #AC: AC cleared in the frame, restarted
    push eax
    mov  eax, [esp+8]
    mov  [0x1F008], eax
    and  dword ptr [esp+16], ~0x40000
    pop  eax
    add  esp, 4
    iretd
hpf:
    push ds
    push eax
    push ebx
    push 0x10
    pop  ds
    mov  ebx, [logp]
    mov  eax, [esp+12]
    or   eax, 0x0E0000
    mov  [ebx], eax
    mov  eax, cr2
    mov  [ebx+4], eax
    mov  eax, [esp+16]
    mov  [ebx+8], eax
    add  dword ptr [logp], 12
    mov  eax, [fixa]
    test eax, eax
    jz   1f
    mov  ebx, [fixv]
    mov  es:[eax], ebx
    mov  dword ptr [fixa], 0
    mov  eax, cr2
    invlpg fs:[eax]
    jmp  2f
1:  mov  eax, [resume]
    mov  [esp+16], eax
2:  pop  ebx
    pop  eax
    pop  ds
    add  esp, 4
    iretd
hgp:                                # (not expected)
    mov  eax, [esp]
    or   eax, 0x0D0000
    logr eax
    hlt
h31:
    mov  ax, 0x10
    mov  ds, ax
    mov  eax, [logp]
    hlt

.align 4
resume: .long 0
fixa:   .long 0
fixv:   .long 0
logp:   .long 0
log:    .fill 96, 4, 0
gdtr:   .word 0x3F
        .long 0x10E00
idtr:   .word 0x32 * 8 - 1
        .long 0x10C00
.org 0xB00
tss:    .long 0, 0xE000, 0x10       # link, ESP0, SS0
        .fill 0x68 - 12, 1, 0
.org 0xC00
idt:
    .fill 1, 8, 0
    gate hdb, 0x08, 0x8E                   # 1 #DB
    .fill 11, 8, 0
    gate hgp, 0x08, 0x8E                   # 13 #GP
    gate hpf, 0x08, 0x8E                   # 14 #PF
    .fill 2, 8, 0
    gate hac, 0x08, 0x8E                   # 17 #AC
    .fill 0x31 - 18, 8, 0
    gate h31, 0x08, 0xEE                   # 31 (DPL 3)
.org 0xE00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
    desc 0x10000, 0xFFFF, 0xFA, 4          # 18 code32 DPL 3
    desc 0x10000, 0xFFFFF, 0xF2, 0xC       # 20 data32 DPL 3
    desc 0, 0xFFFFF, 0xF2, 0xC             # 28 flat data DPL 3
    desc 0, 0xFFFFF, 0x9A, 0xC             # 30 flat code32
    desc 0x10B00, 0x67, 0x89, 0            # 38 TSS32
