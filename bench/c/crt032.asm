; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 ZbuntowanyKamulec
; Freestanding startup for the 32-bit flat builds of the C benchmarks (OpenWatcom
; -mf -4r).  build32.sh links the program as a raw binary at a fixed linear address;
; tools/flat2img.py puts a 16-bit stub at 1000:0100 that enters protected mode (flat
; code 08, data 10) and jumps here.  Sets the segments and the stack, calls main()
; and ends with HLT.
.386p
.model flat
DGROUP  GROUP   CONST,CONST2,_DATA,_BSS,STACK

_TEXT   SEGMENT DWORD PUBLIC USE32 'CODE'
        PUBLIC  _cstart_
        EXTRN   main_:NEAR
_cstart_:
        mov     ax, 10h
        mov     ds, ax
        mov     es, ax
        mov     fs, ax
        mov     gs, ax
        mov     ss, ax
        mov     esp, offset stack_top
        cld
        call    main_
        mov     dword ptr _exit_code, eax
        hlt
_TEXT   ENDS

CONST   SEGMENT DWORD PUBLIC USE32 'DATA'
CONST   ENDS
CONST2  SEGMENT DWORD PUBLIC USE32 'DATA'
CONST2  ENDS
_DATA   SEGMENT DWORD PUBLIC USE32 'DATA'
        PUBLIC  _exit_code
_exit_code dd   0
_DATA   ENDS
_BSS    SEGMENT DWORD PUBLIC USE32 'BSS'
_BSS    ENDS
STACK   SEGMENT DWORD PUBLIC USE32 'STACK'
        db      8192 dup(?)
stack_top label byte
STACK   ENDS

        END     _cstart_
