# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Probe library (included after the code; 32-bit ring 0, DS base 10000h = the image): results
# printed on port E9h as text, then Bochs's shutdown port and HLT.  The testbench shows port
# E9h with LOCKE9=1, Bochs with port_e9_hack.
.code32
putc:
    push edx
    mov  dx, 0xE9
    out  dx, al
    pop  edx
    ret
puts:
    push eax
    push esi
1:  lodsb
    test al, al
    jz   2f
    call putc
    jmp  1b
2:  pop  esi
    pop  eax
    ret
puthex:
    push eax
    push ecx
    push edx
    mov  edx, eax
    mov  ecx, 8
1:  rol  edx, 4
    mov  al, dl
    and  al, 15
    add  al, '0'
    cmp  al, '9'
    jbe  2f
    add  al, 7
2:  call putc
    loop 1b
    mov  al, ' '
    call putc
    pop  edx
    pop  ecx
    pop  eax
    ret
# end of the probe: newline, "Shutdown" on port 8900h (Bochs quits), halt
done:
    mov  al, 10
    call putc
    mov  esi, offset sdstr
    mov  dx, 0x8900
1:  lodsb
    test al, al
    jz   2f
    out  dx, al
    jmp  1b
2:  cli
    hlt
    jmp  2b
sdstr: .asciz "Shutdown"
