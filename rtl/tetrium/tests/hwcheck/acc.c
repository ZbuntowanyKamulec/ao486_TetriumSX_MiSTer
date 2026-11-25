// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* Memory access matrix: a table of instruction forms with the accesses each one makes.  Every
 * access of every form is tried against not-present / read-only / supervisor pages (also as the
 * second page of a crossing access), the alignment check, data breakpoints and segment limits
 * (normal and expand-down).  Checked: the exception, its error code and CR2, registers and memory
 * unchanged at the fault, the result after the restart, and the exact A / D bits. */
#include "kern.h"

#define P_PTA   0x72000u
#define L_BASE  0x10000000u                 /* segment base of the operands */
#define S_AD 0x83
#define S_AE 0x8B
#define S_AS 0x93
enum { M = 1, S, D, K, B };                 /* regions: EBX, ESI, EDI, ESP, EBP (K pages) */
enum { R = 1, W = 2, RW = 3, X = 0x10 /* wider than listed */ };
enum { VT = 1, VS, VF, VL, VH, VC };        /* contents: target EIP, data selector, flags, bound low / high, code selector */
struct acc { signed char rg, off; u8 sz, k, val; };
struct form { const char *name; u8 n; u8 code[10]; struct acc a[5]; u8 fl; };
enum { F_REP = 1, F_NOAC = 2, F_LSS = 4, F_NODR = 8, F_NOLIM = 16, F_PART = 64 /* may have stored a part */, F_POPA = 32 /* keeps the registers it popped before the fault (386EX) */ };
#define C(...) sizeof((u8[]){__VA_ARGS__}), {__VA_ARGS__}
static const struct form forms[] = {
    { "mov r8,m", C(0x8A, 0x03), {{ M, 0, 1, R }} },
    { "mov r32,m", C(0x8B, 0x03), {{ M, 0, 4, R }} },
    { "mov r16,m", C(0x66, 0x8B, 0x03), {{ M, 0, 2, R }} },
    { "mov ah,m", C(0x8A, 0x23), {{ M, 0, 1, R }} },
    { "mov m,r8", C(0x88, 0x03), {{ M, 0, 1, W }} },
    { "mov m,r32", C(0x89, 0x03), {{ M, 0, 4, W }} },
    { "mov m,r16", C(0x66, 0x89, 0x03), {{ M, 0, 2, W }} },
    { "mov m,i8", C(0xC6, 0x03, 0x5A), {{ M, 0, 1, W }} },
    { "mov m,i32", C(0xC7, 0x03, 1, 2, 3, 4), {{ M, 0, 4, W }} },
    { "add m,r8", C(0x00, 0x03), {{ M, 0, 1, RW }} },
    { "add m,r32", C(0x01, 0x03), {{ M, 0, 4, RW }} },
    { "adc m,r16", C(0x66, 0x11, 0x03), {{ M, 0, 2, RW }} },
    { "xor r32,m", C(0x33, 0x03), {{ M, 0, 4, R }} },
    { "cmp m,r8", C(0x38, 0x03), {{ M, 0, 1, R }} },
    { "cmp m,r32", C(0x39, 0x03), {{ M, 0, 4, R }} },
    { "cmp m,i8", C(0x80, 0x3B, 5), {{ M, 0, 1, R }} },
    { "cmp m32,i8", C(0x83, 0x3B, 5), {{ M, 0, 4, R }} },
    { "cmp m32,i32", C(0x81, 0x3B, 5, 0, 1, 2), {{ M, 0, 4, R }} },
    { "test m,r32", C(0x85, 0x03), {{ M, 0, 4, R }} },
    { "test m,i8", C(0xF6, 0x03, 1), {{ M, 0, 1, R }} },
    { "test m,i32", C(0xF7, 0x03, 1, 2, 3, 4), {{ M, 0, 4, R }} },
    { "and m,i8", C(0x83, 0x23, 0xF0), {{ M, 0, 4, RW }} },
    { "sbb m,i32", C(0x81, 0x1B, 1, 2, 3, 4), {{ M, 0, 4, RW }} },
    { "inc m8", C(0xFE, 0x03), {{ M, 0, 1, RW }} },
    { "inc m", C(0xFF, 0x03), {{ M, 0, 4, RW }} },
    { "dec m16", C(0x66, 0xFF, 0x0B), {{ M, 0, 2, RW }} },
    { "not m", C(0xF7, 0x13), {{ M, 0, 4, RW }} },
    { "neg m", C(0xF7, 0x1B), {{ M, 0, 4, RW }} },
    { "shl m,1", C(0xD1, 0x23), {{ M, 0, 4, RW }} },
    { "sar m,3", C(0xC1, 0x3B, 3), {{ M, 0, 4, RW }} },
    { "rol m,cl", C(0xD3, 0x03), {{ M, 0, 4, RW }} },
    { "rcr m8,cl", C(0xD2, 0x1B), {{ M, 0, 1, RW }} },
    { "shld m,i", C(0x0F, 0xA4, 0x03, 5), {{ M, 0, 4, RW }} },
    { "shrd m,cl", C(0x0F, 0xAD, 0x03), {{ M, 0, 4, RW }} },
    { "xchg m,r", C(0x87, 0x03), {{ M, 0, 4, RW }} },
    { "xchg m8,r", C(0x86, 0x03), {{ M, 0, 1, RW }} },
    { "xadd m,r", C(0x0F, 0xC1, 0x03), {{ M, 0, 4, RW }} },
    { "lock xadd", C(0xF0, 0x0F, 0xC1, 0x03), {{ M, 0, 4, RW }} },
    { "lock dec", C(0xF0, 0xFF, 0x0B), {{ M, 0, 4, RW }} },
    { "cmpxchg", C(0x0F, 0xB1, 0x13), {{ M, 0, 4, RW }} },
    { "bt m,i", C(0x0F, 0xBA, 0x23, 5), {{ M, 0, 4, R }} },
    { "bts m,i", C(0x0F, 0xBA, 0x2B, 5), {{ M, 0, 4, RW }} },
    { "bt m,r", C(0x0F, 0xA3, 0x03), {{ M, 4, 4, R }} },
    { "btc m,r", C(0x0F, 0xBB, 0x03), {{ M, 4, 4, RW }} },
    { "bsf r,m", C(0x0F, 0xBC, 0x13), {{ M, 0, 4, R }} },
    { "imul r,m", C(0x0F, 0xAF, 0x03), {{ M, 0, 4, R }} },
    { "imul r,m,i", C(0x6B, 0x03, 5), {{ M, 0, 4, R }} },
    { "mul m", C(0xF7, 0x23), {{ M, 0, 4, R }} },
    { "imul m8", C(0xF6, 0x2B), {{ M, 0, 1, R }} },
    { "div m", C(0xF7, 0x33), {{ M, 0, 4, R }} },
    { "setz m", C(0x0F, 0x94, 0x03), {{ M, 0, 1, W }} },
    { "movzx m8", C(0x0F, 0xB6, 0x03), {{ M, 0, 1, R }} },
    { "movsx m16", C(0x0F, 0xBF, 0x03), {{ M, 0, 2, R }} },
    { "push m", C(0xFF, 0x33), {{ M, 0, 4, R }, { K, -4, 4, W }} },
    { "pop m", C(0x8F, 0x03), {{ K, 0, 4, R }, { M, 0, 4, W }} },
    { "push m16", C(0x66, 0xFF, 0x33), {{ M, 0, 2, R }, { K, -2, 2, W }} },
    { "push r", C(0x50), {{ K, -4, 4, W }} },
    { "push esp", C(0x54), {{ K, -4, 4, W }} },
    { "pop r", C(0x58), {{ K, 0, 4, R }} },
    { "pop esp", C(0x5C), {{ K, 0, 4, R }} },
    { "pop r16", C(0x66, 0x58), {{ K, 0, 2, R }} },
    { "push i", C(0x68, 1, 2, 3, 4), {{ K, -4, 4, W }} },
    { "push i8", C(0x6A, 0xFF), {{ K, -4, 4, W }} },
    { "pushf", C(0x9C), {{ K, -4, 4, W }} },
    { "popf", C(0x9D), {{ K, 0, 4, R, VF }} },
    { "pusha", C(0x60), {{ K, -32, 32, W }} },
    { "popa", C(0x61), {{ K, 0, 32, R }}, F_POPA },
    { "pusha16", C(0x66, 0x60), {{ K, -16, 16, W }} },
    { "popa16", C(0x66, 0x61), {{ K, 0, 16, R }}, F_POPA },
    { "enter 16,0", C(0xC8, 16, 0, 0), {{ K, -4, 4, W }}, F_NOLIM },
    { "enter 4,1", C(0xC8, 4, 0, 1), {{ K, -4, 4, W }, { K, -8, 4, W }}, F_NOLIM },
    { "enter 4,2", C(0xC8, 4, 0, 2), {{ K, -4, 4, W }, { B, -4, 4, R }, { K, -8, 4, W }, { K, -12, 4, W }}, F_NOLIM },
    { "leave", C(0xC9), {{ B, 0, 4, R }} },
    { "lodsb", C(0xAC), {{ S, 0, 1, R }} },
    { "lodsd", C(0xAD), {{ S, 0, 4, R }} },
    { "stosb", C(0xAA), {{ D, 0, 1, W }} },
    { "stosd", C(0xAB), {{ D, 0, 4, W }} },
    { "movsb", C(0xA4), {{ S, 0, 1, R }, { D, 0, 1, W }} },
    { "movsw", C(0x66, 0xA5), {{ S, 0, 2, R }, { D, 0, 2, W }} },
    { "movsd", C(0xA5), {{ S, 0, 4, R }, { D, 0, 4, W }} },
    { "cmpsd", C(0xA7), {{ S, 0, 4, R }, { D, 0, 4, R }} },
    { "cmpsb", C(0xA6), {{ S, 0, 1, R }, { D, 0, 1, R }} },
    { "scasd", C(0xAF), {{ D, 0, 4, R }} },
    { "scasb", C(0xAE), {{ D, 0, 1, R }} },
    { "rep movsd", C(0xF3, 0xA5), {{ S, 0, 12, R }, { D, 0, 12, W }}, F_REP },
    { "rep movsb", C(0xF3, 0xA4), {{ S, 0, 3, R }, { D, 0, 3, W }}, F_REP },
    { "rep stosd", C(0xF3, 0xAB), {{ D, 0, 12, W }}, F_REP },
    { "rep lodsw", C(0xF3, 0x66, 0xAD), {{ S, 0, 6, R }}, F_REP },
    { "repe cmpsd", C(0xF3, 0xA7), {{ S, 0, 4, R, VL }, { D, 0, 4, R, VH }}, F_REP },
    { "repne scasd", C(0xF2, 0xAF), {{ D, 0, 12, R }}, F_REP },
    { "xlat", C(0xD7), {{ M, 0x23, 1, R }} },
    { "call", C(0xE8, 0, 0, 0, 0), {{ K, -4, 4, W }} },
    { "ret", C(0xC3), {{ K, 0, 4, R, VT }} },
    { "ret 8", C(0xC2, 8, 0), {{ K, 0, 4, R, VT }} },
    { "call m", C(0xFF, 0x13), {{ M, 0, 4, R, VT }, { K, -4, 4, W }} },
    { "jmp m", C(0xFF, 0x23), {{ M, 0, 4, R, VT }} },
    { "retf", C(0xCB), {{ K, 0, 4, R, VT }, { K, 4, 2, R | X, VC }} },
    { "iretd", C(0xCF), {{ K, 0, 4, R, VT }, { K, 4, 2, R | X, VC }, { K, 8, 4, R, VF }} },
    { "jmp far m", C(0xFF, 0x2B), {{ M, 0, 4, R, VT }, { M, 4, 2, R, VC }} },
    { "call far m", C(0xFF, 0x1B), {{ M, 0, 4, R, VT }, { M, 4, 2, R, VC }, { K, -4, 2, W | X }, { K, -8, 4, W }} },
    { "les", C(0xC4, 0x13), {{ M, 0, 4, R }, { M, 4, 2, R, VS }} },
    { "lfs16", C(0x66, 0x0F, 0xB4, 0x13), {{ M, 0, 2, R }, { M, 2, 2, R, VS }} },
    { "lss", C(0x0F, 0xB2, 0x23), {{ M, 0, 4, R }, { M, 4, 2, R, VS }}, F_LSS },
    { "mov es,m", C(0x8E, 0x03), {{ M, 0, 2, R, VS }} },
    { "mov m,es", C(0x8C, 0x03), {{ M, 0, 2, W }} },
    { "push ds", C(0x1E), {{ K, -4, 2, W | X }} },
    { "pop es", C(0x07), {{ K, 0, 2, R | X, VS }} },
    { "pop fs", C(0x0F, 0xA1), {{ K, 0, 2, R | X, VS }} },
    { "sgdt", C(0x0F, 0x01, 0x03), {{ M, 0, 2, W }, { M, 2, 4, W }}, F_NOAC | F_NOLIM | F_PART },
    { "sidt", C(0x0F, 0x01, 0x0B), {{ M, 0, 2, W }, { M, 2, 4, W }}, F_NOAC | F_NOLIM | F_PART },
    { "sldt", C(0x0F, 0x00, 0x03), {{ M, 0, 2, W }} },
    { "str", C(0x0F, 0x00, 0x0B), {{ M, 0, 2, W }} },
    { "smsw", C(0x0F, 0x01, 0x23), {{ M, 0, 2, W }} },
    { "verr", C(0x0F, 0x00, 0x23), {{ M, 0, 2, R, VS }} },
    { "lar", C(0x0F, 0x02, 0x13), {{ M, 0, 2, R, VS }} },
    { "lsl", C(0x0F, 0x03, 0x13), {{ M, 0, 2, R, VS }} },
    { "bound", C(0x62, 0x03), {{ M, 0, 4, R, VL }, { M, 4, 4, R, VH }} },
};
#define NF (sizeof forms / sizeof forms[0])

static const struct form *F;
static u32 ptr[6], init[8], efl, endn, rlim[3], redn[3], dracc, nstep, fixpage, fixpte;
static struct frame fin1;
static u32 ref_r[8], ref_fl, ref_eip;
static const u32 lo_page[6] = { 0, 0x10, 0x20, 0x30, 0x40, 0x40 };
#define CODE_OFF 0x100u
#define TGT_OFF  0x200u

static u32 reg_seg(u32 rg) { return rg == D ? 1 : rg == K || rg == B ? 2 : 0; }
static void seg_setup(void) {
    static const u8 sel[3] = { S_AD, S_AE, S_AS };
    for (u32 i = 0; i < 3; i++) desc(gdt, sel[i], L_BASE, rlim[i], redn[i] ? 0xF7 : 0xF3, 4);
}
static u32 a_lin(u32 i) { return ptr[F->a[i].rg] + F->a[i].off; }     /* offset in the segment */
static u32 pat(u32 i) { return ((i * 6 + 2) & 0xBE) | 2; }
static u32 touches(u32 pg, u32 wr);
static u32 used;
static void fill(void) {
    for (u32 pg = 0; pg < 10; pg++)         /* (the pages the form uses) */
        if (used >> pg & 1) copyd(V(P_WIN + pg * 0x1000), V(P_PRI + pg * 0x1000), 1024);
}
/* pages 10,11 -> WIN 0,1   20,21 -> 2,3   30,31 -> 4,5   40.. -> 6.. */
static u32 phys(u32 off) {
    u32 pg = off >> 12, k = (pg >> 4) - 1;
    return P_WIN + (k * 2 + (pg & 15)) * 0x1000 + (off & 0xFFF);
}
static void poke(u32 off, u32 v, u32 n) { for (u32 i = 0; i < n; i++) *(volatile u8 *)V(phys(off + i)) = v >> (8 * i); }
static void values(void) {
    for (u32 i = 0; i < 5 && F->a[i].sz; i++) {
        u32 o = a_lin(i);
        switch (F->a[i].val) {
        case VT: poke(o, U_CODE + TGT_OFF, F->a[i].sz); break;
        case VS: poke(o, S_UD, 2); break;
        case VC: poke(o, S_UC, 2); break;
        case VF: poke(o, 0x2C3, F->a[i].sz); break;
        case VL: poke(o, 0, 4); break;
        case VH: poke(o, 0x7FFFFFFF, 4); break;
        }
    }
}
static u32 ad0;                            /* A / D bits of the fresh PTEs */
static void ptes(void) {
    for (u32 i = 0; i < 4; i++) for (u32 j = 0; j < 4; j++)
        PTE(P_PTA, 0x10 * (i + 1) + j) = (j < (i == 3 ? 4u : 2u)) ? (P_WIN + (i * 2 + j) * 0x1000) | 7 | ad0 : 0;
    wr_cr3(P_PDU);
}
static void frame_init(struct frame *f) {
    for (u32 i = 0; i < sizeof *f / 4; i++) ((u32 *)f)[i] = 0;
    f->eax = init[0] = 0x00000023; f->ecx = init[1] = 3; f->edx = init[2] = 0; f->ebx = init[3] = ptr[M];
    f->esi = init[6] = ptr[S]; f->edi = init[7] = ptr[D]; f->ebp = init[5] = ptr[B]; f->esp = init[4] = ptr[K];
    f->ds = S_AD; f->es = S_AE; f->ss = S_AS; f->fs = f->gs = S_UD;
    f->cs = S_UC; f->eip = U_CODE + CODE_OFF; f->eflags = efl | 2;
}
static int at_end(struct frame *f) {
    return f->vec == 13 && (f->eip == U_CODE + CODE_OFF + F->n || f->eip == U_CODE + TGT_OFF);
}
static int h_stop(struct frame *f) {        /* stops at the first exception; data breakpoints are collected */
    if (f->vec == 1) { dracc |= rd_dr6() & 15; wr_dr6(0); if (++nstep > 50) return 1; return 0; }
    return 1;
}
static int h_fix(struct frame *f) {         /* the first #PF is repaired, then on to the end */
    if (f->vec == 14 && fixpage) { fixpage = 0; return 1; }
    return 1;
}
static void start(void) { struct frame f; frame_init(&f); dracc = 0; nstep = 0; go(&f, h_stop); }
static void resume(void) { struct frame f = fin; go(&f, h_stop); }

static int bad(const char *what, u32 a, u32 b) {
    if (fail_begin(what)) pf("%s: %x expected %x (eip %x err %x cr2 %x)\n", F->name, a, b, fin.eip - U_CODE, fin.err, rd_cr2());
    return 0;
}
static int same_regs(void) {                /* nothing changed at the fault */
    u32 r[8] = { fin.eax, fin.ecx, fin.edx, fin.ebx, fin.esp, fin.ebp, fin.esi, fin.edi };
    if (F->fl & F_REP) return 1;
    for (u32 i = 0; i < 8; i++)
        if (r[i] != init[i] && !(F->fl & F_POPA && i != 4)) return bad("register changed by a faulting instruction", r[i], init[i]);
    if ((fin.eflags & AFL) != (efl & AFL)) return bad("flags changed by a faulting instruction", fin.eflags & AFL, efl & AFL);
    if (fin.eip != U_CODE + CODE_OFF) return bad("fault EIP", fin.eip - U_CODE, CODE_OFF);
    if (!(fin.eflags & RFL)) return bad("RF of a fault frame", fin.eflags, RFL);
    if (fin.cs != S_UC || fin.ss != S_AS || fin.ds != S_AD) return bad("segment changed by a faulting instruction", fin.ss, S_AS);
    return 1;
}
static void take_ref(void) {
    u32 r[8] = { fin.eax, fin.ecx, fin.edx, fin.ebx, fin.esp, fin.ebp, fin.esi, fin.edi };
    for (u32 i = 0; i < 8; i++) ref_r[i] = r[i];
    ref_fl = fin.eflags & AFL; ref_eip = fin.eip;
    for (u32 pg = 0; pg < 10; pg++) if (used >> pg & 1) copyd(V(P_REF + pg * 0x1000), V(P_WIN + pg * 0x1000), 1024);
}
static void same_result(const char *what) {
    u32 r[8] = { fin.eax, fin.ecx, fin.edx, fin.ebx, fin.esp, fin.ebp, fin.esi, fin.edi };
    if (!at_end(&fin)) { bad(what, fin.vec, 13); return; }
    for (u32 i = 0; i < 8; i++) if (r[i] != ref_r[i]) { bad(what, r[i], ref_r[i]); return; }
    if ((fin.eflags & AFL) != ref_fl) { bad(what, fin.eflags & AFL, ref_fl); return; }
    if (fin.eip != ref_eip) { bad(what, fin.eip, ref_eip); return; }
    for (u32 pg = 0; pg < 10; pg++) {
        if (!(used >> pg & 1)) continue;
        u32 a = V(P_WIN + pg * 0x1000), b = V(P_REF + pg * 0x1000), i = cmpd(a, b, 1024);
        if (i != 1024) { bad(what, ((u32 *)a)[i], ((u32 *)b)[i]); return; }
    }
}
/* the region pointers: random, aligned, every access inside the first page */
static void place(void) {
    for (u32 rg = M; rg <= B; rg++) ptr[rg] = (lo_page[rg] << 12) + 0x200 + (rnd() & 0x7FC);
    ptr[K] = (lo_page[K] << 12) + 0x200 + (rnd() & 0x3FC);
    ptr[B] = (lo_page[K] << 12) + 0x900 + (rnd() & 0x3FC);
    /* (an expand-down / limit test of B and K uses one segment: B above K) */
}
static void setup(void) {
    used = 0;
    for (u32 i = 0; i < 4; i++) for (u32 j = 0; j < (i == 3 ? 4u : 2u); j++) if (touches(0x10 * (i + 1) + j, 0)) used |= 1u << (2 * i + j);
    fill(); ptes(); seg_setup(); values(); }
static u32 touches(u32 pg, u32 wr) {        /* does the form access (write) the page (segment page number)? */
    for (u32 i = 0; i < 5 && F->a[i].sz; i++) {
        u32 a = a_lin(i);
        if ((a >> 12) <= pg && ((a + F->a[i].sz - 1) >> 12) >= pg && (!wr || F->a[i].k & W)) return 1;
    }
    return 0;
}
static void check_ad(void) {
    for (u32 rg = 0; rg < 4; rg++) for (u32 j = 0; j < 2; j++) {
        u32 pg = 0x10 * (rg + 1) + j, e = PTE(P_PTA, pg) & 0x60;
        u32 x = (touches(pg, 0) ? 0x20 : 0) | (touches(pg, 1) ? 0x40 : 0);
        if (e != x) bad("A / D bits of a page", e | pg << 12, x | pg << 12);
    }
}
static void t_paging(u32 i, u32 cross) {
    place();
    ad0 = 0;
    const struct acc *a = &F->a[i];
    u32 sz = a->sz;
    if (cfg.tb && F->fl & F_PART) return;
    if (cross) {                            /* the access straddles the pages */
        if (sz == 1) return;
        u32 n = 1 + rnd() % (sz - 1);       /* bytes in the first page */
        if (F->fl & F_REP || sz > 8) n = (n + 3) & ~3u;
        if (n >= sz) return;
        ptr[a->rg] = (((lo_page[a->rg] + 1) << 12) - n) - a->off;
    }
    rlim[0] = rlim[1] = rlim[2] = 0xFFFFF; redn[0] = redn[1] = redn[2] = 0;
    setup();
    start();
    if (!at_end(&fin)) { bad("unexpected exception", fin.vec, 13); return; }
    take_ref();
    check_ad();
    for (u32 c = 0; c < 4; c++) {           /* 0 not present, 1 read-only, 2 supervisor, 3 present (RO allowed) */
        u32 pg = (a_lin(i) >> 12) + (cross ? (rnd() & 1) : 0);
        if (c == 1 && !(a->k & W)) continue;
        if (c == 3 && a->k & W) continue;
        u32 other = 0;                      /* another access of the form in the same page decides first: skip */
        for (u32 q = 0; q < 5 && F->a[q].sz; q++)
            if (q != i && (a_lin(q) >> 12) <= pg && ((a_lin(q) + F->a[q].sz - 1) >> 12) >= pg) other = 1;
        setup();
        u32 e = PTE(P_PTA, pg);
        PTE(P_PTA, pg) = c == 0 ? e & ~1u : c == 1 || c == 3 ? e & ~2u : e & ~4u;
        wr_cr3(P_PDU);
        start();
        if (c == 3) { if (!other) same_result("read of a read-only page"); continue; }
        if (fin.vec != 14) { bad("page fault expected, vector", fin.vec, 14); continue; }
        u32 want = (c ? 1 : 0) | 4, er = fin.err & ~2u;
        if (er != want) bad("#PF error code", fin.err, want | (a->k & W));
        if (!other) {
            if (a->k == R && fin.err & 2) bad("#PF error code W of a read", fin.err, want);
            if ((a->k & ~X) == W && !(fin.err & 2)) bad("#PF error code W of a write", fin.err, want | 2);
            if (c == 1 && !(fin.err & 2)) bad("#PF error code W, read-only page", fin.err, 7);
        }
        if (rd_cr2() >> 12 != (L_BASE >> 12) + pg) bad("CR2 page", rd_cr2(), L_BASE + (pg << 12));
        same_regs();
        PTE(P_PTA, pg) = (PTE(P_PTA, pg) & 0x60) | e;
        wr_cr3(P_PDU);
        resume();
        same_result("result after the restart");
        check_ad();
    }
}
static void t_align(u32 mis) {
    if (F->fl & F_NOAC) return;
    ad0 = 0x60;
    place();
    for (u32 rg = M; rg <= B; rg++) ptr[rg] += mis;
    rlim[0] = rlim[1] = rlim[2] = 0xFFFFF; redn[0] = redn[1] = redn[2] = 0;
    u32 exp = 0;
    for (u32 i = 0; i < 5 && F->a[i].sz; i++) {
        u32 sz = F->a[i].sz, u = sz;
        if (sz == 32 || sz == 12) u = 4;
        if (sz == 16 || sz == 6) u = 2;
        if (sz == 3) u = 1;
        if (F->a[i].k & X) u = 2;
        if (a_lin(i) & (u - 1)) exp = 1;
        if (F->a[i].k & X && a_lin(i) & 3) return;             /* (2 or 4 bytes: not known) */
    }
    setup();
    efl |= ACL;
    u32 c0 = rd_cr0();
    wr_cr0(c0 | 0x40000);
    start();
    wr_cr0(c0);
    efl &= ~ACL;
    if (exp) {
        if (fin.vec != 17) { bad("#AC expected, vector", fin.vec, 17); return; }
        if (fin.err) bad("#AC error code", fin.err, 0);
        same_regs();
    } else if (!at_end(&fin)) bad("no #AC expected, vector", fin.vec, 13);
}
static u32 overlap(u32 a, u32 n, u32 wr, u32 amb) {            /* does the form access [a, a+n)? */
    for (u32 i = 0; i < 5 && F->a[i].sz; i++) {
        u32 s = a_lin(i), z = F->a[i].sz + (amb && F->a[i].k & X ? 2 : 0);
        if (wr && !(F->a[i].k & W)) continue;
        if (a < s + z && s < a + n) return 1;
    }
    return 0;
}
static void t_debug(u32 i) {
    ad0 = 0x60;
    place();
    for (u32 rg = M; rg <= B; rg++) ptr[rg] += rnd() & 3;
    rlim[0] = rlim[1] = rlim[2] = 0xFFFFF; redn[0] = redn[1] = redn[2] = 0;
    setup();
    u32 s = a_lin(i), z = F->a[i].sz, exp = 0, skip = 0, dr7 = 0x400, a[4], n[4], w[4];
    static const u8 lc[3] = { 0, 1, 3 };
    for (u32 b = 0; b < 4; b++) {
        u32 l = lc[rnd() % 3];
        n[b] = l + 1; w[b] = rnd() & 1;
        u32 x = b == 0 ? s : b == 1 ? s + z - 1 : b == 2 ? s + z : s - 1;
        if (b == 0 && (rnd() & 3) == 0) x = s + rnd() % z;
        a[b] = x & ~l;
        dr7 |= (2u << (2 * b)) | ((l << 2 | (w[b] ? 1 : 3)) << (16 + 4 * b));
        u32 o = overlap(a[b], n[b], w[b], 0);
        if (o) exp |= 1u << b;
        if (o != overlap(a[b], n[b], w[b], 1)) skip |= 1u << b;
    }
    if (F->fl & F_LSS) return;              /* (the stack switch holds the trap off) */
    wr_dr0(L_BASE + a[0]); wr_dr1(L_BASE + a[1]); wr_dr2(L_BASE + a[2]); wr_dr3(L_BASE + a[3]);
    wr_dr6(0); wr_dr7(dr7);
    start();
    wr_dr7(0x400);
    if (!at_end(&fin)) { bad("data breakpoints: vector", fin.vec, 13); return; }
    if ((dracc ^ exp) & ~skip) bad("data breakpoints hit", dracc | s << 4, exp | s << 4);
    if (!exp && !skip && nstep) bad("#DB without a breakpoint", nstep, 0);
    if (exp && !(F->fl & F_REP) && nstep != 1) bad("#DB count", nstep, 1);
}
static void t_limit(u32 i) {
    if (F->fl & F_NOLIM) return;
    ad0 = 0x60;
    place();
    u32 g = reg_seg(F->a[i].rg), s = a_lin(i), z = F->a[i].sz;
    for (u32 c = 0; c < 4; c++) {           /* 0 / 1: limit = last byte / one less;  2 / 3: expand-down */
        rlim[0] = rlim[1] = rlim[2] = 0xFFFFF; redn[0] = redn[1] = redn[2] = 0;
        if (cfg.tb && (F->code[0] == 0xCB || F->code[0] == 0xCF)) return;   /* (86Box does not check these) */
        rlim[g] = c == 0 ? s + z - 1 : c == 1 ? s + z - 2 : c == 2 ? s - 1 : s;
        redn[g] = c >= 2;
        u32 exp = 0, skip = 0;
        for (u32 q = 0; q < 5 && F->a[q].sz; q++) {
            if (reg_seg(F->a[q].rg) != g) continue;
            u32 f = a_lin(q), l = f + F->a[q].sz - 1, lx = l + (F->a[q].k & X ? 2 : 0);
            u32 o = redn[g] ? f <= rlim[g] : l > rlim[g];
            if (o) exp = 1;
            if (!redn[g] && (lx > rlim[g]) != (l > rlim[g])) skip = 1;
        }
        if (skip) continue;
        setup();
        start();
        u32 v = g == 2 ? 12 : 13;
        if (exp) {
            if (fin.vec != v || (v == 13 && at_end(&fin))) { bad("segment limit: vector", fin.vec, v); continue; }
            if (fin.err) bad("segment limit: error code", fin.err, 0);
            same_regs();
        } else if (!at_end(&fin)) bad("inside the limit: vector", fin.vec, 0);
    }
}
void s_acc(u32 round) {
    u32 c0 = rd_cr0();
    (void)round;
    for (u32 i = 0; i < 0xA000; i += 4) *(volatile u32 *)V(P_PRI + i) = pat(i) | pat(i + 1) << 8 | pat(i + 2) << 16 | pat(i + 3) << 24;
    filld(V(P_PDU), 0, 1024);
    filld(V(P_SPT), 0, 1024);
    filld(V(P_PTA), 0, 1024);
    PTE(P_PDU, 768) = P_PT0 | 3;
    PTE(P_PDU, U_BASE >> 22) = P_SPT | 7;
    PTE(P_PDU, L_BASE >> 22) = P_PTA | 7;
    for (u32 i = 0; i < 8; i++) PTE(P_SPT, 0x50 + i) = (P_CODE + i * 0x1000) | 0x25;
    wr_cr0(c0 & ~0x4000Eu);
    wr_cr3(P_PDU);
    for (u32 k = 0; k < NF; k++) {
        F = &forms[k];
        if (cfg.one ? cfg.one != k + 1 : cfg.tb && cfg.progs && (k ^ round) % cfg.progs) continue;
        efl = (rnd() & 0x8D1) | 0x202;
        volatile u8 *c = (u8 *)V(P_CODE);
        for (u32 i = 0; i < 16; i++) c[CODE_OFF + i] = 0xF4;
        for (u32 i = 0; i < F->n; i++) c[CODE_OFF + i] = F->code[i];
        c[TGT_OFF] = 0xF4;
        for (u32 i = 0; i < 5 && F->a[i].sz; i++) {
            t_paging(i, 0);
            t_paging(i, 1);
            t_limit(i);
            for (u32 q = 0; q < (cfg.tb ? 1 : 8); q++) t_debug(i);
        }
        for (u32 m = 0; m < 4; m++) t_align(m);
    }
    wr_cr0(c0);
}
