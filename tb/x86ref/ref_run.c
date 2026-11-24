// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* x86ref self-test: run a .COM benchmark (image loaded at 1000:0000, entry 1000:0100, ends with HLT)
 * on the reference model alone.  usage: ref_run [-con] [-conat HEX] prog.com ...  (-con: the text at
 * 20000h, -conat: at another address) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "x86ref.h"

int
main(int argc, char **argv)
{
    int con = 0;
    uint32_t conat = 0x20000;
    if (ref_init(16384, NULL)) { fprintf(stderr, "ref_init failed\n"); return 1; }
    ref_config(0x422, 1, 1);
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-con")) { con = 1; continue; }
        if (!strcmp(argv[i], "-conat") && i + 1 < argc) { con = 1; conat = strtoul(argv[++i], NULL, 16); continue; }
        FILE *f = fopen(argv[i], "rb");
        if (!f) { printf("%s LOADERR\n", argv[i]); continue; }
        ref_reset();
        uint8_t *ram = ref_ram();
        memset(ram, 0, ref_ram_size());
        size_t n = fread(ram + 0x10000, 1, 0x10000, f);
        fclose(f);
        ref_state_t s;
        memset(&s, 0, sizeof(s));
        for (int k = 0; k < REF_NSEG; k++) s.seg[k].sel = (k < 4) ? 0x1000 : 0;
        s.gpr[4] = 0xfffe;
        s.eip    = 0x100;
        s.eflags = 0x0002;
        ref_set(&s, 1);
        long ins = 0;
        int  r   = 0;
        while (ins < 2000000000L) {
            r = ref_step();
            if (r & (REF_STEP_HALT | REF_STEP_RESET)) break;
            ins++;
        }
        ref_get(&s);
        const char *b = strrchr(argv[i], '/');
        if (con) printf("%s", (const char *) ram + conat);
        printf("%-12s size=%zu insns=%ld %s ax=%04x ip=%04x fl=%04x\n", b ? b + 1 : argv[i], n, ins,
               (r & REF_STEP_HALT) ? "HLT" : (r & REF_STEP_RESET) ? "RESET" : "TIMEOUT",
               s.gpr[0] & 0xffff, s.eip, s.eflags & 0xffff);
    }
    return 0;
}
