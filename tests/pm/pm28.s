# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# System instructions with memory operands at ring 0, paging on: SGDT / SIDT / SLDT / STR /
# SMSW stores, LGDT / LIDT / LLDT / LTR / LMSW / VERR / VERW / LAR / LSL / INVLPG operands,
# and other memory forms (BTR, MUL / IMUL, NOT, SETcc, LDS / LGS): each one plain, beyond
# the segment limit, through a read-only segment, on a not-present page and crossing into
# it.  The handlers log vector, error code and CR2 and resume after the instruction.
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
# one case: the handler resumes at the next label (ESI)
.macro T insn:vararg
    mov  esi, offset 9f
    \insn
9:
.endm
PT  = 0x21000
LOG = 0x30000
# FS: data at 40000 (page 40 present, 41 not), limit FFFF; GS: same base, limit FFF;
# ES: same base, read-only
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
    mov  es, ax
    mov  esp, 0x2F000
    mov  edi, 0x20000                   # page directory + table (identity, first 512 KB)
    mov  ecx, 2048
    xor  eax, eax
    cld
    rep  stosd
    mov  dword ptr [0x20000], PT + 3
    mov  edi, PT
    mov  eax, 3
    mov  ecx, 0x80
1:  stosd
    add  eax, 0x1000
    loop 1b
    mov  dword ptr [PT + 0x41 * 4], 0x41000      # page 41: not present
    mov  dword ptr [LOG], 0
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  2f
2:  mov  ax, 0x38
    ltr  ax
    mov  ax, 0x20
    mov  fs, ax
    mov  ax, 0x28
    mov  gs, ax
    mov  ax, 0x30
    mov  es, ax
    # operands for the loads: the current GDTR / IDTR / MSW, the LDT / TSS selectors
    sgdt fs:[0x100]
    sidt fs:[0x108]
    smsw fs:[0x110]
    mov  word ptr fs:[0x112], 0x40       # LDT
    mov  word ptr fs:[0x114], 0x48       # second TSS (available)
    mov  word ptr fs:[0x116], 0x10       # a data segment (VERR / VERW / LAR / LSL)
    mov  word ptr fs:[0xFFE], 0x10       # (the word below page 41)
    mov  dword ptr fs:[0xFFA], 0x12345678

# ---- stores
    T sgdt fs:[0x200]
    T sgdt gs:[0xFFC]                   # beyond the limit
    T sgdt es:[0x200]                   # read-only
    T sgdt fs:[0x1000]                  # not present
    T sgdt fs:[0xFFE]                   # crossing into page 41
    T sidt fs:[0x208]
    T sidt gs:[0xFFB]
    T sidt es:[0x208]
    T sidt fs:[0x1100]
    T sidt fs:[0xFFC]
    T sldt fs:[0x210]
    T sldt gs:[0xFFF]
    T sldt es:[0x210]
    T sldt fs:[0x1004]
    T sldt fs:[0xFFF]
    T str  fs:[0x212]
    T str  gs:[0x1000]
    T str  es:[0x212]
    T str  fs:[0x1008]
    T str  fs:[0xFFF]
    T smsw fs:[0x214]
    T smsw gs:[0xFFF]
    T smsw es:[0x214]
    T smsw fs:[0x100A]
    T smsw fs:[0xFFF]
# ---- loads
    T lgdt fs:[0x100]
    T lgdt gs:[0xFFC]
    T lgdt fs:[0x1000]
    T lgdt fs:[0xFFE]
    T lidt fs:[0x108]
    T lidt gs:[0xFFB]
    T lidt fs:[0x1000]
    T lidt fs:[0xFFC]
    T lmsw fs:[0x110]
    T lmsw gs:[0xFFF]
    T lmsw fs:[0x1000]
    T lmsw fs:[0xFFF]
    T lldt fs:[0x112]
    T lldt gs:[0xFFF]
    T lldt fs:[0x1000]
    T lldt fs:[0xFFF]
    T ltr  gs:[0xFFF]
    T ltr  fs:[0x1000]
    T ltr  fs:[0xFFF]
    T ltr  fs:[0x114]
    T ltr  fs:[0x114]                   # now busy: #GP(48)
    T verr word ptr fs:[0x116]
    T verr word ptr gs:[0xFFF]
    T verr word ptr fs:[0x1000]
    T verw word ptr fs:[0x116]
    T verw word ptr gs:[0x1000]
    T verw word ptr fs:[0xFFF]
    T lar  eax, word ptr fs:[0x116]
    T lar  eax, word ptr gs:[0xFFF]
    T lar  eax, word ptr fs:[0x1000]
    T lsl  ebx, word ptr fs:[0x116]
    T lsl  ebx, word ptr gs:[0x1000]
    T lsl  ebx, word ptr fs:[0xFFF]
    T invlpg fs:[0x1000]
    T invlpg gs:[0x2000]
    T invlpg es:[0x0]
# ---- other memory forms
    T btr  dword ptr fs:[0x300], 5
    T btr  dword ptr gs:[0xFFE], 5
    T btr  dword ptr es:[0x300], 5
    T btr  dword ptr fs:[0x1000], 5
    mov  ecx, 0x8003                    # (bit 8003h: dword 400h above the base)
    T btr  fs:[0xBFE], ecx
    T btr  gs:[0xBFE], ecx
    T btr  fs:[0xC00], ecx
    mov  eax, 3
    T mul  dword ptr fs:[0xFFA]
    T mul  dword ptr gs:[0xFFD]
    T mul  dword ptr fs:[0xFFE]
    T imul word ptr fs:[0xFFA]
    T imul word ptr gs:[0x1000]
    T imul dword ptr fs:[0x1000]
    T not  dword ptr fs:[0xFFA]
    T not  dword ptr es:[0x300]
    T not  word ptr gs:[0xFFF]
    T not  dword ptr fs:[0xFFD]
    T seto  byte ptr fs:[0x320]
    T setno byte ptr fs:[0x321]
    T setb  byte ptr gs:[0x1000]
    T setae byte ptr es:[0x320]
    T sete  byte ptr fs:[0x1000]
    T setne byte ptr fs:[0x1FFF]
    T setbe byte ptr gs:[0x2000]
    T seta  byte ptr es:[0x322]
    T sets  byte ptr fs:[0x1001]
    T setl  byte ptr fs:[0x323]
    mov  dword ptr fs:[0x400], 0x400
    mov  word ptr fs:[0x404], 0x20
    mov  word ptr fs:[0xFFE], 0x20
    T lds  ebx, fs:[0x400]
    mov  ax, 0x10
    mov  ds, ax
    T lgs  ebx, fs:[0x400]
    T lds  ebx, gs:[0xFFE]
    T lgs  ebx, fs:[0xFFC]              # selector on page 41
    T lgs  bx, fs:[0x1000]
    T lfs  ebx, fs:[0xFFE]
    mov  ax, 0x10
    mov  ds, ax
    mov  eax, [LOG]
    out  0xE9, al                       # (the number of faults: LOCKE9=1 shows it)
    hlt

# exception handlers: log {vector, error code, CR2} and resume at ESI
e0:  push 0
     push 0
     jmp  hc
e6:  push 0
     push 6
     jmp  hc
e12: push 12
     jmp  hc
e13: push 13
     jmp  hc
e14: push 14
     jmp  hc
hc:  push ds
     push eax
     push ebx
     mov  ax, 0x10
     mov  ds, ax
     mov  ebx, [LOG]
     lea  ebx, [ebx*4 + ebx]
     add  ebx, ebx
     add  ebx, ebx                      # 20 bytes per entry
     mov  eax, [esp+12]
     mov  [LOG + 4 + ebx], eax
     mov  eax, [esp+16]
     mov  [LOG + 8 + ebx], eax
     mov  eax, cr2
     mov  [LOG + 12 + ebx], eax
     mov  eax, [esp+20]
     mov  [LOG + 16 + ebx], eax          # faulting EIP
     mov  [LOG + 20 + ebx], esi
     inc  dword ptr [LOG]
     mov  [esp+20], esi
     pop  ebx
     pop  eax
     pop  ds
     add  esp, 8
     iretd

.org 0x3000
gdtr:
    .word gdt_end - gdt - 1
    .long 0x10000 + gdt
idtr:
    .word idt_end - idt - 1
    .long 0x10000 + idt
.align 8
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x00000, 0xFFFFF, 0x92, 0xC       # 10 flat data
    .quad 0                                # 18
    desc 0x40000, 0xFFFF, 0x92, 4          # 20 FS: page 40 / 41 not present
    desc 0x40000, 0x0FFF, 0x92, 4          # 28 GS: limit FFF
    desc 0x40000, 0xFFFF, 0x90, 4          # 30 ES: read-only
    desc 0x13300, 0x67, 0x89, 0            # 38 TSS
    desc 0x13200, 0x0F, 0x82, 0            # 40 LDT
    desc 0x13380, 0x67, 0x89, 0            # 48 second TSS
gdt_end:
.org 0x3200
ldt:
    .quad 0
    desc 0x40000, 0xFFFF, 0x92, 4
.org 0x3280
idt:
    gate e0, 0x08, 0x8E
    .fill 5, 8, 0
    gate e6, 0x08, 0x8E
    .fill 5, 8, 0
    gate e12, 0x08, 0x8E
    gate e13, 0x08, 0x8E
    gate e14, 0x08, 0x8E
idt_end:
.org 0x3300
tss:  .long 0, 0x2F000, 0x10
      .fill 0x68 - 12, 1, 0
.org 0x3380
tss2: .long 0, 0x2F000, 0x10
      .fill 0x68 - 12, 1, 0
