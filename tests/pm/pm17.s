# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# L2 TLB (tetrium_mmu, L2TLB_AB): translations evicted from the 32-entry TLB but kept in the
# L2 must follow the architectural invalidation rules.  64 data pages (2x the TLB) are
# read so the first ones live only in the L2, then:
#   1 a PTE remapped + INVLPG: the new frame is read
#   2 a PTE remapped + CR3 reload (no INVLPG): the new frame
#   3 a page made read-only + INVLPG: the write faults (#PF W/R = 1, P = 1), the handler
#     makes it writable again (+ INVLPG) and the write completes
#   4 accessed bit cleared + INVLPG / + CR3 reload: the next read walks and sets it again
#   5 dirty bit: a write through an L2 entry with D clear walks and sets D
#   6 INVLPG of a page sharing the L2 entry of another (same index): both still correct
# Results go to the log (compared store by store in lockstep).
.intel_syntax noprefix
.macro gate off, sel, acc
    .word \off
    .word \sel
    .byte 0, \acc
    .word 0
.endm
.macro logr r                       # (DS is flat: the image is at 10000)
    mov  ebx, [0x10000 + logp]
    mov  [ebx], \r
    add  dword ptr [0x10000 + logp], 4
.endm
PD   = 0x20000                      # page directory
PT0  = 0x21000                      # table for 0-3FFFFF (identity)
PT1  = 0x22000                      # table for 400000-7FFFFF (identity)
AREA = 0x200000                     # 64 data pages, page i holds i at offset 0
ALT  = 0x300000                     # alternative frames, frame i holds 0x100 + i
FAR  = 0x600000                     # a page with the same L2 index as AREA (index = vpn[21:12])
.code16
.org 0x100
start:
    cli
    mov  dword ptr [logp], offset log + 0x10000
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
    mov  ax, 0x28
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  esp, 0x1F000
    cld
    # page directory and two identity tables (P W U), pages i of AREA / ALT tagged
    mov  edi, PD
    xor  eax, eax
    mov  ecx, 1024
    rep  stosd
    mov  dword ptr [PD], PT0 + 7
    mov  dword ptr [PD + 4], PT1 + 7
    mov  edi, PT0
    mov  eax, 7
    mov  ecx, 2048
1:  stosd
    add  eax, 0x1000
    loop 1b
    xor  ecx, ecx
1:  mov  eax, ecx
    shl  eax, 12
    mov  [AREA + eax], ecx
    lea  edx, [ecx + 0x100]
    mov  [ALT + eax], edx
    inc  ecx
    cmp  ecx, 64
    jb   1b
    mov  dword ptr [FAR], 0x600
    mov  eax, PD
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80010000            # PG, WP (supervisor writes check R/W)
    mov  cr0, eax
    jmp  1f
1:  call touch                      # pages 0-31 now only in the L2
    # ---- 1 remap page 0 + INVLPG
    mov  dword ptr [PT0 + (AREA >> 12) * 4], ALT + 7
    mov  eax, AREA
    invlpg [eax]
    mov  eax, [AREA]                # 0x100
    logr eax
    # ---- 2 remap page 1, CR3 reload
    call touch
    mov  dword ptr [PT0 + (AREA >> 12) * 4 + 4], ALT + 0x1000 + 7
    mov  eax, cr3
    mov  cr3, eax
    call touch
    mov  eax, [AREA + 0x1000]       # 0x101
    logr eax
    # ---- 3 page 2 read-only + INVLPG: the write faults once
    call touch
    and  dword ptr [PT0 + (AREA >> 12) * 4 + 8], ~2
    mov  eax, AREA + 0x2000
    invlpg [eax]
    mov  dword ptr [AREA + 0x2000 + 4], 0x22222222
    mov  eax, [AREA + 0x2000 + 4]
    logr eax
    # ---- 4 accessed bit: cleared + INVLPG (page 5), cleared + CR3 reload (page 6)
    call touch
    and  dword ptr [PT0 + (AREA >> 12) * 4 + 20], ~0x20
    mov  eax, AREA + 0x5000
    invlpg [eax]
    mov  eax, [AREA + 0x5000]
    mov  eax, [PT0 + (AREA >> 12) * 4 + 20]
    logr eax                        # A set again
    call touch
    and  dword ptr [PT0 + (AREA >> 12) * 4 + 24], ~0x20
    mov  eax, cr3
    mov  cr3, eax
    mov  eax, [AREA + 0x6000]
    mov  eax, [PT0 + (AREA >> 12) * 4 + 24]
    logr eax
    # ---- 5 dirty bit: page 7 read (D clear in the TLB / L2), evicted, then written
    mov  eax, [AREA + 0x7000]
    call touch
    call touch
    mov  dword ptr [AREA + 0x7000 + 8], 0x77
    mov  eax, [PT0 + (AREA >> 12) * 4 + 28]
    logr eax                        # D (and A) set
    # ---- 6 same L2 index: AREA + 0x8000 and FAR + 0x8000 (vpn 208 / 608)
    mov  eax, [FAR + 0x8000]
    call touch
    mov  dword ptr [PT1 + ((FAR + 0x8000 - 0x400000) >> 12) * 4], ALT + 0x8000 + 7
    mov  eax, FAR + 0x8000
    invlpg [eax]
    mov  eax, [AREA + 0x8000]       # 8
    logr eax
    mov  eax, [FAR + 0x8000]        # 0x108
    logr eax
    call touch
    mov  eax, [AREA + 0x8000]
    logr eax
    mov  eax, [0x10000 + logp]
    hlt

# read every AREA page (64 > 32 TLB entries), summing into the log's checksum
touch:
    xor  ecx, ecx
    xor  edx, edx
1:  mov  eax, ecx
    shl  eax, 12
    add  edx, [AREA + eax]
    inc  ecx
    cmp  ecx, 64
    jb   1b
    logr edx
    ret

hpf:                                # #PF: log CR2 / error code, page writable, restart
    mov  eax, cr2
    logr eax
    mov  eax, [esp]
    logr eax
    or   dword ptr [PT0 + (AREA >> 12) * 4 + 8], 2
    mov  eax, cr2
    invlpg [eax]
    add  esp, 4
    iretd
hgp:                                # (not expected)
    mov  eax, [esp]
    or   eax, 0x0D0000
    logr eax
    hlt

.align 4
logp:   .long 0
log:    .fill 64, 4, 0
gdtr:   .word 0x37
        .long 0x10000 + gdt
idtr:   .word 0x0F * 8 - 1
        .long 0x10000 + idt
.align 8
idt:
    .fill 13, 8, 0
    gate hgp, 0x08, 0x8E                   # 13 #GP
    gate hpf, 0x08, 0x8E                   # 14 #PF
.align 8
gdt:
    .quad 0
    .word 0xFFFF, 0x0000                   # 08 code32, base 10000, limit FFFF
    .byte 0x01, 0x9A, 0x40, 0x00
    .quad 0
    .quad 0
    .quad 0
    .word 0xFFFF, 0x0000                   # 28 flat data 4 GB
    .byte 0x00, 0x92, 0xCF, 0x00
