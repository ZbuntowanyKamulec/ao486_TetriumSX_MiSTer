// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* Virtual memory as an OS uses it: four address spaces over the same linear range, remapped,
 * protected, copied on write and unmapped at random (PTE and PDE level), accessed from ring 3 and
 * ring 0 (with and without CR0.WP), data and code (written through one mapping, run through
 * another), checked against a software model of the memory, the translation and the A / D bits. */
#include "kern.h"

#define NS   4
#define NP   24                             /* linear pages */
#define L0   0x20000000u
#define P_PDS 0x72000u                      /* page directories, then one table per space */
#define P_PTS 0x76000u
#define CODE_OFF 0x100u

static u32 npp;                             /* physical pages and their shadows */
static u32 ppage(u32 i) { return cfg.tb && !(cfg.off & 0x4000) ? P_WIN + i * 0x1000 : 0x200000 + i * 0x1000; }
static u32 shadow(u32 i) { return cfg.tb && !(cfg.off & 0x4000) ? P_REF + i * 0x1000 : 0x300000 + i * 0x1000; }
static u16 map_pg[NS][NP]; static u8 map_fl[NS][NP];           /* flags: 1 P, 2 RW, 4 US */
static u8 map_ad[NS][NP], pde_p[NS];
static u32 sp, wp, opn;
static struct frame f;
static u8 *code;
static u32 cp;
static int h_stop(struct frame *x) { (void)x; return 1; }
static const char *what;
static void bad(const char *s, u32 a, u32 b) {
    if (fail_begin(s)) pf("%s op %d: %x expected %x (vec %x err %x cr2 %x eip %x)\n", what, opn, a, b, fin.vec, fin.err, rd_cr2(), fin.eip);
}
static volatile u32 *pte(u32 s, u32 p) { return &PTE(P_PTS + s * 0x1000, p); }
static void put(u32 s, u32 p) {             /* the PTE from the model */
    *pte(s, p) = ppage(map_pg[s][p]) | map_fl[s][p] | map_ad[s][p];
    if (s == sp) { if (rnd() & 3) invlpg(L0 + p * 0x1000); else wr_cr3(rd_cr3()); }
}
static u32 sh(u32 s, u32 lin) { return shadow(map_pg[s][(lin - L0) >> 12]) + (lin & 0xFFF); }
static u8 rdb(u32 lin) { return *(volatile u8 *)V(sh(sp, lin)); }
static void wrb(u32 lin, u32 v) { *(volatile u8 *)V(sh(sp, lin)) = v; }
/* access check: 0 allowed, else the #PF error code | 80000000; *pg: the faulting page */
static u32 chk1(u32 lin, u32 w, u32 u) {
    u32 p = (lin - L0) >> 12, fl = map_fl[sp][p];
    u32 e = 0x80000000 | w << 1 | u << 2;
    if (!pde_p[sp] || !(fl & 1)) return e;
    if (u && !(fl & 4)) return e | 1;
    if (w && !(fl & 2) && (u || wp)) return e | 1;
    return 0;
}
static u32 chk(u32 lin, u32 n, u32 w, u32 u, u32 *where) {
    u32 e = chk1(lin, w, u), l2 = lin + n - 1, e2 = (l2 ^ lin) >> 12 ? chk1(l2, w, u) : 0;
    *where = e ? lin : l2;
    if (e && e2) *where = 0;                /* either page may be reported */
    return e ? e : e2;
}
static void ad(u32 lin, u32 n, u32 w) {
    for (u32 p = (lin - L0) >> 12; p <= (lin + n - 1 - L0) >> 12; p++) map_ad[sp][p] |= 0x20 | (w ? 0x40 : 0);
}
static void ad_reset(u32 lin) {             /* after a fault: whatever the CPU set is accepted */
    u32 p = (lin - L0) >> 12;
    for (u32 k = p; k <= p + 1 && k < NP; k++) { map_ad[sp][k] = 0; *pte(sp, k) &= ~0x60u; }
    wr_cr3(rd_cr3());
}
static void ad_check(void) {
    for (u32 p = 0; p < NP; p++) {
        u32 e = *pte(sp, p), w = ppage(map_pg[sp][p]) | map_fl[sp][p] | map_ad[sp][p];
        if (e != w) { bad("PTE", e, w); *pte(sp, p) = w; wr_cr3(rd_cr3()); }
    }
}
static void e1(u32 v) { code[cp++] = v; }
static void run(u32 ring, u32 eax, u32 ebx, u32 ecx, u32 edx) {
    e1(0xCD); e1(0x85);
    for (u32 i = 0; i < sizeof f / 4; i++) ((u32 *)&f)[i] = 0;
    f.eax = eax; f.ebx = ebx; f.ecx = ecx; f.edx = edx; f.esi = ebx; f.edi = edx;
    f.eip = U_CODE + CODE_OFF; f.eflags = 2; f.ds = f.es = f.fs = f.gs = S_UD;
    f.cs = ring ? S_UC : S_KC; f.ss = S_UD; f.esp = U_STK + 0x1E00;
    go(&f, h_stop);
}
/* the outcome of a fault: expected e (0: none) at where */
static int fault(u32 e, u32 where, u32 lin) {
    if (!e) {
        if (fin.vec != 0x85) { bad("unexpected exception", fin.vec, 0x85); wr_cr3(rd_cr3()); return 1; }
        return 0;
    }
    if (fin.vec != 14) { bad("#PF expected, vector", fin.vec, 14); return 1; }
    if (fin.err != (e & 7) && where) bad("#PF error code", fin.err, e & 7);
    if (where && (rd_cr2() ^ where) >> 12) bad("CR2", rd_cr2(), where);
    ad_reset(lin);
    return 1;
}
static u32 rlin(u32 n) {                    /* a random address; often at a page end */
    u32 x = rnd(), p = x % NP, o = (x >> 8) & 0xFFF;
    if ((x >> 20 & 7) == 0) o = 0xFFC + (x >> 24 & 3);
    if (p == NP - 1 && o + n > 0x1000) o = 0x1000 - n;
    return L0 + p * 0x1000 + o;
}
static void op(void) {
    u32 k = rnd() % 32, ring = rnd() & 3 ? 1 : 0, a = rlin(4), v = rnd(), e, wh, x;
    cp = CODE_OFF;
    switch (k) {
    case 0: case 1: case 2: case 3:
        what = "read";
        e = chk(a, 4, 0, ring, &wh);
        e1(0x8B); e1(0x03); run(ring, 0, a, 0, 0);
        if (fault(e, wh, a)) return;
        x = rdb(a) | rdb(a + 1) << 8 | rdb(a + 2) << 16 | rdb(a + 3) << 24;
        if (fin.eax != x) bad("data", fin.eax, x);
        ad(a, 4, 0);
        return;
    case 4: case 5: case 6:
        what = "write";
        e = chk(a, 4, 1, ring, &wh);
        e1(0x89); e1(0x03); run(ring, v, a, 0, 0);
        if (fault(e, wh, a)) return;
        for (u32 i = 0; i < 4; i++) wrb(a + i, v >> (8 * i));
        ad(a, 4, 1);
        return;
    case 7: case 8:
        what = "xor [m], r; mov r, [m]";
        e = chk(a, 4, 1, ring, &wh);
        e1(0x31); e1(0x03); e1(0x8B); e1(0x03); run(ring, v, a, 0, 0);
        if (fault(e, wh && 0 ? wh : 0, a)) return;
        x = rdb(a) | rdb(a + 1) << 8 | rdb(a + 2) << 16 | rdb(a + 3) << 24;
        x ^= v;
        for (u32 i = 0; i < 4; i++) wrb(a + i, x >> (8 * i));
        if (fin.eax != x) bad("data", fin.eax, x);
        ad(a, 4, 1);
        return;
    case 9: case 10: {
        what = "rep movsb";
        u32 b = rlin(4), n = rnd() & 63, e2, w2;
        if (a + n > L0 + NP * 0x1000) a -= 0x100;
        if (b + n > L0 + NP * 0x1000) b -= 0x100;
        e = n ? chk(a, n, 0, ring, &wh) : 0; e2 = n ? chk(b, n, 1, ring, &w2) : 0;
        e1(0xF3); e1(0xA4); run(ring, 0, a, n, b);
        if (e || e2) {                      /* the part done before the fault */
            if (fin.vec != 14) { bad("#PF expected, vector", fin.vec, 14); return; }
            u32 done = n - fin.ecx;
            if (fin.esi != a + done || fin.edi != b + done) bad("ESI / EDI at the fault", fin.esi, a + done);
            for (u32 i = 0; i < done; i++) wrb(b + i, rdb(a + i));
            ad_reset(a); ad_reset(b);
            return;
        }
        if (fault(0, 0, a)) return;
        for (u32 i = 0; i < n; i++) wrb(b + i, rdb(a + i));
        if (n) { ad(a, n, 0); ad(b, n, 1); }
        return; }
    case 11: case 12: case 13: {            /* code written through one mapping, run through another */
        what = "run code";
        u32 b = rlin(8), pb = (b - L0) >> 12, i, al = ~0u;
        if ((b & 0xFFF) > 0xFF8) b -= 0x10;
        for (i = 0; i < NP; i++) if (map_pg[sp][i] == map_pg[sp][pb] && !chk1(L0 + i * 0x1000, 1, 1)) { al = L0 + i * 0x1000 + (b & 0xFFF); if (rnd() & 1) break; }
        if (al == ~0u || chk1(b, 0, 1)) return;
        e1(0xC6); e1(0x02); e1(0xB8);                          /* mov byte [edx], B8 */
        e1(0x89); e1(0x4A); e1(0x01);                          /* mov [edx+1], ecx */
        e1(0xC6); e1(0x42); e1(0x05); e1(0xC3);                /* mov byte [edx+5], C3 */
        e1(0xFF); e1(0xD3);                                    /* call ebx */
        run(1, 0, b, v, al);
        if (fault(0, 0, b)) return;
        if (fin.eax != v) bad("code", fin.eax, v);
        wrb(b, 0xB8); for (i = 0; i < 4; i++) wrb(b + 1 + i, v >> (8 * i)); wrb(b + 5, 0xC3);
        ad(al, 6, 1); ad(b, 6, 0);
        return; }
    case 14: case 15: {                     /* run code written by the kernel's mapping */
        what = "run code (kernel write)";
        u32 b = rlin(8), pb = (b - L0) >> 12;
        if ((b & 0xFFF) > 0xFF8) b -= 0x10;
        if (chk1(b, 0, 1)) return;
        volatile u8 *q = (u8 *)V(ppage(map_pg[sp][pb]) + (b & 0xFFF));
        q[0] = 0xB8; *(volatile u32 *)(q + 1) = v; q[5] = 0xC3;
        wrb(b, 0xB8); for (u32 i = 0; i < 4; i++) wrb(b + 1 + i, v >> (8 * i)); wrb(b + 5, 0xC3);
        e1(0xFF); e1(0xD3);
        run(1, 0, b, 0, 0);
        if (fault(0, 0, b)) return;
        if (fin.eax != v) bad("code", fin.eax, v);
        ad(b, 6, 0);
        return; }
    case 16: case 17: case 18:
        what = "switch";
        ad_check();
        sp = rnd() % NS;
        wr_cr3(P_PDS + sp * 0x1000);
        return;
    case 19: case 20: case 21: case 22: case 23: {              /* remap, protect */
        u32 p = rnd() % NP, s = rnd() & 3 ? sp : rnd() % NS;
        map_pg[s][p] = rnd() % npp;
        map_fl[s][p] = (rnd() % 6 ? 1 : 0) | (rnd() % 4 ? 2 : 0) | (rnd() % 5 ? 4 : 0);
        map_ad[s][p] = rnd() & 0x60;
        put(s, p);
        return; }
    case 24: {                              /* copy on write: a ring 3 write faults, copied, restarted */
        what = "copy on write";
        u32 p = (a - L0) >> 12;
        if ((a & 0xFFF) > 0xFFC || !pde_p[sp]) return;
        map_fl[sp][p] = 5; map_ad[sp][p] = 0x20; put(sp, p);
        e1(0x01); e1(0x03); run(1, v, a, 0, 0);
        if (fin.vec != 14 || fin.err != 7) { bad("#PF error code", fin.vec << 8 | fin.err, 0xE07); return; }
        u32 np = rnd() % npp, o = map_pg[sp][p];
        if (np != o) { copyd(V(ppage(np)), V(ppage(o)), 1024); copyd(V(shadow(np)), V(shadow(o)), 1024); }
        map_pg[sp][p] = np; map_fl[sp][p] = 7; put(sp, p);
        f = fin; go(&f, h_stop);
        if (fault(0, 0, a)) return;
        x = rdb(a) | rdb(a + 1) << 8 | rdb(a + 2) << 16 | rdb(a + 3) << 24;
        x += v;
        for (u32 i = 0; i < 4; i++) wrb(a + i, x >> (8 * i));
        ad(a, 4, 1);
        return; }
    case 25:
        pde_p[sp] ^= 1;
        if (rnd() & 3) pde_p[sp] = 1;
        PTE(P_PDS + sp * 0x1000, L0 >> 22) = (P_PTS + sp * 0x1000) | 6 | pde_p[sp] | 0x20;
        wr_cr3(rd_cr3());
        return;
    case 26:
        wp ^= 1;
        wr_cr0((rd_cr0() & ~0x10000u) | wp << 16);
        wr_cr3(rd_cr3());
        return;
    case 27: if (!(rnd() & 7)) wbinvd(); return;
    case 28: what = "check"; ad_check(); return;
    case 29: case 30: {                     /* a chain in one program: store, load through another mapping */
        what = "alias store / load";
        u32 p = (a - L0) >> 12, al = ~0u;
        if ((a & 0xFFF) > 0xFFC) return;
        for (u32 i = 0; i < NP; i++) if (i != p && map_pg[sp][i] == map_pg[sp][p] && !chk1(L0 + i * 0x1000, 0, 1)) al = L0 + i * 0x1000 + (a & 0xFFF);
        if (al == ~0u || chk1(a, 1, 1)) return;
        e1(0x89); e1(0x03);                 /* mov [ebx], eax */
        e1(0x8B); e1(0x0A);                 /* mov ecx, [edx] */
        e1(0xC6); e1(0x43); e1(1); e1(0x5A);                   /* mov byte [ebx+1], 5A */
        e1(0x03); e1(0x0A);                 /* add ecx, [edx] */
        run(1, v, a & ~3u, 0, al & ~3u);
        if (fault(0, 0, a)) return;
        x = v + ((v & 0xFFFF00FF) | 0x5A00);
        if (fin.ecx != x) bad("data", fin.ecx, x);
        a &= ~3u;
        for (u32 i = 0; i < 4; i++) wrb(a + i, v >> (8 * i));
        wrb(a + 1, 0x5A);
        ad(a, 4, 1); ad(al, 4, 0);
        return; }
    default: return;
    }
}
void s_vm(u32 round) {
    (void)round;
    npp = cfg.tb && !(cfg.off & 0x4000) ? 12 : 40;
    u32 c0 = rd_cr0();
    for (u32 s = 0; s < NS; s++) {
        filld(V(P_PDS + s * 0x1000), 0, 1024);
        filld(V(P_PTS + s * 0x1000), 0, 1024);
        PTE(P_PDS + s * 0x1000, 768) = P_PT0 | 0x23;
        PTE(P_PDS + s * 0x1000, U_BASE >> 22) = P_SPT | 0x27;
        PTE(P_PDS + s * 0x1000, L0 >> 22) = (P_PTS + s * 0x1000) | 0x27;
        pde_p[s] = 1;
        for (u32 p = 0; p < NP; p++) {
            map_pg[s][p] = rnd() % npp; map_fl[s][p] = 7; map_ad[s][p] = 0;
            *pte(s, p) = ppage(map_pg[s][p]) | 7;
        }
    }
    filld(V(P_SPT), 0, 1024);
    for (u32 i = 0; i < 8; i++) PTE(P_SPT, 0x50 + i) = (P_CODE + i * 0x1000) | 0x67;
    for (u32 i = 0; i < 2; i++) PTE(P_SPT, 0x60 + i) = (P_STK + i * 0x1000) | 0x67;
    for (u32 i = 0; i < npp; i++)
        for (u32 j = 0; j < 4096; j += 4) *(volatile u32 *)V(ppage(i) + j) = *(volatile u32 *)V(shadow(i) + j) = (i << 24) + j * 0x10003;
    code = (u8 *)V(P_CODE);
    sp = 0; wp = 0;
    wr_cr0(c0 & ~0x1000Eu);
    wr_cr3(P_PDS);
    u32 n = cfg.progs ? cfg.progs * 100 : cfg.tb ? 400 : 100000;
    for (opn = 0; opn < n; opn++) {
        if (!(opn & 63) && rnd() & 1) {     /* (else most pages end up unusable) */
            u32 s = rnd() % NS, p = rnd() % NP;
            for (u32 i = 0; i < 8; i++) { p = (p + 1) % NP; map_fl[s][p] = 7; map_ad[s][p] = 0; put(s, p); }
            pde_p[s] = 1; PTE(P_PDS + s * 0x1000, L0 >> 22) = (P_PTS + s * 0x1000) | 0x27;
        }
        op();
        if (suite_fail[cur_suite] > 200) break;
    }
    wr_cr0(c0);
    wr_cr3(P_PDK);
    what = "end";
    for (u32 i = 0; i < npp; i++) {
        u32 j = cmpd(V(ppage(i)), V(shadow(i)), 1024);
        if (j != 1024) bad("memory", ((u32 *)V(ppage(i)))[j], ((u32 *)V(shadow(i)))[j]);
    }
}
