# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# #PF while a ring-3 CALL through a call gate copies its parameters from the outer stack:
# the inner SS:ESP are already loaded at that point; the fault must be delivered with the
# caller's SS:ESP (the #PF frame's SS slot = the ring-3 SS), and the CALL restarts after
# the handler maps the page.  32-bit and 16-bit gates, 2 and 3 parameters, the outer stack
# page missing (no part of the copy done) and the parameters crossing into a missing page.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.macro gate off, sel, acc, cnt=0
    .word \off
    .word \sel
    .byte \cnt, \acc
    .word 0
.endm
PT = 0x21000
TSSA = 0x30000
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
    mov  esp, 0xF000                    # (linear 1F000)
    mov  ax, 0x20                       # flat data
    mov  es, ax
    cld
    # paging: 0-4 MB identity, user / writable, A and D preset
    mov  edi, 0x20000
    mov  ecx, 1024
    xor  eax, eax
    rep  stosd
    mov  dword ptr es:[0x20000], PT + 7
    mov  edi, PT
    mov  eax, 0x67
    mov  ecx, 1024
1:  stosd
    add  eax, 0x1000
    loop 1b
    mov  edi, TSSA
    mov  ecx, 26
    xor  eax, eax
    rep  stosd
    mov  dword ptr es:[TSSA + 4], 0xE000   # ring 0 stack 10:E000 (linear 1E000)
    mov  dword ptr es:[TSSA + 8], 0x10
    mov  word ptr es:[TSSA + 102], 0x68
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  2f
2:  mov  ax, 0x28
    ltr  ax
    # to ring 3, stack 23:1C000 (page 1B000; 1C000 is mapped too)
    push 0x23
    push 0x1C000
    push 0x202
    push 0x1B
    push offset ring3
    iretd
ring3:
    # 32-bit gate, 2 parameters, the stack page missing
    push 0x11111111
    push 0x22222222
    mov  ebx, 0x1B000
    int  0x31                           # ring 0: unmap page EBX
    .byte 0x9A
    .long 0
    .word 0x4B
    add  es:[res + 0x10000], eax
    # 32-bit gate, 3 parameters crossing from page 1B000 (mapped) into 1C000 (missing)
    mov  esp, 0x1C008
    push 0x01000000
    push 0x00300000
    push 0x00005000
    mov  ebx, 0x1C000
    int  0x31
    .byte 0x9A
    .long 0
    .word 0x53
    add  es:[res + 0x10000], eax
    # 16-bit gate, 2 word parameters, the stack page missing
    mov  esp, 0x1C000
    .byte 0x66, 0x68                    # push word 0707h
    .word 0x0707
    .byte 0x66, 0x68                    # push word 0090h
    .word 0x0090
    mov  ebx, 0x1B000
    int  0x31
    .byte 0x9A
    .long 0
    .word 0x5B
    add  es:[res + 0x10000], eax
    int  0x30                           # done (ring 0 handler: HLT)
# ring 3 service: clear the present bit of page EBX
unmap:
    mov  eax, ebx
    shr  eax, 12
    and  byte ptr es:[PT + eax*4], 0xFE
    invlpg es:[ebx]
    iretd
# #PF: record CR2, the error code and the pushed SS / ESP, map the page
pf:
    push eax
    mov  eax, cr2
    add  es:[sum + 0x10000], eax
    mov  eax, [esp + 4]                 # error code
    add  es:[sum + 0x10000], eax
    mov  eax, [esp + 20]                # ESP slot
    add  es:[sum + 0x10000], eax
    mov  eax, [esp + 24]                # SS slot
    shl  eax, 8
    add  es:[sum + 0x10000], eax
    mov  eax, cr2
    shr  eax, 12
    or   byte ptr es:[PT + eax*4], 1
    pop  eax
    add  esp, 4
    iretd
gfn32:                                  # 2 parameters
    mov  eax, [esp + 8]
    add  eax, [esp + 12]
    retf 8
gfn32b:                                 # 3 parameters
    mov  eax, [esp + 8]
    add  eax, [esp + 12]
    add  eax, [esp + 16]
    retf 12
gfn16:                                  # 16-bit gate: IP, CS, 2 words
    movzx eax, word ptr [esp + 4]
    add  ax, [esp + 6]
    .byte 0x66
    retf 4
done:
    mov  eax, es:[res + 0x10000]
    mov  ebx, es:[sum + 0x10000]
    mov  ecx, [esp + 12]                # the ring-3 ESP at INT 30h
    hlt
.align 4
res:    .long 0
sum:    .long 0
gdtr:   .word gdt_end - gdt - 1
        .long 0x10000 + gdt
idtr:   .word 0x32 * 8 - 1
        .long 0x10000 + idt
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFFF, 0x9A, 0xC       # 08 code32 (base 10000)
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
    desc 0x10000, 0xFFFFF, 0xFA, 0xC       # 18 ring 3 code (1B)
    desc 0x00000, 0xFFFFF, 0xF2, 0xC       # 20 flat data, DPL 3 (23)
    desc TSSA, 0x67, 0x89, 0               # 28 TSS
    .quad 0                                # 30
    .quad 0                                # 38
    .quad 0                                # 40
    gate gfn32, 0x08, 0xEC, 2              # 48 32-bit call gate, DPL 3, 2 dwords
    gate gfn32b, 0x08, 0xEC, 3             # 50 32-bit call gate, 3 dwords
    gate gfn16, 0x08, 0xE4, 2              # 58 16-bit call gate, 2 words
gdt_end:
.org 0xC00
idt:
    .fill 0x0E, 8, 0
    gate pf, 0x08, 0x8E                    # 0E: #PF
    .fill 0x30 - 0x0F, 8, 0
    gate done, 0x08, 0xEE                  # 30: done
    gate unmap, 0x08, 0xEE                 # 31: unmap page EBX
