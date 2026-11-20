# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# A20 gate (A20M#, driven by the testbench through port 92h bit 1: 1 = A20 enabled),
# changed at run time; every OUT is followed by a far jump (the pipeline behind it is
# refetched: the AGU applies the gate to linear addresses in A2, as a 486 may to
# prefetched instructions).
# Real mode (the datasheet's use): data at FFFF:xxxx wraps to the first 64 KB through the
# D-cache (the line above 1 MB cached before the gate closes), a dword load and a dword
# store straddling 1 MB (each line masked on its own), code fetched at FFFF:xxxx (low and
# high copies differ: I-cache physical tags).
# Paging (outside the datasheet's "real mode only": the core and 86Box both mask physical
# bit 20 of every access): a translation already in the TLB, and a page walk whose page
# table lies above 1 MB.
# Results go to the log (compared store by store in lockstep).
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
.macro logr r                       # append a register to the log
    mov  ebx, [logp]
    mov  [ebx], \r
    add  dword ptr [logp], 4
.endm
.macro a20rm v                      # real mode: set the gate, far jump to the next instruction
    mov  al, \v
    out  0x92, al
    .byte 0xEA
    .word 9f
    .word 0x1000
9:
.endm
.macro a20pm v                      # protected mode: the same through selector 08
    mov  al, \v
    out  0x92, al
    .byte 0xEA
    .long 9f
    .word 0x08
9:
.endm
PT = 0x21000
.code16
.org 0x100
start:
    cli
    mov  ax, 0x1000
    mov  ss, ax
    mov  sp, 0xF000
    mov  dword ptr [logp], offset log
    xor  ax, ax
    mov  es, ax                     # 0000: the first 64 KB
    mov  ax, 0xFFFF
    mov  fs, ax                     # FFFF: FFFF0-10FFEF
    mov  ax, 0xF000
    mov  gs, ax                     # F000: F0000-FFFFF
    # ---- real mode, A20 enabled (reset state of the test)
    mov  dword ptr es:[0x500], 0x11111111
    mov  dword ptr fs:[0x510], 0x22222222          # 100500
    mov  eax, es:[0x500]
    logr eax
    mov  eax, fs:[0x510]                            # (line 100500 now cached)
    logr eax
    mov  dword ptr gs:[0xFFFC], 0xDDCCBBAA          # FFFFC
    mov  dword ptr fs:[0x10], 0x55667788            # 100000
    mov  dword ptr es:[0x0], 0x44332211             # 0 (IVT vector 0: unused)
    mov  eax, fs:[0x0E]                             # FFFFE-100001: 7788DDCC
    logr eax
    # code: FFFF:0610 = 100600 (high copy), 0000:0600 (low copy); mov eax, imm32; retf
    mov  dword ptr fs:[0x610], 0xBBBBB866
    mov  dword ptr fs:[0x614], 0x00CBBBBB
    mov  dword ptr es:[0x600], 0xAAAAB866
    mov  dword ptr es:[0x604], 0x00CBAAAA
    .byte 0x9A
    .word 0x0610, 0xFFFF
    logr eax                                        # BBBBBBBB
    # ---- A20 masked
    a20rm 0
    mov  eax, fs:[0x510]                            # 000500: 11111111
    logr eax
    mov  dword ptr fs:[0x520], 0x33333333           # 100510 -> 000510
    mov  eax, es:[0x510]
    logr eax
    mov  eax, fs:[0x0E]                             # FFFFE, FFFFF, 0, 1: 2211DDCC
    logr eax
    mov  dword ptr fs:[0x0E], 0x0F0E0D0C            # FFFFE FFFFF 0 1
    mov  eax, es:[0x0]
    logr eax
    mov  eax, gs:[0xFFFC]
    logr eax
    .byte 0x9A
    .word 0x0610, 0xFFFF                            # executes the low copy
    logr eax                                        # AAAAAAAA
    # ---- A20 enabled again
    a20rm 2
    mov  eax, fs:[0x510]                            # 100500: 22222222
    logr eax
    mov  eax, fs:[0x520]                            # 100510: never written
    logr eax
    mov  eax, fs:[0x10]                             # 100000: 55667788
    logr eax
    .byte 0x9A
    .word 0x0610, 0xFFFF                            # the high copy again
    logr eax                                        # BBBBBBBB

    # ---- protected mode, paging
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
    # page directory 20000: 0-3FFFFF -> table 21000 (pages 0-3F identity), 400000-7FFFFF ->
    # table 122000 (above 1 MB; its masked twin is 22000)
    mov  edi, 0x20000
    mov  ecx, 3072
    xor  eax, eax
    cld
    rep  stosd
    mov  dword ptr es:[0x20000], PT + 7
    mov  dword ptr es:[0x20004], 0x122007
    mov  edi, PT
    mov  eax, 7
    mov  ecx, 0x40
1:  stosd
    add  eax, 0x1000
    loop 1b
    mov  dword ptr es:[PT + 0x40*4], 0x140007       # 40000 -> 140000
    mov  dword ptr es:[PT + 0x41*4], 0x040007       # 41000 -> 40000 (the masked twin)
    mov  dword ptr es:[PT + 0x3E*4], 0x122007       # 3E000 -> 122000 (to write that table)
    mov  dword ptr es:[0x22000], 0x31007            # masked table: 400000 -> 31000
    mov  dword ptr es:[0x30100], 0x30303030
    mov  dword ptr es:[0x31100], 0x31313131
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  1f
1:  mov  dword ptr fs:[0x3E000], 0x30007            # table above 1 MB: 400000 -> 30000
    mov  dword ptr fs:[0x40100], 0x77777777         # 140100
    mov  dword ptr fs:[0x41100], 0x88888888         # 040100
    mov  eax, fs:[0x40100]
    logr eax
    mov  eax, fs:[0x400100]                         # walk through 122000: 30100
    logr eax
    # ---- A20 masked: the TLB entries stay, the walk of a new one reads 22000
    a20pm 0
    mov  eax, fs:[0x40100]                          # 140100 -> 040100: 88888888
    logr eax
    mov  dword ptr fs:[0x40104], 0x99999999         # to 040104
    mov  eax, fs:[0x41104]
    logr eax
    mov  eax, 0x400000
    invlpg fs:[eax]
    mov  eax, fs:[0x400100]                         # walk through 22000: 31100
    logr eax
    # ---- A20 enabled again
    a20pm 2
    mov  eax, fs:[0x40104]                          # 140104: never written
    logr eax
    mov  eax, 0x400000
    invlpg fs:[eax]
    mov  eax, fs:[0x400100]                         # walk through 122000 again: 30100
    logr eax
    mov  eax, fs:[0x3E000]                          # that PTE with A set
    logr eax
    mov  eax, [logp]
    hlt

hgp:                                # (not expected)
    mov  eax, [esp]
    or   eax, 0x0D0000
    logr eax
    hlt
hpf:                                # (not expected)
    mov  eax, cr2
    logr eax
    hlt

.align 4
logp:   .long 0
log:    .fill 32, 4, 0
gdtr:   .word 0x37
        .long 0x10A00
idtr:   .word 0x0F * 8 - 1
        .long 0x10800
.org 0x800
idt:
    .fill 13, 8, 0
    gate hgp, 0x08, 0x8E                   # 13 #GP
    gate hpf, 0x08, 0x8E                   # 14 #PF
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
    .quad 0
    .quad 0
    desc 0, 0xFFFFF, 0x92, 0xC             # 28 flat data
    desc 0, 0xFFFFF, 0x9A, 0xC             # 30 flat code32
