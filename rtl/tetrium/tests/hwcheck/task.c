// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* Task switches: CALL / JMP to a TSS and through task gates, INT and exceptions (with an error
 * code, double fault) through IDT task gates, the state loaded and saved, NT / TS / busy bits /
 * back link, the return by IRET, and the faults of a switch. */
#include "kern.h"

#define CODE_OFF 0x100u
#define LAND_OFF 0x300u
#define S_TG 0xE0u                          /* task gate */
#define S_BAD 0xE8u
#define TSTK (U_STK + 0x1000u)
#define USTK (U_STK + 0x1E00u)

static struct frame f;
static u8 *code;
static u32 cp, done_eip, start_fl, regs0[8], trv;
static const char *what;
static int h_stop(struct frame *x) { (void)x; return 1; }
static void e1(u32 v) { code[cp++] = v; }
static void e2(u32 v) { e1(v); e1(v >> 8); }
static void e4(u32 v) { e2(v); e2(v >> 16); }
static void bad(const char *s, u32 a, u32 b) {
    if (fail_begin(s)) pf("%s: %x expected %x (vec %x err %x cs %x eip %x)\n", what, a, b, fin.vec, fin.err, fin.cs, fin.eip - U_CODE);
}
static void chk(const char *s, u32 a, u32 b) { if (a != b) bad(s, a, b); }
static u32 busy(u32 sel) { return gdt[(sel >> 3) * 2 + 1] >> 9 & 1; }
static u32 str(void) { u32 v; __asm__ volatile("xor %0, %0; str %w0" : "=r"(v)); return v; }

static void tss2_init(void) {
    for (u32 i = 0; i < 26; i++) tss2[i] = 0xEE000000 + i;
    tss2[1] = (u32)istack_top; tss2[2] = S_KD;
    tss2[7] = P_PDU; tss2[8] = U_CODE + LAND_OFF; tss2[9] = 2 | 0x3000 | (rnd() & 0xCD5);
    for (u32 i = 10; i < 18; i++) tss2[i] = rnd();
    tss2[14] = TSTK;
    tss2[18] = S_UD; tss2[19] = S_UC; tss2[20] = S_UD; tss2[21] = S_UD; tss2[22] = S_URO; tss2[23] = 0;
    tss2[24] = 0; tss2[25] = 0x68u << 16;
    desc(gdt, S_TSS2, (u32)tss2, 0x67, 0xE9, 0);
    desc(gdt, S_TSS, (u32)tss1, 0x68 + 8192, 0x8B, 0);
    u32 *g = gdt + (S_TG >> 3) * 2;
    g[0] = S_TSS2 << 16; g[1] = 0xE500;
    tss1[7] = P_PDU; tss1[24] = 0;
    for (u32 i = 8; i < 24; i++) tss1[i] = 0xDD000000 + i;
    wr_cr0(rd_cr0() & ~8u);
}
static void recover(void) {                 /* back to TSS 1 whatever happened */
    __asm__ volatile("pushfl; andl $0xFFFFBFFF, (%%esp); popfl" ::: "cc", "memory");
    desc(gdt, S_TSS, (u32)tss1, 0x68 + 8192, 0x89, 0);
    desc(gdt, S_TSS2, (u32)tss2, 0x67, 0xE9, 0);
    __asm__ volatile("ltr %%ax" :: "a"(S_TSS));
    __asm__ volatile("lldt %%ax" :: "a"(0));
    wr_cr0(rd_cr0() & ~8u);
    tss1[1] = (u32)istack_top; tss1[2] = S_KD;
}
static void start(void) {
    e1(0xCD); e1(0x85);
    done_eip = U_CODE + cp;
    for (u32 i = 0; i < sizeof f / 4; i++) ((u32 *)&f)[i] = 0;
    for (u32 i = 0; i < 8; i++) regs0[i] = rnd();
    regs0[0] = 0x1FF8;                      /* AX: a selector beyond the GDT (the faulting runs) */
    f.eax = regs0[0]; f.ecx = regs0[1]; f.edx = regs0[2]; f.ebx = regs0[3]; f.ebp = regs0[5]; f.esi = regs0[6]; f.edi = regs0[7];
    f.eip = U_CODE + CODE_OFF; f.cs = S_UC; f.eflags = start_fl = 2 | 0x3000 | (rnd() & 0xCD5);
    f.esp = USTK; f.ss = S_UD; f.ds = S_UD; f.es = S_UD; f.fs = S_URO; f.gs = S_UD;
    wr_cr3(P_PDU);
    go(&f, h_stop);
    trv = str();
}
/* the state right after the switch into task 2 (its landing INT 85h), and what was saved */
static void check_in(u32 nested, u32 errc, u32 eip) {
    chk("landing vector", fin.vec, 0x85);
    if (fin.vec != 0x85) return;
    u32 r[8] = { fin.eax, fin.ecx, fin.edx, fin.ebx, fin.esp, fin.ebp, fin.esi, fin.edi };
    for (u32 i = 0; i < 8; i++) chk("register of the new task", r[i], tss2[10 + i] - (i == 4 && errc ? 4 : 0));
    chk("flags of the new task", fin.eflags & 0x37FD7, (tss2[9] & 0x37FD7) | (nested ? NTL : 0));
    chk("CS", fin.cs, tss2[19]); chk("SS", fin.ss, tss2[20]);
    chk("DS", fin.ds & 0xFFFF, tss2[21]); chk("ES", fin.es & 0xFFFF, tss2[18]);
    chk("FS", fin.fs & 0xFFFF, tss2[22]); chk("GS", fin.gs & 0xFFFF, tss2[23]);
    chk("TR", trv & 0xFFF8, S_TSS2);
    chk("CR0.TS", rd_cr0() & 8, 8);
    chk("busy bit of the new TSS", busy(S_TSS2), 1);
    chk("busy bit of the old TSS", busy(S_TSS), nested);
    chk("back link", tss2[0] & 0xFFFF, nested ? S_TSS : 0);
    /* the old task's state */
    chk("saved EIP", tss1[8], eip);
    u32 w[8] = { regs0[0], regs0[1], regs0[2], regs0[3], USTK, regs0[5], regs0[6], regs0[7] };
    for (u32 i = 0; i < 8; i++) chk("saved register", tss1[10 + i], w[i]);
    chk("saved flags", tss1[9] & 0x7FD7, start_fl & 0x7FD7);
    chk("saved CS", tss1[19] & 0xFFFF, S_UC); chk("saved SS", tss1[20] & 0xFFFF, S_UD);
    chk("saved DS", tss1[21] & 0xFFFF, S_UD); chk("saved FS", tss1[22] & 0xFFFF, S_URO);
    chk("CR3 field of the old TSS", tss1[7], P_PDU);
}
static void check_back(u32 eip2) {
    trv = str();
    chk("return: vector", fin.vec, 0x85);
    if (fin.vec != 0x85) return;
    chk("return: EIP", fin.eip, done_eip);
    u32 r[8] = { fin.eax, fin.ecx, fin.edx, fin.ebx, fin.esp, fin.ebp, fin.esi, fin.edi };
    u32 w[8] = { regs0[0], regs0[1], regs0[2], regs0[3], USTK, regs0[5], regs0[6], regs0[7] };
    for (u32 i = 0; i < 8; i++) chk("return: register", r[i], w[i]);
    chk("return: flags", fin.eflags & 0x7FD7, start_fl & 0x7FD7);
    chk("return: TR", trv, S_TSS);
    chk("return: busy bit of the left TSS", busy(S_TSS2), 0);
    chk("return: busy bit of the TSS", busy(S_TSS), 1);
    chk("return: FS", fin.fs & 0xFFFF, S_URO);
    chk("return: NT of the left task", tss2[9] & NTL, 0);
    if (eip2) chk("return: saved EIP of the left task", tss2[8], eip2);
}
static void land(u32 pop) {
    u32 q = LAND_OFF;
    code[q++] = 0xCD; code[q++] = 0x85;
    if (pop) { code[q++] = 0x83; code[q++] = 0xC4; code[q++] = 4; }
    code[q++] = 0xCF;                       /* IRET: back through the link */
    code[q++] = 0xCD; code[q++] = 0x85;
}
static void ret_to_old(u32 pop) {           /* on from the landing: IRET with NT */
    f = fin;
    wr_cr0(rd_cr0() & ~8u);
    go(&f, h_stop);
    check_back(U_CODE + LAND_OFF + 2 + (pop ? 3 : 0) + 1);
}
static void t_switch(u32 k) {
    static const char *n[6] = { "call tss", "jmp tss", "call task gate", "jmp task gate", "int task gate", "call m:tss" };
    what = n[k];
    tss2_init();
    land(0);
    cp = CODE_OFF;
    u32 nested = 1;
    switch (k) {
    case 0: e1(0x9A); e4(0x12345678); e2(S_TSS2 | 3); break;
    case 1: e1(0xEA); e4(0x12345678); e2(S_TSS2 | 3); nested = 0; break;
    case 2: e1(0x9A); e4(0); e2(S_TG | 3); break;
    case 3: e1(0xEA); e4(0); e2(S_TG | 3); nested = 0; break;
    case 4: idt[0x8C * 2] = S_TSS2 << 16; idt[0x8C * 2 + 1] = 0xE500; e1(0xCD); e1(0x8C); break;
    case 5: e1(0xFF); e1(0x1D); e4(U_CODE + 0x400); *(u32 *)(code + 0x400) = 0; *(u32 *)(code + 0x404) = S_TSS2; break;
    }
    u32 eip = U_CODE + cp;
    start();
    check_in(nested, 0, eip);
    if (nested && fin.vec == 0x85) ret_to_old(0);
    recover();
}
/* exceptions through a task gate: #GP with an error code; a double fault */
static void t_exc(u32 df) {
    what = df ? "#DF task gate" : "#GP task gate";
    tss2_init();
    land(1);
    cp = CODE_OFF;
    u32 g0 = idt[26], g1 = idt[27], d0 = idt[16], d1 = idt[17];
    if (df) { idt[27] &= ~0x8000u; idt[16] = S_TSS2 << 16; idt[17] = 0x8500; }     /* #GP gate not present: #NP -> #DF */
    else { idt[26] = S_TSS2 << 16; idt[27] = 0x8500; }
    e1(0x8E); e1(0xD8);                     /* mov ds, ax (1FF8) */
    start();
    idt[26] = g0; idt[27] = g1; idt[16] = d0; idt[17] = d1;
    check_in(1, 1, U_CODE + CODE_OFF);
    if (fin.vec == 0x85) {
        chk("error code", *(volatile u32 *)V(P_STK + fin.esp - U_STK), df ? 0 : 0x1FF8);
        if (!df) chk("RF of the saved flags", tss1[9] & RFL, RFL);
        tss1[8] += 2; tss1[9] &= ~RFL;      /* skip the instruction */
        ret_to_old(1);
    }
    recover();
}
/* faults of the switch itself */
static void t_bad(u32 k) {
    static const char *n[] = { "TSS not present", "TSS limit", "TSS type", "bad DS", "DS not present", "bad SS", "SS not present",
                               "bad CS", "CS not present", "bad LDT", "ES: code not readable", "SS RPL" };
    u32 v = 0, e = 0, old = 0;
    what = n[k];
    tss2_init();
    land(0);
    desc(gdt, S_BAD, 0, 0xFFFFF, 0x73, 0xC);                   /* not-present data DPL 3 */
    switch (k) {
    case 0: gdt[(S_TSS2 >> 3) * 2 + 1] &= ~0x8000u; v = 11; e = S_TSS2; old = 1; break;
    case 1: desc(gdt, S_TSS2, (u32)tss2, 0x66, 0xE9, 0); v = 10; e = S_TSS2; old = 1; break;
    case 2: desc(gdt, S_TSS2, (u32)tss2, 0x67, 0xEA, 0); v = 13; e = S_TSS2; old = 1; break;
    case 3: tss2[21] = 0x1FF8; v = 10; e = 0x1FF8; break;
    case 4: tss2[21] = S_BAD | 3; v = 11; e = S_BAD; break;
    case 5: tss2[20] = 0x1FFB; v = 10; e = 0x1FF8; break;
    case 6: tss2[20] = S_BAD | 3; v = 12; e = S_BAD; break;
    case 7: tss2[19] = S_UD; v = 10; e = S_UD & ~3; break;
    case 8: desc(gdt, S_BAD, 0, 0xFFFFF, 0x7B, 0xC); tss2[19] = S_BAD | 3; v = 11; e = S_BAD; break;
    case 9: tss2[24] = S_UD & ~3; v = 10; e = S_UD & ~3; break;
    case 10: desc(gdt, S_BAD, 0, 0xFFFFF, 0xF9, 0xC); tss2[18] = S_BAD | 3; v = 10; e = S_BAD; break;
    case 11: tss2[20] = S_UD & ~3; v = 10; e = S_UD & ~3; break;
    }
    cp = CODE_OFF;
    e1(0xEA); e4(0); e2(S_TSS2 | 3);        /* JMP */
    start();
    chk("switch fault: vector", fin.vec, v);
    chk("switch fault: error code", fin.err & 0xFFFE, e);
    if (old) {
        chk("switch fault: EIP", fin.eip, U_CODE + CODE_OFF);
        chk("switch fault: TR", trv, S_TSS);
        chk("switch fault: busy bit", busy(S_TSS), 1);
    } else {
        chk("switch fault: TR", trv & 0xFFF8, S_TSS2);
        if (k != 7 && k != 8 && k != 9) chk("switch fault: EIP", fin.eip, U_CODE + LAND_OFF);
        chk("switch fault: saved EIP", tss1[8], U_CODE + CODE_OFF + 7);
        chk("switch fault: busy bit", busy(S_TSS2), 1);
    }
    recover();
    desc(gdt, S_BAD, 0, 0, 0, 0);
}
void s_task(u32 round) {
    filld(V(P_PDU), 0, 1024);
    filld(V(P_SPT), 0, 1024);
    PTE(P_PDU, 768) = P_PT0 | 3;
    PTE(P_PDU, U_BASE >> 22) = P_SPT | 7;
    for (u32 i = 0; i < 8; i++) PTE(P_SPT, 0x50 + i) = (P_CODE + i * 0x1000) | 0x67;
    for (u32 i = 0; i < 2; i++) PTE(P_SPT, 0x60 + i) = (P_STK + i * 0x1000) | 0x67;
    code = (u8 *)V(P_CODE);
    u32 n = cfg.tb ? 1 : 50;
    (void)round;
    while (n--) {
        for (u32 k = 0; k < 6; k++) t_switch(k);
        t_exc(0); t_exc(1);
        for (u32 k = 0; k < 12; k++) if (k != 9 || !cfg.tb) t_bad(k);       /* (LDTR after a bad LDT: 86Box has its selector) */
    }
    gate(0x8C, S_KC, (u32)isr_stubs + 0x8C * 16, 0xEE);
    tss1[7] = P_PDK;
}
