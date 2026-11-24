// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* Protection checks against an oracle written from the i486 manual: segment loads, LAR / LSL /
 * VERR / VERW, far JMP / CALL (suite seg), call gates and interrupt gates with stack switches and
 * the returns (suite xfer), with random descriptors, RPLs and CPLs. */
#include "kern.h"

#define SEL_C(l) (0xA0u + 8 * (l) + (l))    /* code / data of privilege level l */
#define SEL_D(l) (0xC0u + 8 * (l) + (l))
#define S_T  0xE0u                          /* descriptors under test */
#define S_T2 0xE8u
#define S_G  0xF0u
#define CODE_OFF 0x100u
#define LAND_OFF 0x300u
#define USTK (U_STK + 0x1E00u)
#define RSTK(l) (U_STK + 0x400u * (l))      /* TSS stacks of levels 1, 2 */

static struct frame f;
static u8 *code;
static u32 cpl, cp;
static int h_stop(struct frame *x) { (void)x; return 1; }
static void e1(u32 v) { code[cp++] = v; }
static void e2(u32 v) { e1(v); e1(v >> 8); }
static void e4(u32 v) { e2(v); e2(v >> 16); }
static void begin(void) { cp = CODE_OFF; }
static u32 done_eip;
static void run(u32 eax, u32 ebx) {
    e1(0xCD); e1(0x85);
    done_eip = U_CODE + cp;
    for (u32 i = 0; i < sizeof f / 4; i++) ((u32 *)&f)[i] = 0;
    f.eax = eax; f.ebx = ebx; f.ecx = 0xC0C0C0C0; f.edx = 0xD0D0D0D0; f.esi = 0x51515151; f.edi = 0xD1D1D1D1; f.ebp = 0xB9B9B9B9;
    f.eip = U_CODE + CODE_OFF; f.cs = SEL_C(cpl); f.eflags = 2 | 0x3000;
    f.esp = USTK; f.ss = SEL_D(cpl);
    f.ds = f.es = f.fs = f.gs = S_UD;
    wr_cr3(P_PDU);
    go(&f, h_stop);
}
static void base_setup(void) {
    filld(V(P_PDU), 0, 1024);
    filld(V(P_SPT), 0, 1024);
    PTE(P_PDU, 768) = P_PT0 | 3;
    PTE(P_PDU, U_BASE >> 22) = P_SPT | 7;
    for (u32 i = 0; i < 8; i++) PTE(P_SPT, 0x50 + i) = (P_CODE + i * 0x1000) | 0x67;
    for (u32 i = 0; i < 2; i++) PTE(P_SPT, 0x60 + i) = (P_STK + i * 0x1000) | 0x67;
    code = (u8 *)V(P_CODE);
    for (u32 l = 0; l < 4; l++) {
        desc(gdt, SEL_C(l), 0, 0xFFFFF, 0x9B | l << 5, 0xC);
        desc(gdt, SEL_D(l), 0, 0xFFFFF, 0x93 | l << 5, 0xC);
    }
    tss1[3] = RSTK(1); tss1[4] = SEL_D(1); tss1[5] = RSTK(2); tss1[6] = SEL_D(2);
}
static const char *what;
static u32 p1, p2;
static void bad(const char *s, u32 a, u32 b) {
    if (fail_begin(s)) pf("%s cpl %d (%x %x): %x expected %x (vec %x err %x eip %x)\n", what, cpl, p1, p2, a, b, fin.vec, fin.err, fin.eip - U_CODE);
}
#define EXC(v, e) ((v) << 16 | ((e) & 0xFFFF))
#define OKAY 0u
static u32 outcome(void) { return fin.vec == 0x85 ? OKAY : EXC(fin.vec, fin.err); }
static u32 mx(u32 a, u32 b) { return a > b ? a : b; }

/* random descriptor: the access byte decides everything */
static u32 rnd_acc(void) {
    u32 x = rnd(), a = x & 0xFF;
    if (x & 0x100) a |= 0x10;               /* mostly code / data, mostly present */
    if (x & 0x600) a |= 0x80;
    return a;
}
/* selector of descriptor d with a random RPL; sometimes null or beyond the table */
static u32 rnd_sel(u32 d) {
    u32 x = rnd();
    if ((x & 63) == 0) return (x >> 8) & 3;
    if ((x & 63) == 1) return 0x200 | ((x >> 16) & 0xFFF8);
    if ((x & 63) == 2) return d | 4 | (x >> 8 & 3);             /* TI with a null LDT */
    return d | ((x >> 8) & 3);
}
static int in_table(u32 sel) { return !(sel & 4) && (sel | 7) < sizeof gdt; }

static u32 ld_data(u32 sel, u32 a) {        /* MOV DS / ES / FS / GS */
    u32 e = sel & 0xFFFC, dpl = a >> 5 & 3, rpl = sel & 3;
    if (!(sel & 0xFFFC)) return OKAY;
    if (!in_table(sel)) return EXC(13, e);
    if (!(a & 0x10) || ((a & 8) && !(a & 2))) return EXC(13, e);
    if ((a & 0xC) != 0xC && dpl < mx(cpl, rpl)) return EXC(13, e);
    if (!(a & 0x80)) return EXC(11, e);
    return OKAY;
}
static u32 ld_ss(u32 sel, u32 a, u32 lvl, u32 ts) {            /* SS load; ts: from the TSS */
    u32 e = sel & 0xFFFC, dpl = a >> 5 & 3, rpl = sel & 3, v = ts ? 10 : 13;
    if (!(sel & 0xFFFC)) return EXC(v, ts ? e : 0);
    if (!in_table(sel)) return EXC(v, e);
    if (rpl != lvl || !(a & 0x10) || (a & 8) || !(a & 2) || dpl != lvl) return EXC(v, e);
    if (!(a & 0x80)) return EXC(12, e);
    return OKAY;
}
static u32 cs_chk(u32 sel, u32 a, u32 rpl) {                   /* JMP / CALL to a code segment */
    u32 e = sel & 0xFFFC, dpl = a >> 5 & 3;
    if (!(sel & 0xFFFC)) return EXC(13, 0);
    if (!in_table(sel)) return EXC(13, e);
    if ((a & 0x18) != 0x18) return EXC(13, e);
    if (a & 4) { if (dpl > cpl) return EXC(13, e); }
    else if (dpl != cpl || rpl > cpl) return EXC(13, e);
    if (!(a & 0x80)) return EXC(11, e);
    return OKAY;
}
static void t_seg(void) {
    u32 a = rnd_acc(), sel = rnd_sel(S_T), fl = rnd() & 0xF, lim = rnd() & 0xFFFFF, k = rnd() % 10;
    u32 x, y = 0;
    cpl = rnd() & 3;
    u32 vis = in_table(sel) && (sel & 0xFFFC) ? 1 : 0, dpl = a >> 5 & 3, rpl = sel & 3;
    p1 = a; p2 = sel;
    if (k <= 6) { fl = 0xC; lim = 0xFFFFF; }                   /* flat, so that it can be used */
    desc(gdt, S_T, 0, lim, a, fl);
    u32 *d = gdt + (S_T >> 3) * 2, d1 = d[1];
    begin();
    switch (k) {
    case 0: case 1: case 2: case 3: {
        static const u8 sr[4] = { 0, 3, 4, 5 };
        what = "mov sreg"; x = ld_data(sel, a);
        e1(0x8E); e1(0xC0 | sr[k] << 3);
        break; }
    case 4: if (!cpl && a & 4) return;                         /* (a ring 0 stack without room: shutdown) */
        what = "mov ss"; x = ld_ss(sel, a, cpl, 0); e1(0x8E); e1(0xD0); e1(0x90); break;
    case 5: what = "jmp far"; goto cs;
    case 6: what = "call far";
    cs:
        if (vis && !(a & 0x10)) { u32 t = a & 0xF; if (t == 1 || t == 9 || t == 5 || t == 4 || t == 12) return; }
        x = cs_chk(sel, a, rpl);
        e1(k == 5 ? 0xEA : 0x9A); e4(U_CODE + cp + 6); e2(sel);
        break;
    case 7: what = "lar"; e1(0x0F); e1(0x02); e1(0xD8); x = OKAY;       /* lar ebx, eax */
        y = vis && ((a & 0x10) || (0x1A3E >> (a & 15) & 1)) && ((a & 0x1C) == 0x1C || dpl >= mx(cpl, rpl));
        break;
    case 8: what = "lsl"; e1(0x0F); e1(0x03); e1(0xD8); x = OKAY;
        y = vis && ((a & 0x10) || (0x0A0E >> (a & 15) & 1)) && ((a & 0x1C) == 0x1C || dpl >= mx(cpl, rpl));
        break;
    default:
        x = OKAY;
        if (rnd() & 1) { what = "verr"; e1(0x0F); e1(0x00); e1(0xE0);
            y = vis && (a & 0x10) && (!(a & 8) || a & 2) && ((a & 0xC) == 0xC || dpl >= mx(cpl, rpl)); }
        else { what = "verw"; e1(0x0F); e1(0x00); e1(0xE8);
            y = vis && (a & 0x10) && !(a & 8) && (a & 2) && dpl >= mx(cpl, rpl); }
    }
    u32 ebx = rnd();
    run(sel, ebx);
    u32 o = outcome();
    if (o != x) { bad("protection check", o, x); return; }
    if (o == OKAY && fin.eip != done_eip) { bad("EIP", fin.eip, done_eip); return; }
    if (o != OKAY && !(fin.eflags & RFL)) bad("RF of a fault frame", fin.eflags, RFL);
    if (o != OKAY && fin.eip != U_CODE + CODE_OFF) bad("fault EIP", fin.eip - U_CODE, CODE_OFF);
    if (o != OKAY && fin.cs != SEL_C(cpl)) bad("CS of a faulting transfer", fin.cs, SEL_C(cpl));
    if (k <= 4 || k == 5 || k == 6) {       /* the accessed bit is set by a successful load only */
        u32 w = o == OKAY && (sel & 0xFFFC) ? d1 | 0x100 : d1;
        if (d[1] != w) bad("accessed bit", d[1] >> 8 & 0xFF, w >> 8 & 0xFF);
        if (o == OKAY && k >= 5 && (fin.cs & 3) != cpl) bad("CPL", fin.cs & 3, cpl);
        if (o == OKAY && k >= 5 && (fin.cs & 0xFFFC) != (sel & 0xFFFC)) bad("CS", fin.cs, sel);
    } else {
        if (d[1] != d1) bad("descriptor changed", d[1], d1);
        u32 z = fin.eflags >> 6 & 1;
        if (z != y) { bad("ZF", z, y); return; }
        if (k == 7) {
            u32 w = y ? d1 & 0x00F0FF00 : ebx;
            if ((y ? fin.ebx & 0xFFF0FF00 : fin.ebx) != w) bad("LAR result", fin.ebx, w);
        }
        if (k == 8) {
            u32 w = fl & 8 ? lim << 12 | 0xFFF : lim;
            if (!y) w = ebx;
            if (fin.ebx != w) bad("LSL result", fin.ebx, w);
        }
    }
}
void s_seg(u32 round) {
    (void)round;
    base_setup();
    u32 n = cfg.progs ? cfg.progs * 100 : cfg.tb ? 200 : 20000;
    while (n--) t_seg();
    desc(gdt, S_T, 0, 0, 0, 0);
}

/* ---------------------------------------------------------------- gates */
/* the target: an INT 85h of the new privilege level.  Returns the expected outcome and the new CPL */
static u32 tgt_chk(u32 sel, u32 a, u32 jmp, u32 *ncpl) {
    u32 e = sel & 0xFFFC, dpl = a >> 5 & 3;
    *ncpl = cpl;
    if (!(sel & 0xFFFC)) return EXC(13, 0);
    if (!in_table(sel)) return EXC(13, e);
    /* (an interrupt gate takes an expand-up data segment as non-conforming code: real CPUs do) */
    if ((a & 0x18) != 0x18 && !(jmp == 2 && (a & 0x1C) == 0x10)) return EXC(13, e);
    if (dpl > cpl) return EXC(13, e);
    if (jmp == 1 && !(a & 4) && dpl != cpl) return EXC(13, e);
    if (!(a & 0x80)) return EXC(11, e);
    if (!(a & 4)) *ncpl = dpl;
    return OKAY;
}
static void t_gate(void) {
    u32 kind = rnd() % 3;                   /* 0 CALL gate, 1 JMP gate, 2 INT n */
    u32 ga = rnd() & 0xFF, ta = rnd_acc(), gsel, tsel = rnd_sel(S_T2), x, nc = 0, np = rnd() & 3;
    cpl = rnd() & 3;
    static const u8 gt[4] = { 0x0C, 0x0E, 0x0F, 0x04 };
    ga = (ga & 0x60) | 0x80;
    if (rnd() % 12 == 0) ga &= ~0x80;
    if (rnd() & 1) ta = 0x9A | (rnd() & 0x64);                 /* usually a usable code segment */
    if (rnd() & 1) tsel = S_T2 | (rnd() & 3);
    ga |= kind == 2 ? gt[1 + (rnd() & 1)] : gt[0];
    if (rnd() % 10 == 0) { ga = (ga & 0xF0) | (rnd() & 0x1F); }
    u32 gtp = ga & 0x1F;
    desc(gdt, S_T2, 0, 0xFFFFF, ta, 0xC);
    u32 g0 = (tsel << 16) | ((U_CODE + LAND_OFF) & 0xFFFF), g1 = ((U_CODE + LAND_OFF) & 0xFFFF0000) | ga << 8 | (kind == 2 ? 0 : np);
    code[LAND_OFF] = 0xCD; code[LAND_OFF + 1] = 0x85;
    begin();
    p1 = ga << 8 | ta;
    u32 ss1a = 0x93, sss = 0, vec = 0x8A, dpl = ga >> 5 & 3;
    /* the inner stacks: now and then a bad SS in the TSS */
    tss1[4] = SEL_D(1); tss1[6] = SEL_D(2); tss1[2] = S_KD;
    if (kind == 2) {
        what = "int gate";
        idt[vec * 2] = g0; idt[vec * 2 + 1] = g1;
        e1(0xCD); e1(vec);
        gsel = vec * 8 + 2;
        p2 = tsel;
        if (gtp != 0xE && gtp != 0xF) { if (gtp == 5 || gtp == 6 || gtp == 7) return; x = EXC(13, gsel); }
        else if (dpl < cpl) x = EXC(13, gsel);
        else if (!(ga & 0x80)) x = EXC(11, gsel);
        else x = tgt_chk(tsel, ta, 2, &nc);
    } else {
        what = kind ? "jmp gate" : "call gate";
        u32 *d = gdt + (S_G >> 3) * 2;
        d[0] = g0; d[1] = g1;
        gsel = S_G | (rnd() & 3);
        p2 = gsel << 16 | tsel;
        if (gtp != 0xC) {                   /* other types: only plainly invalid ones */
            if (gtp & 0x10 || gtp == 1 || gtp == 9 || gtp == 5 || gtp == 4) return;
            x = EXC(13, gsel & 0xFFFC);
        } else if (dpl < mx(cpl, gsel & 3)) x = EXC(13, gsel & 0xFFFC);
        else if (!(ga & 0x80)) x = EXC(11, gsel & 0xFFFC);
        else x = tgt_chk(tsel, ta, kind, &nc);
        e1(kind ? 0xEA : 0x9A); e4(0x12345678); e2(gsel);
    }
    if (x == OKAY && nc < cpl && nc && rnd() % 6 == 0) {       /* a bad inner stack */
        ss1a = rnd_acc(); sss = 0xE0 | (rnd() & 3);
        if (rnd() & 1) { ss1a = 0x93 | nc << 5; sss = 0xE0 | nc; if (rnd() & 1) ss1a &= ~0x80; }
        if (cfg.tb) ss1a &= ~4;            /* (86Box has no limit check on an inner stack) */
        desc(gdt, S_T, 0, 0xFFFFF, ss1a, 0xC);
        tss1[2 + 2 * nc] = sss;
        x = ld_ss(sss, ss1a, nc, 1);
        if (x == OKAY && (ss1a & 4)) x = EXC(12, 0);           /* expand-down, 4 GB limit: no valid offset */
    }
    u32 ret = U_CODE + cp;                  /* return address; after it: done */
    for (u32 i = 0; i < 4; i++) ((volatile u32 *)V(P_STK + 0x1E00))[i] = 0xABCD0000 + i;   /* parameters */
    run(tsel, 0x1111);
    u32 o = outcome();
    if (o != x) { bad("gate check", o, x); goto out; }
    if (o != OKAY) {
        if (fin.eip != U_CODE + CODE_OFF) bad("fault EIP", fin.eip - U_CODE, CODE_OFF);
        if (fin.cs != SEL_C(cpl)) bad("CS of a faulting transfer", fin.cs, SEL_C(cpl));
        if (cpl && (fin.ss != SEL_D(cpl) || fin.esp != USTK)) bad("SS:ESP of a faulting transfer", fin.esp, USTK);
        if (!(fin.eflags & RFL)) bad("RF of a fault frame", fin.eflags, RFL);
        goto out;
    }
    if (fin.eip != U_CODE + LAND_OFF + 2) { bad("landing EIP", fin.eip - U_CODE, LAND_OFF + 2); goto out; }
    if (fin.cs != ((tsel & 0xFFFC) | nc)) { bad("CS", fin.cs, (tsel & 0xFFFC) | nc); goto out; }
    /* the new stack and what was pushed on it */
    u32 top = nc == cpl ? USTK : nc ? RSTK(nc) : (u32)istack_top, n = 0, w[12];
    if (cpl == 0) goto out;                 /* (same-privilege ring 0: the kernel stack itself) */
    if (fin.ss != (nc == cpl ? SEL_D(cpl) : nc ? (sss ? sss : SEL_D(nc)) : S_KD)) bad("SS", fin.ss, SEL_D(nc));
    if (kind == 1) { if (fin.esp != top) bad("ESP", fin.esp, top); goto out; }
    if (nc != cpl) { w[n++] = SEL_D(cpl); w[n++] = USTK; }
    if (kind == 2) w[n++] = 2 | 0x3000;
    else if (nc != cpl) for (u32 i = np; i; i--) w[n++] = 0xABCD0000 + i - 1;
    w[n++] = SEL_C(cpl); w[n++] = ret;
    if (fin.esp != top - 4 * n) { bad("ESP", fin.esp, top - 4 * n); goto out; }
    for (u32 i = 0; i < n; i++) {
        u32 va = top - 4 - 4 * i, v = nc ? *(volatile u32 *)V(P_STK + va - U_STK) : *(volatile u32 *)va;
        /* (selector slots: the upper half is not defined) */
        u32 m = (nc != cpl && i == 0) || i == n - 2 ? 0xFFFF : 0xFFFFFFFF;
        if ((v ^ w[i]) & m) { bad("pushed value", v, w[i]); break; }
    }
out:
    tss1[4] = SEL_D(1); tss1[6] = SEL_D(2);
    for (u32 i = 0; i < 4; i++) ((volatile u32 *)V(P_STK + 0x1E00))[i] = 0;
}
/* CALL through a gate to an inner level and RETF n back; INT and IRET back; data segments too
   privileged for the outer level come back null */
static void t_return(void) {
    u32 in = rnd() & 3, np = rnd() & 7, kind = rnd() & 1, ds = rnd() & 3, vec = 0x8B;
    cpl = rnd() & 3;
    if (in > cpl || cpl == 0) return;
    what = kind ? "int / iret" : "call / retf"; p1 = in; p2 = np << 4 | ds;
    u32 *d = gdt + (S_G >> 3) * 2;
    u32 g0 = (SEL_C(in) << 16) | ((U_CODE + LAND_OFF) & 0xFFFF), g1 = ((U_CODE + LAND_OFF) & 0xFFFF0000);
    d[0] = g0; d[1] = g1 | 0xEC00 | np;
    idt[vec * 2] = g0; idt[vec * 2 + 1] = g1 | 0xEE00;
    u32 q = LAND_OFF;
    code[q++] = 0x66; code[q++] = 0xB8; code[q++] = SEL_D(ds); code[q++] = 0;      /* mov ax, data of level ds */
    u32 useds = ds >= in;                   /* (else it would fault) */
    if (useds) { code[q++] = 0x8E; code[q++] = 0xD8; code[q++] = 0x8E; code[q++] = 0xC0; }   /* DS, ES */
    if (kind) code[q++] = 0xCF;
    else if (in == cpl) code[q++] = 0xCB;
    else { code[q++] = 0xCA; code[q++] = np * 4; code[q++] = 0; }
    begin();
    u32 adj = !kind && in != cpl ? np * 4 : 0;
    if (kind) { e1(0xCD); e1(vec); }
    else { e1(0x9A); e4(0); e2(S_G | 3); }
    run(0, 0);
    if (fin.vec != 0x85) { bad("return: vector", fin.vec, 0x85); return; }
    if (fin.eip != done_eip) bad("return: EIP", fin.eip - U_CODE, done_eip - U_CODE);
    if (fin.cs != SEL_C(cpl) || fin.ss != SEL_D(cpl)) bad("return: CS / SS", fin.cs << 16 | fin.ss, SEL_C(cpl) << 16 | SEL_D(cpl));
    if (fin.esp != USTK + adj) bad("return: ESP", fin.esp, USTK + adj);
    if (useds) {
        u32 w = ds < cpl ? 0 : SEL_D(ds);
        if ((fin.ds & 0xFFFF) != w || (fin.es & 0xFFFF) != w) bad("return: data segments", fin.ds << 16 | (fin.es & 0xFFFF), w << 16 | w);
    }
    if (fin.fs != S_UD) bad("return: FS", fin.fs, S_UD);
}
void s_xfer(u32 round) {
    (void)round;
    base_setup();
    u32 n = cfg.progs ? cfg.progs * 100 : cfg.tb ? 200 : 20000;
    while (n--) { if (n % 3) t_gate(); else t_return(); }
    for (u32 v = 0x8A; v <= 0x8B; v++) gate(v, S_KC, (u32)isr_stubs + v * 16, 0xEE);
    desc(gdt, S_T, 0, 0, 0, 0); desc(gdt, S_T2, 0, 0, 0, 0); desc(gdt, S_G, 0, 0, 0, 0);
    tss1[3] = tss1[4] = tss1[5] = tss1[6] = 0;
}
