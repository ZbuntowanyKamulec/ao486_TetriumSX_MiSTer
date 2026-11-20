// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* x86ref: lockstep reference model built from the 86Box interpreter.
 * See x86ref.h.  Machine-level dependencies are in stubs.c. */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#define HAVE_STDARG_H
#include <86box/86box.h>
#include "cpu.h"
#include "x86.h"
#include "x86_flags.h"
#include "x86seg_common.h"
#include "x86seg.h"
#include <86box/mem.h>
#include <86box/io.h>
#include <86box/nmi.h>
#include <86box/timer.h>
#include <86box/machine.h>
#include "386_common.h"
#include "x86ref.h"

/* shared with stubs.c */
ref_io_t ref_io;
int      ref_irq_pending = 0, ref_irq_vector = 0;

extern int fpu_type, machine, cpu, cpu_use_dynarec;
extern uint32_t mem_size;
extern int cpu_debug_regs_486;

/* processor configuration (ref_config): reset EDX, CPUID, debug registers */
static uint32_t ref_sig = 0x420;
static int      ref_cpuid = 0;
static void
ref_apply_cfg(void)
{
    CPUID = ref_cpuid ? ref_sig : 0;
    EDX   = ref_sig;
}
void
ref_config(uint32_t sig, int has_cpuid, int debug_regs)
{
    ref_sig            = sig;
    ref_cpuid          = has_cpuid;
    cpu_debug_regs_486 = debug_regs;
    resetx86();
    ref_apply_cfg();
}

/* the BIOS alias at the top of the address space (FFFE0000-FFFFFFFF = E0000-FFFFF, read
   only), where the i486 starts after reset */
static mem_mapping_t rom_alias_mapping;
static uint8_t
rom_rb(uint32_t addr, void *priv)
{
    (void) priv;
    return ram[0xe0000 + (addr & 0x1ffff)];
}
static uint16_t
rom_rw(uint32_t addr, void *priv)
{
    return rom_rb(addr, priv) | (rom_rb(addr + 1, priv) << 8);
}
static uint32_t
rom_rl(uint32_t addr, void *priv)
{
    return rom_rw(addr, priv) | ((uint32_t) rom_rw(addr + 2, priv) << 16);
}

/* ------------------------------------------------------------ write log */
#define WLOG_MAX (1 << 20)
static ref_wr_t wlog[WLOG_MAX];
static uint8_t  wlog_old[WLOG_MAX];    /* the byte overwritten (undo of a step) */
static int      wlog_n;

static inline void
wr8(uint32_t addr, uint8_t val)
{
    if (wlog_n < WLOG_MAX) {
        wlog[wlog_n].addr  = addr;
        wlog[wlog_n].val   = val;
        wlog_old[wlog_n++] = ram[addr];
    }
    ram[addr] = val;
}
/* RAM write handlers that never enter the write lookup cache, so every
   store of the interpreter comes through here */
static void
ref_wb(uint32_t addr, uint8_t val, void *priv)
{
    (void) priv;
    wr8(addr, val);
}
static void
ref_ww(uint32_t addr, uint16_t val, void *priv)
{
    (void) priv;
    wr8(addr, val & 0xff);
    wr8(addr + 1, val >> 8);
}
static void
ref_wl(uint32_t addr, uint32_t val, void *priv)
{
    (void) priv;
    for (int i = 0; i < 4; i++)
        wr8(addr + i, (val >> (8 * i)) & 0xff);
}

/* the model's accessed / dirty bit updates go to the write log too */
extern void (*mmu_ad_hook)(uint32_t addr, uint32_t val);
static void
ref_ad(uint32_t addr, uint32_t val)
{
    for (int i = 0; i < 4; i++)
        wr8(addr + i, (val >> (8 * i)) & 0xff);
}

const ref_wr_t *
ref_wlog(int *n)
{
    *n = wlog_n;
    return wlog;
}
void
ref_wlog_clear(void)
{
    wlog_n = 0;
}

/* ------------------------------------------------------------ init */
int
ref_init(uint32_t mem_kb, const ref_io_t *io)
{
    if (io)
        ref_io = *io;
    machine         = 0;
    mem_size        = mem_kb;
    fpu_type        = FPU_NONE;
    cpu_use_dynarec = 0;
    cpu             = 0;
    cpu_f           = cpu_get_family("i486sx");
    if (cpu_f == NULL)
        return -1;

    mem_init();
    cpu_set();
    mem_reset();
    /* A0000-FFFFF is plain RAM too (86Box leaves it to the machine's ROM / shadow setup) */
    mem_set_mem_state_both(0xa0000, 0x60000, MEM_READ_INTERNAL | MEM_WRITE_INTERNAL);
    mem_mapping_set_write_handler(&ram_low_mapping, ref_wb, ref_ww, ref_wl);
    mem_mapping_set_write_handler(&ram_mid_mapping, ref_wb, ref_ww, ref_wl);
    mem_mapping_set_write_handler(&ram_high_mapping, ref_wb, ref_ww, ref_wl);
    mmu_ad_hook = ref_ad;
    mem_mapping_add(&rom_alias_mapping, 0xfffe0000, 0x20000, rom_rb, rom_rw, rom_rl,
                    NULL, NULL, NULL, ram + 0xe0000, MEM_MAPPING_EXTERNAL, NULL);
    ref_reset();
    return 0;
}

void
ref_reset(void)
{
    resetx86();
    ref_apply_cfg();
    /* A20 enabled: the full address space */
    mem_a20_key = 2;
    mem_a20_alt = 0;
    mem_a20_recalc();
    flushmmucache();
    wlog_n          = 0;
    ref_irq_pending = 0;
}

void
ref_set_a20(int on)
{
    mem_a20_key = on ? 2 : 0;
    mem_a20_alt = 0;
    mem_a20_recalc();
    flushmmucache();
}

uint8_t *
ref_ram(void)
{
    return ram;
}
uint32_t
ref_ram_size(void)
{
    return mem_size * 1024u;
}

/* ------------------------------------------------------------ state */
static x86seg *const segp[REF_NSEG] = {
    &cpu_state.seg_es, &cpu_state.seg_cs, &cpu_state.seg_ss,
    &cpu_state.seg_ds, &cpu_state.seg_fs, &cpu_state.seg_gs
};
static void
seg_get(ref_seg_t *d, const x86seg *s)
{
    d->sel   = s->seg;
    d->base  = s->base;
    d->limit = s->limit;
    d->attr  = (uint16_t) (s->access | ((s->ar_high & 0xf0) << 4));
}

void
ref_get_dr(uint32_t d[8])
{
    for (int i = 0; i < 8; i++)
        d[i] = dr[i];
}

void
ref_get(ref_state_t *s)
{
    flags_rebuild();
    for (int i = 0; i < 8; i++)
        s->gpr[i] = cpu_state.regs[i].l;
    s->eip    = cpu_state.pc;
    s->eflags = cpu_state.flags | ((uint32_t) cpu_state.eflags << 16);
    for (int i = 0; i < REF_NSEG; i++)
        seg_get(&s->seg[i], segp[i]);
    seg_get(&s->ldtr, &ldt);
    seg_get(&s->tr, &tr);
    s->gdt_base  = gdt.base;
    s->gdt_limit = gdt.limit;
    s->idt_base  = idt.base;
    s->idt_limit = idt.limit;
    s->creg0     = cr0;
    s->creg2     = cr2;
    s->creg3     = cr3;
}

void
ref_set(const ref_state_t *s, int real)
{
    for (int i = 0; i < 8; i++)
        cpu_state.regs[i].l = s->gpr[i];
    cpu_state.flags  = (uint16_t) (s->eflags | 2);
    cpu_state.eflags = (uint16_t) (s->eflags >> 16);
    flags_extract();
    if (real) {
        /* real-mode segment loads (CR0.PE must be clear) */
        loadcs(s->seg[REF_CS].sel);
        for (int i = 0; i < REF_NSEG; i++)
            if (i != REF_CS)
                loadseg(s->seg[i].sel, segp[i]);
    } else {
        for (int i = 0; i < REF_NSEG; i++) {
            x86seg *d  = segp[i];
            d->seg     = s->seg[i].sel;
            d->base    = s->seg[i].base;
            d->limit   = s->seg[i].limit;
            d->access  = (uint8_t) s->seg[i].attr;
            d->ar_high = (uint8_t) ((s->seg[i].attr >> 4) & 0xf0);
            d->limit_low  = 0;
            d->limit_high = s->seg[i].limit;
            d->checked    = 1;
        }
    }
    cpu_state.pc = s->eip;
    flushmmucache();
}

void
ref_set_csbase(uint32_t base)
{
    cpu_state.seg_cs.base = base;
    flushmmucache();
}

void
ref_set_sys(uint32_t cr0v, uint32_t cr2v, uint32_t cr3v, uint32_t gdtb, uint32_t gdtl, uint32_t idtb, uint32_t idtl)
{
    cr0       = cr0v;
    cr2       = cr2v;
    cr3       = cr3v;
    gdt.base  = gdtb;
    gdt.limit = gdtl;
    idt.base  = idtb;
    idt.limit = idtl;
    flushmmucache();
}

void
ref_set_flags(uint32_t mask, uint32_t val)
{
    uint32_t f;
    flags_rebuild();
    f                = cpu_state.flags | ((uint32_t) cpu_state.eflags << 16);
    f                = (f & ~mask) | (val & mask);
    cpu_state.flags  = (uint16_t) f;
    cpu_state.eflags = (uint16_t) (f >> 16);
    flags_extract();
}

/* ------------------------------------------------------------ execution */
/* one pass of the interpreter loop: the debugger hook in stubs.c makes
   exec386() return after every instruction */
static void
run_one(void)
{
    cycles       = 0;
    timer_target = tsc + 0x40000000ull;
    exec386(1000000);
}

uint64_t
ref_cycles(void)
{
    return tsc;
}

/* physical address of an instruction byte (the prefix / opcode scans below): with
   paging through the model's page tables (no faults, no A/D updates) */
static uint32_t
lin2phys(uint32_t lin)
{
    uint64_t p;
    if (!(cr0 >> 31))
        return lin;
    p = mmutranslate_noabrt(lin, 0);
    return (p == 0xffffffffffffffffULL) ? lin : (uint32_t) p;
}

/* does the instruction at CS:pc carry a REP prefix? */
static int
has_rep(uint32_t lin)
{
    for (int i = 0; i < 14; i++) {
        uint8_t b = ram[(lin + i) & rammask & (mem_size * 1024u - 1)];
        switch (b) {
            case 0xf2:
            case 0xf3:
                return 1;
            case 0x26:
            case 0x2e:
            case 0x36:
            case 0x3e:
            case 0x64:
            case 0x65:
            case 0x66:
            case 0x67:
            case 0xf0:
                break;
            default:
                return 0;
        }
    }
    return 0;
}

/* ---- control transfers beyond the code segment limit
   86Box loads such an EIP and faults at the target's fetch.  A 486 raises #GP(0)
   at the transferring instruction, before any of its effects ("IF tempEIP is not
   within code segment limit THEN #GP(0)", SDM Vol. 2 JMP / CALL / RET / Jcc / IRET):
   ref_step() undoes such a step and delivers the #GP at the instruction.  INT n and
   exceptions are checked in pmodeint() (x86seg.c, tb/x86ref/86box-486.patch). */
static int
is_xfer(uint32_t lin)
{
    uint32_t msk = rammask & (mem_size * 1024u - 1);
    for (int i = 0; i < 14; i++) {
        uint8_t b = ram[(lin + i) & msk], m;
        switch (b) {
            case 0x26: case 0x2e: case 0x36: case 0x3e: case 0x64: case 0x65:
            case 0x66: case 0x67: case 0xf0: case 0xf2: case 0xf3:
                continue;
            case 0x0f:
                b = ram[(lin + i + 1) & msk];
                return (b >= 0x80) && (b <= 0x8f);
            case 0xff:
                m = (ram[(lin + i + 1) & msk] >> 3) & 7;
                return (m >= 2) && (m <= 5);
            default:
                return ((b >= 0x70) && (b <= 0x7f)) || ((b >= 0xe0) && (b <= 0xe3)) || (b == 0xe8) ||
                       (b == 0xe9) || (b == 0xea) || (b == 0xeb) || (b == 0x9a) || (b == 0xc2) ||
                       (b == 0xc3) || (b == 0xca) || (b == 0xcb) || (b == 0xcf);
        }
    }
    return 0;
}
static struct {
    cpu_state_t st;
    uint32_t    use32;
    int         stack32, oldcpl, optype;
    uint16_t    oldcs, cur_status;
} snap;
static void
snap_take(void)
{
    flags_rebuild();
    snap.st         = cpu_state;
    snap.use32      = use32;
    snap.stack32    = stack32;
    snap.oldcpl     = oldcpl;
    snap.optype     = optype;
    snap.oldcs      = oldcs;
    snap.cur_status = cpu_cur_status;
}
/* undo the step (registers and the memory written since log entry w0), then
   deliver #GP(0) at the instruction as exec386 does for a faulting one */
static void
xfer_fault(int w0)
{
    int a;
    for (int i = wlog_n - 1; i >= w0; i--)
        ram[wlog[i].addr] = wlog_old[i];
    wlog_n         = w0;
    cpu_state      = snap.st;
    use32          = snap.use32;
    stack32        = snap.stack32;
    oldcpl         = snap.oldcpl;
    optype         = snap.optype;
    oldcs          = CS;
    cpu_cur_status = snap.cur_status;
    flushmmucache();
    cpu_state.oldpc = cpu_state.pc;
    x86gpf(NULL, 0);
    a              = cpu_state.abrt & ABRT_MASK;
    cpu_state.abrt = 0;
    x86_doabrt(a);
    if (cpu_state.abrt) {
        int second     = cpu_state.abrt & ABRT_MASK;
        cpu_state.abrt = 0;
        cpu_state.pc   = cpu_state.oldpc;
        x86_fault_in_delivery(a, second);
        if (cpu_state.abrt) {
            cpu_state.abrt = 0;
            softresetx86();
            ref_apply_cfg();
        }
    }
}

int
ref_step(void)
{
    int      r    = 0;
    uint32_t pc0  = cpu_state.pc;
    uint16_t cs0  = CS;
    int      trp  = !!(cpu_state.flags & T_FLAG);
    /* (the scans read the instruction through the page tables, lin2phys) */
    uint32_t ph0  = lin2phys(cs + pc0);
    int      rep  = has_rep(ph0);
    int      hlt0 = (ram[ph0 & rammask & (mem_size * 1024u - 1)] == 0xf4);

    int      xfer = is_xfer(ph0);
    int      w0   = wlog_n;

    if (xfer)
        snap_take();
    x86_was_reset = 0;
    run_one();
    /* (a delivered fault leaves EIP at its handler, inside the limit) */
    if (xfer && !x86_was_reset && (cpu_state.pc > cpu_state.seg_cs.limit_high))
        xfer_fault(w0);
    if (rep && !trp) {
        /* a REP string instruction yields with pc at its start while the
           count is non-zero: run it to completion */
        int guard = 1 << 24;
        while (cpu_state.pc == pc0 && CS == cs0 && !x86_was_reset && --guard)
            run_one();
    }
    if (x86_was_reset)
        r |= REF_STEP_RESET;
    if (hlt0 && cpu_state.pc == pc0 && CS == cs0)
        r |= REF_STEP_HALT;
    if (trp)
        r |= REF_STEP_FAULT;
    return r;
}

int
ref_step_rep_partial(uint32_t remaining)
{
    uint32_t pc0   = cpu_state.pc;
    uint32_t lin   = cs + pc0;
    uint32_t msk   = mem_size * 1024u - 1;
    int      a32   = !!use32;
    uint32_t cnt, done;

    lin = lin2phys(lin);
    if (!has_rep(lin))
        return 0;
    for (int i = 0; i < 14; i++) {      /* address-size prefix among the prefixes */
        uint8_t b = ram[(lin + i) & rammask & msk];
        if (b == 0x67)
            a32 = !a32;
        else if (!(b == 0xf2 || b == 0xf3 || b == 0x26 || b == 0x2e || b == 0x36 || b == 0x3e ||
                   b == 0x64 || b == 0x65 || b == 0x66 || b == 0xf0))
            break;
    }
    cnt = a32 ? ECX : CX;
    if (remaining >= cnt)
        return 1;                       /* nothing done yet */
    done = cnt - remaining;
    if (a32)
        ECX = done;
    else
        CX = (uint16_t) done;
    ref_step();                         /* runs 'done' iterations, EIP moves past */
    if (a32)
        ECX = remaining;
    else
        CX = (uint16_t) remaining;
    cpu_state.pc = pc0;
    return 1;
}

/* external interrupt at an instruction boundary: the delivery part of
   exec386_common() */
void
ref_interrupt(int vector)
{
    uint32_t addr;

    flags_rebuild();
    oldcs           = CS;
    cpu_state.oldpc = cpu_state.pc;
    if (msw & 1)
        pmodeint(vector, 0);
    else if ((vector << 2UL) + 3UL > idt.limit) {
        x86_int(0x08);
    } else {
        if (stack32) {
            writememw(ss, ESP - 2, cpu_state.flags);
            writememw(ss, ESP - 4, CS);
            writememw(ss, ESP - 6, cpu_state.pc);
            ESP -= 6;
        } else {
            writememw(ss, (SP - 2) & 0xFFFF, cpu_state.flags);
            writememw(ss, (SP - 4) & 0xFFFF, CS);
            writememw(ss, (SP - 6) & 0xFFFF, cpu_state.pc);
            SP -= 6;
        }
        addr = (vector << 2) + idt.base;
        cpu_state.flags &= ~I_FLAG;
        cpu_state.flags &= ~T_FLAG;
        cpu_state.pc = readmemw(0, addr);
        loadcs(readmemw(0, addr + 2));
    }
    if (cpu_state.abrt) {
        int a          = cpu_state.abrt & ABRT_MASK;
        cpu_state.abrt = 0;
        x86_doabrt(a);
    }
    cpu_debug_trap_after_delivery();
}

void
ref_nmi(void)
{
    flags_rebuild();
    oldcs           = CS;
    cpu_state.oldpc = cpu_state.pc;
    x86_int(2);
    cpu_debug_trap_after_delivery();
}
