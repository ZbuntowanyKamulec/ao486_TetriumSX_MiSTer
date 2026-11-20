# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
.intel_syntax noprefix
.code16
.org 0x100
start:
    mov word ptr [cnt], 40
outer:
    call f0
    call f1
    call f2
    call f3
    call f4
    call f5
    call f6
    call f7
    call f8
    call f9
    call f10
    call f11
    call f12
    call f13
    call f14
    call f15
    call f16
    call f17
    call f18
    call f19
    call f20
    call f21
    call f22
    call f23
    call f24
    call f25
    call f26
    call f27
    call f28
    call f29
    call f30
    call f31
    call f32
    call f33
    call f34
    call f35
    call f36
    call f37
    call f38
    call f39
    call f40
    call f41
    call f42
    call f43
    call f44
    call f45
    call f46
    call f47
    call f48
    call f49
    call f50
    call f51
    call f52
    call f53
    call f54
    call f55
    call f56
    call f57
    call f58
    call f59
    call f60
    call f61
    call f62
    call f63
    call f64
    call f65
    call f66
    call f67
    call f68
    call f69
    call f70
    call f71
    call f72
    call f73
    call f74
    call f75
    call f76
    call f77
    call f78
    call f79
    call f80
    call f81
    call f82
    call f83
    call f84
    call f85
    call f86
    call f87
    call f88
    call f89
    call f90
    call f91
    call f92
    call f93
    call f94
    call f95
    call f96
    call f97
    call f98
    call f99
    call f100
    call f101
    call f102
    call f103
    call f104
    call f105
    call f106
    call f107
    call f108
    call f109
    call f110
    call f111
    call f112
    call f113
    call f114
    call f115
    call f116
    call f117
    call f118
    call f119
    call f120
    call f121
    call f122
    call f123
    call f124
    call f125
    call f126
    call f127
    dec word ptr [cnt]
    jz done
    jmp outer
done:
    hlt
cnt: .word 0
acc: .word 0
buf: .space 64
f0:
    push bp
    mov bp, sp
    mov cx, 4
l0:
    mov ax, cx
    and ax, 1
    jnz s0
    add word ptr [acc], 7
s0:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 83
    mov [buf+bx], ax
    call h0
    loop l0
    pop bp
    ret
f1:
    push bp
    mov bp, sp
    mov cx, 2
l1:
    mov ax, cx
    and ax, 1
    jnz s1
    add word ptr [acc], 2
s1:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 46
    mov [buf+bx], ax
    call h1
    loop l1
    pop bp
    ret
f2:
    push bp
    mov bp, sp
    mov cx, 2
l2:
    mov ax, cx
    and ax, 1
    jnz s2
    add word ptr [acc], 1
s2:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 11
    mov [buf+bx], ax
    call h2
    loop l2
    pop bp
    ret
f3:
    push bp
    mov bp, sp
    mov cx, 5
l3:
    mov ax, cx
    and ax, 3
    jnz s3
    add word ptr [acc], 2
s3:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 30
    mov [buf+bx], ax
    call h3
    loop l3
    pop bp
    ret
f4:
    push bp
    mov bp, sp
    mov cx, 2
l4:
    mov ax, cx
    and ax, 3
    jnz s4
    add word ptr [acc], 1
s4:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 72
    mov [buf+bx], ax
    call h4
    loop l4
    pop bp
    ret
f5:
    push bp
    mov bp, sp
    mov cx, 2
l5:
    mov ax, cx
    and ax, 1
    jnz s5
    add word ptr [acc], 1
s5:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 73
    mov [buf+bx], ax
    call h5
    loop l5
    pop bp
    ret
f6:
    push bp
    mov bp, sp
    mov cx, 5
l6:
    mov ax, cx
    and ax, 1
    jnz s6
    add word ptr [acc], 4
s6:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 5
    mov [buf+bx], ax
    call h6
    loop l6
    pop bp
    ret
f7:
    push bp
    mov bp, sp
    mov cx, 3
l7:
    mov ax, cx
    and ax, 3
    jnz s7
    add word ptr [acc], 7
s7:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 18
    mov [buf+bx], ax
    call h7
    loop l7
    pop bp
    ret
f8:
    push bp
    mov bp, sp
    mov cx, 2
l8:
    mov ax, cx
    and ax, 3
    jnz s8
    add word ptr [acc], 3
s8:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 13
    mov [buf+bx], ax
    call h0
    loop l8
    pop bp
    ret
f9:
    push bp
    mov bp, sp
    mov cx, 3
l9:
    mov ax, cx
    and ax, 3
    jnz s9
    add word ptr [acc], 2
s9:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 70
    mov [buf+bx], ax
    call h1
    loop l9
    pop bp
    ret
f10:
    push bp
    mov bp, sp
    mov cx, 2
l10:
    mov ax, cx
    and ax, 1
    jnz s10
    add word ptr [acc], 4
s10:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 63
    mov [buf+bx], ax
    call h2
    loop l10
    pop bp
    ret
f11:
    push bp
    mov bp, sp
    mov cx, 5
l11:
    mov ax, cx
    and ax, 3
    jnz s11
    add word ptr [acc], 8
s11:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 74
    mov [buf+bx], ax
    call h3
    loop l11
    pop bp
    ret
f12:
    push bp
    mov bp, sp
    mov cx, 5
l12:
    mov ax, cx
    and ax, 3
    jnz s12
    add word ptr [acc], 5
s12:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 31
    mov [buf+bx], ax
    call h4
    loop l12
    pop bp
    ret
f13:
    push bp
    mov bp, sp
    mov cx, 3
l13:
    mov ax, cx
    and ax, 1
    jnz s13
    add word ptr [acc], 2
s13:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 73
    mov [buf+bx], ax
    call h5
    loop l13
    pop bp
    ret
f14:
    push bp
    mov bp, sp
    mov cx, 4
l14:
    mov ax, cx
    and ax, 3
    jnz s14
    add word ptr [acc], 6
s14:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 93
    mov [buf+bx], ax
    call h6
    loop l14
    pop bp
    ret
f15:
    push bp
    mov bp, sp
    mov cx, 5
l15:
    mov ax, cx
    and ax, 3
    jnz s15
    add word ptr [acc], 2
s15:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 15
    mov [buf+bx], ax
    call h7
    loop l15
    pop bp
    ret
f16:
    push bp
    mov bp, sp
    mov cx, 5
l16:
    mov ax, cx
    and ax, 1
    jnz s16
    add word ptr [acc], 6
s16:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 19
    mov [buf+bx], ax
    call h0
    loop l16
    pop bp
    ret
f17:
    push bp
    mov bp, sp
    mov cx, 5
l17:
    mov ax, cx
    and ax, 3
    jnz s17
    add word ptr [acc], 1
s17:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 85
    mov [buf+bx], ax
    call h1
    loop l17
    pop bp
    ret
f18:
    push bp
    mov bp, sp
    mov cx, 2
l18:
    mov ax, cx
    and ax, 3
    jnz s18
    add word ptr [acc], 6
s18:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 88
    mov [buf+bx], ax
    call h2
    loop l18
    pop bp
    ret
f19:
    push bp
    mov bp, sp
    mov cx, 4
l19:
    mov ax, cx
    and ax, 3
    jnz s19
    add word ptr [acc], 8
s19:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 8
    mov [buf+bx], ax
    call h3
    loop l19
    pop bp
    ret
f20:
    push bp
    mov bp, sp
    mov cx, 2
l20:
    mov ax, cx
    and ax, 3
    jnz s20
    add word ptr [acc], 8
s20:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 89
    mov [buf+bx], ax
    call h4
    loop l20
    pop bp
    ret
f21:
    push bp
    mov bp, sp
    mov cx, 2
l21:
    mov ax, cx
    and ax, 1
    jnz s21
    add word ptr [acc], 5
s21:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 82
    mov [buf+bx], ax
    call h5
    loop l21
    pop bp
    ret
f22:
    push bp
    mov bp, sp
    mov cx, 5
l22:
    mov ax, cx
    and ax, 3
    jnz s22
    add word ptr [acc], 7
s22:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 85
    mov [buf+bx], ax
    call h6
    loop l22
    pop bp
    ret
f23:
    push bp
    mov bp, sp
    mov cx, 4
l23:
    mov ax, cx
    and ax, 1
    jnz s23
    add word ptr [acc], 8
s23:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 45
    mov [buf+bx], ax
    call h7
    loop l23
    pop bp
    ret
f24:
    push bp
    mov bp, sp
    mov cx, 3
l24:
    mov ax, cx
    and ax, 1
    jnz s24
    add word ptr [acc], 8
s24:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 7
    mov [buf+bx], ax
    call h0
    loop l24
    pop bp
    ret
f25:
    push bp
    mov bp, sp
    mov cx, 3
l25:
    mov ax, cx
    and ax, 3
    jnz s25
    add word ptr [acc], 3
s25:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 94
    mov [buf+bx], ax
    call h1
    loop l25
    pop bp
    ret
f26:
    push bp
    mov bp, sp
    mov cx, 3
l26:
    mov ax, cx
    and ax, 3
    jnz s26
    add word ptr [acc], 7
s26:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 63
    mov [buf+bx], ax
    call h2
    loop l26
    pop bp
    ret
f27:
    push bp
    mov bp, sp
    mov cx, 2
l27:
    mov ax, cx
    and ax, 1
    jnz s27
    add word ptr [acc], 8
s27:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 51
    mov [buf+bx], ax
    call h3
    loop l27
    pop bp
    ret
f28:
    push bp
    mov bp, sp
    mov cx, 4
l28:
    mov ax, cx
    and ax, 1
    jnz s28
    add word ptr [acc], 7
s28:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 70
    mov [buf+bx], ax
    call h4
    loop l28
    pop bp
    ret
f29:
    push bp
    mov bp, sp
    mov cx, 4
l29:
    mov ax, cx
    and ax, 3
    jnz s29
    add word ptr [acc], 6
s29:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 87
    mov [buf+bx], ax
    call h5
    loop l29
    pop bp
    ret
f30:
    push bp
    mov bp, sp
    mov cx, 5
l30:
    mov ax, cx
    and ax, 1
    jnz s30
    add word ptr [acc], 3
s30:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 10
    mov [buf+bx], ax
    call h6
    loop l30
    pop bp
    ret
f31:
    push bp
    mov bp, sp
    mov cx, 3
l31:
    mov ax, cx
    and ax, 1
    jnz s31
    add word ptr [acc], 4
s31:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 84
    mov [buf+bx], ax
    call h7
    loop l31
    pop bp
    ret
f32:
    push bp
    mov bp, sp
    mov cx, 3
l32:
    mov ax, cx
    and ax, 1
    jnz s32
    add word ptr [acc], 8
s32:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 75
    mov [buf+bx], ax
    call h0
    loop l32
    pop bp
    ret
f33:
    push bp
    mov bp, sp
    mov cx, 3
l33:
    mov ax, cx
    and ax, 3
    jnz s33
    add word ptr [acc], 5
s33:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 0
    mov [buf+bx], ax
    call h1
    loop l33
    pop bp
    ret
f34:
    push bp
    mov bp, sp
    mov cx, 3
l34:
    mov ax, cx
    and ax, 3
    jnz s34
    add word ptr [acc], 6
s34:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 78
    mov [buf+bx], ax
    call h2
    loop l34
    pop bp
    ret
f35:
    push bp
    mov bp, sp
    mov cx, 4
l35:
    mov ax, cx
    and ax, 1
    jnz s35
    add word ptr [acc], 1
s35:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 58
    mov [buf+bx], ax
    call h3
    loop l35
    pop bp
    ret
f36:
    push bp
    mov bp, sp
    mov cx, 5
l36:
    mov ax, cx
    and ax, 3
    jnz s36
    add word ptr [acc], 7
s36:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 50
    mov [buf+bx], ax
    call h4
    loop l36
    pop bp
    ret
f37:
    push bp
    mov bp, sp
    mov cx, 2
l37:
    mov ax, cx
    and ax, 3
    jnz s37
    add word ptr [acc], 7
s37:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 7
    mov [buf+bx], ax
    call h5
    loop l37
    pop bp
    ret
f38:
    push bp
    mov bp, sp
    mov cx, 3
l38:
    mov ax, cx
    and ax, 1
    jnz s38
    add word ptr [acc], 4
s38:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 56
    mov [buf+bx], ax
    call h6
    loop l38
    pop bp
    ret
f39:
    push bp
    mov bp, sp
    mov cx, 3
l39:
    mov ax, cx
    and ax, 1
    jnz s39
    add word ptr [acc], 6
s39:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 76
    mov [buf+bx], ax
    call h7
    loop l39
    pop bp
    ret
f40:
    push bp
    mov bp, sp
    mov cx, 2
l40:
    mov ax, cx
    and ax, 1
    jnz s40
    add word ptr [acc], 1
s40:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 72
    mov [buf+bx], ax
    call h0
    loop l40
    pop bp
    ret
f41:
    push bp
    mov bp, sp
    mov cx, 3
l41:
    mov ax, cx
    and ax, 1
    jnz s41
    add word ptr [acc], 6
s41:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 78
    mov [buf+bx], ax
    call h1
    loop l41
    pop bp
    ret
f42:
    push bp
    mov bp, sp
    mov cx, 2
l42:
    mov ax, cx
    and ax, 1
    jnz s42
    add word ptr [acc], 4
s42:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 78
    mov [buf+bx], ax
    call h2
    loop l42
    pop bp
    ret
f43:
    push bp
    mov bp, sp
    mov cx, 5
l43:
    mov ax, cx
    and ax, 1
    jnz s43
    add word ptr [acc], 5
s43:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 44
    mov [buf+bx], ax
    call h3
    loop l43
    pop bp
    ret
f44:
    push bp
    mov bp, sp
    mov cx, 4
l44:
    mov ax, cx
    and ax, 3
    jnz s44
    add word ptr [acc], 2
s44:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 14
    mov [buf+bx], ax
    call h4
    loop l44
    pop bp
    ret
f45:
    push bp
    mov bp, sp
    mov cx, 5
l45:
    mov ax, cx
    and ax, 3
    jnz s45
    add word ptr [acc], 8
s45:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 61
    mov [buf+bx], ax
    call h5
    loop l45
    pop bp
    ret
f46:
    push bp
    mov bp, sp
    mov cx, 4
l46:
    mov ax, cx
    and ax, 1
    jnz s46
    add word ptr [acc], 3
s46:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 13
    mov [buf+bx], ax
    call h6
    loop l46
    pop bp
    ret
f47:
    push bp
    mov bp, sp
    mov cx, 4
l47:
    mov ax, cx
    and ax, 3
    jnz s47
    add word ptr [acc], 8
s47:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 88
    mov [buf+bx], ax
    call h7
    loop l47
    pop bp
    ret
f48:
    push bp
    mov bp, sp
    mov cx, 3
l48:
    mov ax, cx
    and ax, 1
    jnz s48
    add word ptr [acc], 4
s48:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 67
    mov [buf+bx], ax
    call h0
    loop l48
    pop bp
    ret
f49:
    push bp
    mov bp, sp
    mov cx, 4
l49:
    mov ax, cx
    and ax, 1
    jnz s49
    add word ptr [acc], 1
s49:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 97
    mov [buf+bx], ax
    call h1
    loop l49
    pop bp
    ret
f50:
    push bp
    mov bp, sp
    mov cx, 4
l50:
    mov ax, cx
    and ax, 1
    jnz s50
    add word ptr [acc], 5
s50:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 66
    mov [buf+bx], ax
    call h2
    loop l50
    pop bp
    ret
f51:
    push bp
    mov bp, sp
    mov cx, 4
l51:
    mov ax, cx
    and ax, 1
    jnz s51
    add word ptr [acc], 6
s51:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 98
    mov [buf+bx], ax
    call h3
    loop l51
    pop bp
    ret
f52:
    push bp
    mov bp, sp
    mov cx, 3
l52:
    mov ax, cx
    and ax, 3
    jnz s52
    add word ptr [acc], 4
s52:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 78
    mov [buf+bx], ax
    call h4
    loop l52
    pop bp
    ret
f53:
    push bp
    mov bp, sp
    mov cx, 3
l53:
    mov ax, cx
    and ax, 1
    jnz s53
    add word ptr [acc], 7
s53:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 94
    mov [buf+bx], ax
    call h5
    loop l53
    pop bp
    ret
f54:
    push bp
    mov bp, sp
    mov cx, 3
l54:
    mov ax, cx
    and ax, 1
    jnz s54
    add word ptr [acc], 8
s54:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 45
    mov [buf+bx], ax
    call h6
    loop l54
    pop bp
    ret
f55:
    push bp
    mov bp, sp
    mov cx, 2
l55:
    mov ax, cx
    and ax, 1
    jnz s55
    add word ptr [acc], 5
s55:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 60
    mov [buf+bx], ax
    call h7
    loop l55
    pop bp
    ret
f56:
    push bp
    mov bp, sp
    mov cx, 4
l56:
    mov ax, cx
    and ax, 1
    jnz s56
    add word ptr [acc], 6
s56:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 57
    mov [buf+bx], ax
    call h0
    loop l56
    pop bp
    ret
f57:
    push bp
    mov bp, sp
    mov cx, 4
l57:
    mov ax, cx
    and ax, 3
    jnz s57
    add word ptr [acc], 2
s57:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 28
    mov [buf+bx], ax
    call h1
    loop l57
    pop bp
    ret
f58:
    push bp
    mov bp, sp
    mov cx, 2
l58:
    mov ax, cx
    and ax, 1
    jnz s58
    add word ptr [acc], 8
s58:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 25
    mov [buf+bx], ax
    call h2
    loop l58
    pop bp
    ret
f59:
    push bp
    mov bp, sp
    mov cx, 4
l59:
    mov ax, cx
    and ax, 1
    jnz s59
    add word ptr [acc], 8
s59:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 79
    mov [buf+bx], ax
    call h3
    loop l59
    pop bp
    ret
f60:
    push bp
    mov bp, sp
    mov cx, 2
l60:
    mov ax, cx
    and ax, 3
    jnz s60
    add word ptr [acc], 6
s60:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 82
    mov [buf+bx], ax
    call h4
    loop l60
    pop bp
    ret
f61:
    push bp
    mov bp, sp
    mov cx, 2
l61:
    mov ax, cx
    and ax, 1
    jnz s61
    add word ptr [acc], 7
s61:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 91
    mov [buf+bx], ax
    call h5
    loop l61
    pop bp
    ret
f62:
    push bp
    mov bp, sp
    mov cx, 3
l62:
    mov ax, cx
    and ax, 3
    jnz s62
    add word ptr [acc], 3
s62:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 55
    mov [buf+bx], ax
    call h6
    loop l62
    pop bp
    ret
f63:
    push bp
    mov bp, sp
    mov cx, 4
l63:
    mov ax, cx
    and ax, 1
    jnz s63
    add word ptr [acc], 7
s63:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 59
    mov [buf+bx], ax
    call h7
    loop l63
    pop bp
    ret
f64:
    push bp
    mov bp, sp
    mov cx, 5
l64:
    mov ax, cx
    and ax, 1
    jnz s64
    add word ptr [acc], 3
s64:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 21
    mov [buf+bx], ax
    call h0
    loop l64
    pop bp
    ret
f65:
    push bp
    mov bp, sp
    mov cx, 3
l65:
    mov ax, cx
    and ax, 1
    jnz s65
    add word ptr [acc], 3
s65:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 75
    mov [buf+bx], ax
    call h1
    loop l65
    pop bp
    ret
f66:
    push bp
    mov bp, sp
    mov cx, 5
l66:
    mov ax, cx
    and ax, 1
    jnz s66
    add word ptr [acc], 8
s66:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 84
    mov [buf+bx], ax
    call h2
    loop l66
    pop bp
    ret
f67:
    push bp
    mov bp, sp
    mov cx, 4
l67:
    mov ax, cx
    and ax, 1
    jnz s67
    add word ptr [acc], 3
s67:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 2
    mov [buf+bx], ax
    call h3
    loop l67
    pop bp
    ret
f68:
    push bp
    mov bp, sp
    mov cx, 2
l68:
    mov ax, cx
    and ax, 1
    jnz s68
    add word ptr [acc], 3
s68:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 55
    mov [buf+bx], ax
    call h4
    loop l68
    pop bp
    ret
f69:
    push bp
    mov bp, sp
    mov cx, 3
l69:
    mov ax, cx
    and ax, 1
    jnz s69
    add word ptr [acc], 1
s69:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 32
    mov [buf+bx], ax
    call h5
    loop l69
    pop bp
    ret
f70:
    push bp
    mov bp, sp
    mov cx, 3
l70:
    mov ax, cx
    and ax, 3
    jnz s70
    add word ptr [acc], 4
s70:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 97
    mov [buf+bx], ax
    call h6
    loop l70
    pop bp
    ret
f71:
    push bp
    mov bp, sp
    mov cx, 4
l71:
    mov ax, cx
    and ax, 3
    jnz s71
    add word ptr [acc], 7
s71:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 16
    mov [buf+bx], ax
    call h7
    loop l71
    pop bp
    ret
f72:
    push bp
    mov bp, sp
    mov cx, 2
l72:
    mov ax, cx
    and ax, 3
    jnz s72
    add word ptr [acc], 8
s72:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 84
    mov [buf+bx], ax
    call h0
    loop l72
    pop bp
    ret
f73:
    push bp
    mov bp, sp
    mov cx, 5
l73:
    mov ax, cx
    and ax, 1
    jnz s73
    add word ptr [acc], 3
s73:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 67
    mov [buf+bx], ax
    call h1
    loop l73
    pop bp
    ret
f74:
    push bp
    mov bp, sp
    mov cx, 2
l74:
    mov ax, cx
    and ax, 3
    jnz s74
    add word ptr [acc], 3
s74:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 77
    mov [buf+bx], ax
    call h2
    loop l74
    pop bp
    ret
f75:
    push bp
    mov bp, sp
    mov cx, 2
l75:
    mov ax, cx
    and ax, 1
    jnz s75
    add word ptr [acc], 3
s75:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 18
    mov [buf+bx], ax
    call h3
    loop l75
    pop bp
    ret
f76:
    push bp
    mov bp, sp
    mov cx, 5
l76:
    mov ax, cx
    and ax, 1
    jnz s76
    add word ptr [acc], 1
s76:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 41
    mov [buf+bx], ax
    call h4
    loop l76
    pop bp
    ret
f77:
    push bp
    mov bp, sp
    mov cx, 5
l77:
    mov ax, cx
    and ax, 1
    jnz s77
    add word ptr [acc], 1
s77:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 31
    mov [buf+bx], ax
    call h5
    loop l77
    pop bp
    ret
f78:
    push bp
    mov bp, sp
    mov cx, 3
l78:
    mov ax, cx
    and ax, 3
    jnz s78
    add word ptr [acc], 1
s78:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 98
    mov [buf+bx], ax
    call h6
    loop l78
    pop bp
    ret
f79:
    push bp
    mov bp, sp
    mov cx, 2
l79:
    mov ax, cx
    and ax, 3
    jnz s79
    add word ptr [acc], 1
s79:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 97
    mov [buf+bx], ax
    call h7
    loop l79
    pop bp
    ret
f80:
    push bp
    mov bp, sp
    mov cx, 2
l80:
    mov ax, cx
    and ax, 3
    jnz s80
    add word ptr [acc], 6
s80:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 78
    mov [buf+bx], ax
    call h0
    loop l80
    pop bp
    ret
f81:
    push bp
    mov bp, sp
    mov cx, 3
l81:
    mov ax, cx
    and ax, 3
    jnz s81
    add word ptr [acc], 8
s81:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 65
    mov [buf+bx], ax
    call h1
    loop l81
    pop bp
    ret
f82:
    push bp
    mov bp, sp
    mov cx, 5
l82:
    mov ax, cx
    and ax, 1
    jnz s82
    add word ptr [acc], 5
s82:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 71
    mov [buf+bx], ax
    call h2
    loop l82
    pop bp
    ret
f83:
    push bp
    mov bp, sp
    mov cx, 3
l83:
    mov ax, cx
    and ax, 3
    jnz s83
    add word ptr [acc], 3
s83:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 53
    mov [buf+bx], ax
    call h3
    loop l83
    pop bp
    ret
f84:
    push bp
    mov bp, sp
    mov cx, 2
l84:
    mov ax, cx
    and ax, 3
    jnz s84
    add word ptr [acc], 8
s84:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 40
    mov [buf+bx], ax
    call h4
    loop l84
    pop bp
    ret
f85:
    push bp
    mov bp, sp
    mov cx, 2
l85:
    mov ax, cx
    and ax, 1
    jnz s85
    add word ptr [acc], 7
s85:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 9
    mov [buf+bx], ax
    call h5
    loop l85
    pop bp
    ret
f86:
    push bp
    mov bp, sp
    mov cx, 3
l86:
    mov ax, cx
    and ax, 3
    jnz s86
    add word ptr [acc], 2
s86:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 99
    mov [buf+bx], ax
    call h6
    loop l86
    pop bp
    ret
f87:
    push bp
    mov bp, sp
    mov cx, 3
l87:
    mov ax, cx
    and ax, 3
    jnz s87
    add word ptr [acc], 3
s87:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 32
    mov [buf+bx], ax
    call h7
    loop l87
    pop bp
    ret
f88:
    push bp
    mov bp, sp
    mov cx, 3
l88:
    mov ax, cx
    and ax, 3
    jnz s88
    add word ptr [acc], 4
s88:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 95
    mov [buf+bx], ax
    call h0
    loop l88
    pop bp
    ret
f89:
    push bp
    mov bp, sp
    mov cx, 2
l89:
    mov ax, cx
    and ax, 3
    jnz s89
    add word ptr [acc], 8
s89:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 20
    mov [buf+bx], ax
    call h1
    loop l89
    pop bp
    ret
f90:
    push bp
    mov bp, sp
    mov cx, 3
l90:
    mov ax, cx
    and ax, 1
    jnz s90
    add word ptr [acc], 7
s90:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 65
    mov [buf+bx], ax
    call h2
    loop l90
    pop bp
    ret
f91:
    push bp
    mov bp, sp
    mov cx, 5
l91:
    mov ax, cx
    and ax, 3
    jnz s91
    add word ptr [acc], 7
s91:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 25
    mov [buf+bx], ax
    call h3
    loop l91
    pop bp
    ret
f92:
    push bp
    mov bp, sp
    mov cx, 4
l92:
    mov ax, cx
    and ax, 3
    jnz s92
    add word ptr [acc], 2
s92:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 92
    mov [buf+bx], ax
    call h4
    loop l92
    pop bp
    ret
f93:
    push bp
    mov bp, sp
    mov cx, 4
l93:
    mov ax, cx
    and ax, 1
    jnz s93
    add word ptr [acc], 6
s93:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 70
    mov [buf+bx], ax
    call h5
    loop l93
    pop bp
    ret
f94:
    push bp
    mov bp, sp
    mov cx, 5
l94:
    mov ax, cx
    and ax, 3
    jnz s94
    add word ptr [acc], 1
s94:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 49
    mov [buf+bx], ax
    call h6
    loop l94
    pop bp
    ret
f95:
    push bp
    mov bp, sp
    mov cx, 4
l95:
    mov ax, cx
    and ax, 3
    jnz s95
    add word ptr [acc], 2
s95:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 14
    mov [buf+bx], ax
    call h7
    loop l95
    pop bp
    ret
f96:
    push bp
    mov bp, sp
    mov cx, 3
l96:
    mov ax, cx
    and ax, 1
    jnz s96
    add word ptr [acc], 2
s96:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 33
    mov [buf+bx], ax
    call h0
    loop l96
    pop bp
    ret
f97:
    push bp
    mov bp, sp
    mov cx, 4
l97:
    mov ax, cx
    and ax, 1
    jnz s97
    add word ptr [acc], 3
s97:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 34
    mov [buf+bx], ax
    call h1
    loop l97
    pop bp
    ret
f98:
    push bp
    mov bp, sp
    mov cx, 3
l98:
    mov ax, cx
    and ax, 3
    jnz s98
    add word ptr [acc], 5
s98:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 51
    mov [buf+bx], ax
    call h2
    loop l98
    pop bp
    ret
f99:
    push bp
    mov bp, sp
    mov cx, 3
l99:
    mov ax, cx
    and ax, 3
    jnz s99
    add word ptr [acc], 6
s99:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 11
    mov [buf+bx], ax
    call h3
    loop l99
    pop bp
    ret
f100:
    push bp
    mov bp, sp
    mov cx, 4
l100:
    mov ax, cx
    and ax, 1
    jnz s100
    add word ptr [acc], 3
s100:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 54
    mov [buf+bx], ax
    call h4
    loop l100
    pop bp
    ret
f101:
    push bp
    mov bp, sp
    mov cx, 2
l101:
    mov ax, cx
    and ax, 3
    jnz s101
    add word ptr [acc], 1
s101:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 81
    mov [buf+bx], ax
    call h5
    loop l101
    pop bp
    ret
f102:
    push bp
    mov bp, sp
    mov cx, 2
l102:
    mov ax, cx
    and ax, 3
    jnz s102
    add word ptr [acc], 2
s102:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 77
    mov [buf+bx], ax
    call h6
    loop l102
    pop bp
    ret
f103:
    push bp
    mov bp, sp
    mov cx, 3
l103:
    mov ax, cx
    and ax, 1
    jnz s103
    add word ptr [acc], 5
s103:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 15
    mov [buf+bx], ax
    call h7
    loop l103
    pop bp
    ret
f104:
    push bp
    mov bp, sp
    mov cx, 5
l104:
    mov ax, cx
    and ax, 1
    jnz s104
    add word ptr [acc], 6
s104:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 70
    mov [buf+bx], ax
    call h0
    loop l104
    pop bp
    ret
f105:
    push bp
    mov bp, sp
    mov cx, 5
l105:
    mov ax, cx
    and ax, 3
    jnz s105
    add word ptr [acc], 3
s105:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 5
    mov [buf+bx], ax
    call h1
    loop l105
    pop bp
    ret
f106:
    push bp
    mov bp, sp
    mov cx, 3
l106:
    mov ax, cx
    and ax, 1
    jnz s106
    add word ptr [acc], 3
s106:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 33
    mov [buf+bx], ax
    call h2
    loop l106
    pop bp
    ret
f107:
    push bp
    mov bp, sp
    mov cx, 2
l107:
    mov ax, cx
    and ax, 1
    jnz s107
    add word ptr [acc], 4
s107:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 39
    mov [buf+bx], ax
    call h3
    loop l107
    pop bp
    ret
f108:
    push bp
    mov bp, sp
    mov cx, 4
l108:
    mov ax, cx
    and ax, 1
    jnz s108
    add word ptr [acc], 5
s108:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 57
    mov [buf+bx], ax
    call h4
    loop l108
    pop bp
    ret
f109:
    push bp
    mov bp, sp
    mov cx, 3
l109:
    mov ax, cx
    and ax, 3
    jnz s109
    add word ptr [acc], 6
s109:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 2
    mov [buf+bx], ax
    call h5
    loop l109
    pop bp
    ret
f110:
    push bp
    mov bp, sp
    mov cx, 4
l110:
    mov ax, cx
    and ax, 1
    jnz s110
    add word ptr [acc], 1
s110:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 2
    mov [buf+bx], ax
    call h6
    loop l110
    pop bp
    ret
f111:
    push bp
    mov bp, sp
    mov cx, 3
l111:
    mov ax, cx
    and ax, 3
    jnz s111
    add word ptr [acc], 4
s111:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 57
    mov [buf+bx], ax
    call h7
    loop l111
    pop bp
    ret
f112:
    push bp
    mov bp, sp
    mov cx, 2
l112:
    mov ax, cx
    and ax, 3
    jnz s112
    add word ptr [acc], 8
s112:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 69
    mov [buf+bx], ax
    call h0
    loop l112
    pop bp
    ret
f113:
    push bp
    mov bp, sp
    mov cx, 5
l113:
    mov ax, cx
    and ax, 3
    jnz s113
    add word ptr [acc], 4
s113:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 29
    mov [buf+bx], ax
    call h1
    loop l113
    pop bp
    ret
f114:
    push bp
    mov bp, sp
    mov cx, 4
l114:
    mov ax, cx
    and ax, 1
    jnz s114
    add word ptr [acc], 3
s114:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 51
    mov [buf+bx], ax
    call h2
    loop l114
    pop bp
    ret
f115:
    push bp
    mov bp, sp
    mov cx, 4
l115:
    mov ax, cx
    and ax, 1
    jnz s115
    add word ptr [acc], 3
s115:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 1
    mov [buf+bx], ax
    call h3
    loop l115
    pop bp
    ret
f116:
    push bp
    mov bp, sp
    mov cx, 2
l116:
    mov ax, cx
    and ax, 3
    jnz s116
    add word ptr [acc], 7
s116:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 20
    mov [buf+bx], ax
    call h4
    loop l116
    pop bp
    ret
f117:
    push bp
    mov bp, sp
    mov cx, 2
l117:
    mov ax, cx
    and ax, 1
    jnz s117
    add word ptr [acc], 7
s117:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 64
    mov [buf+bx], ax
    call h5
    loop l117
    pop bp
    ret
f118:
    push bp
    mov bp, sp
    mov cx, 4
l118:
    mov ax, cx
    and ax, 1
    jnz s118
    add word ptr [acc], 5
s118:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 5
    mov [buf+bx], ax
    call h6
    loop l118
    pop bp
    ret
f119:
    push bp
    mov bp, sp
    mov cx, 5
l119:
    mov ax, cx
    and ax, 1
    jnz s119
    add word ptr [acc], 3
s119:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 34
    mov [buf+bx], ax
    call h7
    loop l119
    pop bp
    ret
f120:
    push bp
    mov bp, sp
    mov cx, 5
l120:
    mov ax, cx
    and ax, 1
    jnz s120
    add word ptr [acc], 5
s120:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 46
    mov [buf+bx], ax
    call h0
    loop l120
    pop bp
    ret
f121:
    push bp
    mov bp, sp
    mov cx, 4
l121:
    mov ax, cx
    and ax, 3
    jnz s121
    add word ptr [acc], 4
s121:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 4
    mov [buf+bx], ax
    call h1
    loop l121
    pop bp
    ret
f122:
    push bp
    mov bp, sp
    mov cx, 4
l122:
    mov ax, cx
    and ax, 1
    jnz s122
    add word ptr [acc], 6
s122:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 23
    mov [buf+bx], ax
    call h2
    loop l122
    pop bp
    ret
f123:
    push bp
    mov bp, sp
    mov cx, 2
l123:
    mov ax, cx
    and ax, 3
    jnz s123
    add word ptr [acc], 7
s123:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 10
    mov [buf+bx], ax
    call h3
    loop l123
    pop bp
    ret
f124:
    push bp
    mov bp, sp
    mov cx, 5
l124:
    mov ax, cx
    and ax, 3
    jnz s124
    add word ptr [acc], 4
s124:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 31
    mov [buf+bx], ax
    call h4
    loop l124
    pop bp
    ret
f125:
    push bp
    mov bp, sp
    mov cx, 2
l125:
    mov ax, cx
    and ax, 1
    jnz s125
    add word ptr [acc], 5
s125:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 11
    mov [buf+bx], ax
    call h5
    loop l125
    pop bp
    ret
f126:
    push bp
    mov bp, sp
    mov cx, 3
l126:
    mov ax, cx
    and ax, 3
    jnz s126
    add word ptr [acc], 1
s126:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 50
    mov [buf+bx], ax
    call h6
    loop l126
    pop bp
    ret
f127:
    push bp
    mov bp, sp
    mov cx, 2
l127:
    mov ax, cx
    and ax, 3
    jnz s127
    add word ptr [acc], 5
s127:
    mov bx, cx
    shl bx, 1
    mov ax, [buf+bx]
    add ax, 80
    mov [buf+bx], ax
    call h7
    loop l127
    pop bp
    ret
h0:
    inc word ptr [acc]
    cmp ax, 0
    jb hh0
    xor ax, ax
hh0:
    ret
h1:
    inc word ptr [acc]
    cmp ax, 100
    jb hh1
    xor ax, ax
hh1:
    ret
h2:
    inc word ptr [acc]
    cmp ax, 200
    jb hh2
    xor ax, ax
hh2:
    ret
h3:
    inc word ptr [acc]
    cmp ax, 300
    jb hh3
    xor ax, ax
hh3:
    ret
h4:
    inc word ptr [acc]
    cmp ax, 400
    jb hh4
    xor ax, ax
hh4:
    ret
h5:
    inc word ptr [acc]
    cmp ax, 500
    jb hh5
    xor ax, ax
hh5:
    ret
h6:
    inc word ptr [acc]
    cmp ax, 600
    jb hh6
    xor ax, ax
hh6:
    ret
h7:
    inc word ptr [acc]
    cmp ax, 700
    jb hh7
    xor ax, ax
hh7:
    ret
