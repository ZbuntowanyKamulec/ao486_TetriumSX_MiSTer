; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 ZbuntowanyKamulec
; Freestanding .COM startup for the Tetrium benchmarks (OpenWatcom, tiny model).
; The testbench loads the image at 1000:0100 with CS=DS=ES=SS=1000, SP=FFFE and
; zeroed memory; main() runs and the program ends with HLT.
.8086
DGROUP  GROUP   _TEXT,CONST,CONST2,_DATA,_BSS

_TEXT   SEGMENT WORD PUBLIC USE16 'CODE'
        ASSUME  CS:DGROUP, DS:DGROUP, SS:DGROUP
        ORG     100h
        PUBLIC  _cstart_
_cstart_:
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

        EXTRN   main_:NEAR
        END     _cstart_
