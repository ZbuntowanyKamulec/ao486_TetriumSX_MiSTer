// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* CPU stress kernel (tests/hwstress, see README.md).
 *
 * Random workloads (gen.py) run in five environments: V86 under a Win9x-like monitor, flat 32-bit
 * ring 3 and ring 0, 16-bit protected mode at ring 3 (Win16-like: GDT + LDT selectors, CLI/STI
 * emulated, IRQs reflected) and real mode (PE / PG switched off and back).  Each workload runs
 * once quiet (no IRQs reach it) as the reference, then repeatedly under stress: PIT and RTC
 * interrupts at random rates, pages stolen (P cleared, restored by the #PF handler), A/D bits
 * cleared, CR3 reloads, WBINVD, IDE sector reads checked against the disk image.  The workloads
 * fault on purpose (#DE #UD #BR #GP #SS #NM, INT3, INTO: resumed from a table), do port I/O
 * through the I/O permission bitmap (trapped ports: a virtual device), self-modify, call a
 * ring 0 call gate and switch tasks; some seeds single-step them (TF).  Any difference in the
 * final state, any unexpected exception and any hang stops the kernel with a report (screen +
 * port E9h).
 */
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;

/* ---------------------------------------------------------------- memory map */
#define PD        0x90000u
#define PT        0x91000u
#define IDT       0x92000u
#define ISTACK    0x96000u               /* TSS.esp0 (the main kernel stack is 98000 down to 96000) */
#define V86_LO    0x40000u               /* 16-bit data: DS ES FS GS 4000-7000, SS 8000 below E000 */
#define V86_SZ    0x4E000u
#define W32_LO    0x100000u              /* 32-bit sandbox */
#define W32_SZ    0x48000u
#define W32_STK   0x14FFF0u
#define W32_FPTR  0x148000u              /* far pointers: fsub 0-2, call gate (40), task (48) */
#define W32_REPS  0x148100u
#define V86_REPS  0x8DFF0u               /* SS:DFF0 */
#define V86_PRI   0x200000u
#define V86_REF   0x260000u
#define W32_PRI   0x2C0000u
#define W32_REF   0x320000u
#define GDT2      0x3A0000u              /* 32 KB: selectors up to 8000h (real-mode values) */
#define IDEBUF    0x3A9000u
#define TASK_STK  0x3AF000u
#define LDT       0x3B0000u
#define TSS1      0x3C0000u              /* + I/O permission bitmap */
#define TSS2      0x3C4000u
#define DISK      0x3D0000u              /* copy of LBA 1-384 (the loaded image) taken at boot */
#define RMB       0x700u                 /* real-mode register block (entry.s) */
#define WL16      0x20000u
#define WL32      0x30000u
#define VGA       ((volatile u16 *)0xB8000)

/* ---------------------------------------------------------------- configuration (patched by cfg.py) */
struct cfg { u32 magic, seed, tests, passes, reps, stop, pit_sel, steal_max, first, off; };
__attribute__((section(".cfg"), used)) volatile struct cfg cfg =
    { 0x54534857 /* "WHST" */, 1, 0xFFFFF, 16, 6, 0, 0, 255, 1, 0 };

struct frame {
    u32 gs, fs, es, ds;
    u32 edi, esi, ebp, esp0, ebx, edx, ecx, eax;
    u32 vec, err;
    u32 eip, cs, eflags;
    u32 esp, ss;                         /* privilege change / V86 only */
    u32 ves, vds, vfs, vgs;              /* V86 only */
};
#define VM  0x20000u
#define IFL 0x200u
#define TFL 0x100u
#define AFL 0xCD5u                       /* OF DF SF ZF AF PF CF */

enum { M_V86, M_R3, M_R0, M_P16, M_RM, NMODE };
#define NT (NMODE * 4)

extern char isr_stubs[], gate_fn[], task_fn[], rm_exit[], rm_irq0[], rm_irq8[], rm_spur[], rm_db[],
    rm_f0[], rm_f5[], rm_f6[], rm_f7[], rm_f12[], rm_f13[], rm_bad[], _start[];
extern u32 rm_chain0, rm_chain70;
extern struct { u16 lim; u32 base; } __attribute__((packed)) gdtr2, idtr_pm;
void run_frame(struct frame *f);
void run_real(void);
__attribute__((noreturn)) void kexit(void);

/* ---------------------------------------------------------------- low level */
static inline void outb(u16 p, u8 v) { __asm__ volatile("outb %0, %1" :: "a"(v), "Nd"(p)); }
static inline u8 inb(u16 p) { u8 v; __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline void invlpg(u32 a) { __asm__ volatile("invlpg (%0)" :: "r"(a) : "memory"); }
static inline u32 rd_cr2(void) { u32 v; __asm__ volatile("mov %%cr2, %0" : "=r"(v)); return v; }
static inline u32 rd_cr0(void) { u32 v; __asm__ volatile("mov %%cr0, %0" : "=r"(v)); return v; }
static inline void wr_cr0(u32 v) { __asm__ volatile("mov %0, %%cr0" :: "r"(v) : "memory"); }
static inline void cr3_reload(void) { __asm__ volatile("mov %%cr3, %%eax; mov %%eax, %%cr3" ::: "eax", "memory"); }
static inline void wbinvd(void) { __asm__ volatile("wbinvd" ::: "memory"); }
static void copyd(u32 dst, u32 src, u32 n) {
    __asm__ volatile("cld; rep movsl" : "+D"(dst), "+S"(src), "+c"(n) :: "memory");
}
static u32 cmpd(u32 a, u32 b, u32 n) {
    u32 i = 0;
    volatile u32 *p = (u32 *)a, *q = (u32 *)b;
    for (; i < n; i++) if (p[i] != q[i]) break;
    return i;
}

static u32 rs = 1;
static u32 rnd(void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }
static u32 mix(u32 a, u32 b) { u32 x = a * 0x9E3779B1u ^ (b + 0x7F4A7C15u); x ^= x >> 15; x *= 0x2C1B3C6Du; x ^= x >> 12; return x ? x : 1; }

/* ---------------------------------------------------------------- screen + E9 */
static int row, col;
static u8 attr = 0x07;
static int msgmode = 1;                  /* 1: newline scrolls rows 15-24 */
static void scroll_msgs(void) {
    for (int r = 15; r < 24; r++) for (int c = 0; c < 80; c++) VGA[r * 80 + c] = VGA[(r + 1) * 80 + c];
    for (int c = 0; c < 80; c++) VGA[24 * 80 + c] = 0x0720;
}
static void putc_(char c) {
    outb(0xE9, (u8)c);
    if (c == '\n') {
        col = 0;
        if (msgmode && row >= 24) scroll_msgs(); else row++;
        if (row > 24) row = 24;
        return;
    }
    if (col < 80) VGA[row * 80 + col] = (u16)(attr << 8 | (u8)c);
    col++;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void hex(u32 v, int d) { for (int i = d - 1; i >= 0; i--) putc_("0123456789ABCDEF"[(v >> (4 * i)) & 15]); }
static void dec(u32 v) { char b[12]; int n = 0; do { b[n++] = '0' + v % 10; v /= 10; } while (v); while (n) putc_(b[--n]); }
static void at(int r, int c) { row = r; col = c; }
static void clr(int r0, int r1) { for (int i = r0 * 80; i < (r1 + 1) * 80; i++) VGA[i] = 0x0720; }

/* ---------------------------------------------------------------- state */
static const char *tname[NMODE] = { "V86", "R3 ", "R0 ", "P16", "RM " };
static u32 t_pass[NT], t_irq[NT], t_pf[NT];
static u32 cur_t, cur_mode, cur_seed, cur_k, stressed, step_on, em_on;
static u32 *const pte = (u32 *)PT;

static struct { u32 pit_lo, pit_span, rtc, steal, adclr, cr3, wbinv, ide; } st;
static u32 cur_cnt, ticks, run_t0, n_irq, n_pf, n_steal, n_gp, n_flt, n_step, n_ide, n_io;
static u32 vif, pend_t, pend_r, dev;
static u8 cand[1024];
static u16 cand_list[256];
static u32 ncand;
struct hist { u32 cs, eip, fl, vec; };
static struct hist hist[16];
static u32 nh;
static u32 pflog[8], npl;

struct res { u32 r[8], fl, sg[6], steps, nflt, dev; };
static struct res ref, cur;
static const char *rn[8] = { "EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI" };
static const char *sn[6] = { "ES", "CS", "SS", "DS", "FS", "GS" };

static void report_head(const char *what) {
    __asm__ volatile("cli");
    msgmode = 0; attr = 0x4F; clr(0, 24); at(0, 0);
    puts_("*** "); puts_(what); puts_("  test "); puts_(tname[cur_mode]); puts_("/w"); dec(cur_t & 3);
    puts_(" seed "); dec(cur_seed); puts_(" pass "); dec(cur_k); puts_(stressed ? " stress" : " quiet"); putc_('\n');
    attr = 0x0F;
    puts_("pit "); dec(st.pit_lo); putc_('+'); dec(st.pit_span); puts_(" rtc "); dec(st.rtc);
    puts_(" steal "); dec(st.steal); puts_(" adclr "); dec(st.adclr); puts_(" cr3 "); dec(st.cr3); puts_(" wbinvd "); dec(st.wbinv);
    puts_(" ide "); dec(st.ide); puts_(" em "); dec(em_on); puts_(" tf "); dec(step_on); putc_('\n');
    puts_("irq "); dec(n_irq); puts_(" pf "); dec(n_pf); puts_(" gp "); dec(n_gp); puts_(" flt "); dec(n_flt);
    puts_(" step "); dec(n_step); puts_(" io "); dec(n_io); puts_(" ide "); dec(n_ide); putc_('\n');
}
static void report_hist(void) {
    puts_("last IRQs (vec cs:eip flags), newest first:\n");
    for (u32 i = 0; i < 16 && i < nh; i++) {
        struct hist *h = &hist[(nh - 1 - i) & 15];
        hex(h->vec, 2); putc_(' '); hex(h->cs, 4); putc_(':'); hex(h->eip, 8); putc_(' '); hex(h->fl, 5);
        puts_((i & 3) == 3 ? "\n" : "   ");
    }
    if (npl) { puts_("last #PF CR2:"); for (u32 i = 0; i < 8 && i < npl; i++) { putc_(' '); hex(pflog[(npl - 1 - i) & 7], 6); } putc_('\n'); }
}
__attribute__((noreturn)) static void halt_all(void) {
    outb(0x80, 0xEE);
    puts_("\nhalted.\n");
    for (;;) __asm__ volatile("cli; hlt");
}
static u32 segbase(u32 sel, int vm) {    /* 16-bit code / stack segments: real-mode value or selector */
    return vm ? (sel & 0xFFFF) << 4 : (sel & 0xFFF8) << 4;
}
static void dump_frame(struct frame *f) {
    int vm = (f->eflags & VM) != 0;
    puts_("vec "); hex(f->vec, 2); puts_(" err "); hex(f->err, 8); puts_(" at "); hex(f->cs & 0xFFFF, 4); putc_(':'); hex(f->eip, 8);
    puts_(" fl "); hex(f->eflags, 8); puts_(" cr2 "); hex(rd_cr2(), 8); puts_(vm ? " V86" : ((f->cs & 3) ? " ring3" : " ring0")); putc_('\n');
    puts_("EAX "); hex(f->eax, 8); puts_(" EBX "); hex(f->ebx, 8); puts_(" ECX "); hex(f->ecx, 8); puts_(" EDX "); hex(f->edx, 8); putc_('\n');
    puts_("ESI "); hex(f->esi, 8); puts_(" EDI "); hex(f->edi, 8); puts_(" EBP "); hex(f->ebp, 8);
    if (vm || (f->cs & 3)) { puts_(" SS:ESP "); hex(f->ss & 0xFFFF, 4); putc_(':'); hex(f->esp, 8); }
    else { puts_(" ESP "); hex((u32)&f->esp, 8); }
    putc_('\n');
    if (vm) { puts_("DS "); hex(f->vds & 0xFFFF, 4); puts_(" ES "); hex(f->ves & 0xFFFF, 4); puts_(" FS "); hex(f->vfs & 0xFFFF, 4); puts_(" GS "); hex(f->vgs & 0xFFFF, 4); }
    else { puts_("DS "); hex(f->ds, 4); puts_(" ES "); hex(f->es, 4); puts_(" FS "); hex(f->fs, 4); puts_(" GS "); hex(f->gs, 4); }
    puts_(" vif "); dec(vif); putc_('\n');
    u32 cb = (vm || (f->cs & 0xFFF8) == 0x2000) ? segbase(f->cs, vm) : 0;
    u32 l = cb + (cb ? (f->eip & 0xFFFF) : f->eip);
    if (l < 0x400000 - 16) {
        puts_("bytes at CS:EIP:"); for (int i = 0; i < 12; i++) { putc_(' '); hex(*(volatile u8 *)(l + i), 2); } putc_('\n');
    }
    if (vm || (f->cs & 0xFFF8) == 0x2000) {
        u32 s = segbase(f->ss, vm);
        puts_("stack:"); for (int i = 0; i < 12; i++) { putc_(' '); hex(*(volatile u16 *)(s + ((f->esp + 2 * i) & 0xFFFF)), 4); } putc_('\n');
    }
}
__attribute__((noreturn)) static void fail_frame(const char *what, struct frame *f) {
    report_head(what);
    dump_frame(f);
    report_hist();
    halt_all();
}

/* ---------------------------------------------------------------- hardware */
static void pic_init(void) {
    outb(0x20, 0x11); outb(0xA0, 0x11);
    outb(0x21, 0x20); outb(0xA1, 0x28);
    outb(0x21, 0x04); outb(0xA1, 0x02);
    outb(0x21, 0x01); outb(0xA1, 0x01);
    outb(0x21, 0xFF); outb(0xA1, 0xFF);
}
static void pit_set(u32 c) { outb(0x43, 0x34); outb(0x40, c & 0xFF); outb(0x40, c >> 8); }
static void rtc_set(u32 rate) {   /* 0: off, else rate select 3..15 */
    outb(0x70, 0x0A); u8 a = inb(0x71); outb(0x70, 0x0A); outb(0x71, (a & 0xF0) | (rate ? rate : 6));
    outb(0x70, 0x0B); u8 b = inb(0x71); outb(0x70, 0x0B); outb(0x71, rate ? (b | 0x40) : (b & ~0x40));
    outb(0x70, 0x0C); (void)inb(0x71);
}

/* IDE: read one sector (polled, LBA 28) and check it against the boot-time copy of the image */
static int ide_wait(u8 mask, u8 want) {
    for (u32 i = 0; i < 20000000; i++) { u8 s = inb(0x1F7); if (!(s & 0x80) && (s & mask) == want) return 1; if (s & 1) return 0; }
    return 0;
}
static void ide_check(struct frame *f) {
    u32 lba = 1 + rnd() % 384;
    if (!ide_wait(0x40, 0x40)) fail_frame("IDE: drive not ready", f);
    outb(0x1F6, 0xE0); outb(0x1F2, 1);
    outb(0x1F3, lba & 0xFF); outb(0x1F4, lba >> 8); outb(0x1F5, 0);
    outb(0x1F7, 0x20);
    if (!ide_wait(0x08, 0x08)) fail_frame("IDE: no data (DRQ)", f);
    u32 d = IDEBUF, n;
    if (rnd() & 1) { n = 128; __asm__ volatile("cld; rep insl" : "+D"(d), "+c"(n) : "d"(0x1F0) : "memory"); }
    else { n = 256; __asm__ volatile("cld; rep insw" : "+D"(d), "+c"(n) : "d"(0x1F0) : "memory"); }
    n_ide++;
    u32 i = cmpd(IDEBUF, DISK + (lba - 1) * 512, 128);
    if (i != 128) {
        report_head("IDE sector data differs from the boot-time copy");
        puts_("LBA "); dec(lba); puts_(" dword "); dec(i); puts_(" expected "); hex(((u32 *)(DISK + (lba - 1) * 512))[i], 8);
        puts_(" read "); hex(((u32 *)IDEBUF)[i], 8); putc_('\n');
        dump_frame(f); halt_all();
    }
}

/* ---------------------------------------------------------------- V86 / 16-bit PM monitor */
static int is_p16(struct frame *f) { return cur_mode == M_P16 && !(f->eflags & VM) && (f->cs & 3) == 3; }
static u32 cbase(struct frame *f) { return segbase(f->cs, (f->eflags & VM) != 0); }
static u32 sbase(struct frame *f) { return segbase(f->ss, (f->eflags & VM) != 0); }
static void vpush16(struct frame *f, u32 v) { u32 sp = (f->esp - 2) & 0xFFFF; f->esp = sp; *(volatile u16 *)(sbase(f) + sp) = (u16)v; }
static void vpush32(struct frame *f, u32 v) { u32 sp = (f->esp - 4) & 0xFFFF; f->esp = sp; *(volatile u32 *)(sbase(f) + sp) = v; }
static u32 vpop16(struct frame *f) { u32 sp = f->esp & 0xFFFF; u32 v = *(volatile u16 *)(sbase(f) + sp); f->esp = (sp + 2) & 0xFFFF; return v; }
static u32 vpop32(struct frame *f) { u32 sp = f->esp & 0xFFFF; u32 v = *(volatile u32 *)(sbase(f) + sp); f->esp = (sp + 4) & 0xFFFF; return v; }
static u32 vflags(struct frame *f) { return (f->eflags & (AFL | TFL)) | 2 | (vif ? IFL : 0); }
static void vsetflags(struct frame *f, u32 v) { f->eflags = (f->eflags & ~(AFL | TFL)) | (v & (AFL | TFL)); vif = (v >> 9) & 1; }
/* V86: INT n / IRQ through the IVT; 16-bit PM: IRQ to the handler (its IRET is native) */
static void reflect(struct frame *f, u32 vec, u32 retip) {
    vpush16(f, vflags(f)); vpush16(f, f->cs); vpush16(f, retip);
    f->eflags &= ~TFL;
    if (f->eflags & VM) {
        vif = 0;
        f->eip = *(volatile u16 *)(vec * 4);
        f->cs = *(volatile u16 *)(vec * 4 + 2);
    } else {
        f->eip = *(volatile u16 *)(WL16 + 2 * (vec == 0x08 ? 4 : 5));
    }
}
static void deliver(struct frame *f) {
    if (!vif || !((f->eflags & VM) || is_p16(f))) return;
    if (pend_t) { pend_t = 0; reflect(f, 0x08, f->eip); }
    else if (pend_r) { pend_r = 0; reflect(f, 0x70, f->eip); }
}
static void save_res(struct frame *f, struct res *r);
static void save_rm(struct res *r);

/* the resume table of the code that faulted: (key, resume) pairs */
static int fault_fix(struct frame *f) {
    u32 key, i, n;
    if ((f->eflags & VM) || (f->cs & 0xFFF8) == 0x2000) {
        if ((f->cs & 0xFFF8) != 0x2000) return 0;
        volatile u16 *h = (u16 *)WL16, *t = (u16 *)(WL16 + h[12]);
        n = h[13]; key = f->eip & 0xFFFF;
        for (i = 0; i < n; i++) if (t[2 * i] == key) { f->eip = t[2 * i + 1]; break; }
        if (i == n) return 0;
    } else {
        volatile u32 *h = (u32 *)WL32, *t = (u32 *)h[9];
        n = h[10]; key = f->eip;
        for (i = 0; i < n; i++) if (t[2 * i] == key) { f->eip = t[2 * i + 1]; break; }
        if (i == n) return 0;
    }
    f->eax ^= 0x9E3779B1u * (f->vec + 1);
    n_flt++;
    return 1;
}
/* trapped ports: a virtual device with state (deterministic for the instruction stream) */
static u32 dev_in(u32 port, u32 size) {
    u32 v = dev ^ (port * 0x01000193u);
    dev = ((dev << 5) | (dev >> 27)) + 0x9E37 + size;
    return v;
}
static void dev_out(u32 port, u32 v) { dev ^= v * 31 + port; dev = (dev << 3) | (dev >> 29); }
static int io_emul(struct frame *f, u32 op, u32 n, int o32, u32 base, int m16) {
    u32 size = (op & 1) ? (o32 ? 4 : 2) : 1, port;
    if (op == 0xE4 || op == 0xE5 || op == 0xE6 || op == 0xE7) {
        port = *(volatile u8 *)(base + (m16 ? ((f->eip + n + 1) & 0xFFFF) : f->eip + n + 1)); n += 2;
    } else if (op >= 0xEC && op <= 0xEF) { port = f->edx & 0xFFFF; n += 1; }
    else return 0;
    u32 m = size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFFFFFF;
    if ((op & 2) == 0) f->eax = (f->eax & ~m) | (dev_in(port, size) & m);
    else dev_out(port, f->eax & m);
    n_io++;
    f->eip = m16 ? (f->eip + n) & 0xFFFF : f->eip + n;
    return 1;
}
/* #GP from V86 / 16-bit PM ring 3 / 32-bit ring 3: the sensitive instructions, else the fault table */
static void gp_trap(struct frame *f) {
    int vm = (f->eflags & VM) != 0, p16 = is_p16(f), r3 = !vm && !p16 && (f->cs & 3) == 3;
    if (!vm && !p16 && !r3) { if (fault_fix(f)) return; fail_frame("#GP", f); }
    n_gp++;
    u32 base = (vm || p16) ? cbase(f) : 0, ip = f->eip, n = 0, o32 = r3;
    u8 op;
    for (;;) {
        op = *(volatile u8 *)(base + ((vm || p16) ? ((ip + n) & 0xFFFF) : ip + n));
        if (op == 0x66) { o32 = !o32; n++; }
        else if (op == 0x67 || op == 0xF0 || op == 0xF2 || op == 0xF3 || op == 0x26 || op == 0x2E ||
                 op == 0x36 || op == 0x3E || op == 0x64 || op == 0x65) n++;
        else break;
        if (n > 14) fail_frame("#GP: prefixes", f);
    }
    if (f->err == 0 && io_emul(f, op, n, o32, base, vm || p16)) { deliver(f); return; }
    if (vm && f->err == 0) {
        switch (op) {
        case 0xFA: vif = 0; break;
        case 0xFB: vif = 1; break;
        case 0x9C: if (o32) vpush32(f, vflags(f)); else vpush16(f, vflags(f)); break;
        case 0x9D: vsetflags(f, o32 ? vpop32(f) : vpop16(f)); break;
        case 0xCD: {
            u32 v = *(volatile u8 *)(base + ((ip + n + 1) & 0xFFFF));
            n += 2;
            if (v == 0x31) { save_res(f, &cur); kexit(); }
            if (v == 0x32) fail_frame("V86 code reached an unused interrupt vector", f);
            reflect(f, v, (ip + n) & 0xFFFF);
            deliver(f);
            return;
        }
        case 0xCF: {
            u32 nip, ncs, fl;
            if (o32) { nip = vpop32(f); ncs = vpop32(f); fl = vpop32(f); }
            else { nip = vpop16(f); ncs = vpop16(f); fl = vpop16(f); }
            f->eip = nip & 0xFFFF; f->cs = ncs & 0xFFFF;
            vsetflags(f, fl);
            deliver(f);
            return;
        }
        default:
            if (fault_fix(f)) return;
            fail_frame("V86 #GP on an unexpected instruction", f);
        }
        f->eip = (ip + n + 1) & 0xFFFF;
        deliver(f);
        return;
    }
    if (p16 && f->err == 0 && (op == 0xFA || op == 0xFB)) {
        vif = op == 0xFB;
        f->eip = (ip + n + 1) & 0xFFFF;
        deliver(f);
        return;
    }
    if (fault_fix(f)) return;
    fail_frame(vm ? "V86 #GP" : "#GP", f);
}

/* ---------------------------------------------------------------- stress */
static u32 cand_pick(void) { return cand_list[rnd() % ncand]; }
static void stress(struct frame *f) {
    u32 x = rnd();
    if (ncand && st.steal && (x & 0xFF) < st.steal) {
        u32 p = cand_pick();
        if (pte[p] & 1) { pte[p] &= ~1u; invlpg(p << 12); n_steal++; }
    }
    if (ncand && st.adclr && ((x >> 8) & 0xFF) < st.adclr) { u32 p = cand_pick(); pte[p] &= ~0x60u; invlpg(p << 12); }
    if (st.cr3 && ((x >> 16) & 0xFF) < st.cr3) cr3_reload();
    if (st.wbinv && ((x >> 24) & 0xFF) < st.wbinv) wbinvd();
    if (st.ide && (rnd() & 0xFF) < st.ide) ide_check(f);
}
static void hist_add(struct frame *f) {
    struct hist *h = &hist[nh++ & 15];
    h->vec = f->vec; h->cs = f->cs & 0xFFFF; h->eip = f->eip; h->fl = f->eflags;
}
#define WATCHDOG (1193182u * 8u)        /* 8 s of PIT time per pass */

void isr_dispatch(struct frame *f) {
    switch (f->vec) {
    case 0x20:
        outb(0x20, 0x20);
        if (!stressed || (cfg.off & 64)) {   /* quiet run: a slow watchdog tick only, invisible to the workload */
            ticks += 65536;
            if (ticks - run_t0 > WATCHDOG) fail_frame("HANG in the quiet run (watchdog, the IRQ hit here)", f);
            return;
        }
        n_irq++; ticks += cur_cnt; hist_add(f);
        cur_cnt = st.pit_lo + rnd() % st.pit_span;
        pit_set(cur_cnt);
        if (ticks - run_t0 > WATCHDOG) fail_frame("HANG (watchdog, the IRQ hit here)", f);
        stress(f);
        pend_t = 1; deliver(f);
        return;
    case 0x28:
        outb(0x70, 0x0C); (void)inb(0x71);
        outb(0xA0, 0x20); outb(0x20, 0x20);
        n_irq++; hist_add(f);
        stress(f);
        pend_r = 1; deliver(f);
        return;
    case 0x27: case 0x2F:
        return;                          /* spurious */
    case 1:
        n_step++;
        return;
    case 14: {
        u32 a = rd_cr2(), p = a >> 12;
        if (p < 1024 && cand[p] && !(pte[p] & 1) && !(f->err & 1)) {
            pte[p] |= 1; invlpg(a); n_pf++;
            pflog[npl++ & 7] = a;
            return;
        }
        fail_frame("unexpected #PF", f);
    }
    case 13:
        gp_trap(f);
        return;
    case 0: case 3: case 4: case 5: case 6: case 7: case 12:
        if (fault_fix(f)) return;
        fail_frame("unexpected exception", f);
    case 0x30:                           /* "system call": a deterministic register transform */
        f->eax = f->eax * 0x9E3779B1u + (f->ebx ^ 0x5A5A5A5Au);
        f->edx ^= f->eax >> 7;
        if (stressed) stress(f);
        return;
    case 0x31:
        save_res(f, &cur);
        kexit();
    default:
        fail_frame("unexpected exception / interrupt", f);
    }
}

/* ---------------------------------------------------------------- setup */
static void desc(u32 sel, u32 base, u32 limit, u32 acc, u32 fl, u32 tbl) {
    volatile u32 *d = (u32 *)(tbl + (sel & ~7u));
    d[0] = (base << 16) | (limit & 0xFFFF);
    d[1] = (base & 0xFF000000) | ((fl & 0xF) << 20) | (limit & 0xF0000) | (acc << 8) | ((base >> 16) & 0xFF);
}
static void gate(u32 vec, u32 sel, u32 off, u32 acc) {
    volatile u32 *g = (u32 *)(IDT + vec * 8);
    g[0] = (sel << 16) | (off & 0xFFFF);
    g[1] = (off & 0xFFFF0000) | (acc << 8);
}
static void tables(void) {
    /* GDT: flat ring 0 / 3, TSS 1 (+ I/O bitmap), FS-style data (base 100000), LDT, TSS 2 (DPL 3),
       call gate, 16-bit ring 0 code / data (real-mode switch) and, at the selectors equal to the
       real-mode segment values, the 16-bit ring 3 segments of the P16 workloads */
    for (u32 i = 0; i < 0x8008 / 4; i++) ((volatile u32 *)GDT2)[i] = 0;
    desc(0x08, 0, 0xFFFFF, 0x9A, 0xC, GDT2);
    desc(0x10, 0, 0xFFFFF, 0x92, 0xC, GDT2);
    desc(0x18, 0, 0xFFFFF, 0xFA, 0xC, GDT2);
    desc(0x20, 0, 0xFFFFF, 0xF2, 0xC, GDT2);
    desc(0x28, TSS1, 0x68 + 8192, 0x89, 0, GDT2);
    desc(0x30, 0x100000, 0xFFFF, 0xF2, 0x4, GDT2);
    desc(0x38, LDT, 0x7007, 0x82, 0, GDT2);
    desc(0x40, TSS2, 0x67, 0xE9, 0, GDT2);
    {   /* call gate 48h: DPL 3, 32-bit, 2 parameters, to 08:gate_fn */
        volatile u32 *d = (u32 *)(GDT2 + 0x48);
        d[0] = (0x08 << 16) | ((u32)gate_fn & 0xFFFF);
        d[1] = ((u32)gate_fn & 0xFFFF0000) | 0xEC00 | 2;
    }
    desc(0x50, 0x10000, 0xFFFF, 0x9A, 0, GDT2);
    desc(0x58, 0, 0xFFFF, 0x92, 0, GDT2);
    desc(0x100, 0x1000, 0xFFFF, 0xF2, 0, GDT2);
    desc(0x2000, 0x20000, 0xFFFF, 0xFA, 0, GDT2);
    desc(0x2008, 0x20080, 0xFFFF, 0xF2, 0, GDT2);
    for (u32 s = 0x4000; s <= 0x8000; s += 0x1000) desc(s, s << 4, 0xFFFF, 0xF2, 0, GDT2);
    for (u32 i = 0; i < 0x7008 / 4; i++) ((volatile u32 *)LDT)[i] = 0;
    for (u32 s = 0x4007; s <= 0x7007; s += 0x1000) desc(s, s << 4, 0xFFFF, 0xF2, 0, LDT);
    gdtr2.lim = 0x8007; gdtr2.base = GDT2;
    __asm__ volatile("lgdt %0" :: "m"(gdtr2));
    /* TSS 1: ring 0 stack, I/O bitmap (everything trapped but port 80h) */
    volatile u8 *t1 = (u8 *)TSS1;
    for (u32 i = 0; i < 0x68 + 8193; i++) t1[i] = i >= 0x68 ? 0xFF : 0;
    ((volatile u32 *)TSS1)[1] = ISTACK; ((volatile u32 *)TSS1)[2] = 0x10;
    ((volatile u32 *)TSS1)[7] = PD;      /* CR3: a task switch back loads it (it is never saved) */
    ((volatile u32 *)TSS1)[24] = 0x38;   /* LDT: the same (static field, loaded on the switch back) */
    ((volatile u16 *)TSS1)[51] = 0x68;
    t1[0x68 + 0x80 / 8] &= ~1u;
    /* TSS 2: the task of task_fn */
    volatile u32 *t2 = (u32 *)TSS2;
    for (int i = 0; i < 26; i++) t2[i] = 0;
    t2[7] = PD; t2[8] = (u32)task_fn; t2[9] = 0x202; t2[14] = TASK_STK;
    t2[18] = 0x10; t2[19] = 0x08; t2[20] = 0x10; t2[21] = 0x10; t2[22] = 0x10; t2[23] = 0x10; t2[24] = 0x38;
    t2[25] = 0x68u << 16;
    __asm__ volatile("ltr %%ax; lldt %%cx" :: "a"(0x28), "c"(0x38));
    __asm__ volatile("mov $0x10, %%ax; mov %%ax, %%ds; mov %%ax, %%es; mov %%ax, %%ss; ljmp $0x08, $1f; 1:" ::: "eax", "memory");
    /* IDT: interrupt gates; INT 3 / 4 / 30 / 31 for ring 3; 40-43: 16-bit ring 3 trap gates to
       the P16 services (V86 never gets there: INT n traps first) */
    for (u32 i = 0; i < 256; i++)
        gate(i, 0x08, (u32)isr_stubs + i * 16, (i == 3 || i == 4 || i == 0x30 || i == 0x31) ? 0xEE : 0x8E);
    volatile u16 *h16 = (u16 *)WL16;
    for (u32 i = 0; i < 4; i++) gate(0x40 + i, 0x2000, h16[6 + i], 0xE7);
    idtr_pm.lim = 256 * 8 - 1; idtr_pm.base = IDT;
    __asm__ volatile("lidt %0" :: "m"(idtr_pm));
    /* paging: 0-4 MB identity, user pages except the kernel and the tables */
    volatile u32 *pd = (u32 *)PD;
    for (int i = 0; i < 1024; i++) pd[i] = 0;
    pd[0] = PT | 7;
    for (u32 i = 0; i < 1024; i++) {
        u32 sup = (i >= 0x10 && i < 0x20) || (i >= 0x90 && i < 0xA0) || i >= 0x200;
        pte[i] = (i << 12) | (sup ? 3 : 7);
    }
    __asm__ volatile("mov %0, %%cr3" :: "r"(PD));
    wr_cr0((rd_cr0() & ~0x60010000u) | 0x80000001u);
}

static void cand_set(u32 mode) {
    for (int i = 0; i < 1024; i++) cand[i] = 0;
    ncand = 0;
    if (mode == M_V86 || mode == M_P16) {
        for (u32 p = 0x20; p < 0x30; p++) cand_list[ncand++] = p;      /* 16-bit code */
        for (u32 p = 0x40; p < 0x90; p++) cand_list[ncand++] = p;      /* data + stack */
    } else if (mode == M_R3 || mode == M_R0) {
        for (u32 p = 0x30; p < 0x40; p++) cand_list[ncand++] = p;      /* code */
        u32 top = mode == M_R3 ? 0x150 : 0x148;                        /* ring 0: never its stack */
        for (u32 p = 0x100; p < top; p++) cand_list[ncand++] = p;
    }                                                                  /* real mode: no paging */
    for (u32 i = 0; i < ncand; i++) cand[cand_list[i]] = 1;
}
static void restore_pages(void) { for (u32 i = 0; i < ncand; i++) pte[cand_list[i]] |= 1; cr3_reload(); }

/* ---------------------------------------------------------------- one run */
static u32 init_r[8], init_fl;
static struct frame fr;

static void save_res(struct frame *f, struct res *r) {
    r->r[0] = f->eax; r->r[1] = f->ecx; r->r[2] = f->edx; r->r[3] = f->ebx;
    r->r[5] = f->ebp; r->r[6] = f->esi; r->r[7] = f->edi;
    if (f->eflags & VM) {
        r->r[4] = f->esp;
        r->fl = (f->eflags & AFL) | (vif ? IFL : 0);
        r->sg[0] = f->ves; r->sg[1] = f->cs; r->sg[2] = f->ss; r->sg[3] = f->vds; r->sg[4] = f->vfs; r->sg[5] = f->vgs;
    } else {
        r->r[4] = (f->cs & 3) ? f->esp : (u32)&f->esp;
        r->fl = (f->eflags & (AFL | IFL)) | (cur_mode == M_P16 && vif ? 0x80000000u : 0);
        r->sg[0] = f->es; r->sg[1] = f->cs; r->sg[2] = (f->cs & 3) ? f->ss : 0x10; r->sg[3] = f->ds; r->sg[4] = f->fs; r->sg[5] = f->gs;
    }
    for (int i = 0; i < 6; i++) r->sg[i] &= 0xFFFF;
    r->steps = n_step; r->nflt = n_flt; r->dev = dev;
}
static volatile u32 *const rmb = (u32 *)RMB;
static void save_rm(struct res *r) {
    for (int i = 0; i < 8; i++) r->r[i] = rmb[i];
    r->r[4] &= 0xFFFF;
    r->fl = rmb[8] & (AFL | IFL);
    r->sg[0] = rmb[13] & 0xFFFF; r->sg[1] = rmb[10] & 0xFFFF; r->sg[2] = rmb[11] & 0xFFFF;
    r->sg[3] = rmb[12] & 0xFFFF; r->sg[4] = rmb[14] & 0xFFFF; r->sg[5] = rmb[15] & 0xFFFF;
    r->steps = rmb[21]; r->nflt = rmb[22]; r->dev = 0;
}
static void rm_report(void) {
    static const char *what[5] = { "", "", "HANG in real mode (watchdog, the IRQ hit here)",
                                   "unexpected exception in real mode", "real-mode code reached an unused interrupt vector" };
    u32 s = rmb[16];
    report_head(s < 5 ? what[s] : "real mode: bad status");
    puts_("at "); hex(rmb[18] & 0xFFFF, 4); putc_(':'); hex(rmb[17] & 0xFFFF, 4);
    if (s == 3) { puts_(" vec "); hex(rmb[19] & 0xFF, 2); }
    puts_(" irqs "); dec(rmb[28]); putc_('\n');
    u32 l = ((rmb[18] & 0xFFFF) << 4) + (rmb[17] & 0xFFFF);
    puts_("bytes at CS:IP:"); for (int i = 0; i < 12; i++) { putc_(' '); hex(*(volatile u8 *)(l + i), 2); } putc_('\n');
    halt_all();
}

static void run(u32 t, u32 stress_on) {
    u32 mode = t / 4, w = t & 3;
    stressed = stress_on;
    n_irq = n_pf = n_steal = n_gp = n_flt = n_step = n_ide = n_io = 0; nh = 0; npl = 0;
    vif = 1; pend_t = pend_r = 0;
    dev = mix(cur_seed, t);
    for (u32 i = 0; i < sizeof fr / 4; i++) ((u32 *)&fr)[i] = 0;
    fr.eax = init_r[0]; fr.ecx = init_r[1]; fr.edx = init_r[2]; fr.ebx = init_r[3];
    fr.ebp = init_r[5]; fr.esi = init_r[6]; fr.edi = init_r[7];
    fr.eflags = (init_fl & AFL) | IFL | 2 | (step_on ? TFL : 0);
    wr_cr0((rd_cr0() & ~0xCu) | (em_on ? 4 : 0));    /* EM per seed; TS clear (task switches set it) */
    u32 entry16 = *(volatile u16 *)(WL16 + 2 * w);
    if (mode == M_V86 || mode == M_P16 || mode == M_RM) {
        copyd(V86_LO, V86_PRI, V86_SZ / 4);
        *(volatile u16 *)V86_REPS = (u16)cfg.reps;
    } else {
        copyd(W32_LO, W32_PRI, W32_SZ / 4);
        *(volatile u32 *)W32_REPS = cfg.reps;
        u32 nfs = *(volatile u32 *)(WL32 + 4 * 8);
        for (u32 k = 0; k < nfs; k++) {
            *(volatile u32 *)(W32_FPTR + 8 * k) = *(volatile u32 *)(WL32 + 16 + 4 * k);
            *(volatile u32 *)(W32_FPTR + 8 * k + 4) = mode == M_R3 ? 0x1B : 0x08;
        }
        *(volatile u32 *)(W32_FPTR + 0x40) = 0; *(volatile u32 *)(W32_FPTR + 0x44) = 0x4B;   /* call gate */
        *(volatile u32 *)(W32_FPTR + 0x48) = 0; *(volatile u32 *)(W32_FPTR + 0x4C) = 0x43;   /* task 2 */
    }
    if (stress_on && (cfg.off & 64)) { st.rtc = 0; pit_set(0); }
    else if (stress_on) {
        cur_cnt = st.pit_lo + rnd() % st.pit_span;
        pit_set(cur_cnt);
        rtc_set(st.rtc);
    } else {
        pit_set(0);                      /* 65536: 55 ms watchdog tick */
    }
    if (mode == M_RM) {
        for (int i = 0; i < 32; i++) rmb[i] = 0;
        for (int i = 0; i < 8; i++) rmb[i] = init_r[i];
        rmb[4] = 0xFFF0;
        rmb[8] = fr.eflags & 0xFFFF; rmb[9] = entry16; rmb[10] = 0x2000; rmb[11] = 0x8000;
        rmb[12] = 0x4000; rmb[13] = 0x5000; rmb[14] = 0x6000; rmb[15] = 0x7000;
        rmb[23] = rnd(); rmb[24] = st.pit_lo; rmb[25] = st.pit_span;
        rmb[26] = stress_on ? 400000 : 150;      /* watchdog in IRQs (quiet: 55 ms ticks) */
        rmb[27] = stress_on;
        rm_chain0 = *(volatile u32 *)(0x08 * 4); rm_chain70 = *(volatile u32 *)(0x70 * 4);
        outb(0x21, stress_on && st.rtc ? 0xFA : 0xFE);
        outb(0xA1, stress_on && st.rtc ? 0xFE : 0xFF);
        run_real();
        outb(0x21, 0xFF); outb(0xA1, 0xFF);
        if (stress_on && st.rtc) rtc_set(0);
        n_irq = rmb[28]; n_step = rmb[21]; n_flt = rmb[22];
        if (rmb[16] != 1) rm_report();
        save_rm(&cur);
        return;
    }
    if (mode == M_V86) {
        fr.eflags |= VM;
        fr.eip = entry16; fr.cs = 0x2000;
        fr.esp = 0xFFF0; fr.ss = 0x8000;
        fr.ves = 0x5000; fr.vds = 0x4000; fr.vfs = 0x6000; fr.vgs = 0x7000;
    } else if (mode == M_P16) {
        fr.eip = entry16; fr.cs = 0x2003;
        fr.esp = 0xFFF0; fr.ss = 0x8003;
        fr.es = 0x5000; fr.ds = 0x4000; fr.fs = 0x6000; fr.gs = 0x7000;
    } else {
        fr.eip = *(volatile u32 *)(WL32 + 4 * w);
        fr.ds = fr.es = fr.gs = 0x23; fr.fs = 0x33;
        if (mode == M_R3) { fr.cs = 0x1B; fr.esp = W32_STK; fr.ss = 0x23; }
        else fr.cs = 0x08;
    }
    struct frame *f = &fr;
    if (mode == M_R0) {                  /* same privilege: the frame sits on the workload stack */
        f = (struct frame *)(W32_STK - 17 * 4);
        copyd((u32)f, (u32)&fr, 17);
    }
    outb(0x21, stress_on && st.rtc ? 0xFA : 0xFE);   /* IRQ0 (+ IRQ2 cascade) */
    outb(0xA1, stress_on && st.rtc ? 0xFE : 0xFF);   /* IRQ8 */
    run_t0 = ticks;
    run_frame(f);
    outb(0x21, 0xFF); outb(0xA1, 0xFF);
    if (stress_on && st.rtc) rtc_set(0);
    restore_pages();
}

/* ---------------------------------------------------------------- status */
static void status(void) {
    msgmode = 0;
    for (u32 t = 0; t < NT; t++) {
        attr = (t == cur_t) ? 0x0E : (cfg.tests >> t & 1) ? 0x07 : 0x08;
        at(3 + t % 10, (t / 10) * 40);
        puts_(tname[t / 4]); putc_('/'); dec(t & 3);
        puts_(" p "); dec(t_pass[t]); puts_(" i "); dec(t_irq[t]); puts_(" f "); dec(t_pf[t]); puts_("      ");
    }
    attr = 0x07; at(1, 0); puts_("seed "); dec(cur_seed); puts_("  pass "); dec(cur_k);
    puts_(em_on ? "  EM" : "    "); puts_(step_on ? " TF" : "   "); puts_("     ");
    msgmode = 1;
}

static void mismatch(void) {
    report_head("MISMATCH (stressed run differs from the quiet reference)");
    puts_("item     expected  actual\n");
    for (int i = 0; i < 8; i++) if (ref.r[i] != cur.r[i]) { puts_(rn[i]); puts_("      "); hex(ref.r[i], 8); puts_("  "); hex(cur.r[i], 8); putc_('\n'); }
    if (ref.fl != cur.fl) { puts_("EFLAGS   "); hex(ref.fl, 8); puts_("  "); hex(cur.fl, 8); putc_('\n'); }
    for (int i = 0; i < 6; i++) if (ref.sg[i] != cur.sg[i]) { puts_(sn[i]); puts_("       "); hex(ref.sg[i], 8); puts_("  "); hex(cur.sg[i], 8); putc_('\n'); }
    if (ref.steps != cur.steps) { puts_("steps    "); hex(ref.steps, 8); puts_("  "); hex(cur.steps, 8); putc_('\n'); }
    if (ref.nflt != cur.nflt) { puts_("faults   "); hex(ref.nflt, 8); puts_("  "); hex(cur.nflt, 8); putc_('\n'); }
    if (ref.dev != cur.dev) { puts_("io dev   "); hex(ref.dev, 8); puts_("  "); hex(cur.dev, 8); putc_('\n'); }
    int m16 = cur_mode == M_V86 || cur_mode == M_P16 || cur_mode == M_RM;
    u32 lo = m16 ? V86_LO : W32_LO, rf = m16 ? V86_REF : W32_REF, n = (m16 ? V86_SZ : W32_SZ) / 4;
    u32 shown = 0, total = 0;
    for (u32 i = 0; i < n; i++) {
        u32 e = ((volatile u32 *)rf)[i], a = ((volatile u32 *)lo)[i];
        if (e != a) {
            total++;
            if (shown < 6) { puts_("mem "); hex(lo + 4 * i, 6); puts_("  "); hex(e, 8); puts_("  "); hex(a, 8); putc_('\n'); shown++; }
        }
    }
    if (total) { puts_("differing dwords: "); dec(total); putc_('\n'); }
    report_hist();
    halt_all();
}

static void params(u32 k) {
    rs = mix(mix(cur_seed, cur_t), k + 1000);
    u32 x = rnd();
    u32 sel = cfg.pit_sel ? cfg.pit_sel - 1 : x % 3;
    if (sel == 0) { st.pit_lo = 100; st.pit_span = 300; }       /* 84-335 us */
    else if (sel == 1) { st.pit_lo = 300; st.pit_span = 2500; }
    else { st.pit_lo = 2000; st.pit_span = 12000; }
    x = rnd();
    st.rtc = (x & 3) ? 3 + (x >> 2) % 4 : 0;                    /* 8192 / 4096 / 2048 / 1024 Hz or off */
    x = rnd();
    static const u8 lv[4] = { 0, 16, 96, 255 };
    st.steal = lv[x & 3]; if (st.steal > cfg.steal_max) st.steal = cfg.steal_max;
    st.adclr = lv[(x >> 2) & 3];
    st.cr3 = (x >> 4) & 1 ? 32 : 0;
    st.wbinv = (x >> 5) & 1 ? 16 : 0;
    st.ide = (x >> 6) & 1 ? 4 : 0;                              /* a sector read in 4/256 IRQs */
    /* cfg.off: features switched off (bisecting a report) */
    if (cfg.off & 1) st.rtc = 0;
    if (cfg.off & 2) st.steal = 0;
    if (cfg.off & 4) st.adclr = 0;
    if (cfg.off & 8) st.cr3 = 0;
    if (cfg.off & 16) st.wbinv = 0;
    if (cfg.off & 32) st.ide = 0;
}

void kmain(void) {
    copyd(DISK, 0x10000, 0x30000 / 4);   /* the loaded image = LBA 1-384, before anything changes it */
    msgmode = 0; clr(0, 24); at(0, 0); attr = 0x1F;
    puts_(" Tetrium hwstress: V86 / R3 / R0 / P16 / RM workloads, IRQ + paging + fault stress   ");
    attr = 0x07;
    pic_init();
    rtc_set(0);
    outb(0x3F6, 0x02);                   /* IDE: no IRQ 14 (polled reads) */
    tables();
    /* IVT: V86 reflection (08 IRQ0, 70 RTC, 40-43 services), real-mode stubs, everything else
       to badvec */
    volatile u16 *ivt = (u16 *)0, *h16 = (u16 *)WL16;
    for (int v = 0; v < 256; v++) { ivt[2 * v] = h16[10]; ivt[2 * v + 1] = 0x2000; }
    ivt[2 * 0x08] = h16[4]; ivt[2 * 0x70] = h16[5];
    for (int i = 0; i < 4; i++) ivt[2 * (0x40 + i)] = h16[6 + i];
#define RMV(v, l) do { ivt[2 * (v)] = (u16)((u32)(l) - (u32)_start); ivt[2 * (v) + 1] = 0x1000; } while (0)
    RMV(0, rm_f0); RMV(1, rm_db); RMV(5, rm_f5); RMV(6, rm_f6); RMV(7, rm_f7); RMV(12, rm_f12); RMV(13, rm_f13);
    RMV(0x20, rm_irq0); RMV(0x27, rm_spur); RMV(0x28, rm_irq8); RMV(0x2F, rm_spur); RMV(0x31, rm_exit); RMV(0x32, rm_bad);
    at(14, 0); attr = 0x08;
    for (int c = 0; c < 80; c++) putc_(0xC4);
    attr = 0x07; msgmode = 1; at(15, 0);
    puts_("config: seed "); dec(cfg.seed); puts_(" tests "); hex(cfg.tests, 5); puts_(" passes "); dec(cfg.passes);
    puts_(" reps "); dec(cfg.reps); puts_(" stop "); dec(cfg.stop); putc_('\n');
    for (cur_seed = cfg.seed; !cfg.stop || cur_seed < cfg.seed + cfg.stop; cur_seed++) {
        for (cur_t = 0; cur_t < NT; cur_t++) {
            if (!(cfg.tests >> cur_t & 1)) continue;
            cur_mode = cur_t / 4;
            int m16 = cur_mode == M_V86 || cur_mode == M_P16 || cur_mode == M_RM;
            cand_set(cur_mode);
            rs = mix(cur_seed, 0x1234 + m16);
            u32 pri = m16 ? V86_PRI : W32_PRI, n = (m16 ? V86_SZ : W32_SZ) / 4;
            for (u32 i = 0; i < n; i++) ((volatile u32 *)pri)[i] = rnd();
            rs = mix(cur_seed, cur_t);
            for (int i = 0; i < 8; i++) init_r[i] = rnd();
            init_fl = rnd();
            u32 x = rnd();
            em_on = (x & 1) && !(cfg.off & 128);   /* ESC: #NM (EM) or no-op */
            step_on = (x >> 1) % 6 == 0;         /* single-step every instruction */
            cur_k = 0;
            status();
            run(cur_t, 0);
            ref = cur;
            copyd(m16 ? V86_REF : W32_REF, m16 ? V86_LO : W32_LO, n);
            for (cur_k = 1; cur_k <= cfg.passes; cur_k++) {
                if (cur_seed == cfg.seed && cur_k < cfg.first) continue;   /* replay: start at pass 'first' */
                params(cur_k);
                run(cur_t, 1);
                t_pass[cur_t]++; t_irq[cur_t] += n_irq; t_pf[cur_t] += n_pf;
                int bad = 0;
                for (int i = 0; i < 8; i++) bad |= ref.r[i] != cur.r[i];
                for (int i = 0; i < 6; i++) bad |= ref.sg[i] != cur.sg[i];
                bad |= ref.fl != cur.fl || ref.steps != cur.steps || ref.nflt != cur.nflt || ref.dev != cur.dev;
                if (!bad) bad = cmpd(m16 ? V86_LO : W32_LO, m16 ? V86_REF : W32_REF, n) != n;
                if (bad) mismatch();
                status();
            }
        }
        puts_("seed "); dec(cur_seed); puts_(" OK\n");
    }
    msgmode = 0; status(); at(15, 0); attr = 0x2F; puts_(" ALL PASSED "); attr = 0x07;
    outb(0x80, 0xAA);
    for (;;) __asm__ volatile("cli; hlt");
}
