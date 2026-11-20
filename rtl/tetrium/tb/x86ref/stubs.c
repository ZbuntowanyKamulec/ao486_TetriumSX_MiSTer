// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* x86ref: stand-ins for the parts of 86Box the CPU interpreter links against
 * (machine table, devices, PIC, timers, I/O, platform).  Nothing here models
 * hardware: I/O goes to the testbench callbacks, interrupts are injected by
 * ref_interrupt(). */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#define HAVE_STDARG_H
#include <86box/86box.h>
#include "cpu.h"
#include <86box/mem.h>
#include <86box/io.h>
#include <86box/pic.h>
#include <86box/timer.h>
#include <86box/machine.h>
#include <86box/thread.h>
#include "x86ref.h"

extern ref_io_t ref_io;
extern int      ref_irq_pending, ref_irq_vector;

/* ---- configuration variables normally owned by 86box.c / config.c */
int      cpu             = 0;
int      cpu_use_dynarec = 0;
int      fpu_type        = 0;
int      fpu_softfloat   = 0;
int      machine         = 0;
uint32_t mem_size        = 0;
int      is_pcjr         = 0;
int      inboard386_present = 0;
int      nmi_mask        = 1;
__thread int is_cpu_thread = 1;
volatile int debugger_attached = 1;      /* makes exec386() return per instruction */

const machine_t machines[2];             /* one zeroed entry */

/* ---- bus timing knobs */
int pci_burst_time, pci_nonburst_time, agp_burst_time, agp_nonburst_time;
int io_delay, io_delay_multi, io_turbo_throttle;
uint8_t io_turbo_map[65536 / 8];

/* ---- PIC / APIC */
pic_t    pic;
int      cascade = 0;
uint8_t  ioapic_irq_path_active = 0;
uint8_t  cpu_lapic_extint_live[256];
uint32_t cpu_lapic_irr_live = 0;

uint8_t
pic_any_pending(void)
{
    return (uint8_t) ref_irq_pending;
}
int
picinterrupt(void)
{
    if (!ref_irq_pending)
        return -1;
    ref_irq_pending = 0;
    return ref_irq_vector;
}
void picint_common(uint16_t num, int level, int set, uint8_t *irq_state) { (void) num; (void) level; (void) set; (void) irq_state; }
int  ioapic_external_interrupt_pending(void) { return 0; }
int  ioapic_external_interrupt_vector(void) { return -1; }
int  ioapic_lint1_raise(void) { return 0; }
int  ioapic_pic_fallback_allowed(void) { return 1; }
void ioapic_processor_reset(void) { }
void lapic_index_board_reset(uint8_t index) { (void) index; }
void lapic_set_index_source(uint8_t (*source)(void)) { (void) source; }
uint64_t cpu_apic_base_msr_read_current(void) { return 0; }
void     cpu_apic_base_msr_write_current(uint64_t val) { (void) val; }
int      cpu_apic_feature_enabled(void) { return 0; }
uint32_t cpu_cpuid_apic_id_ebx(void) { return 0; }
int      cpu_lapic_highest_deliverable_irr_index(uint8_t lapic_index, int started) { (void) lapic_index; (void) started; return -1; }
uint8_t  cpu_lapic_index_source(void) { return 0; }
void     cpu_lapic_reset_all(void) { }
void     cpu_lapic_ven_reset(void) { }

/* ---- debugger hook: stop after every instruction */
int
debugger_instruction(int partial)
{
    (void) partial;
    return 1;
}

/* ---- timers */
uint64_t timer_target = 0;
void timer_process(void) { }
void timer_disable(pc_timer_t *timer) { (void) timer; }
void timer_on_auto(pc_timer_t *timer, double period) { (void) timer; (void) period; }
void timer_set_new_tsc(uint64_t new_tsc) { (void) new_tsc; }

/* ---- I/O */
uint8_t  inb(uint16_t port) { return ref_io.in ? (uint8_t) ref_io.in(port, 1) : 0xff; }
uint16_t inw(uint16_t port) { return ref_io.in ? (uint16_t) ref_io.in(port, 2) : 0xffff; }
uint32_t inl(uint16_t port) { return ref_io.in ? ref_io.in(port, 4) : 0xffffffffu; }
void outb(uint16_t port, uint8_t val) { if (ref_io.out) ref_io.out(port, 1, val); }
void outw(uint16_t port, uint16_t val) { if (ref_io.out) ref_io.out(port, 2, val); }
void outl(uint16_t port, uint32_t val) { if (ref_io.out) ref_io.out(port, 4, val); }
void
io_handler(uint8_t set, uint16_t base, uint16_t size,
           uint8_t (*inb)(uint16_t addr, void *priv),
           uint16_t (*inw)(uint16_t addr, void *priv),
           uint32_t (*inl)(uint16_t addr, void *priv),
           void (*outb)(uint16_t addr, uint8_t val, void *priv),
           void (*outw)(uint16_t addr, uint16_t val, void *priv),
           void (*outl)(uint16_t addr, uint32_t val, void *priv),
           void *priv)
{
    (void) set; (void) base; (void) size; (void) inb; (void) inw; (void) inl;
    (void) outb; (void) outw; (void) outl; (void) priv;
}

/* ---- devices / machine */
void device_reset_all(uint32_t match_flags) { (void) match_flags; }
void dma_reset(void) { }
void dma_set_at(uint8_t at) { (void) at; }
void pci_reset(void) { }
void ppi_reset(void) { }
void pc_speed_changed(void) { }
void smram_backup_all(void) { }
void smram_recalc_all(int ret) { (void) ret; }
void cpu_car_invalidate(void) { }
void cpu_car_reset(void) { }
void cpu_car_update(void) { }
void mmx_init(void) { }
void startblit(void) { }
void endblit(void) { }
void pcjr_waitstates(void *priv) { (void) priv; }
int  machine_has_bus(int m, uintptr_t bus_flags) { (void) m; (void) bus_flags; return 0; }
int  machine_at_cobalt3k_init(const machine_t *m) { (void) m; return 0; }
int  machine_at_nupro592_init(const machine_t *m) { (void) m; return 0; }
int  machine_at_tandy_vis_init(const machine_t *m) { (void) m; return 0; }
int  machine_xt_ibm5535_init(const machine_t *m) { (void) m; return 0; }
int  machine_xt_ibm5550_init(const machine_t *m) { (void) m; return 0; }

/* ---- other CPU cores (never selected) */
int  is8086 = 0;
void execx86(int32_t cycs) { (void) cycs; }
void execvx0(int32_t cycs) { (void) cycs; }
void reset_808x(int hard) { (void) hard; }
void reset_vx0(int hard) { (void) hard; }

/* ---- platform */
void *
plat_mmap(size_t size, uint8_t executable, uint8_t *large)
{
    (void) executable;
    if (large)
        *large = 0;
    return calloc(1, size);
}
void plat_munmap(void *ptr, size_t size) { (void) size; free(ptr); }
mutex_t *thread_create_mutex(void) { return (mutex_t *) malloc(1); }
int thread_wait_mutex(mutex_t *arg) { (void) arg; return 1; }
int thread_release_mutex(mutex_t *mutex) { (void) mutex; return 1; }

void
pclog(const char *fmt, ...)
{
    (void) fmt;
}
void
fatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "x86ref fatal: ");
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    abort();
}

/* ---- MMX register pointers (no MMX on a 486) */
uint16_t *MMEP[8];
MMX_REG  *MMP[8];
