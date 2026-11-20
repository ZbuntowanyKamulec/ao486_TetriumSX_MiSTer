// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* x86ref: run converted SingleStepTests/80386 files (tests/conv386.py) on
 * the reference model alone.  Shows where the 86Box i486SX model and the
 * 386EX hardware captures disagree, i.e. which tests can be trusted as a
 * 486 reference.   usage: ref_sst [-v] file.bin ... */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "x86ref.h"

enum { R_CR0, R_CR3, R_EAX, R_EBX, R_ECX, R_EDX, R_ESI, R_EDI, R_EBP, R_ESP,
       R_CS, R_DS, R_ES, R_FS, R_GS, R_SS, R_EIP, R_EFL, R_DR6, R_DR7, R_N };
static const char *RNAME[R_N] = { "cr0", "cr3", "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp",
                                  "cs", "ds", "es", "fs", "gs", "ss", "eip", "efl", "dr6", "dr7" };
static const int GPR[8]  = { R_EAX, R_ECX, R_EDX, R_EBX, R_ESP, R_EBP, R_ESI, R_EDI };
static const int SEG[6]  = { R_ES, R_CS, R_SS, R_DS, R_FS, R_GS };

int
main(int argc, char **argv)
{
    int  verbose = 0;
    long tp = 0, tt = 0;
    if (ref_init(16384, NULL)) { fprintf(stderr, "ref_init failed\n"); return 1; }
    uint8_t *ram = ref_ram();
    for (int ai = 1; ai < argc; ai++) {
        if (!strcmp(argv[ai], "-v")) { verbose = 1; continue; }
        FILE *f = fopen(argv[ai], "rb");
        char  mg[4];
        uint32_t n;
        const char *b = strrchr(argv[ai], '/');
        b = b ? b + 1 : argv[ai];
        if (!f || fread(mg, 1, 4, f) != 4 || memcmp(mg, "T386", 4) || fread(&n, 4, 1, f) != 1) {
            printf("%s LOADERR\n", b);
            if (f) fclose(f);
            continue;
        }
        int pass = 0, first = -1, shown = 0;
        static uint32_t ir[R_N], fr[R_N], rm[65536], ck[65536];
        for (uint32_t t = 0; t < n; t++) {
            uint32_t fmask, faddr;
            uint8_t  ex[4];
            uint16_t nr, nc;
            if (fread(ir, 4, R_N, f) != R_N || fread(fr, 4, R_N, f) != R_N || fread(&fmask, 4, 1, f) != 1 ||
                fread(ex, 1, 4, f) != 4 || fread(&faddr, 4, 1, f) != 1 || fread(&nr, 2, 1, f) != 1 ||
                fread(rm, 4, nr, f) != nr || fread(&nc, 2, 1, f) != 1 || fread(ck, 4, nc, f) != nc)
                break;
            ref_reset();
            ref_set_a20(1);
            /* default IVT: vector v -> 0000:v, so an unexpected exception shows its number in EIP */
            for (int v = 0; v < 256; v++) { ram[v * 4] = (uint8_t) v; ram[v * 4 + 1] = ram[v * 4 + 2] = ram[v * 4 + 3] = 0; }
            for (int k = 0; k < nr; k++) ram[rm[k] >> 8] = rm[k] & 0xff;
            ref_state_t s;
            memset(&s, 0, sizeof(s));
            for (int k = 0; k < 8; k++) s.gpr[k] = ir[GPR[k]];
            for (int k = 0; k < 6; k++) s.seg[k].sel = (uint16_t) ir[SEG[k]];
            s.eip    = ir[R_EIP];
            s.eflags = ir[R_EFL] & 0x00037fd7;
            ref_set(&s, 1);
            ref_wlog_clear();
            ref_step();
            ref_get(&s);
            char buf[600];
            int  bl = 0;
            buf[0]  = 0;
            for (int k = 0; k < 8; k++)
                if (s.gpr[k] != fr[GPR[k]])
                    bl += snprintf(buf + bl, sizeof(buf) - bl, " %s=%08x/%08x", RNAME[GPR[k]], s.gpr[k], fr[GPR[k]]);
            for (int k = 0; k < 6; k++)
                if (s.seg[k].sel != (uint16_t) fr[SEG[k]])
                    bl += snprintf(buf + bl, sizeof(buf) - bl, " %s=%04x/%04x", RNAME[SEG[k]], s.seg[k].sel, fr[SEG[k]] & 0xffff);
            /* the captured EIP is one past the HLT that ends the test */
            if (s.eip + 1 != fr[R_EIP])
                bl += snprintf(buf + bl, sizeof(buf) - bl, " eip=%08x/%08x", s.eip + 1, fr[R_EIP]);
            uint32_t m = fmask & 0x0fd5;
            if ((s.eflags & m) != (fr[R_EFL] & m))
                bl += snprintf(buf + bl, sizeof(buf) - bl, " efl=%04x/%04x", s.eflags & m, fr[R_EFL] & m);
            for (int k = 0; k < nc; k++) {
                uint32_t a  = ck[k] >> 8;
                uint8_t  mm = 0xff;
                if (ex[0] != 0xff && a == faddr) mm = (uint8_t) (fmask & 0xd5);
                if (ex[0] != 0xff && a == faddr + 1) mm = (uint8_t) ((fmask >> 8) & 0x0f);
                if ((ram[a] & mm) != (ck[k] & mm) && bl < 500)
                    bl += snprintf(buf + bl, sizeof(buf) - bl, " [%06x]=%02x/%02x", a, ram[a], ck[k] & 0xff);
            }
            /* restore memory for the next test */
            for (int k = 0; k < nr; k++) ram[rm[k] >> 8] = 0;
            for (int k = 0; k < nc; k++) ram[ck[k] >> 8] = 0;
            int nw;
            const ref_wr_t *wl = ref_wlog(&nw);
            for (int k = 0; k < nw; k++) ram[wl[k].addr] = 0;
            if (!bl) pass++;
            else {
                if (first < 0) first = (int) t;
                if (verbose && shown < 3) {
                    shown++;
                    printf("  %s #%u (exc %02x):%s\n", b, t, ex[0], buf);
                }
            }
        }
        fclose(f);
        tp += pass;
        tt += n;
        if (pass == (int) n) printf("%-12s PASS %d/%u\n", b, pass, n);
        else printf("%-12s FAIL %d/%u first=%d\n", b, pass, n, first);
    }
    if (argc > 3) printf("TOTAL %ld/%ld\n", tp, tt);
    return 0;
}
