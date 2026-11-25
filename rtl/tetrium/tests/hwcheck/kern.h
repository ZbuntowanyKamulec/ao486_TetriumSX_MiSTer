// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* hwcheck: shared definitions */
typedef unsigned int u32;
typedef int s32;
typedef unsigned short u16;
typedef unsigned char u8;
typedef unsigned long long u64;

#define KB 0xC0000000u
#define V(phys) ((phys) + KB)
/* physical memory (the kernel sees the first 4 MB at C0000000) */
#define P_WIN   0x30000u        /* data window, up to 16 pages */
#define P_REF   0x40000u
#define P_CODE  0x50000u        /* user code, 8 pages */
#define P_STK   0x60000u        /* user stack, 2 pages */
#define P_PDK   0x62000u
#define P_PT0   0x63000u
#define P_PDU   0x64000u        /* flat / 16-bit PM ring 3 */
#define P_PDV   0x65000u        /* V86 */
#define P_SPT   0x66000u        /* 08000000-083FFFFF: code + stack */
#define P_VPT   0x67000u        /* 00000000-003FFFFF of the V86 space */
#define P_APT   0x68000u        /* 2 alias tables */
#define P_PTPRI 0x6A000u        /* pristine SPT VPT APT0 APT1 */
#define P_PTREF 0x6E000u
#define P_FREE  0x72000u        /* directed suites: 72000-7FFFF */
#define P_PRI   0x80000u
#define P_LOG   0x90000u        /* text log (64 KB minus EBDA) */
#define U_BASE  0x08000000u
#define U_CODE  (U_BASE + P_CODE)
#define U_STK   (U_BASE + P_STK)

struct cfg { u32 magic, seed, suites, stop, tb, items, progs, off, envs, one; };
extern volatile struct cfg cfg;
extern u32 memkb;

struct frame {
    u32 gs, fs, es, ds;
    u32 edi, esi, ebp, esp0, ebx, edx, ecx, eax;
    u32 vec, err;
    u32 eip, cs, eflags;
    u32 esp, ss;                /* privilege change / V86 only */
    u32 ves, vds, vfs, vgs;     /* V86 only */
};
#define VM  0x20000u
#define IFL 0x200u
#define TFL 0x100u
#define RFL 0x10000u
#define NTL 0x4000u
#define ACL 0x40000u
#define AFL 0xCD5u

/* selectors */
enum { S_KC = 0x08, S_KD = 0x10, S_UC = 0x1B, S_UD = 0x23, S_TSS = 0x28, S_LDT = 0x30, S_TSS2 = 0x38,
       S_UC16 = 0x43, S_US16 = 0x4B, S_UD16 = 0x53, S_URO = 0x5B, S_UED = 0x63, S_UCC = 0x6B, S_K0 = 0x70,
       S_UNP = 0x7B, S_T0 = 0x80 /* ... scratch descriptors up to 1F8 */ };

/* entry.s */
extern char isr_stubs[], istack_top[], kstack_top[];
void run_frame(struct frame *f);
__attribute__((noreturn)) void kexit(void);

/* kern.c */
extern u32 gdt[128], ldt[16], idt[512], tss1[26 + 2049], tss2[26];
extern u32 rs;
extern int (*hook)(struct frame *f);             /* != 0: stop the run (the frame is copied to fin) */
extern struct frame fin;
extern volatile u32 irq_n, ticks;
extern u32 suite_fail[16], suite_runs[16], cur_suite, total_fail;
extern void (*irq_hook)(struct frame *f);
u32 rnd(void);
u32 mix(u32 a, u32 b);
void pf(const char *fmt, ...);                   /* %x %8 (8 digits) %4 %2 %d %s %c */
int fail_begin(const char *what);                /* prints the head of a report line; 0: too many already */
void status(const char *s);
void desc(u32 *t, u32 sel, u32 base, u32 limit, u32 acc, u32 fl);
void gate(u32 vec, u32 sel, u32 off, u32 acc);
void fstop(const char *what, struct frame *f) __attribute__((noreturn));
void go(struct frame *f, int (*h)(struct frame *));
void irqs_on(u32 lo, u32 span);
void irqs_off(void);
u32 rdtmr(void);

static inline void outb(u16 p, u8 v) { __asm__ volatile("outb %0, %1" :: "a"(v), "Nd"(p)); }
static inline u8 inb(u16 p) { u8 v; __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline void outw(u16 p, u16 v) { __asm__ volatile("outw %0, %1" :: "a"(v), "Nd"(p)); }
static inline u16 inw(u16 p) { u16 v; __asm__ volatile("inw %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline void outl(u16 p, u32 v) { __asm__ volatile("outl %0, %1" :: "a"(v), "Nd"(p)); }
static inline u32 inl(u16 p) { u32 v; __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline void invlpg(u32 a) { __asm__ volatile("invlpg (%0)" :: "r"(a) : "memory"); }
static inline u32 rd_cr2(void) { u32 v; __asm__ volatile("mov %%cr2, %0" : "=r"(v)); return v; }
static inline u32 rd_cr0(void) { u32 v; __asm__ volatile("mov %%cr0, %0" : "=r"(v)); return v; }
static inline void wr_cr0(u32 v) { __asm__ volatile("mov %0, %%cr0" :: "r"(v) : "memory"); }
static inline u32 rd_cr3(void) { u32 v; __asm__ volatile("mov %%cr3, %0" : "=r"(v)); return v; }
static inline void wr_cr3(u32 v) { __asm__ volatile("mov %0, %%cr3" :: "r"(v) : "memory"); }
static inline void wr_dr0(u32 v) { __asm__ volatile("mov %0, %%dr0" :: "r"(v)); }
static inline void wr_dr1(u32 v) { __asm__ volatile("mov %0, %%dr1" :: "r"(v)); }
static inline void wr_dr2(u32 v) { __asm__ volatile("mov %0, %%dr2" :: "r"(v)); }
static inline void wr_dr3(u32 v) { __asm__ volatile("mov %0, %%dr3" :: "r"(v)); }
static inline void wr_dr6(u32 v) { __asm__ volatile("mov %0, %%dr6" :: "r"(v)); }
static inline void wr_dr7(u32 v) { __asm__ volatile("mov %0, %%dr7" :: "r"(v)); }
static inline u32 rd_dr6(void) { u32 v; __asm__ volatile("mov %%dr6, %0" : "=r"(v)); return v; }
static inline void wbinvd(void) { __asm__ volatile("wbinvd" ::: "memory"); }
static inline void copyd(u32 dst, u32 src, u32 n) { __asm__ volatile("cld; rep movsl" : "+D"(dst), "+S"(src), "+c"(n) :: "memory"); }
static inline void filld(u32 dst, u32 v, u32 n) { __asm__ volatile("cld; rep stosl" : "+D"(dst), "+c"(n) : "a"(v) : "memory"); }
/* index of the first differing dword, n if equal */
static inline u32 cmpd(u32 a, u32 b, u32 n) {
    u32 c = n; u8 ne;
    __asm__ volatile("cld; cmp %%eax, %%eax; repe cmpsl; setne %1" : "+c"(c), "=q"(ne), "+S"(a), "+D"(b) :: "memory", "cc", "eax");
    return ne ? n - 1 - c : n;
}
#define PTE(tbl, i) (((volatile u32 *)V(tbl))[i])

/* suites (bit numbers of cfg.suites) */
void s_fuzz(u32 round);
void s_acc(u32 round);
void s_seg(u32 round);
void s_xfer(u32 round);
void s_task(u32 round);
void s_vm(u32 round);
void s_irq(u32 round);
void s_soc(u32 round);
void s_unreal(u32 round);
