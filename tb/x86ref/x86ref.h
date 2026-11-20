// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* x86ref: the 86Box interpreter (i486SX, no FPU, no dynarec) as a lockstep
 * reference model for the Tetrium testbench.
 *
 * The model owns a flat RAM (ref_ram()).  The testbench loads the same image
 * into the DUT's memory, then calls ref_step() once per instruction retired
 * by the DUT and compares architectural state.  External events are replayed
 * from the DUT: IN data through the io callbacks, interrupts with
 * ref_interrupt().
 *
 * 86Box is GPL-2.0-or-later: this library is linked into the simulation
 * testbench only, never into the RTL.
 */
#ifndef X86REF_H
#define X86REF_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum { REF_ES, REF_CS, REF_SS, REF_DS, REF_FS, REF_GS, REF_NSEG };
/* gpr order as in the instruction encoding: AX CX DX BX SP BP SI DI */

typedef struct {
    uint16_t sel;
    uint32_t base;
    uint32_t limit;     /* highest valid offset (expand-up) */
    uint16_t attr;      /* access byte [7:0], G/D/AVL nibble in [11:8] */
} ref_seg_t;

typedef struct {
    uint32_t  gpr[8];
    uint32_t  eip;
    uint32_t  eflags;
    ref_seg_t seg[REF_NSEG];
    ref_seg_t ldtr, tr;
    uint32_t  gdt_base, gdt_limit, idt_base, idt_limit;
    uint32_t  creg0, creg2, creg3;     /* CR0, CR2, CR3 (86Box defines cr0 as a macro) */
} ref_state_t;

/* one byte written to memory by the model (physical address) */
typedef struct {
    uint32_t addr;
    uint8_t  val;
} ref_wr_t;

/* I/O callbacks (set before running; NULL = reads return all ones) */
typedef struct {
    uint32_t (*in)(uint16_t port, int size);                 /* size 1/2/4 */
    void     (*out)(uint16_t port, int size, uint32_t val);
} ref_io_t;

int      ref_init(uint32_t mem_kb, const ref_io_t *io);      /* 0 = ok */
void     ref_reset(void);                                    /* CPU hard reset */
/* the processor: reset EDX (signature), CPUID present (returns sig, EDX features 0),
   i486 debug registers with breakpoints; applied now and on every reset */
void     ref_config(uint32_t sig, int has_cpuid, int debug_regs);
/* CS base after the state is loaded (the i486 reset: FFFF0000) */
void     ref_set_csbase(uint32_t base);
/* A20 gate: off = bit 20 of every physical address forced to 0 */
void     ref_set_a20(int on);
uint8_t *ref_ram(void);
uint32_t ref_ram_size(void);

void     ref_get(ref_state_t *s);
/* debug registers DR0-DR7 */
void     ref_get_dr(uint32_t d[8]);
/* load registers; segments are loaded real-mode style (base = sel << 4,
   64 KB limit) when 'real' is set, else from the given hidden parts */
void     ref_set(const ref_state_t *s, int real);
/* system registers: CR0 / CR2 / CR3, GDTR, IDTR (86Box's reset leaves some of them alone) */
void     ref_set_sys(uint32_t cr0v, uint32_t cr2v, uint32_t cr3v, uint32_t gdtb, uint32_t gdtl,
                     uint32_t idtb, uint32_t idtl);
/* overwrite the EFLAGS bits selected by mask (testbench: undefined flags) */
void     ref_set_flags(uint32_t mask, uint32_t val);

/* execute one instruction (a REP string instruction runs to completion).
   returns REF_STEP_* flags */
#define REF_STEP_FAULT  1    /* an exception was delivered instead / as well */
#define REF_STEP_HALT   2    /* HLT executed, now halted */
#define REF_STEP_RESET  4    /* triple fault: the CPU was reset */
int      ref_step(void);
uint64_t ref_cycles(void);   /* 86Box's i486 clock count (its tsc) so far */
/* The DUT was interrupted inside the REP string instruction at CS:EIP with
   'remaining' iterations left in (E)CX: run the model's copy of it up to
   the same point (EIP stays at the instruction).  Returns 0 if the
   instruction at CS:EIP is not a REP string instruction. */
int      ref_step_rep_partial(uint32_t remaining);
/* deliver an external (INTR) interrupt / an NMI at the current boundary */
void     ref_interrupt(int vector);
void     ref_nmi(void);

/* byte writes made since the last ref_wlog_clear() (program order) */
const ref_wr_t *ref_wlog(int *n);
void     ref_wlog_clear(void);

#ifdef __cplusplus
}
#endif
#endif
