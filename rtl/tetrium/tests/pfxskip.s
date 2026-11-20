# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Prefixes consumed together with the instruction in front of them (decode skip):
# single prefixes and prefix chains behind instructions of every length, 0F after
# another prefix, a prefix right behind an 11-byte instruction, prefixed branch
# targets and branches, REP / LOCK with segment overrides; the body is repeated at
# 8 alignments.  Real mode .COM, lockstep: tests/lock.sh
.intel_syntax noprefix
.code16
.org 0x100
start:
    mov  ax, cs
    mov  fs, ax
    mov  gs, ax
    mov  bp, 40
outer:
    xor  eax, eax
    xor  esi, esi
    xor  edi, edi
    mov  ecx, 0x00010003
    mov  ebx, 0x40
    call body0
    call body1
    call body2
    call body3
    call body4
    call body5
    call body6
    call body7
    call ptend
    dec  bp
    jnz  outer
    hlt

# predicted-taken branches ending at a block end whose target block holds a prefix
# value in front of the target (byte 0 of the block is not part of the instruction)
ptend:
    mov  cx, 6
    .align 8
1:  .fill 6, 1, 0x90
    jmp  2f                             # EB xx: bytes 6-7 of the block
    .align 8
    .byte 0x66                          # never executed
2:  mov  di, 0x1234                     # (BF imm16: with a 66 it would take imm32)
    add  ax, di
    .fill 4, 1, 0x90
    .byte 0x2E                          # block offset 7 of this block? (data, not executed)
    .align 8
    .fill 5, 1, 0x90
    dec  cx                             # 49 at offset 5
    jnz  3f                             # 75 xx: bytes 6-7
    ret
    .align 8
    .byte 0x67, 0xF3
3:  mov  si, 0x0010                     # with a 67 / F3 in front it would decode differently
    add  ax, [si]
    jmp  1b
.macro BODY n
body\n:
    .rept \n
    nop
    .endr
    mov  edx, 0x12345678
    add  eax, edx                       # 66 prefix behind 66-prefixed
    bswap edx                           # 66 0F C8: 66 skipped, 0F alone
    add  eax, edx
    movzx edx, word ptr fs:[bx]         # 64 66 0F B7: chain
    add  eax, edx
    movsx dx, byte ptr gs:[bx + 1]      # 65 0F BE
    add  ax, dx
    mov  dword ptr [ebx + ebx * 2 + 0x1000], 0x11223344   # 66 67 C7 84 5B disp32 imm32
    mov  edx, cs:[bx + 0x1000 + 0x80]   # 2E 66 8B (behind the 11-byte instruction)
    add  eax, edx
    mov  word ptr es:[bx + 0x1100], 0x5566
    add  ax, word ptr ss:[bx + 0x1100]
    lock add word ptr ds:[bx + 0x1100], ax
    lock xadd word ptr [bx + 0x1100], cx
    add  eax, ecx
    sete dl                             # 0F 94
    add  al, dl
    cmp  ax, 0x1234
    jne  1f                             # 0F-free short branch to a prefixed target
    inc  si
1:  add  esi, eax                       # target: 66 01 C6
    cmp  si, 0x7FFF
    .byte 0x0F, 0x87                    # ja rel16 (0F 87) over a prefixed instruction
    .word 2f - 3f
3:  add  eax, 0x10101010
2:  mov  di, 0x1200
    push ds
    pop  es
    lea  si, [bx + 0x1000]
    mov  cx, 5
    rep  movsw es:[di], cs:[si]         # F3 2E A5 / 2E F3 A5 order varies by assembler
    mov  cx, 3
    mov  di, 0x1200
    repe cmpsw fs:[si], es:[di]
    add  ax, cx
    mov  ecx, 0x00010003
    .byte 0x66, 0x2E, 0x8B, 0x16  # 66 2E mov edx, cs:[0x1100]: chain behind 2 prefixes
    .word 0x1100
    add  eax, edx
    .byte 0xF3, 0x66, 0x90              # pause-like rep 66 nop
    .byte 0x26, 0x3E, 0x67, 0x66, 0x8B, 0x43, 0x10   # 4 prefixes: mov eax, ds:[ebx + 16]
    add  [res], eax
    ret
.endm
    BODY 0
    BODY 1
    BODY 2
    BODY 3
    BODY 4
    BODY 5
    BODY 6
    BODY 7
.align 4
res: .long 0
