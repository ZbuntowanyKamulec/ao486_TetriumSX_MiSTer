// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* hwcheck kernel core: console, tables, traps, main loop (see README.md) */
#include "kern.h"

u32 gdt[128] __attribute__((aligned(16))), ldt[16] __attribute__((aligned(16))), idt[512] __attribute__((aligned(16)));
u32 tss1[26 + 2049] __attribute__((aligned(16))), tss2[26] __attribute__((aligned(16)));
u32 rs = 1;
int (*hook)(struct frame *f);
void (*irq_hook)(struct frame *f);
struct frame fin;
volatile u32 irq_n, ticks;
u32 suite_fail[16], suite_runs[16], cur_suite, total_fail, round_no;

u32 rnd(void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }
u32 mix(u32 a, u32 b) { u32 x = a * 0x9E3779B1u ^ (b + 0x7F4A7C15u); x ^= x >> 15; x *= 0x2C1B3C6Du; x ^= x >> 12; return x ? x : 1; }

/* ---------------------------------------------------------------- console */
#define VGA ((volatile u16 *)V(0xB8000))
static int row, col, lines, scr = 1;       /* scr: to the screen too */
static u8 attr = 7;
static u32 logp;
static void clr(int r0, int r1) { if (!cfg.tb) for (int i = r0 * 80; i < (r1 + 1) * 80; i++) VGA[i] = 0x0720; }
static void pc(char c) {
    outb(0xE9, (u8)c);
    if (logp < 0xBFFF) { ((volatile u8 *)V(P_LOG))[logp++] = c; ((volatile u8 *)V(P_LOG))[logp] = 0; }
    if (c == '\n') { col = 0; if (row < 24) row++; return; }
    if (!cfg.tb && scr && col < 80) VGA[row * 80 + col] = (u16)(attr << 8 | (u8)c);
    col++;
}
static void phex(u32 v, int d) { for (int i = d - 1; i >= 0; i--) pc("0123456789ABCDEF"[(v >> (4 * i)) & 15]); }
static void pdec(u32 v) { char b[12]; int n = 0; do { b[n++] = '0' + v % 10; v /= 10; } while (v); while (n) pc(b[--n]); }
void pf(const char *s, ...) {
    __builtin_va_list a;
    __builtin_va_start(a, s);
    for (; *s; s++) {
        if (*s != '%') { pc(*s); continue; }
        switch (*++s) {
        case '8': phex(__builtin_va_arg(a, u32), 8); break;
        case '4': phex(__builtin_va_arg(a, u32), 4); break;
        case '2': phex(__builtin_va_arg(a, u32), 2); break;
        case 'x': { u32 v = __builtin_va_arg(a, u32); int d = 1; while (d < 8 && v >> (4 * d)) d++; phex(v, d); break; }
        case 'd': pdec(__builtin_va_arg(a, u32)); break;
        case 'c': pc((char)__builtin_va_arg(a, u32)); break;
        case 's': { const char *q = (const char *)__builtin_va_arg(a, u32); while (*q) pc(*q++); break; }
        }
    }
}
static const char *sname[] = { "fuzz", "acc", "seg", "xfer", "task", "vm", "irq", "soc", "unreal" };
#define NS 9
int fail_begin(const char *what) {
    u32 n = suite_fail[cur_suite]++;
    total_fail++;
    if (n >= 40) return 0;                  /* log: 40 lines per suite;  screen: 4 per suite, 18 in all */
    scr = n < 4 && lines < 18;
    if (scr) lines++;
    attr = 0x0C; row = 5 + (lines - 1); col = 0;
    pf("%s: %s ", sname[cur_suite], what);
    attr = 0x0F;
    return 1;
}
void status(const char *s) {
    if (cfg.tb) return;
    int r = row, c = col; u8 a = attr;
    attr = 7;
    for (int i = 0; i < NS; i++) {
        row = 1 + i / 5; col = (i % 5) * 16;
        attr = suite_fail[i] ? 0x0C : 0x0A;
        if (!(cfg.suites >> i & 1)) attr = 8;
        if (i == (int)cur_suite) attr = 0x0E;
        /* (screen only: no E9 traffic) */
        static char b[18]; int n = 0; const char *q = sname[i];
        while (*q) b[n++] = *q++;
        b[n++] = ' ';
        u32 v = suite_runs[i]; char d[12]; int k = 0; do { d[k++] = '0' + v % 10; v /= 10; } while (v); while (k) b[n++] = d[--k];
        if (suite_fail[i]) { b[n++] = '!'; v = suite_fail[i]; do { d[k++] = '0' + v % 10; v /= 10; } while (v); while (k && n < 16) b[n++] = d[--k]; }
        while (n < 15) b[n++] = ' ';
        for (int j = 0; j < 15; j++) VGA[row * 80 + col + j] = (u16)(attr << 8 | (u8)b[j]);
    }
    for (int j = 0; j < 80; j++) VGA[3 * 80 + j] = 0x0720;
    for (int j = 0; s[j] && j < 60; j++) VGA[3 * 80 + j] = (u16)(0x0700 | (u8)s[j]);
    row = r; col = c; attr = a;
}

/* ---------------------------------------------------------------- descriptors */
void desc(u32 *t, u32 sel, u32 base, u32 limit, u32 acc, u32 fl) {
    u32 *d = t + (sel >> 3) * 2;
    d[0] = (base << 16) | (limit & 0xFFFF);
    d[1] = (base & 0xFF000000) | ((fl & 0xF) << 20) | (limit & 0xF0000) | (acc << 8) | ((base >> 16) & 0xFF);
}
void gate(u32 vec, u32 sel, u32 off, u32 acc) {
    idt[vec * 2] = (sel << 16) | (off & 0xFFFF);
    idt[vec * 2 + 1] = (off & 0xFFFF0000) | (acc << 8);
}
void log_save(u32 n);
static struct { u16 lim; u32 base; } __attribute__((packed)) gdtr, idtr;
extern char ur_gdtr[], ur_idtrpm[];
static void tables(void) {
    desc(gdt, S_KC, 0, 0xFFFFF, 0x9B, 0xC);
    desc(gdt, S_KD, 0, 0xFFFFF, 0x93, 0xC);
    desc(gdt, S_UC, 0, 0xFFFFF, 0xFB, 0xC);
    desc(gdt, S_UD, 0, 0xFFFFF, 0xF3, 0xC);
    desc(gdt, S_TSS, (u32)tss1, 0x68 + 8192, 0x89, 0);
    desc(gdt, S_LDT, (u32)ldt, sizeof ldt - 1, 0x82, 0);
    desc(gdt, S_TSS2, (u32)tss2, 0x67, 0x89, 0);
    desc(gdt, S_UC16, U_CODE, 0xFFFF, 0xFB, 0x0);
    desc(gdt, S_US16, U_STK, 0xFFFF, 0xF3, 0x4);     /* B = 1: IRET to a B = 0 stack leaks the kernel's ESP[31:16] */
    desc(gdt, S_UD16, 0x12340000, 0xFFFF, 0xF3, 0x0);
    desc(gdt, S_URO, 0, 0xFFFFF, 0xF1, 0xC);
    desc(gdt, S_UED, 0, 0x00007, 0xF7, 0xC);
    desc(gdt, S_UCC, 0, 0xFFFFF, 0x9F, 0xC);
    desc(gdt, S_K0, 0, 0xFFFFF, 0x93, 0xC);
    desc(gdt, S_UNP, 0, 0xFFFFF, 0x73, 0xC);
    desc(gdt, 0x1E0, 0x10000, 0xFFFF, 0x9B, 0);                 /* unreal mode: 16-bit code / data, 4 GB data */
    desc(gdt, 0x1E8, 0, 0xFFFF, 0x93, 0);
    desc(gdt, 0x1F0, 0, 0xFFFFF, 0x93, 0x8);
    gdtr.lim = sizeof gdt - 1; gdtr.base = (u32)gdt;
    __asm__ volatile("lgdt %0" :: "m"(gdtr));
    for (u32 i = 0; i < 2048 / 4 * 4; i++) tss1[26 + i] = 0xFFFFFFFF;
    tss1[26 + 2048] = 0xFF;
    tss1[1] = (u32)istack_top; tss1[2] = S_KD; tss1[7] = P_PDK; tss1[24] = 0; tss1[25] = 0x68u << 16;
    __asm__ volatile("ltr %%ax" :: "a"(S_TSS));
    __asm__ volatile("lldt %%ax" :: "a"(0));
    __asm__ volatile("mov $0x10, %%ax; mov %%ax, %%ds; mov %%ax, %%es; mov %%ax, %%fs; mov %%ax, %%gs; mov %%ax, %%ss; ljmp $0x08, $1f; 1:" ::: "eax", "memory");
    for (u32 i = 0; i < 256; i++)
        gate(i, S_KC, (u32)isr_stubs + i * 16, (i == 3 || i == 4 || (i >= 0x80 && i < 0x90)) ? 0xEE : 0x8E);
    if (cfg.tb) gate(8, S_KC, (u32)isr_stubs + 0x20 * 16, 0x8E);      /* the testbench's INTR vector */
    idtr.lim = sizeof idt - 1; idtr.base = (u32)idt;
    __asm__ volatile("lidt %0" :: "m"(idtr));
    copyd((u32)ur_gdtr, (u32)&gdtr, 1); ((u16 *)ur_gdtr)[2] = ((u16 *)&gdtr)[2];
    copyd((u32)ur_idtrpm, (u32)&idtr, 1); ((u16 *)ur_idtrpm)[2] = ((u16 *)&idtr)[2];
}

/* ---------------------------------------------------------------- traps */
void fstop(const char *what, struct frame *f) {
    __asm__ volatile("cli");
    attr = 0x4F; row = 24 - 4; col = 0; scr = 1;
    pf("*** %s: %s vec %2 err %8 at %4:%8 fl %8 cr2 %8\n", sname[cur_suite], what, f->vec, f->err, f->cs & 0xFFFF, f->eip, f->eflags, rd_cr2());
    pf("eax %8 ebx %8 ecx %8 edx %8 esi %8 edi %8\n", f->eax, f->ebx, f->ecx, f->edx, f->esi, f->edi);
    pf("ebp %8 esp %8 ss %4 ds %4 es %4 round %d seed %d\n", f->ebp, f->esp, f->ss & 0xFFFF, f->ds & 0xFFFF, f->es & 0xFFFF, round_no, cfg.seed);
    total_fail++;
    log_save(logp);
    outb(0x80, 0xEE);
    for (;;) __asm__ volatile("cli; hlt");
}
void isr_dispatch(struct frame *f) {
    if (f->vec == 0x20 && !(cfg.tb && cfg.off & 0x80000000)) {
        if (!cfg.tb) outb(0x20, 0x20);
        irq_n++; ticks++;
        if (irq_hook) irq_hook(f);
        return;
    }
    if (f->vec == 0x28 && !cfg.tb) {
        outb(0x70, 0x0C); (void)inb(0x71);
        outb(0xA0, 0x20); outb(0x20, 0x20);
        irq_n++;
        if (irq_hook) irq_hook(f);
        return;
    }
    if ((f->vec == 0x27 || f->vec == 0x2F) && !cfg.tb) return;        /* spurious */
    if (!hook) fstop("unexpected exception", f);
    if (hook(f)) {
        /* (a same-privilege frame: ESP / SS are those after the delivery's pushes) */
        u32 n = (f->eflags & VM) ? 23 : 19;
        if (!(f->eflags & VM) && !(f->cs & 3)) n = 17;
        for (u32 i = 0; i < n; i++) ((u32 *)&fin)[i] = ((u32 *)f)[i];
        fin.cs &= 0xFFFF;
        if (n >= 19) fin.ss &= 0xFFFF;
        if (n == 17) { fin.esp = (u32)&f->esp; fin.ss = S_KD; }
        kexit();
    }
}
static u32 k0stack[1024];
void go(struct frame *f, int (*h)(struct frame *)) {
    hook = h;
    if (!(f->cs & 3) && !(f->eflags & VM)) {                   /* ring 0: its own stack */
        u32 *d = k0stack + 1024 - 17;
        for (u32 i = 0; i < 17; i++) d[i] = ((u32 *)f)[i];
        f = (struct frame *)d;
    }
    run_frame(f);
    hook = 0;
}

/* ---------------------------------------------------------------- devices */
static void pic_init(void) {
    outb(0x20, 0x11); outb(0xA0, 0x11);
    outb(0x21, 0x20); outb(0xA1, 0x28);
    outb(0x21, 0x04); outb(0xA1, 0x02);
    outb(0x21, 0x01); outb(0xA1, 0x01);
    outb(0x21, 0xFF); outb(0xA1, 0xFF);
}
static void pit_set(u32 c) { outb(0x43, 0x34); outb(0x40, c & 0xFF); outb(0x40, c >> 8); }
void irqs_on(u32 lo, u32 span) {
    if (cfg.tb) return;
    pit_set(lo + (span ? rnd() % span : 0));
    outb(0x21, 0xFA); outb(0xA1, 0xFF);
}
void irqs_off(void) {
    if (cfg.tb) return;
    outb(0x21, 0xFF); outb(0xA1, 0xFF);
    pit_set(0);
}
u32 rdtmr(void) { outb(0x43, 0); u32 l = inb(0x40); return l | inb(0x40) << 8; }

void kmain(void) {
    if (!cfg.tb) { pic_init(); pit_set(0); outb(0x3F6, 2); }
    tables();
    clr(0, 24);
    row = 0; col = 0; attr = 0x1F;
    pf(" Tetrium hwcheck  seed %d  mem %d KB\n", cfg.seed, memkb);
    attr = 7;
    static void (*const suite[NS])(u32) = { s_fuzz, s_acc, s_seg, s_xfer, s_task, s_vm, s_irq, s_soc, s_unreal };
    for (round_no = cfg.seed; !cfg.stop || round_no < cfg.seed + cfg.stop; round_no++) {
        for (cur_suite = 0; cur_suite < NS; cur_suite++) {
            if (!(cfg.suites >> cur_suite & 1)) continue;
            rs = mix(round_no, cur_suite);
            status("");
            suite[cur_suite](round_no);
            wr_cr3(P_PDK);
            suite_runs[cur_suite]++;
            static u32 saved;
            if (total_fail != saved) { saved = total_fail; log_save(logp); }
        }
    }
    scr = 1; row = 24; col = 0; attr = total_fail ? 0x4F : 0x2F;
    pf(total_fail ? "FAILED %d" : "ALL PASSED %d", total_fail);
    log_save(logp);
    outb(0x80, total_fail ? 0xEE : 0xAA);
    for (;;) __asm__ volatile("cli; hlt");
}
