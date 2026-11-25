// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* On-target fuzzer: random programs (random opcodes, ModR/M, SIB, prefixes, 32-bit addresses)
 * in flat 32-bit ring 3, 16-bit protected mode ring 3 and V86 mode.  Nearly the whole linear
 * space maps onto a small data window (random aliases, read-only / supervisor / not-present /
 * uncached pages), so random addresses need no masking; whatever still faults is skipped by the
 * trap handler.  Each program runs
 *   R  as it is (the reference),
 *   T  single-stepped (TF) with every page it touched stolen again after each instruction: each
 *      access of each instruction takes a page fault and the instruction restarts,
 *   P  with only a few of its pages present at a time,
 *   I  under timer interrupts that flush the TLB and caches and steal pages,
 * and must end with the same registers, flags, memory, fault sequence and PTE A / D bits. */
#include "kern.h"

enum { E32, E16, EV86, NENV };
static const char *ename[NENV] = { "E32", "E16", "V86" };
#define CODESZ 0x6000u
#define NAPT 2

#define nxt ((u16 *)V(0x74000u))            /* code offset -> start of the next item (fault skip) */
static u8 *code;                            /* kernel view of P_CODE */
static u32 p, env, is16, winp, hotn, gflt_base, end_off, start_off;
static u8 hot[8];
static u32 pool[8];                         /* absolute linear addresses used often (E32) */
static u32 nsub, sub_off[4];
static u16 subfix[64]; static u8 subfix_k[64]; static u32 nsubfix;
static u32 insub, nostore;
static u32 iopl, cr0x, dr_on, dr_a[4], dr7;

static void e1(u32 v) { code[p++] = (u8)v; }
static void e2(u32 v) { e1(v); e1(v >> 8); }
static void e4(u32 v) { e2(v); e2(v >> 16); }
static void item(u32 s) { for (u32 i = s; i < p; i++) nxt[i] = (u16)p; }     /* a fault in [s, p) resumes at p */
static u32 pct(u32 n) { return rnd() % 100 < n; }

static u32 rr(void) {                       /* a register number */
    u32 r;
    do r = pct(70) ? hot[rnd() % hotn] : rnd() & 7; while (insub && r == 4);
    return r;
}
static u32 rr8(void) { u32 r = pct(70) ? (hot[rnd() % hotn] & 3) | (rnd() & 4) : rnd() & 7; return r; }
static u32 immv(void) {
    u32 x = rnd();
    switch (x & 7) {
    case 0: return (x >> 8) & 3;
    case 1: return 0xFFFFFFFF;
    case 2: return 0x80000000u >> ((x >> 8) & 31);
    case 3: return (s32)(signed char)(x >> 8);
    case 4: return x >> 24;
    default: return rnd();
    }
}

/* ModR/M + SIB + displacement; mem: 0 register, 1 memory, 2 any; byte: r/m is a byte register */
static void modrm(u32 reg, u32 mem, u32 a32, u32 byte) {
    u32 m = mem == 2 ? pct(50) : mem;
    if (!m) { u32 r = byte ? rr8() : rr(); e1(0xC0 | reg << 3 | r); return; }
    if (a32) {
        if (pct(25)) {                      /* absolute, from the pool of addresses */
            e1(reg << 3 | 5);
            u32 a = pool[rnd() & 7] + (pct(50) ? rnd() & 7 : 0);
            e4(is16 ? a & 0xFFFF : a);
            return;
        }
        u32 mod = rnd() % 3, rm = rnd() & 7;
        if (rm != 4 && pct(60)) { rm = rr(); if (rm == 4) rm = 3; }
        e1(mod << 6 | reg << 3 | rm);
        u32 base = rm;
        if (rm == 4) {
            u32 s = rnd() & 0xC0, i = rr(), b = rr();
            if (i == 4 && pct(80)) i = 1;
            e1(s | i << 3 | b);
            base = b;
        }
        if (mod == 1) e1(rnd());
        else if (mod == 2 || (mod == 0 && base == 5)) e4(pct(50) ? rnd() : rnd() & 0xFFFF);
        return;
    }
    u32 mod = rnd() % 3, rm = rnd() & 7;
    e1(mod << 6 | reg << 3 | rm);
    if (mod == 1) e1(rnd());
    else if (mod == 2 || (mod == 0 && rm == 6)) e2(pct(50) ? pool[rnd() & 7] : rnd());
}

/* opcode forms: M ModR/M, m ModR/M byte operands, B / c + imm8 (c: byte), Z / y + imm16/32 (y: byte
   op with imm8 = c), n none, b imm8, z imm16/32, o moffs, . not here */
static const char op1[257] =
    "mMmMbznnmMmMbzn." "mMmMbznnmMmMbznn" "mMmMbz.nmMmMbz.n" "mMmMbz.nmMmMbz.n"
    "nnnnnnnnnnnnnnnn" "nnnnnnnnnnnnnnnn" "nnMM....zZbBnnnn" "................"
    "cZcBmMmMmMmMMMMP" "nnnnnnnnnn.n..nn" "oooonnnnbznnnnnn" "bbbbbbbbzzzzzzzz"
    "cB..MMcZen..n.n." "mMmMbb.nMMMMMMMM" "....bbbb....nnnn" "....nnfFnnnnnnGH";
static const char op2[257] =
    "MMMM..n.nn.n...." "................" "MMMM............" "nnn............."
    "................" "................" "................" "................"
    "................" "mmmmmmmmmmmmmmmm" "nnnMBM..nnnMBM.M" "mMMMMMmM..BMMMmM"
    "mM......nnnnnnnn" "................" "................" "................";

static void prefixes(u32 *o32, u32 *a32, u32 locks) {
    *o32 = !is16; *a32 = !is16;
    if (pct(22)) { e1(0x66); *o32 ^= 1; }
    if (pct(12)) { e1(0x67); *a32 ^= 1; }
    if (pct(8)) { static const u8 sg[6] = { 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65 }; e1(sg[rnd() % 6]); }
    if (locks && pct(3)) e1(0xF0);
}

static void any_op(void) {                  /* one instruction, uniformly from the opcode maps */
    u32 s = p, o32, a32, op, two;
    char c;
    for (;;) {
        op = rnd() & 0xFF; two = pct(25);
        c = two ? op2[op] : op1[op];
        if (c == '.' || c == ' ') continue;
        if (!two && env != E32 && op == 0x66) continue;
        /* protected mode: random selectors could be null ones with RPL 1-3, which a trap's IRET zeroes */
        if (env != EV86 && (two ? op == 0xA1 || op == 0xA9 || op == 0xB2 || op == 0xB4 || op == 0xB5
                                : op == 0x07 || op == 0x17 || op == 0x1F || op == 0x8E || op == 0xC4 || op == 0xC5)) continue;
        /* IOPL 3: the I/O would reach real ports */
        if (!two && iopl == 3 && env != EV86 && ((op >= 0x6C && op <= 0x6F) || (op >= 0xE4 && op <= 0xE7) || (op >= 0xEC && op <= 0xEF))) continue;
        break;
    }
    prefixes(&o32, &a32, 1);
    if (two && (op & 0xF7) == 0xA5 && !o32) { p = s; return; }  /* SHLD / SHRD r16 by CL > 16: undefined */
    if (two) e1(0x0F);
    e1(op);
    u32 reg = rr();
    switch (c) {
    case 'M':
        if (!two && op == 0x8C) reg = rnd() % 6;
        if (!two && op == 0x8E) { reg = rnd() & 7; if (reg == 2 && env == EV86 && pct(70)) reg = 3; }
        if (!two && (op == 0xD1 || op == 0xD3)) reg = rnd() & 7;
        modrm(reg, 2, a32, 0);
        break;
    case 'm':
        if (two) { modrm(rnd() & 7, 2, a32, 1); break; }
        modrm(op == 0x84 || op == 0x86 || (op & 0xC4) == 0 || (op & 0xFC) == 0x88 || op == 0x8A ? rr8() : rnd() & 7, 2, a32, 1);
        break;
    case 'P': modrm(0, 2, a32, 0); break;                      /* 8F /0 */
    case 'c':
        modrm(op == 0xC6 ? 0 : rnd() & 7, 2, a32, 1); e1(immv()); break;
    case 'B':
        if (two && op == 0xBA) reg = 4 | (rnd() & 3);
        else if (!two && op != 0x6B) reg = rnd() & 7;
        modrm(reg, 2, a32, 0); e1(two && (op & 0xF7) == 0xA4 && !o32 ? rnd() & 15 : immv()); break;
    case 'Z':
        if (op == 0xC7) reg = 0; else if (op == 0x81) reg = rnd() & 7;
        modrm(reg, 2, a32, 0);
        if (o32) e4(immv()); else e2(immv());
        break;
    case 'b': e1(immv()); break;
    case 'z': if (o32) e4(immv()); else e2(immv()); break;
    case 'o': if (a32) e4(pct(60) ? pool[rnd() & 7] : rnd()); else e2(pool[rnd() & 7]); break;
    case 'e': e2(rnd() & 0xFF); e1(pct(70) ? 0 : env == E16 ? 1 : rnd() & 7); break;      /* ENTER */
    case 'f': { u32 r = rnd() & 7; modrm(r, 2, a32, 1); if (r < 2) e1(immv()); break; }
    case 'F': { u32 r = rnd() & 7; modrm(r, 2, a32, 0); if (r < 2) { if (o32) e4(immv()); else e2(immv()); } break; }
    case 'G': modrm(rnd() & 1, 2, a32, 1); break;
    case 'H': { static const u8 q[4] = { 0, 1, 6, 6 }; modrm(q[rnd() & 3], 2, a32, 0); break; }
    }
    item(s);
}

/* the pipeline's favourites: short dependency chains of loads, byte moves, early ALU and shifts */
static void hot_op(void) {
    u32 s = p, x = rnd() % 22, o32 = !is16, a32 = !is16;
    if (pct(is16 ? 60 : 15)) { e1(0x66); o32 ^= 1; }
    if (pct(is16 ? 40 : 4)) { e1(0x67); a32 ^= 1; }
    switch (x) {
    case 0: case 1: case 2: e1(0x8B); modrm(rr(), 1, a32, 0); break;                     /* load */
    case 3: e1(0x8A); modrm(rr8(), 1, a32, 1); break;
    case 4: case 5: e1(0x0F); e1(0xB6 + (rnd() & 1)); modrm(rr(), 2, a32, 1); break;     /* MOVZX */
    case 6: e1(0x0F); e1(0xBE + (rnd() & 1)); modrm(rr(), 2, a32, 1); break;
    case 7: case 8: e1(0x01 | (rnd() & 7) << 3 | (pct(50) ? 2 : 0)); modrm(rr(), 0, a32, 0); break;   /* r, r */
    case 9: e1(0x03 | (rnd() & 7) << 3); modrm(rr(), 1, a32, 0); break;                  /* r, m */
    case 10: e1(0x81); modrm(rnd() & 7, 0, a32, 0); if (o32) e4(immv()); else e2(immv()); break;
    case 11: case 12: e1(0x83); modrm(rnd() & 7, 0, a32, 0); e1(immv()); break;
    case 13: case 14: e1(0xC1); modrm((pct(60) ? 5 | (rnd() & 2) : rnd() & 7), 0, a32, 0); e1(pct(50) ? (rnd() & 3) * 8 : rnd()); break;
    case 15: e1(0xD1); modrm(rnd() & 7, 0, a32, 0); break;
    case 16: e1(0x8D); modrm(rr(), 1, a32, 0); break;                                    /* LEA */
    case 17: if (nostore) { e1(0x90); break; } e1(0x89); modrm(rr(), 1, a32, 0); break;  /* store */
    case 18: if (nostore) { e1(0x90); break; } e1(0x88); modrm(rr8(), 1, a32, 1); break;
    case 19: e1(0x02 | (rnd() & 7) << 3); modrm(rr8(), 0, a32, 1); break;                /* byte ALU r, r */
    case 20: { u32 r = rr(); e1(0x40 | (rnd() & 8) | r); break; }
    case 21: if (!nostore && pct(50)) { e1(0x01 | (rnd() & 7) << 3); modrm(rr(), 1, a32, 0); }       /* RMW */
             else { e1(0xB0 | rr8()); e1(immv()); } break;
    }
    item(s);
}
static void mov_ri(u32 r, u32 v) { if (is16) e1(0x66); e1(0xB8 | r); e4(v); }
static void set_stack(void) {               /* (SS:)ESP back to the stack; V86 / 16-bit: through AX */
    if (env == E16) { e1(0xB8); e2(S_US16); e1(0x8E); e1(0xD0); }
    if (env == EV86) { e1(0xB8); e2(P_STK >> 4); e1(0x8E); e1(0xD0); }
    if (env == E32) { e1(0xBC); e4(U_STK + 0x1F00 - (rnd() & 0x3F)); }
    else { e1(0x66); e1(0xBC); e4(0x1F00 - (rnd() & 0x3F)); }
}
static u32 fl_imm(void) {                   /* a flags image: no TF, NT, VM, RF */
    u32 f = rnd() & (AFL | IFL | 0x3000);
    if (pct(30)) f |= ACL;
    if (pct(80)) f |= IFL;
    return f | 2;
}
static void push_off(u32 o32, u32 v) { if (o32 == is16) e1(0x66); e1(0x68); if (o32) e4(v); else e2(v); }
static u32 cbase(void) { return env == E32 ? U_CODE : 0; }     /* EIP of code offset 0 */
static u32 csel(void) { return env == E32 ? S_UC : env == E16 ? S_UC16 : P_CODE >> 4; }

static void special(void) {                 /* multi-instruction items */
    u32 s = p, o32, fix = 0;
    switch (rnd() % 19) {
    case 0: case 1: case 2: {                                  /* REP string */
        mov_ri(1, pct(80) ? rnd() % 40 : rnd() % 600);
        if (pct(40)) e1(pct(50) ? 0xFD : 0xFC);
        if (pct(25)) e1(0x66);
        if (pct(15)) e1(0x67);
        if (pct(10)) e1(0x64);
        e1(0xF2 + (rnd() & 1));
        static const u8 so[] = { 0xA4, 0xA5, 0xA5, 0xA6, 0xA7, 0xAA, 0xAB, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF };
        e1(so[rnd() % 12]);
        break; }
    case 3:                                                    /* POPF */
        o32 = rnd() & 1;
        push_off(o32, fl_imm());
        if (o32 == is16) e1(0x66);
        e1(0x9D);
        break;
    case 4: {                                                  /* PUSHF, TF masked */
        u32 r = rnd() & 3;
        o32 = rnd() & 1;
        if (o32 == is16) e1(0x66);
        e1(0x9C);
        if (o32 == is16) e1(0x66);
        e1(0x58 | r);
        if (o32 == is16) e1(0x66);
        e1(0x81); e1(0xE0 | r); if (o32) e4(0x00243ED5); else e2(0x3ED5);
        if (o32 == is16) e1(0x66);
        e1(0x50 | r);
        break; }
    case 5:                                                    /* IRET to the next item */
        o32 = !is16;
        if (env == EV86) o32 = 0;
        else if (pct(20)) o32 = env == E32 ? 1 : 0;
        push_off(o32, fl_imm());
        if (o32 == is16) e1(0x66);
        e1(0x0E);
        fix = p + 1 + (o32 == is16);
        push_off(o32, 0);
        if (o32 == is16) e1(0x66);
        e1(0xCF);
        if (o32) *(u32 *)(code + fix) = cbase() + p; else *(u16 *)(code + fix) = p;
        break;
    case 6:                                                    /* far JMP / CALL to the next item */
        e1(pct(50) ? 0xEA : 0x9A);
        if (is16) { e2(p + 4); e2(csel()); } else { e4(cbase() + p + 6); e2(csel()); }
        break;
    case 7: {                                                  /* RETF (n) */
        o32 = !is16;
        e1(0x0E);
        fix = p + 1;
        push_off(o32, 0);
        u32 n = rnd() & 1;
        e1(n ? 0xCA : 0xCB); if (n) e2(rnd() & 0x1C);
        if (o32) *(u32 *)(code + fix) = cbase() + p; else *(u16 *)(code + fix) = p;
        break; }
    case 8: {                                                  /* RET (n) */
        o32 = !is16;
        fix = p + 1;
        push_off(o32, 0);
        u32 n = rnd() & 1;
        e1(n ? 0xC2 : 0xC3); if (n) e2(rnd() & 0x1C);
        if (o32) *(u32 *)(code + fix) = cbase() + p; else *(u16 *)(code + fix) = p;
        break; }
    case 9: {                                                  /* JMP / CALL r */
        u32 r = rnd() & 3;
        e1(0xB8 | r); fix = p;
        if (is16) e2(0); else e4(0);
        e1(0xFF); e1((pct(50) ? 0xE0 : 0xD0) | r);
        if (is16) *(u16 *)(code + fix) = p; else *(u32 *)(code + fix) = cbase() + p;
        break; }
    case 10: {                                                 /* JMP / CALL m, far JMP / CALL m */
        u32 a = pool[rnd() & 7], far = rnd() & 1;
        if (far) { e1(0xC7); e1(is16 ? 0x06 : 0x05); if (is16) { e2(a + 2); e2(csel()); } else { e4(a + 4); e4(csel()); } }
        e1(0xC7); e1(is16 ? 0x06 : 0x05); if (is16) e2(a); else e4(a);
        fix = p; if (is16) e2(0); else e4(0);
        e1(0xFF); e1((far ? (pct(50) ? 0x28 : 0x18) : (pct(50) ? 0x20 : 0x10)) | (is16 ? 6 : 5));
        if (is16) e2(a); else e4(a);
        if (is16) *(u16 *)(code + fix) = p; else *(u32 *)(code + fix) = cbase() + p;
        break; }
    case 11: case 12:                                          /* CALL of a subroutine */
        if (nsubfix >= 64) { e1(0x90); break; }
        set_stack();
        e1(0xE8);
        subfix_k[nsubfix] = rnd() % nsub; subfix[nsubfix++] = p;
        if (is16) e2(0); else e4(0);
        break;
    case 13: {                                                 /* segment register load */
        static const u16 sl[] = { S_UD, S_UD, S_UD, S_UD16, S_URO, S_UED, S_UCC, S_US16, 0, S_K0, S_UNP, S_TSS, S_UC, S_UC16 };
        u32 r = rnd() & 3, g = rnd() & 3;
        static const u8 sr[4] = { 0, 3, 4, 5 };
        e1(0xB8 | r);
        u32 v = env == EV86 ? (rnd() & 0x7FFF) : (pct(50) ? S_UD : sl[rnd() % 14]);
        if (is16) e2(v); else e4(v);
        u32 how = rnd() & 3, a = pool[rnd() & 7];
        static const u16 pp[4] = { 0x07, 0x1F, 0xA10F, 0xA90F }, ls[4] = { 0xC4, 0xC5, 0xB40F, 0xB50F };
        if (how == 1) { e1(0x50 | r); e1(pp[g]); if (pp[g] >> 8) e1(pp[g] >> 8); }                   /* push, pop sreg */
        else if (how == 2) {                                   /* mov m, r; LES / LDS / LFS / LGS */
            u32 d = is16 ? 2 : 4;
            e1(0x89); e1(r << 3 | (is16 ? 6 : 5)); if (is16) e2(a + d); else e4(a + d);
            e1(ls[g]); if (ls[g] >> 8) e1(ls[g] >> 8);
            e1(rr() << 3 | (is16 ? 6 : 5)); if (is16) e2(a); else e4(a);
        } else { e1(0x8E); e1(0xC0 | sr[g] << 3 | r); }
        break; }
    case 14: e1(0xCD); e1(pct(80) ? 0x80 : rnd()); if (code[p - 1] == 0x20 || code[p - 1] == 0x28 || code[p - 1] == 8) code[p - 1] = 0x80; break;
    case 15: mov_ri(rnd() % 8, pct(50) ? rnd() : (pool[rnd() & 7])); if (insub) p = s; break;
    case 16: {                                                 /* SS from another selector, pushes, back */
        if (env == E32) {
            u32 r = rnd() & 3;
            e1(0xB8 | r); e4(S_US16); e1(0x8E); e1(0xD0 | r);
            for (u32 i = rnd() & 3; i; i--) e1(pct(50) ? 0x50 | (rnd() & 3) : pct(50) ? 0x06 : 0x58 | (rnd() & 3));
            e1(0xB8 | r); e4(S_UD); e1(0x8E); e1(0xD0 | r);
        }
        set_stack();
        break; }
    case 17: {                                                 /* Jcc / LOOP over the next few items */
        break; }
    case 18: {                                                 /* XLAT / LOCK RMW / CMPXCHG loops */
        e1(0xF0); e1(0x0F); e1(pct(50) ? 0xB1 : 0xC1); modrm(rr(), 1, !is16, 0);
        break; }
    }
    if (p == s) e1(0x90);
    item(s);
}

static void body(u32 n, u32 depth);
static void branch(u32 depth) {
    u32 s = p, k = rnd() % 3, x = rnd() & 15, at;
    if (k == 2) {                                              /* LOOPcc / JCXZ / short */
        if (pct(25)) e1(0x67);
        e1(pct(80) ? 0xE0 + (rnd() & 3) : 0xEB); at = p; e1(0);
    }
    else if (k == 1) { e1(0x70 | x); at = p; e1(0); }
    else { if (pct(10)) e1(0xE9); else { e1(0x0F); e1(0x80 | x); } at = p; if (is16) e2(0); else e4(0); }
    item(s);
    u32 q = p;
    body(1 + rnd() % (k ? 2 : 5), depth + 1);
    u32 d = p - q;
    if (k == 0) { if (is16) *(u16 *)(code + at) = d; else *(u32 *)(code + at) = d; }
    else if (d < 128) code[at] = d;
}
static void body(u32 n, u32 depth) {
    while (n-- && p < CODESZ - 0x600) {
        u32 x = rnd() % 100;
        if (insub) { hot_op(); continue; }
        if (x < 45) hot_op();
        else if (x < 78) any_op();
        else if (x < 90 && depth < 3) branch(depth);
        else special();
    }
}

/* ---------------------------------------------------------------- page tables */
static void spaces(void) {
    for (u32 pd = P_PDU; pd <= P_PDV; pd += 0x1000) {
        for (u32 i = 0; i < 1024; i++) PTE(pd, i) = (P_APT + (rnd() % NAPT) * 0x1000) | 7 | (pct(90) ? 0x20 : 0);
        PTE(pd, 768) = P_PT0 | 3 | 0x20;
        PTE(pd, U_BASE >> 22) = P_SPT | 7;
        for (u32 i = 0; i < 6; i++) { u32 k = rnd() & 1023; if (k != 768 && k != U_BASE >> 22 && k) PTE(pd, k) = (PTE(pd, k) & ~6u) | (rnd() & 6); }
        for (u32 i = 0; i < 4; i++) { u32 k = rnd() & 1023; if (k != 768 && k != U_BASE >> 22 && k) PTE(pd, k) &= ~1u; }
    }
    PTE(P_PDV, 0) = P_VPT | 7;
}
static u32 rpte(u32 easy) {
    u32 e = (P_WIN + (rnd() % winp) * 0x1000) | 7;
    u32 x = rnd();
    if (!easy) {
        if ((x & 31) == 0) e &= ~1u;
        if (((x >> 5) & 31) == 0) e &= ~2u;
        if (((x >> 10) & 63) == 0) e &= ~4u;
        if (((x >> 16) & 15) == 0) e |= 0x10;                  /* PCD */
        if (((x >> 20) & 15) == 0) e |= 0x08;                  /* PWT */
    }
    if ((x >> 24) & 1) e |= 0x20;
    if (((x >> 24) & 3) == 3) e |= 0x40;
    return e;
}
static void tables_init(void) {
    u32 easy = pct(30);
    for (u32 t = 0; t < 4; t++)
        for (u32 i = 0; i < 1024; i++) PTE(P_PTPRI + t * 0x1000, i) = rpte(easy);
    for (u32 t = 0; t < 2; t++) {
        u32 b = P_PTPRI + t * 0x1000;                          /* SPT, VPT: code and stack */
        for (u32 i = 0; i < 8; i++) PTE(b, 0x50 + i) = (P_CODE + i * 0x1000) | 0x25;
        for (u32 i = 0; i < 2; i++) PTE(b, 0x60 + i) = (P_STK + i * 0x1000) | 7;
    }
}

/* ---------------------------------------------------------------- one run */
struct res { u32 r[8], fl, eip, sg[6], hash, nflt, why; };
static struct res ref, cur;
static u32 mode, hash, nflt, iters, why;    /* mode: 0 R, 1 T, 2 P, 3 I */
static u32 wd;                              /* watchdog: timer ticks of the run */
static volatile u32 *stl[64];
static u32 nstl, keep, mode_tf;
#define STOLEN 0x200u

static volatile u32 *pte_of(u32 lin) {
    u32 pd = env == EV86 ? P_PDV : P_PDU;
    u32 d = PTE(pd, lin >> 22);
    if (!(d & 1) || lin >> 22 == 768) return 0;
    return &PTE(d & 0xFFFFF000, (lin >> 12) & 1023);
}
static void steal1(volatile u32 *e) { if (*e & 1) *e = (*e & ~1u) | STOLEN; }
static void steal_random(u32 n) {
    static const u32 t[2] = { P_SPT, P_VPT };
    while (n--) {
        u32 x = rnd();
        if (x & 1) steal1(&PTE(P_APT + ((x >> 1) & (NAPT - 1)) * 0x1000, (x >> 8) & 1023));
        else { u32 k = cfg.tb ? 8 + (x >> 8) % 2 : (x >> 8) % 10; steal1(&PTE(t[env == EV86], k < 8 ? 0x50 + k : 0x58 + k)); }
    }
}
static int fz_hook(struct frame *f) {
    u32 off = f->eip - cbase();
    if (f->vec == 1) {
        u32 d6 = rd_dr6();
        if (d6 & 15 & dr_on) {
            wr_dr6(0);
            if (cfg.off & 1) pf("%c DB %x off %x\n", "RTPI"[mode], d6, off);
            hash = (hash << 5 | hash >> 27) ^ (0xDB000000 | (d6 & 15 & dr_on)) ^ off; nflt++;
            /* an instruction breakpoint (RF set in the image by the CPU): goes on */
        } else wr_dr6(0);
        if (mode_tf) {
            while (nstl) steal1(stl[--nstl]);
            if (cfg.tb || rnd() & 1) wr_cr3(rd_cr3());        /* (the lockstep model has another TLB: no stale entries) */
            f->eflags |= TFL;
        } else f->eflags &= ~TFL;
        return 0;
    }
    if (f->vec == 14) {
        u32 a = rd_cr2();
        volatile u32 *e = pte_of(a);
        if (!(f->err & 1) && e && (*e & (STOLEN | 1)) == STOLEN) {
            *e = (*e & ~STOLEN) | 1;
            if (nstl < 64) stl[nstl++] = e;
            if (mode == 2 && nstl > keep) {                    /* the oldest one goes again */
                steal1(stl[0]);
                for (u32 i = 1; i < nstl; i++) stl[i - 1] = stl[i];
                nstl--;
                wr_cr3(rd_cr3());
            }
            if (mode_tf) f->eflags |= TFL;
            return 0;
        }
        hash ^= a * 0x9E3779B1u;
    }
    if (f->vec == 0x80) {
        f->eax = f->eax * 0x9E3779B1u + (f->ebx ^ 0x5A5A5A5Au);
        hash = (hash << 5 | hash >> 27) ^ off;
        if (mode_tf) f->eflags |= TFL;
        return 0;
    }
    if (off == end_off && f->vec == 13) {
        if (--iters) { f->eip = cbase() + start_off; if (mode_tf) f->eflags |= TFL; return 0; }
        why = 1;
        return 1;
    }
    if (off >= end_off) { why = 2; return 1; }                 /* ran wild */
    if (cfg.off & 1) pf("%c %2 err %x off %x cr2 %x\n", "RTPI"[mode], f->vec, f->err, off, f->vec == 14 ? rd_cr2() : 0);
    hash = (hash << 5 | hash >> 27) ^ (f->vec * 0x01000193u) ^ (f->err << 8) ^ off;
    if (++nflt > 60000) { why = 3; return 1; }
    f->eip = cbase() + nxt[off];
    f->eflags &= ~RFL;
    if (mode_tf) f->eflags |= TFL;
    return 0;
}
static void fz_irq(struct frame *f) {
    u32 x = rnd();
    if (++wd > 200000) fstop("HANG", f);
    if (f->eip - cbase() >= CODESZ) return;
    if (x & 1) steal_random(1 + ((x >> 4) & 3));
    if (cfg.tb || x & 2) wr_cr3(rd_cr3());
    if (!((x >> 8) & 15)) wbinvd();
    if (!((x >> 12) & 7) && !cfg.tb) { u32 c = 80 + (rnd() & 1023); outb(0x43, 0x34); outb(0x40, c & 0xFF); outb(0x40, c >> 8); }
}
static void fz_tick(struct frame *f) { if (++wd > 200) fstop("HANG", f); }
static u32 init_r[8], init_fl, seedp;
static void run(u32 m) {
    static struct frame f;
    mode = m; mode_tf = m == 1;
    hash = 0; nflt = 0; why = 0; iters = 1 + (seedp & 1); nstl = 0;
    copyd(V(P_WIN), V(P_PRI), winp * 1024);
    copyd(V(P_STK), V(P_PRI), 2048);
    copyd(V(P_SPT), V(P_PTPRI), 4096);
    if (m == 1 || m == 2) {
        keep = 10 + (rnd() & 15);
        for (u32 t = 0; t < NAPT; t++) for (u32 i = 0; i < 1024; i++) steal1(&PTE(P_APT + t * 0x1000, i));
        for (u32 i = 0x50; i < 0x62; i++) {
            if (cfg.tb && i < 0x58) continue;                  /* (86Box reads ahead of the instruction: not its code pages) */
            steal1(&PTE(P_SPT, i)); steal1(&PTE(P_VPT, i));
        }
    }
    for (u32 i = 0; i < sizeof f / 4; i++) ((u32 *)&f)[i] = 0;
    f.eax = init_r[0]; f.ecx = init_r[1]; f.edx = init_r[2]; f.ebx = init_r[3];
    f.ebp = init_r[5]; f.esi = init_r[6]; f.edi = init_r[7];
    f.eflags = (init_fl & AFL) | 2 | IFL | iopl << 12 | (mode_tf ? TFL : 0);
    f.eip = cbase() + start_off;
    f.cs = csel();
    if (env == EV86) {
        f.eflags |= VM; f.ss = P_STK >> 4; f.esp = 0x1F00;
        f.ves = 0x1234; f.vds = 0x4000; f.vfs = 0xFFFF; f.vgs = 0x8000;
    } else {
        f.ds = f.es = f.fs = S_UD; f.gs = S_UD16;
        if (env == E32) { f.ss = S_UD; f.esp = U_STK + 0x1F00; }
        else { f.ss = S_US16; f.esp = 0x1F00; f.ds = S_UD16; }
    }
    wr_dr6(0);
    if (dr_on) { wr_dr0(dr_a[0]); wr_dr1(dr_a[1]); wr_dr2(dr_a[2]); wr_dr3(dr_a[3]); wr_dr7(dr7); }
    wr_cr3(env == EV86 ? P_PDV : P_PDU);
    u32 c0 = rd_cr0();
    wr_cr0((c0 & ~0x4000Eu) | cr0x);
    wd = 0;
    if (m == 3) { irq_hook = fz_irq; irqs_on(100, 2000); }
    else if (!cfg.tb) { irq_hook = fz_tick; irqs_on(0, 0); }
    else if (cfg.tb) irq_hook = fz_irq;                        /* (-i: every run is interrupted) */
    go(&f, fz_hook);
    irqs_off();
    irq_hook = 0;
    wr_cr0(c0);
    if (dr_on) wr_dr7(0x400);
    wr_cr3(P_PDK);
    cur.r[0] = fin.eax; cur.r[1] = fin.ecx; cur.r[2] = fin.edx; cur.r[3] = fin.ebx;
    cur.r[4] = fin.esp; cur.r[5] = fin.ebp; cur.r[6] = fin.esi; cur.r[7] = fin.edi;
    cur.fl = fin.eflags & ~(TFL | RFL); cur.eip = fin.eip - cbase();
    if (fin.eflags & VM) { cur.sg[0] = fin.ves; cur.sg[3] = fin.vds; cur.sg[4] = fin.vfs; cur.sg[5] = fin.vgs; }
    else { cur.sg[0] = fin.es; cur.sg[3] = fin.ds; cur.sg[4] = fin.fs; cur.sg[5] = fin.gs; }
    cur.sg[1] = fin.cs; cur.sg[2] = fin.ss;
    for (u32 i = 0; i < 6; i++) cur.sg[i] &= 0xFFFF;
    cur.hash = hash; cur.nflt = nflt; cur.why = why;
    for (u32 t = 0; t < 4; t++)                                /* stolen pages back */
        if (m >= 1 || cfg.tb) for (u32 i = 0; i < 1024; i++) { volatile u32 *e = &PTE(P_SPT + t * 0x1000, i); if (*e & STOLEN) *e = (*e & ~STOLEN) | 1; }
}
static const char *rn[8] = { "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi" };
static const char *sn[6] = { "es", "cs", "ss", "ds", "fs", "gs" };
static const char mn[4] = { 'R', 'T', 'P', 'I' };
static void mism(u32 a, u32 b) {
    if (!fail_begin("MISMATCH")) return;
    pf("%s/%c prog %x:", ename[env], mn[mode], seedp);
    u32 n = 0;
    for (u32 i = 0; i < 8; i++) if (ref.r[i] != cur.r[i] && n++ < 3) pf(" %s %x/%x", rn[i], cur.r[i], ref.r[i]);
    for (u32 i = 0; i < 6; i++) if (ref.sg[i] != cur.sg[i] && n++ < 3) pf(" %s %x/%x", sn[i], cur.sg[i], ref.sg[i]);
    if (ref.fl != cur.fl) pf(" fl %x/%x", cur.fl, ref.fl);
    if (ref.eip != cur.eip) pf(" eip %x/%x", cur.eip, ref.eip);
    if (ref.why != cur.why) pf(" end %d/%d", cur.why, ref.why);
    if (ref.nflt != cur.nflt) pf(" faults %d/%d", cur.nflt, ref.nflt);
    else if (ref.hash != cur.hash) pf(" fault hash");
    if (a != ~0u) pf(" mem %x %x/%x", a, *(u32 *)V(a < P_STK ? P_WIN + a : a), b);
    pf("\n");
}
static u32 cmp_mem(u32 *val) {              /* WIN, stack, tables against the reference copy */
    u32 i = cmpd(V(P_WIN), V(P_REF), winp * 1024);
    if (i != winp * 1024) { *val = ((u32 *)V(P_REF))[i]; return i * 4; }
    i = cmpd(V(P_STK), V(P_FREE), 2048);
    if (i != 2048) { *val = ((u32 *)V(P_FREE))[i]; return P_STK + i * 4; }
    i = cmpd(V(P_SPT), V(P_PTREF), 4096);
    if (i != 4096) { *val = ((u32 *)V(P_PTREF))[i]; return P_SPT + i * 4; }
    return ~0u;
}
static int differs(u32 *a, u32 *v) {
    *a = cmp_mem(v);
    int bad = *a != ~0u;
    for (u32 i = 0; i < sizeof ref / 4; i++) bad |= ((u32 *)&ref)[i] != ((u32 *)&cur)[i];
    return bad;
}

static void program(u32 sd) {
    if (cfg.one && sd != cfg.one) return;
    seedp = sd;
    rs = sd;
    env = rnd() % NENV;
    if (cfg.envs) while (!(cfg.envs >> env & 1)) env = (env + 1) % NENV;
    is16 = env != E32;
    iopl = env == EV86 && pct(60) ? 3 : pct(20) ? 3 : 0;
    cr0x = 4 | (pct(25) ? 0x40000 : 0) | (pct(50) ? 2 : 0) | (pct(30) ? 8 : 0);
    static const u8 wn[4] = { 1, 2, 4, 4 };
    winp = cfg.tb ? wn[rnd() & 3] : 1u << (rnd() % 5);
    hotn = 2 + rnd() % 5;
    for (u32 i = 0; i < 8; i++) { hot[i] = rnd() & 7; if (hot[i] == 4 && pct(80)) hot[i] = i & 3; }
    for (u32 i = 0; i < 8; i++) { pool[i] = rnd(); if (i & 1) pool[i] = pool[i - 1] + (rnd() & 15) - 8; if (pct(15)) pool[i] = (pool[i] & ~0xFFFu) - (1 + (rnd() & 3)); }
    /* (the 16-bit wrap of a far pointer's second half is left alone: 486 behaviour unknown) */
    if (is16) for (u32 i = 0; i < 8; i++) if ((pool[i] & 0xFFFF) > 0xFFD0) pool[i] -= 0x40;
    for (u32 i = 0; i < 8; i++) init_r[i] = pct(60) ? rnd() : rnd() & 0xFFFF;
    init_fl = rnd();
    for (u32 i = 0; i < winp * 1024 || i < 2048; i++) ((volatile u32 *)V(P_PRI))[i] = rnd();
    tables_init();
    spaces();
    /* the program */
    code = (u8 *)V(P_CODE);
    p = rnd() % 0x2000; start_off = p;
    nsubfix = 0; nsub = 2; insub = 0; nostore = 0;
    u32 n = cfg.items ? cfg.items : 20 + rnd() % (cfg.tb ? 60 : 150);
    body(n, 0);
    u32 s = p;
    end_off = p;
    e1(0xF4); e1(0xF4); e1(0xEB); e1(0xFC);
    item(s);
    u32 eo = end_off;
    for (u32 k = 0; k < nsub; k++) {
        sub_off[k] = p;
        insub = 1; nostore = 1;
        body(2 + rnd() % 5, 3);
        insub = 0; nostore = 0;
        s = p; e1(0xC3); item(s);
    }
    for (u32 i = 0; i < nsubfix; i++) {
        u32 at = subfix[i], t = sub_off[subfix_k[i]];
        if (is16) *(u16 *)(code + at) = t - (at + 2); else *(u32 *)(code + at) = t - (at + 4);
    }
    end_off = eo;
    /* debug registers */
    dr_on = 0;
    if (pct(25)) {
        dr7 = 0x400; dr_on = 15;
        for (u32 i = 0; i < 4; i++) {
            u32 x = rnd();
            u32 lin0 = env == EV86 ? 0x40000 + (pool[i] & 0xFFFF) : env == E16 ? 0x12340000 + (pool[i] & 0xFFFF) : pool[i];
            u32 cl = (env == EV86 ? P_CODE : U_CODE);
            if ((x & 3) == 0) { dr_a[i] = cl + start_off + rnd() % (eo - start_off); dr7 |= 2u << (2 * i); continue; }
            if ((x & 3) == 1) lin0 = (env == EV86 ? P_STK : U_STK) + 0x1E80 + (rnd() & 0x7F);
            if (lin0 >> 22 == 768) continue;                   /* (the kernel itself) */
            static const u8 ln[3] = { 0, 1, 3 };
            u32 l = ln[(x >> 4) % 3];
            dr_a[i] = lin0 & ~l;
            dr7 |= (2u << (2 * i)) | ((l << 2 | ((x >> 8) & 1 ? 3 : 1)) << (16 + 4 * i));
        }
    }
    u32 a, v = 0;
    run(0);
    ref = cur;
    copyd(V(P_REF), V(P_WIN), winp * 1024);
    copyd(V(P_FREE), V(P_STK), 2048);
    copyd(V(P_PTREF), V(P_SPT), 4096);
    if (ref.why == 3) return;                                  /* too many faults */
    run(1);
    if (differs(&a, &v)) mism(a, v);
    run(2);
    if (differs(&a, &v)) mism(a, v);
    if (!cfg.tb)
        for (u32 k = 0; k < 4; k++) { run(3); if (differs(&a, &v)) { mism(a, v); break; } }
}
void s_fuzz(u32 round) {
    u32 n = cfg.progs ? cfg.progs : cfg.tb ? 4 : 400;
    for (u32 i = 0; i < n; i++) program(mix(round, i + 0x10000));
}
