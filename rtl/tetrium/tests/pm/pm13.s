# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Cache control: WBINVD / INVD (both caches swept; execution goes on with refetched code),
# CR0.CD (hits are served, misses are not filled: read uncached), CR0.NW with CD (a write hit
# stays in the D-cache: memory keeps the old value, the program reads the new one; a write
# miss goes to memory).  Real mode.  The log is compared in lockstep; the memory side of
# NW (lineA keeps 11111111 on the bus) is checked with LOCKDUMP (86Box has no cache, so the
# model's memory holds the new value: nothing reads lineA after the final INVD; the log,
# also written as cache hits under NW, is copied onto itself with write-through on).
# lockenv: LOCKMEMIGN=10220:8
.intel_syntax noprefix
.macro logr r
    mov  edi, [logp]
    mov  [edi], \r
    add  dword ptr [logp], 4
.endm
.code16
.org 0x100
start:
    cli
    mov  dword ptr [logp], offset log
    mov  eax, [lineA]                # cached
    mov  eax, [lineB]
    wbinvd
    mov  eax, [lineA]                # filled again
    logr eax
    # CD: hits served, a miss is read uncached
    mov  eax, cr0
    or   eax, 0x40000000
    mov  cr0, eax
    mov  eax, [lineA]
    logr eax
    mov  eax, [lineC]
    logr eax
    mov  dword ptr [lineC], 0x33333334
    mov  eax, [lineC]
    logr eax
    # NW (with CD): write hit to lineA stays in the cache, write miss to lineC goes out
    mov  eax, cr0
    or   eax, 0x20000000
    mov  cr0, eax
    mov  dword ptr [lineA], 0x5A5A5A5A
    mov  dword ptr [lineC + 4], 0x6B6B6B6B
    mov  word ptr [lineA + 6], 0x7788         # (a word: the same)
    mov  eax, [lineA]
    logr eax
    mov  eax, [lineA + 4]
    logr eax
    mov  eax, [lineC + 4]
    logr eax
    mov  eax, cr0
    logr eax
    # write-through again
    and  eax, ~0x60000000
    mov  cr0, eax
    mov  dword ptr [lineB], 0x7C7C7C7C
    mov  eax, [lineB]
    logr eax
    push ds
    pop  es
    cld
    mov  si, offset logp
    mov  di, si
    mov  cx, 17
    rep  movsd
    invd
    mov  eax, [logp]
    hlt

.align 32
lineA:  .long 0x11111111, 0x11111112, 0, 0, 0, 0, 0, 0
lineB:  .long 0x22222222, 0, 0, 0, 0, 0, 0, 0
lineC:  .long 0x33333333, 0x33333335, 0, 0, 0, 0, 0, 0
logp:   .long 0
log:    .fill 16, 4, 0
