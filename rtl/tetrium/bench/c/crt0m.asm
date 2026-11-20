; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 ZbuntowanyKamulec
; Freestanding startup for the medium-model builds of the C benchmarks (OpenWatcom
; -mm: far code, near data; every call is CALL FAR / RETF).  bench/c/buildm.sh links an
; MZ .EXE and tools/mz2img.py relocates it behind a jump at 1000:0100 (the testbench's
; entry); this sets DS = SS = DGROUP, calls main() and ends with HLT.
.8086
DGROUP  GROUP   CONST,CONST2,_DATA,_BSS,STACK

_TEXT   SEGMENT WORD PUBLIC USE16 'CODE'
        ASSUME  CS:_TEXT, DS:DGROUP, SS:DGROUP
        PUBLIC  _cstart_
        EXTRN   main_:FAR
_cstart_:
        mov     ax, DGROUP
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, offset DGROUP:stack_top
        cld
        call    main_
        mov     word ptr DGROUP:_exit_code, ax
        hlt
_TEXT   ENDS

CONST   SEGMENT WORD PUBLIC USE16 'DATA'
CONST   ENDS
CONST2  SEGMENT WORD PUBLIC USE16 'DATA'
CONST2  ENDS
_DATA   SEGMENT WORD PUBLIC USE16 'DATA'
        PUBLIC  _exit_code
_exit_code dw   0
_DATA   ENDS
_BSS    SEGMENT WORD PUBLIC USE16 'BSS'
_BSS    ENDS
STACK   SEGMENT PARA STACK USE16 'STACK'
        db      4096 dup(?)
stack_top label byte
STACK   ENDS

        END     _cstart_
