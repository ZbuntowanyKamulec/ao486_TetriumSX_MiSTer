# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Startup of the 32-bit benchmark builds (tests/perf.sh): flat segments, stack, call ENTRY;
# with CHECK_RESULT a zero return writes "OK" to the console buffer (20000h), else "FAIL".
    .section .text.start, "ax"
    .code32
    .global _start
_start:
    movl $0x10, %eax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    movl $0x9fff0, %esp
    cld
    call ENTRY
#ifdef CHECK_RESULT
    testl %eax, %eax
    jnz 1f
    movl $0x00004b4f, 0x20000
    jmp 2f
1:  movl $0x4c494146, 0x20000
    movb $0, 0x20004
#endif
2:  hlt
    jmp 2b
