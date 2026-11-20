# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# DMA snoop test (testbench DMA controller, I/O ports C8-DF, see tb/tb_main.cpp):
# the cached copies of memory written by DMA must be invalidated (data and code).
# Assembled twice: PG=0 real mode; PG=1 16-bit protected mode with paging, the DMA
# areas reached through alias pages (linear 50000 -> 30000, 4F000 -> 2F000, 58000 -> 38000).
# Per round:
#  1. the CPU writes the 4 KB buffer (physical 30000) with a PRNG stream and reads it all
#     (cached); DS:9000 keeps the old contents, DS:8000 the expected new ones
#  2. a DMA fill of [off, off + len) with another stream; while it runs every byte read
#     must be its old or new value (e2); after the flag (polled in a cached line) the
#     whole buffer must equal the expected contents (e1)
#  3. code: the CPU writes "mov ax, imm16; retf" crossing a line boundary at 3801E and
#     calls it; a DMA copy then replaces it (new imm) and the next call must run the new
#     code (e3); a flag poll timing out counts in 'to'
# Result on the console (DS:0 of segment 2000): "DMA OK" or the error counts.
.intel_syntax noprefix
.ifndef PG
PG = 0
.endif
.ifndef PCD                        # PG = 1: the alias pages uncacheable (PCD): the test then
PCD = 0                            # passes without snoops too (DMANOSNOOP), code included
.endif
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.if PG
S_BUF = 0x18
S_FLG = 0x20
S_CW  = 0x30
S_XC  = 0x28
S_CON = 0x38
.else
S_BUF = 0x3000
S_FLG = 0x2F00
S_CW  = 0x3800
S_XC  = 0x3800
S_CON = 0x2000
.endif
EXP = 0x8000                       # DS offsets (physical 18000 / 19000)
OLD = 0x9000
NROUND = 12
.macro dmaout port, val            # 32-bit OUT
    mov  eax, \val
    mov  dx, \port
    out  dx, eax
.endm
.code16
.org 0x100
start:
    cli
    cld
.if PG
    lgdt [gdtr]
    mov  eax, cr0
    or   al, 1
    mov  cr0, eax
    .byte 0xEA
    .word pm16
    .word 0x08
pm16:
    mov  ax, 0x10
    mov  ds, ax
    mov  ss, ax
    # page directory 22000, one table 23000: identity, plus the three alias pages
    mov  ax, 0x40
    mov  es, ax
    mov  edi, 0x22000
    mov  ecx, 2048
    xor  eax, eax
1:  mov  es:[edi], eax
    add  edi, 4
    dec  ecx
    jnz  1b
    mov  ebx, 0x22000
    mov  dword ptr es:[ebx], 0x23003
    mov  edi, 0x23000
    mov  eax, 3
    mov  ecx, 1024
1:  mov  es:[edi], eax
    add  edi, 4
    add  eax, 0x1000
    dec  ecx
    jnz  1b
    mov  ebx, 0x23000
    mov  dword ptr es:[ebx + 0x50 * 4], 0x30003 + PCD * 0x10
    mov  dword ptr es:[ebx + 0x4F * 4], 0x2F003 + PCD * 0x10
    mov  dword ptr es:[ebx + 0x58 * 4], 0x38003 + PCD * 0x10
    mov  eax, 0x22000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  1f
1:
.endif
    mov  ax, S_BUF
    mov  es, ax
    mov  ax, S_FLG
    mov  fs, ax
    mov  ax, S_CW
    mov  gs, ax
    mov  word ptr [round], 0

round_top:
    # ---- 1. CPU writes the buffer (seed A) and its OLD copy, then reads it all
    mov  bx, [round]
    imul bx, bx, 77
    add  bx, 1
    xor  di, di
1:  call prng
    mov  es:[di], al
    mov  [OLD + di], al
    inc  di
    cmp  di, 4096
    jb   1b
    xor  di, di
    xor  ax, ax
1:  add  al, es:[di]
    inc  di
    cmp  di, 4096
    jb   1b
    # range: off = round * 0x2B3 mod 2048, len = 1 + round * 997 mod 2040
    mov  ax, [round]
    imul ax, ax, 0x2B3
    and  ax, 0x7FF
    mov  [off], ax
    mov  ax, [round]
    imul ax, ax, 997
    xor  dx, dx
    mov  cx, 2040
    div  cx
    inc  dx
    mov  [len], dx
    # EXP = OLD, then [off, off + len) from the stream with seed B
    xor  di, di
1:  mov  al, [OLD + di]
    mov  [EXP + di], al
    inc  di
    cmp  di, 4096
    jb   1b
    mov  bx, [round]
    imul bx, bx, 1234
    add  bx, 0x5A5
    mov  [seed], bx
    mov  di, [off]
    mov  cx, [len]
1:  call prng
    mov  [EXP + di], al
    inc  di
    loop 1b
    # ---- 2. DMA fill
    inc  dword ptr [flagv]
    xor  eax, eax
    mov  ax, [off]
    add  eax, 0x30000
    dmaout 0xD4, eax
    xor  eax, eax
    mov  ax, [len]
    mov  dx, 0xD8
    out  dx, ax
    mov  ax, [seed]
    mov  dx, 0xDA
    out  dx, ax
    dmaout 0xDC, 0x2F000
    dmaout 0xCC, [flagv]
    mov  al, 1
    mov  dx, 0xC8
    out  dx, al
    # while it runs: every byte is the old or the new one
    mov  ecx, 3000                    # timeout (flag checks, one per 64 bytes read)
2:  xor  di, di
1:  mov  al, es:[di]
    cmp  al, [OLD + di]
    je   3f
    cmp  al, [EXP + di]
    je   3f
    inc  word ptr [e2]
3:  test di, 63
    jnz  4f
    mov  eax, fs:[0]
    cmp  eax, [flagv]
    je   5f
    dec  ecx
    jz   6f
4:  inc  di
    cmp  di, 4096
    jb   1b
    jmp  2b
6:  inc  word ptr [to]
5:  # done: all of it
    xor  di, di
1:  mov  al, es:[di]
    cmp  al, [EXP + di]
    je   3f
    inc  word ptr [e1]
3:  inc  di
    cmp  di, 4096
    jb   1b
    # ---- 3. code: CPU-written snippet, then a DMA-copied one
    mov  ax, [round]
    add  ax, 0x1000
    mov  byte ptr gs:[0x1E], 0xB8
    mov  gs:[0x1F], ax
    mov  byte ptr gs:[0x21], 0xCB
    push ax
    .byte 0x9A
    .word 0x1E
    .word S_XC
    pop  dx
    cmp  ax, dx
    je   1f
    inc  word ptr [e3]
1:  mov  ax, [round]
    add  ax, 0x2000
    mov  [tpl + 1], ax
    inc  dword ptr [flagv]
    mov  eax, offset tpl
    add  eax, 0x10000
    dmaout 0xD0, eax
    dmaout 0xD4, 0x3801E
    mov  ax, 4
    mov  dx, 0xD8
    out  dx, ax
    dmaout 0xDC, 0x2F000
    dmaout 0xCC, [flagv]
    mov  al, 2
    mov  dx, 0xC8
    out  dx, al
    call waitf
    .byte 0x9A
    .word 0x1E
    .word S_XC
    mov  dx, [round]
    add  dx, 0x2000
    cmp  ax, dx
    je   1f
    inc  word ptr [e3]
1:
    inc  word ptr [round]
    cmp  word ptr [round], NROUND
    jb   round_top

    # ---- result
    mov  ax, S_CON
    mov  es, ax
    xor  di, di
    mov  si, offset msg
    call puts
    mov  ax, [e1]
    or   ax, [e2]
    or   ax, [e3]
    or   ax, [to]
    jnz  1f
    mov  si, offset m_ok
    call puts
    jmp  9f
1:  mov  si, offset m_e1
    call puts
    mov  ax, [e1]
    call puthex
    mov  si, offset m_e2
    call puts
    mov  ax, [e2]
    call puthex
    mov  si, offset m_e3
    call puts
    mov  ax, [e3]
    call puthex
    mov  si, offset m_to
    call puts
    mov  ax, [to]
    call puthex
9:  mov  byte ptr es:[di], 10
    hlt

# flag poll (cached line), with a timeout
waitf:
    mov  ecx, 30000
1:  mov  eax, fs:[0]
    cmp  eax, [flagv]
    je   2f
    dec  ecx
    jnz  1b
    inc  word ptr [to]
2:  ret
# bx: x = x * 25173 + 13849, al = x >> 8
prng:
    imul bx, bx, 25173
    add  bx, 13849
    mov  al, bh
    ret
puts:
1:  lodsb
    test al, al
    jz   2f
    mov  es:[di], al
    inc  di
    jmp  1b
2:  ret
puthex:
    mov  cx, 4
1:  rol  ax, 4
    mov  bx, ax
    and  bx, 15
    mov  bl, [hexd + bx]
    mov  es:[di], bl
    inc  di
    loop 1b
    ret

hexd:   .ascii "0123456789ABCDEF"
.if PG
msg:    .asciz "DMA PG "
.else
msg:    .asciz "DMA RM "
.endif
m_ok:   .asciz "OK"
m_e1:   .asciz "FAIL e1="
m_e2:   .asciz " e2="
m_e3:   .asciz " e3="
m_to:   .asciz " to="
.balign 4
tpl:    .byte 0xB8, 0, 0, 0xCB
round:  .word 0
off:    .word 0
len:    .word 0
seed:   .word 0
e1:     .word 0
e2:     .word 0
e3:     .word 0
to:     .word 0
.balign 4
flagv:  .long 0xF1A60000
gdtr:   .word 0x47
        .long 0x10000 + gdt
.balign 8
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 0          # 08 code16 (the program)
    desc 0x10000, 0xFFFF, 0x92, 0          # 10 data16 (program data, stack)
    desc 0x50000, 0xFFFF, 0x92, 0          # 18 buffer (alias of 30000)
    desc 0x4F000, 0xFFFF, 0x92, 0          # 20 flag (alias of 2F000)
    desc 0x58000, 0xFFFF, 0x9A, 0          # 28 code area (alias of 38000), code16
    desc 0x58000, 0xFFFF, 0x92, 0          # 30 code area, data
    desc 0x20000, 0xFFFF, 0x92, 0          # 38 console
    desc 0, 0xFFFFF, 0x92, 0xC             # 40 flat data
