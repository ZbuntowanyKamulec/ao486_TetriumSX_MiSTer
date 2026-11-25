// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* Suites for the machine around the CPU (none of them in the lockstep testbench, but unreal):
 * irq     when exactly a pending interrupt is taken (STI, POPF, IRET, MOV / POP SS, HLT, REP ...)
 * soc     RAM through the L2, cache control, the A20 gate, the order of VGA memory and I/O accesses,
 *         IDE transfers that page-fault in the middle (INS / OUTS)
 * unreal  real mode with 4 GB segment limits */
#include "kern.h"

static struct frame f;
static u8 *code;
static u32 cp;
static const char *what;
static void bad(const char *s, u32 a, u32 b) {
    if (fail_begin(s)) pf("%s: %x expected %x (vec %x err %x eip %x)\n", what, a, b, fin.vec, fin.err, fin.eip);
}
static void e1(u32 v) { code[cp++] = v; }
static void e4(u32 v) { e1(v); e1(v >> 8); e1(v >> 16); e1(v >> 24); }
#define CODE_OFF 0x100u
#define USTK (U_STK + 0x1E00u)
#define L_IO 0x20000000u                    /* IDE buffers */
#define P_PTI 0x76000u
static void base_setup(void) {
    filld(V(P_PDU), 0, 1024);
    filld(V(P_SPT), 0, 1024);
    filld(V(P_PTI), 0, 1024);
    PTE(P_PDU, 768) = P_PT0 | 0x23;
    PTE(P_PDU, U_BASE >> 22) = P_SPT | 0x27;
    PTE(P_PDU, L_IO >> 22) = P_PTI | 0x27;
    for (u32 i = 0; i < 8; i++) PTE(P_SPT, 0x50 + i) = (P_CODE + i * 0x1000) | 0x67;
    for (u32 i = 0; i < 2; i++) PTE(P_SPT, 0x60 + i) = (P_STK + i * 0x1000) | 0x67;
    for (u32 i = 0; i < 4; i++) PTE(P_PTI, i) = (P_WIN + i * 0x1000) | 0x67;
    code = (u8 *)V(P_CODE);
}

/* ---------------------------------------------------------------- irq */
static volatile u32 irq_eip, irq_cnt, irq_ecx, irq_esi, irq_edi;
static void ih(struct frame *x) { irq_cnt++; irq_eip = x->eip - U_CODE - CODE_OFF; irq_ecx = x->ecx; irq_esi = x->esi; irq_edi = x->edi; }
static int h_irq(struct frame *x) { return x->vec != 0x84; }
static int pend(void) {                     /* IRQ0 pending in the PIC (interrupts off) */
    outb(0x21, 0xFE); outb(0xA1, 0xFF);
    outb(0x43, 0x30); outb(0x40, 60); outb(0x40, 0);
    for (u32 i = 0; i < 1000000; i++) { outb(0x20, 0x0A); if (inb(0x20) & 1) return 1; }
    return 0;
}
static void irq_case(const char *n, u32 ring, s32 expect) {
    what = n;
    e1(0xCD); e1(0x85);
    for (u32 i = cp; i < CODE_OFF + 64; i++) code[i] = 0x90;
    for (u32 i = 0; i < sizeof f / 4; i++) ((u32 *)&f)[i] = 0;
    f.eax = ring ? S_UD : S_KD; f.ebp = USTK - 0x40; f.ecx = 300; f.esi = L_IO + 0x100; f.edi = L_IO + 0x1100; f.ebx = U_CODE + 0x400;
    f.eip = U_CODE + CODE_OFF; f.eflags = 2 | 0x3000; f.ds = f.es = f.fs = f.gs = S_UD;
    f.cs = ring ? S_UC : S_KC; f.ss = S_UD; f.esp = USTK;
    *(u32 *)(code + 0x400) = USTK - 0x80; *(u32 *)(code + 0x404) = f.eax;
    wr_cr3(P_PDU);
    if (!pend()) { bad("IRQ0 did not become pending", 0, 1); return; }
    irq_cnt = 0; irq_eip = ~0u;
    irq_hook = ih;
    go(&f, h_irq);
    irq_hook = 0;
    if (!irq_cnt) __asm__ volatile("sti; nop; nop; nop; cli");
    irqs_off();
    if (fin.vec != 0x85) { bad("vector", fin.vec, 0x85); return; }
    if (expect >= 100) { if (irq_eip == (u32)expect / 100) return; expect %= 100; }           /* either of two */
    if (expect < 0) { if (irq_eip != ~0u) bad("interrupt taken at offset", irq_eip, 99); return; }
    if (irq_eip == ~0u) bad("interrupt not taken, offset", 99, expect);
    else if (irq_eip != (u32)expect) bad("interrupt taken at offset", irq_eip, expect);
}
#define BEGIN cp = CODE_OFF
static void e(u32 n, ...) { __builtin_va_list a; __builtin_va_start(a, n); while (n--) e1(__builtin_va_arg(a, u32)); __builtin_va_end(a); }
void s_irq(u32 round) {
    (void)round;
    if (cfg.tb) return;
    base_setup();
    for (u32 n = 0; n < 20; n++)
        for (u32 ring = 0; ring < 2; ring++) {
            BEGIN; e(4, 0xFB, 0x40, 0x41, 0x42); irq_case("sti; inc; inc", ring, 2);
            BEGIN; e(4, 0xFB, 0xFA, 0x40, 0x41); irq_case("sti; cli", ring, -1);
            BEGIN; e(4, 0xFB, 0xFB, 0x40, 0x41); irq_case("sti; sti; inc", ring, 302);
            BEGIN; e(8, 0x68, 2, 0x32, 0, 0, 0x9D, 0x40, 0x41); irq_case("popf", ring, 6);
            BEGIN; e1(0x68); e4(0x3202); e1(0x0E); e1(0x68); e4(U_CODE + cp + 4 + 1); e1(0xCF); e(2, 0x40, 0x41); irq_case("iret", ring, 12);
            BEGIN; e(7, 0xFB, 0x8E, 0xD0, 0x89, 0xEC, 0x40, 0x41); irq_case("sti; mov ss; mov esp", ring, 5);
            BEGIN; e(6, 0x50, 0xFB, 0x17, 0x40, 0x41, 0x42); irq_case("sti; pop ss; inc", ring, 4);
            BEGIN; e(6, 0xFB, 0x0F, 0xB2, 0x23, 0x40, 0x41); if (ring) irq_case("sti; lss", ring, 4);
            BEGIN; e(5, 0xFB, 0xCD, 0x84, 0x40, 0x41); irq_case("sti; int", ring, 3);
            BEGIN; e(3, 0xFB, 0xF4, 0x40); if (!ring) irq_case("sti; hlt", ring, 2);
            BEGIN; e(5, 0xFB, 0x0F, 0xA2, 0x40, 0x41); irq_case("sti; cpuid", ring, 3);
            for (u32 i = 0; i < 300; i++) { *(volatile u8 *)V(P_WIN + 0x100 + i) = rnd(); *(volatile u8 *)V(P_WIN + 0x1100 + i) = 0; }
            BEGIN; e(4, 0xFB, 0xF3, 0xA4, 0x40); 
            irq_case("sti; rep movsb", ring, 301);
            if (irq_cnt) {
                u32 done = 300 - irq_ecx;
                if (irq_esi != L_IO + 0x100 + done || irq_edi != L_IO + 0x1100 + done) bad("rep movsb: ESI / EDI", irq_esi, L_IO + 0x100 + done);
                if (!done) bad("rep movsb: no iteration after STI", 0, 1);
            }
            for (u32 i = 0; i < 300; i++)
                if (*(volatile u8 *)V(P_WIN + 0x100 + i) != *(volatile u8 *)V(P_WIN + 0x1100 + i)) { bad("rep movsb: data", i, 0); break; }
            BEGIN; e(5, 0xFB, 0xF2, 0xAE, 0x40, 0x41); code[0x3FF] = 0;
            irq_case("sti; repne scasb", ring, 301);
        }
    wr_cr3(P_PDK);
}

/* ---------------------------------------------------------------- RAM */
#define L_RAM 0x40000000u
static void ram_map(u32 base, u32 fl) {     /* 4 MB of physical memory at L_RAM */
    for (u32 i = 0; i < 1024; i++) PTE(P_PTI, i) = (base + i * 0x1000) | 0x63 | fl;
    PTE(P_PDK, L_RAM >> 22) = P_PTI | 0x23;
    wr_cr3(P_PDK);
}
static void ram(void) {
    u32 top = (memkb + 1024) & ~4095u;      /* KB, whole 4 MB chunks */
    if (top < 8192) return;
    what = "ram";
    u32 chunks = top / 4096;
    /* address lines: a signature in every chunk */
    for (u32 c = 1; c < chunks; c++) { ram_map(c << 22, 0); *(volatile u32 *)(L_RAM + 0x1230) = c * 0x01010101u ^ 0x5AA5; }
    for (u32 c = 1; c < chunks; c++) {
        ram_map(c << 22, 0);
        u32 v = *(volatile u32 *)(L_RAM + 0x1230), w = c * 0x01010101u ^ 0x5AA5;
        if (v != w) bad("chunk signature", v, w);
    }
    for (u32 n = 0; n < 2; n++) {
        u32 c = 1 + rnd() % (chunks - 1), k = rnd();
        ram_map(c << 22, 0);
        for (u32 i = 0; i < 0x400000; i += 4) *(volatile u32 *)(L_RAM + i) = (i * 0x9E3779B1u) ^ k;
        for (u32 i = 0; i < 0x400000; i += 4) {
            u32 v = *(volatile u32 *)(L_RAM + i), w = (i * 0x9E3779B1u) ^ k;
            if (v != w) { bad("fill", v, w); pf("  at %x chunk %d key %x\n", i, c, k); break; }
        }
        /* random accesses to a window spread over conflicting lines, against a shadow; partly uncached */
        static const u32 str[6] = { 0x1000, 0x2000, 0x4000, 0x8000, 0x10000, 0x40000 };
        u32 st = str[rnd() % 6], sh = V(0x200000);
        ram_map(c << 22, 0);
        for (u32 pg = 0; pg < 16; pg++) if (rnd() % 5 == 0) PTE(P_PTI, pg * st >> 12) |= 0x10;       /* PCD */
        wr_cr3(P_PDK);
        for (u32 pg = 0; pg < 16; pg++) copyd(sh + pg * 0x1000, L_RAM + pg * st, 1024);
        for (u32 q = 0; q < 60000; q++) {
            u32 x = rnd(), o = (x >> 4) & 0xFFFC, a, b = sh + o, v = rnd();
            o += x >> 2 & 3; b = sh + o;
            if ((o & 0xFFF) > 0xFFC) continue;
            a = L_RAM + (o >> 12) * st + (o & 0xFFF);
            switch (x >> 22 & 7) {
            case 0: *(volatile u8 *)a = v; *(volatile u8 *)b = v; break;
            case 1: *(volatile u16 *)a = v; *(volatile u16 *)b = v; break;
            case 2: *(volatile u32 *)a = v; *(volatile u32 *)b = v; break;
            case 3: *(volatile u32 *)a += v; *(volatile u32 *)b += v; break;
            case 4: if (*(volatile u8 *)a != *(volatile u8 *)b) { bad("byte", *(volatile u8 *)a, *(volatile u8 *)b); goto out; } break;
            case 5: if (*(volatile u16 *)a != *(volatile u16 *)b) { bad("word", *(volatile u16 *)a, *(volatile u16 *)b); goto out; } break;
            default: if (*(volatile u32 *)a != *(volatile u32 *)b) { bad("dword", *(volatile u32 *)a, *(volatile u32 *)b); goto out; } break;
            }
            if ((x >> 25) == 5) wbinvd();
        }
        for (u32 pg = 0; pg < 16; pg++) if (cmpd(sh + pg * 0x1000, L_RAM + pg * st, 1024) != 1024) bad("window page", pg, 0);
    out:;
    }
    PTE(P_PDK, L_RAM >> 22) = 0;
    wr_cr3(P_PDK);
}

/* ---------------------------------------------------------------- cache control, A20 */
static void cachectl(void) {
    what = "cache control";
    volatile u32 *w = (u32 *)V(P_WIN), *s = (u32 *)V(P_REF);
    for (u32 i = 0; i < 4096; i++) w[i] = s[i] = rnd();
    u32 c0 = rd_cr0() & ~0x60000000u;
    for (u32 n = 0; n < 12; n++) {
        u32 cd = rnd() & 1 ? 0x40000000u : 0;
        wr_cr0(c0 | cd);
        if (rnd() & 1) wbinvd();
        for (u32 q = 0; q < 3000; q++) {
            u32 x = rnd(), i = x >> 4 & 4095, v = rnd();
            if (x & 1) { w[i] = v; s[i] = v; }
            else if (x & 2) { ((volatile u8 *)w)[i] = v; ((volatile u8 *)s)[i] = v; }
            else if (w[i] != s[i]) { bad("data", w[i], s[i]); wr_cr0(c0); return; }
        }
        if (!(rnd() & 3)) __asm__ volatile("invd" ::: "memory");       /* (write-through caches: nothing is lost) */
    }
    wr_cr0(c0);
    wbinvd();
    for (u32 i = 0; i < 4096; i++) if (w[i] != s[i]) { bad("data at the end", w[i], s[i]); return; }
}
static void a20_set(u32 on) {
    u8 v = inb(0x92);
    outb(0x92, (v & ~3) | (on ? 2 : 0));
    (void)inb(0x92);
    __asm__ volatile("ljmp $0x08, $1f; 1:" ::: "memory");
}
static void a20(void) {
    what = "a20 gate";
    if (memkb < 2048) return;
    /* 130000-133FFF and 030000-033FFF (kernel view: the first 4 MB at C0000000) */
    volatile u32 *lo = (u32 *)V(P_WIN), *hi = (u32 *)V(P_WIN + 0x100000);
    a20_set(0);
    u32 pt = inb(0x92);
    a20_set(1);
    if (pt & 2) return;                     /* (not the gate of this machine) */
    for (u32 n = 0; n < 4; n++) {
        for (u32 i = 0; i < 1024; i++) { lo[i] = rnd() & ~1u; hi[i] = rnd() | 1; }
        u32 k = rnd() & 1023, l = lo[k], h = hi[k], z = rnd();
        a20_set(0);
        u32 a = hi[k];
        hi[(k + 1) & 1023] = z;
        u32 b = lo[(k + 1) & 1023];
        a20_set(1);
        u32 c = hi[k], d = lo[(k + 1) & 1023];
        /* off and on with no other memory access between: no translation kept over the change */
        u32 r1, r2, r3;
        __asm__ volatile("mov (%3), %0; in $0x92, %%al; and $0xFD, %%al; out %%al, $0x92; in $0x92, %%al; jmp 1f; 1: mov (%3), %1\n"
                         "or $2, %%al; out %%al, $0x92; in $0x92, %%al; jmp 1f; 1: mov (%3), %2\n"
                         : "=&r"(r1), "=&r"(r2), "=&r"(r3) : "r"(&hi[k]) : "eax", "memory");
        u32 l2 = lo[k], h2 = hi[k];
        if (r1 != h2) bad("A20 on: read of 1xxxxx", r1, h2);
        if (r2 != l2) bad("A20 just off: read of 1xxxxx", r2, l2);
        if (r3 != h2) bad("A20 just on: read of 1xxxxx", r3, h2);
        if (a != l) bad("A20 off: read of 1xxxxx", a, l);
        if (b != z) bad("A20 off: write of 1xxxxx", b, z);
        if (c != h) bad("A20 on again: read of 1xxxxx", c, h);
        if (d != z) bad("A20 on again: read of 0xxxxx", d, z);
    }
}

/* ---------------------------------------------------------------- VGA memory against I/O */
/* Not a test of the VGA: only its map mask, read map select and latched copy are used, to see that
   the CPU and the L2's byte path make the right accesses, each once, in order with the OUTs */
#define VA   V(0xAC000u)
#define VN   1024u
static u8 vm_[4][VN], lat[4];
static u8 sr2, g5, g4;
static void sr(u32 i, u32 v) { outw(0x3C4, i | v << 8); }
static void gr(u32 i, u32 v) { outw(0x3CE, i | v << 8); }
static void vw(u32 o, u32 v) {              /* model of one byte write (write mode 0 or 1) */
    for (u32 p = 0; p < 4; p++) if (sr2 >> p & 1) vm_[p][o] = g5 ? lat[p] : v;
}
static u32 vr(u32 o) { for (u32 p = 0; p < 4; p++) lat[p] = vm_[p][o]; return lat[g4 & 3]; }
#define VBAD(s, a, b) { err = s; ea = a; eb = b; goto end; }
static void vga(void) {
    const char *err = 0;                    /* reported at the end: the text screen is off here */
    u32 ea = 0, eb = 0, q, x = 0, o = 0, d = 0, n, r, again = 0;
    what = "vga / io order";
    sr(0, 1); sr(4, 6); sr(0, 3);           /* planes addressed one by one */
    gr(6, 4);                               /* A0000, 64 KB */
    gr(0, 0); gr(1, 0); gr(3, 0); gr(8, 0xFF);
    sr2 = 15; sr(2, 15); g5 = 0; gr(5, 0); g4 = 0; gr(4, 0);
    volatile u8 *v = (u8 *)VA;
    for (u32 o = 0; o < VN; o++) { v[o] = o * 7; vw(o, o * 7 & 0xFF); }
    (void)v[0]; vr(0);                      /* the latches: known from here on */
    for (q = 0; q < 1500; q++) {
        x = rnd(); o = (x >> 4) % (VN - 80); d = rnd(); r = rnd();
        if ((r & 3) == 0) { sr2 = r >> 4 & 15; sr(2, sr2); }
        if ((r & 0xC) == 0) { g4 = r >> 8 & 3; gr(4, g4); }
        if (g5 || (r & 0xF000) == 0) { g5 = r >> 16 & 1; gr(5, g5); }
        switch (x & 15) {
        case 0: case 1: v[o] = d; vw(o, d & 0xFF); break;
        case 2: *(volatile u16 *)(v + o) = d; vw(o, d & 0xFF); vw(o + 1, d >> 8 & 0xFF); break;
        case 3: case 4: *(volatile u32 *)(v + o) = d; for (u32 i = 0; i < 4; i++) vw(o + i, d >> 8 * i & 0xFF); break;
        case 5: case 6: n = v[o]; if (n != vr(o)) { VBAD("read", n, lat[g4]) } break;
        case 7: n = *(volatile u16 *)(v + o); { u32 w = vr(o); w |= vr(o + 1) << 8; if (n != w) { VBAD("read 16", n, w) } } break;
        case 8: n = *(volatile u32 *)(v + o); { u32 w = 0; for (u32 i = 0; i < 4; i++) w |= vr(o + i) << 8 * i; if (n != w) { VBAD("read 32", n, w) } } break;
        case 9: n = 1 + (d & 63); { u32 di = (u32)(v + o), c = n; __asm__ volatile("cld; rep stosb" : "+D"(di), "+c"(c) : "a"(d) : "memory"); } for (u32 i = 0; i < n; i++) vw(o + i, d & 0xFF); break;
        case 10: n = 1 + (d & 15); { u32 di = (u32)(v + o), c = n; __asm__ volatile("cld; rep stosl" : "+D"(di), "+c"(c) : "a"(d) : "memory"); for (u32 i = 0; i < 4 * n; i++) vw(o + i, d >> 8 * (i & 3) & 0xFF); } break;
        case 11: case 12: {                 /* latched copy: each byte read, then written */
            u32 t = rnd() % (VN - 80), si = (u32)(v + o), di = (u32)(v + t), c = n = 1 + (d & 31);
            g5 = 1; gr(5, 1); sr2 = 15; sr(2, 15);
            __asm__ volatile("cld; rep movsb" : "+S"(si), "+D"(di), "+c"(c) :: "memory");
            for (u32 i = 0; i < n; i++) vw(t + i, vr(o + i));
            break; }
        case 13: v[o] |= 1; { u32 w = vr(o) | 1; vw(o, w); } break;                          /* read-modify-write */
        case 14: { u8 b = d; __asm__ volatile("xchgb %0, %1" : "+q"(b), "+m"(v[o])); u32 w = vr(o); vw(o, d & 0xFF); if (b != w) { VBAD("xchg", b, w) } break; }
        case 15:                            /* plane by plane, the map mask changed between the writes */
            g5 = 0; gr(5, 0);
            for (u32 p = 0; p < 4; p++) { sr(2, 1 << p); v[o] = d >> 8 * p; sr2 = 1 << p; vw(o, d >> 8 * p & 0xFF); }
            sr2 = 15; sr(2, 15);
            break;
        }
    }
    gr(5, 0); g5 = 0;
    for (u32 p = 0; p < 4; p++) {
        gr(4, p);
        for (o = 0; o < VN; o++) if (v[o] != vm_[p][o]) { VBAD("plane contents", v[o] | p << 12 | o << 16, vm_[p][o]) }
    }
end:
    if (err) for (n = 0; n < 4; n++) { gr(4, n); again |= (u32)v[o] << 8 * n; }     /* the byte once more: all planes */
    sr(0, 1); sr(4, 2); sr(0, 3); sr(2, 3);
    gr(0, 0); gr(1, 0); gr(3, 0); gr(4, 0); gr(5, 0x10); gr(6, 0x0E); gr(8, 0xFF);
    if (err && fail_begin("vga"))
        pf("%s %x expected %x (op %d:%d at %x data %x g4 %d g5 %d sr2 %x; again %x)\n", err, ea, eb, q, x & 15, o, d, g4, g5, sr2, again);
}

/* ---------------------------------------------------------------- IDE transfers that page-fault */
static int ide_wait(u8 mask, u8 want) {
    for (u32 i = 0; i < 20000000; i++) { u8 s = inb(0x1F7); if (!(s & 0x80) && (s & mask) == want) return 1; if (s & 1) return 0; }
    return 0;
}
static int ide_cmd(u32 lba, u8 cmd) {
    if (!ide_wait(0x40, 0x40)) { bad("drive not ready", inb(0x1F7), 0x40); return 0; }
    outb(0x1F6, 0xE0); outb(0x1F2, 1); outb(0x1F3, lba); outb(0x1F4, lba >> 8); outb(0x1F5, lba >> 16);
    outb(0x1F7, cmd);
    if (!ide_wait(8, 8)) { bad("no DRQ", inb(0x1F7), 8); return 0; }
    return 1;
}
static int ide_rd(u32 lba, u32 dst) {
    if (!ide_cmd(lba, 0x20)) return 0;
    for (u32 i = 0; i < 256; i++) ((volatile u16 *)dst)[i] = inw(0x1F0);
    return 1;
}
static u32 io_pf;
static int h_io(struct frame *x) {
    if (x->vec != 14) return 1;
    u32 a = rd_cr2();
    if (a - L_IO >= 0x4000 || x->err & 1) return 1;
    PTE(P_PTI, (a - L_IO) >> 12) |= 1;
    invlpg(a);
    io_pf++;
    return 0;
}
#define SCR 8192u                           /* scratch sectors of the hwcheck disk (signature in the first) */
static void ide(void) {
    what = "ide";
    base_setup();
    u32 ref = V(P_REF), has = 0;
    if (!ide_rd(SCR, ref)) return;
    has = ((u32 *)ref)[0] == 0x4B435748 && ((u32 *)ref)[1] == 0x21524353;       /* "HWCKSCR!" */
    for (u32 n = 0; n < 40; n++) {
        u32 wr = has && rnd() & 1, w32 = rnd() & 1, lba = wr ? SCR + 1 + rnd() % 64 : 1 + rnd() % 100, off = 0x1000 - 2 * (rnd() & 0xFF), m;
        if (rnd() & 3) off &= ~3u;
        off += 0x1000 * (rnd() & 1);
        what = wr ? (w32 ? "ide rep outsd" : "ide rep outsw") : w32 ? "ide rep insd" : "ide rep insw";
        cp = CODE_OFF;
        e1(0xF3); if (!w32) e1(0x66); e1(wr ? 0x6F : 0x6D); e1(0xCD); e1(0x85);
        for (u32 i = 0; i < sizeof f / 4; i++) ((u32 *)&f)[i] = 0;
        f.ecx = w32 ? 128 : 256; f.edx = 0x1F0; f.esi = f.edi = L_IO + off;
        f.eip = U_CODE + CODE_OFF; f.eflags = 2 | 0x3000; f.ds = f.es = f.fs = f.gs = S_UD; f.cs = S_UC; f.ss = S_UD; f.esp = USTK;
        for (u32 i = 0; i < 4; i++) PTE(P_PTI, i) = (P_WIN + i * 0x1000) | 0x67;
        if (wr) for (u32 i = 0; i < 256; i++) ((volatile u16 *)V(P_WIN + off))[i] = rnd();
        else { if (!ide_rd(lba, ref)) return; filld(V(P_WIN), 0xEEEEEEEE, 4096); }
        if (!ide_cmd(lba, wr ? 0x30 : 0x20)) return;
        for (u32 i = 0; i < 4; i++) if (rnd() & 3) PTE(P_PTI, i) &= ~1u;
        wr_cr3(P_PDU);
        io_pf = 0;
        go(&f, h_io);
        wr_cr3(P_PDK);
        if (fin.vec != 0x85) { bad("vector", fin.vec, 0x85); return; }
        if (fin.ecx) bad("ECX", fin.ecx, 0);
        m = inb(0x1F7);
        if (!wr && m & 8) bad("DRQ left: a word was lost or not read", m, 0x50);
        if (wr) {
            if (!ide_wait(0x40, 0x40)) { bad("after the write: status", inb(0x1F7), 0x50); return; }
            if (inb(0x1F7) & 8) { bad("DRQ left after the write", inb(0x1F7), 0x50); return; }
            if (!ide_rd(lba, ref)) return;
        }
        u32 i = cmpd(V(P_WIN + off), ref, 128);
        if (i != 128) bad("sector data (dword)", ((u32 *)V(P_WIN + off))[i], ((u32 *)ref)[i]);
    }
    /* code read from the disk into a page that has just run */
    if (!has) return;
    what = "ide: code read over code";
    for (u32 n = 0; n < 8; n++) {
        u32 imm = rnd(), lba = SCR + 80;
        volatile u8 *b = (u8 *)V(P_WIN + 0x2000);
        filld(V(P_WIN + 0x2000), 0x90909090, 128);
        b[0] = 0xB8; *(volatile u32 *)(b + 1) = imm; b[5] = 0xC3;
        if (!ide_cmd(lba, 0x30)) return;
        for (u32 i = 0; i < 256; i++) outw(0x1F0, ((volatile u16 *)b)[i]);
        if (!ide_wait(0x48, 0x40)) return;
        *(volatile u32 *)(b + 1) = 0;
        u32 r1, r2;
        __asm__ volatile("call *%1" : "=a"(r1) : "r"(b) : "memory", "cc");
        if (!ide_cmd(lba, 0x20)) return;
        u32 di = (u32)b, c = 128;
        __asm__ volatile("cld; rep insl" : "+D"(di), "+c"(c) : "d"(0x1F0) : "memory");
        __asm__ volatile("call *%1" : "=a"(r2) : "r"(b) : "memory", "cc");
        if (r1 != 0 || r2 != imm) bad("result", r2, imm);
    }
}
void s_soc(u32 round) {
    (void)round;
    if (cfg.tb) { if (cfg.off & 0x8000) { memkb = 15360; ram(); } return; }
    if (!(cfg.off & 0x100)) ram();
    if (!(cfg.off & 0x200)) cachectl();
    if (!(cfg.off & 0x400)) a20();
    if (!(cfg.off & 0x800)) vga();
    if (!(cfg.off & 0x1000)) ide();
}

/* the text log (P_LOG) to the scratch sectors from SCR + 128 on (logread.py) */
void log_save(u32 n) {
    static u32 buf[128];
    if (cfg.tb || cfg.off & 0x2000) return;
    if (!ide_rd(SCR, (u32)buf) || buf[0] != 0x4B435748 || buf[1] != 0x21524353) return;
    if (n > 0xC000) n = 0xC000;
    for (u32 k = 0; k <= n / 512 && k < 96; k++) {
        if (!ide_cmd(SCR + 128 + k, 0x30)) return;
        for (u32 i = 0; i < 256; i++) outw(0x1F0, ((volatile u16 *)V(P_LOG))[k * 256 + i]);
        if (!ide_wait(0x48, 0x40)) return;
    }
}

/* ---------------------------------------------------------------- unreal mode */
#define UB ((volatile u32 *)V(0x700))       /* results of entry.s unreal_run */
void unreal_run(void);
void s_unreal(u32 round) {
    (void)round;
    u32 n = cfg.tb ? 1 : 30, big = 0x210000;
    what = "unreal";
    while (n--) {
        u32 k = rnd();
        for (u32 i = 0; i < 64; i++) UB[i] = 0;
        for (u32 i = 0; i < 1024; i++) ((volatile u32 *)V(big))[i] = i ^ k;
        for (u32 i = 0; i < 1024; i++) ((volatile u32 *)V(big + 0x10000 - 0x800))[i] = i * 3 ^ k;
        UB[0] = k;
        unreal_run();
        fin.vec = 0;
        if (UB[1] != 0x600D) bad("status", UB[1], 0x600D);
        if (UB[2] != (5 ^ k)) bad("read FS:[210014]", UB[2], 5 ^ k);
        if (*(u32 *)V(big + 0x40) != k + 1) bad("write ES:[210040]", *(u32 *)V(big + 0x40), k + 1);
        if (UB[3] != (9 ^ k)) bad("DS keeps its limit over a real-mode load", UB[3], 9 ^ k);
        if (UB[4] != (7 ^ k)) bad("limit after INT / IRET", UB[4], 7 ^ k);
        if (UB[5] != 13) bad("GS beyond 64 KB: vector", UB[5], 13);
        if (UB[7] != 0x10000 + 0x100) bad("ESI after a32 rep movsd", UB[7], 0x10000 + 0x100);
        for (u32 i = 0; i < 0x400; i++) {   /* a32 REP MOVSD over a 64 KB boundary: 21F800 -> 250000 */
            u32 v = ((u32 *)V(0x250000))[i], w = i * 3 ^ k;
            if (v != w) { bad("a32 rep movsd", v, w); break; }
        }
    }
}
