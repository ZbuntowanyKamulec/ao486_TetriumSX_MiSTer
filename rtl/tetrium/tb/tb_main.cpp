// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium Verilator test harness
//
//  SingleStepTests mode:   Vtetrium_core [-v] [-f N] [-n N] [-l LAT] file.bin ...
//      one compact line per file: "<name> PASS n/n avg_cyc=x" / "<name> FAIL k/n first=i"
//  Lockstep vs 86Box:      Vtetrium_core -k [-kr] [-rb] [-i N] prog.com ...
//      runs the program pipelined; after every retired instruction the 86Box
//      interpreter (tb/x86ref) is stepped and registers, flags and stores are
//      compared.  -kr: resynchronise after a mismatch and list them by opcode.
//      one line per program: "<name> LOCK OK ..." or "<name> LOCK MISMATCH ..."
//      -rom: the file is a 64 / 128 KB ROM (test386) mapped below 1 MB, run from F000:FFF0;
//      prints the POST codes written to port 190h, port E9h output goes to <file>.out
//  Random differential:    Vtetrium_core -r prog.bin ...
//      runs each program single-stepped and fully pipelined (random bus timing),
//      compares registers + all memory after N retired instructions.
//      one line per program: "<name> OK ... ipc=x" or "<name> MISMATCH ..."
#include "Vtetrium_core.h"
#include "x86ref.h"
#include "verilated.h"
#ifdef TRACE
#include "verilated_fst_c.h"
static VerilatedFstC *tfp = nullptr;
static long tstart = 0, tlen = 0, tglob = 0;
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <map>
#include <deque>
#include <map>

static const int gmap[8] = {0, 2, 3, 1, 8, 9, 10, 11};   // core order AX CX DX BX SP BP SI DI -> test idx

static uint8_t mem[1 << 24];             // 16 MB of RAM behind the bus
#define MEM1M (1 << 20)                  // the real-mode tests only use (and clear) the first megabyte

// ------------------------------------------------------------------ bus model
// self-modifying-code detector for the random differential test: the
// reference run notes when each byte was last written (in retired insns) and
static bool io_rec = false;                                        // record I/O writes (-rom)
static std::vector<std::pair<uint16_t, uint8_t>> io_log;
// OUT data, byte by byte in order (port, value): the DUT's I/O write cycles and the model's OUTs,
// compared as they come (the DUT's write may be on the bus after its instruction retired)
static std::deque<std::pair<uint16_t, uint8_t>> dut_o, ref_o;
// Wishbone data width of the build (make CORE=486 sim BW=64 passes -DBUS_DW to both)
#ifndef CPU_SIG                                  // processor configuration (tetrium_cfg.svh)
#define CPU_SIG 0x422
#endif
#ifndef HAS_CPUID
#define HAS_CPUID 1
#endif
#ifndef DEBUG_REGS
#define DEBUG_REGS 1
#endif
#ifndef BUS_DW
#define BUS_DW 32
#endif
static const int BB = BUS_DW / 8;                                   // bytes per beat
static const int AB = BB == 2 ? 1 : BB == 4 ? 2 : BB == 8 ? 3 : 4;  // wb_adr = byte address >> AB
struct Req { uint32_t adr; uint16_t sel; bool we; uint8_t dat[16]; uint8_t tga; long t; };
static void bus_get(const Vtetrium_core *t, uint8_t *o) {
#if BUS_DW == 128
    for (int i = 0; i < 4; i++) for (int b = 0; b < 4; b++) o[i * 4 + b] = t->wb_dato[i] >> (8 * b);
#else
    uint64_t v = t->wb_dato; for (int b = 0; b < BB; b++) o[b] = v >> (8 * b);
#endif
}
static void bus_set(Vtetrium_core *t, const uint8_t *in) {
#if BUS_DW == 128
    for (int i = 0; i < 4; i++) { uint32_t w = 0; for (int b = 0; b < 4; b++) w |= (uint32_t)in[i * 4 + b] << (8 * b); t->wb_dati[i] = w; }
#else
    uint64_t v = 0; for (int b = 0; b < BB; b++) v |= (uint64_t)in[b] << (8 * b); t->wb_dati = v;
#endif
}
struct Bus {
    std::deque<Req> pend;
    int lat = 1;            // fixed latency (cycles from accept to ack)
    int rnd = 0;            // random latency / stall mode
    uint32_t rs = 1;
    long last_ack = 0;
    uint32_t rnd32() { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }
    void reset(uint32_t seed) { pend.clear(); rs = seed | 1; last_ack = 0; }
};

// DMA controller (I/O ports C8-DF), for the snoop tests (tests/dma.s):
//   C8 command (written last: 1 = fill with the PRNG bytes, 2 = copy), CC flag value,
//   D0 source, D4 destination (physical), D8 length (16 bit), DA PRNG seed, DC flag address.
// Works in chunks of 1-16 bytes with random gaps; every line written is snooped
// (snoop_v, one line per cycle, after its bytes are in memory); when the last chunk's
// snoops are out, the flag dword is written (and snooped).  PRNG: x = x * 25173 + 13849
// (16 bit), byte = x >> 8.  DMANOISE=N: also a spurious snoop of a random line in
// 10000-6FFFF about every N cycles.
struct Dma {
    uint8_t r[24] = {0};
    bool act = false, fl = false;
    int mode = 0, gap = 0;
    uint32_t src = 0, dst = 0, len = 0, pos = 0, flagp = 0, flagv = 0;
    uint16_t x = 0;
    std::deque<uint32_t> snq;
    uint32_t rs = 7;
    long n_dma = 0, n_snoop = 0;
    uint32_t rnd() { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }
    uint32_t r32(int o) { return r[o] | r[o + 1] << 8 | r[o + 2] << 16 | (uint32_t)r[o + 3] << 24; }
    void reset(uint32_t seed) { act = false; snq.clear(); rs = seed | 1; memset(r, 0, sizeof r); }
    void io(uint16_t port, uint8_t v) {
        if (port < 0xC8 || port >= 0xE0) return;
        r[port - 0xC8] = v;
        if (port == 0xC8 && (v == 1 || v == 2)) {
            mode = v; flagv = r32(4); src = r32(8); dst = r32(12); len = r[16] | r[17] << 8;
            x = r[18] | r[19] << 8; flagp = r32(20); pos = 0; act = true; fl = false; gap = rnd() % 8; n_dma++;
        }
    }
    void push_line(uint32_t a) { uint32_t l = a >> 4; if (snq.empty() || snq.back() != l) snq.push_back(l); }
    // one cycle: memory writes of this cycle, then the snoop to present
    void tick(uint8_t *m, bool &sv, uint32_t &sl) {
        static const long noise = getenv("DMANOISE") ? atol(getenv("DMANOISE")) : 0;
        if (act && !fl) {
            if (gap > 0) gap--;
            else {
                uint32_t n = 1 + rnd() % 16;
                if (n > len - pos) n = len - pos;
                for (uint32_t k = 0; k < n; k++) {
                    uint8_t b;
                    if (mode == 1) { x = (uint16_t)(x * 25173u + 13849u); b = x >> 8; }
                    else b = m[(src + pos + k) & 0xFFFFFF];
                    m[(dst + pos + k) & 0xFFFFFF] = b;
                    push_line(dst + pos + k);
                }
                pos += n;
                gap = (rnd() % 3 == 0) ? 0 : rnd() % 12;
                if (pos >= len) fl = true;
            }
        } else if (act && fl && snq.empty()) {
            for (int k = 0; k < 4; k++) m[(flagp + k) & 0xFFFFFF] = flagv >> (8 * k);
            push_line(flagp);
            act = false;
        }
        sv = false;
        static const bool nosn = getenv("DMANOSNOOP") != nullptr;          // (test check: must fail)
        if (!snq.empty()) { sv = !nosn; sl = snq.front(); snq.pop_front(); n_snoop++; }
        else if (noise && rnd() % noise == 0) { sv = true; sl = (0x10000 + rnd() % 0x60000) >> 4; }
    }
};

struct Sim {
    Vtetrium_core *top;
    Dma dma;
    int trace = 0;
    Bus bus;
    long cyc = 0;
    long irq_per = 0, irq_next = 0, n_inta = 0;   // -i N: raise INTR every N cycles
    int a20m = 1;           // A20 masked: 20-bit address wrap for the real-mode tests
    // lockstep: stores leaving W (program order, byte granular), INTA since the last retire
    bool lock = false, inta_seen = false;
    std::deque<std::pair<uint32_t, uint8_t>> dq;
    std::vector<uint32_t> *wtrack = nullptr;   // addresses written on the bus (80386 tests: cleanup)
    void init_regs32(const uint32_t *gpr, const uint16_t *seg6, uint32_t ip, uint32_t fl) {
        for (int i = 0; i < 8; i++) top->init_gpr[i] = gpr[i];
        for (int i = 0; i < 6; i++) top->init_seg[i] = seg6[i];
        top->init_csbase = (uint32_t)seg6[1] << 4;
        top->init_cr0 = 0x00000010;                     // caches on (as a BIOS leaves them)
        top->init_ip = ip; top->init_flags = fl;
    }
    void init_regs(const uint16_t *r) {
        for (int i = 0; i < 8; i++) top->init_gpr[i] = r[gmap[i]];
        top->init_seg[0] = r[7]; top->init_seg[1] = r[4]; top->init_seg[2] = r[5]; top->init_seg[3] = r[6];
        top->init_seg[4] = 0; top->init_seg[5] = 0;
        top->init_csbase = (uint32_t)r[4] << 4;
        top->init_cr0 = 0x00000010;
        top->init_ip = r[12];
        top->init_flags = r[13];
    }
    void reset() {
        top->intr = 0; top->nmi = 0; top->snoop_v = 0; top->flush = 0; top->a20m = a20m; dma.reset(bus.rs);
        top->wb_ack = 0; top->wb_stall = 0; { uint8_t z[16] = {0}; bus_set(top, z); }
        top->rst = 1;
        for (int c = 0; c < 3; c++) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
        top->rst = 0;
        cyc = 0; irq_next = irq_per; n_inta = 0;
    }
    // one clock cycle including the memory model
    void tick() {
        top->clk = 0; top->eval();
        top->wb_ack = 0;
        if (!bus.pend.empty() && bus.pend.front().t <= cyc) {
            Req r = bus.pend.front(); bus.pend.pop_front();
            top->wb_ack = 1;
            uint8_t d[16] = {0};
            if (r.tga == 0) {
                for (int b = 0; b < BB; b++) {
                    uint32_t a = (r.adr << AB) + b;
                    // the BIOS alias at the top of the 4 GB (i486 reset: FFFFFFF0) = E0000-FFFFF
                    a = (a >= 0xFFFE0000u) ? (0xE0000 | (a & 0x1FFFF)) : (a & 0xFFFFFF);
                    if (r.we) {
                        if (r.sel >> b & 1) {
                            mem[a] = r.dat[b];
                            if (wtrack) wtrack->push_back(a);
                            static long wlo = getenv("WWATCH") ? strtol(getenv("WWATCH"), nullptr, 16) : -1;
                            if (wlo >= 0 && a >= (uint32_t)wlo && a < (uint32_t)wlo + 16)
                                printf("  write [%05x]=%02x at cycle %ld\n", a, mem[a], cyc);
                        }
                    }
                    else d[b] = mem[a];
                }
            } else if (r.tga == 1) {
                memset(d, 0xFF, sizeof d);
                if (r.we)
                    for (int b = 0; b < BB; b++)
                        if (r.sel >> b & 1) {
                            uint16_t port = (uint16_t)((r.adr << AB) + b);
                            dma.io(port, r.dat[b]);
                            dut_o.push_back({port, r.dat[b]});
                            // port 92h (PS/2 system control A): bit 1 = A20 enabled
                            if (port == 0x92) top->a20m = !(r.dat[b] & 2);
                        }
                if (r.we && io_rec)                      // (-rom: byte OUTs, lowest selected lane)
                    for (int b = 0; b < BB; b++)
                        if (r.sel >> b & 1) {
                            io_log.push_back({(uint16_t)((r.adr << AB) + b), r.dat[b]});
                            static const bool lpost = getenv("LOCKPOST") != nullptr;    // POST codes as they come
                            if (lpost && ((r.adr << AB) + b) == 0x190) printf("  POST %02X at cycle %ld\n", r.dat[b], cyc);
                            break;
                        }
            }
            else d[0] = 8;
            bus_set(top, d);
            static const bool btrace = getenv("BUSTRACE") != nullptr;
            if (btrace) {
                printf("  bus %ld %s t%d a=%08x sel=%x d=", cyc, r.we ? "W" : "R", r.tga, r.adr << AB, r.sel);
                for (int b = BB - 1; b >= 0; b--) printf("%02x", r.we ? r.dat[b] : d[b]);
                printf("\n");
            }
        }
        { bool sv; uint32_t sl = 0; dma.tick(mem, sv, sl); top->snoop_v = sv; if (sv) top->snoop_line = sl; }
        top->wb_stall = bus.rnd ? ((bus.rnd32() & 7) == 0) : 0;
        if (irq_per && !top->intr && cyc >= irq_next) top->intr = 1;
        top->eval();
        if (top->wb_cyc && top->wb_stb && !top->wb_stall) {
            if (top->wb_tga == 2) { top->intr = 0; irq_next = cyc + irq_per; n_inta++; inta_seen = true; }
            long t = cyc + (bus.rnd ? 1 + (bus.rnd32() % 4) : bus.lat);
            if (t <= bus.last_ack) t = bus.last_ack + 1;
            bus.last_ack = t;
            Req q{(uint32_t)top->wb_adr, (uint16_t)top->wb_sel, (bool)top->wb_we, {0}, (uint8_t)top->wb_tga, t};
            bus_get(top, q.dat);
            bus.pend.push_back(q);
        }
        if (lock && top->dbg_st_v)
            for (int k = 0; k < (1 << top->dbg_st_sz); k++)
            {
                // bytes past the first word: at the second word's (physical) address
                uint32_t a = (uint32_t)top->dbg_st_lin + k;
                if ((((uint32_t)top->dbg_st_lin & 3) + k) >= 4) a = ((uint32_t)top->dbg_st_lin4 << 2) + ((((uint32_t)top->dbg_st_lin & 3) + k) & 3);
                dq.push_back({a & 0xFFFFFF, (uint8_t)(top->dbg_st_data >> (8 * k))});
            }
        // page walker: accessed / dirty bit updates (the model logs them too)
        static const bool dtr = getenv("LOCKTRACE") && getenv("LOCKTRACE")[0] == '2';
        if (lock && dtr && top->dbg_st_v) printf("     dut st [%06x] sz%d %08x\n", (uint32_t)top->dbg_st_lin, (int)top->dbg_st_sz, (uint32_t)top->dbg_st_data);
        if (lock && dtr && top->dbg_pw_v) printf("     dut pw [%06x] %08x\n", (uint32_t)top->dbg_pw_adr << 2, (uint32_t)top->dbg_pw_dat);
        if (lock && top->dbg_pw_v)
            for (int k = 0; k < 4; k++)
                dq.push_back({(((uint32_t)top->dbg_pw_adr << 2) + k) & 0xFFFFFF, (uint8_t)(top->dbg_pw_dat >> (8 * k))});
        top->clk = 1; top->eval();
#ifdef TRACE
        if (tfp && tglob >= tstart && tglob < tstart + tlen) tfp->dump((uint64_t)(tglob * 2));
        tglob++;
#endif
        cyc++;
    }
    void snap(uint16_t *s) {
        for (int i = 0; i < 8; i++) {
            s[gmap[i]] = top->dbg_gpr[i] & 0xFFFF;
        }
        s[7] = top->dbg_seg[0] & 0xFFFF; s[4] = top->dbg_seg[0] >> 16;
        s[5] = top->dbg_seg[1] & 0xFFFF; s[6] = top->dbg_seg[1] >> 16;
        s[12] = top->dbg_ip;
        s[13] = top->dbg_flags;
    }
    // run until n instructions retired (single-step or pipelined), then drain
    bool run(long n, bool step, long maxcyc, long *retired_out) {
        long ret = 0;
        int drain = 0;
        top->sstep = step;
        top->stop_req = n <= 1;
        while (cyc < maxcyc) {
            tick();
            if (top->retire) {
                ret++;
                if (trace) printf("  ret %ld cyc %ld ip=%04x\n", ret, cyc, (unsigned)top->dbg_ip);
                if (ret == n - 1) top->stop_req = 1;
            }
            if (ret >= n || top->halted) {
                if (top->idle && bus.pend.empty()) drain++;
                if (drain > 2) { *retired_out = ret; return true; }
            }
        }
        *retired_out = ret;
        return false;
    }
};

static int skipn = 0;         // -s N: start SST files at test N
static int showcon = 0;       // -con: print the C benchmarks' console buffer (2000:0000)
// ------------------------------------------------------------------ SingleStepTests/80386 (tests/conv386.py)
// A test passes if the DUT matches the 386EX capture.  If it does not, the 86Box model
// runs the same test: a DUT result equal to the model's is counted separately ("ref").
enum { R_CR0, R_CR3, R_EAX, R_EBX, R_ECX, R_EDX, R_ESI, R_EDI, R_EBP, R_ESP,
       R_CS, R_DS, R_ES, R_FS, R_GS, R_SS, R_EIP, R_EFL, R_DR6, R_DR7, R_N };
static const char *R3N[R_N] = {"cr0", "cr3", "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp",
                               "cs", "ds", "es", "fs", "gs", "ss", "eip", "efl", "dr6", "dr7"};
static const int G386[8] = {R_EAX, R_ECX, R_EDX, R_EBX, R_ESP, R_EBP, R_ESI, R_EDI};   // core / model gpr order
static const int S386[6] = {R_ES, R_CS, R_SS, R_DS, R_FS, R_GS};                       // core segment order

static void run_t386(Sim &S, const std::string &fn, int verbose, int maxn, int showf, long &tp, long &tt) {
    std::string name = fn.substr(fn.find_last_of('/') + 1);
    name = name.substr(0, name.find(".bin"));
    FILE *f = fopen(fn.c_str(), "rb");
    char mg[4]; uint32_t n = 0;
    if (!f || fread(mg, 1, 4, f) != 4 || memcmp(mg, "T386", 4) || fread(&n, 4, 1, f) != 1) {
        printf("%s LOADERR\n", name.c_str()); if (f) fclose(f); return;
    }
    static bool inited = false;
    if (!inited) { if (ref_init(16384, nullptr)) { printf("%s REFERR\n", name.c_str()); fclose(f); return; } inited = true; }
    uint8_t *rram = ref_ram();
    int pass = 0, refok = 0, cnt = 0, first = -1, shown = 0;
    long cyc_sum = 0;
    std::vector<uint32_t> wl;
    static uint32_t ir[R_N], fr[R_N], rm[65536], ck[65536];
    for (uint32_t t = 0; t < n; t++) {
        uint32_t fmask, faddr; uint8_t ex[4]; uint16_t nr, nc;
        if (fread(ir, 4, R_N, f) != R_N || fread(fr, 4, R_N, f) != R_N || fread(&fmask, 4, 1, f) != 1 ||
            fread(ex, 1, 4, f) != 4 || fread(&faddr, 4, 1, f) != 1 || fread(&nr, 2, 1, f) != 1 ||
            fread(rm, 4, nr, f) != nr || fread(&nc, 2, 1, f) != 1 || fread(ck, 4, nc, f) != nc) break;
        if ((int)t < skipn || cnt >= maxn) continue;
        cnt++;
        // default IVT (vector v -> 0000:v), then the test's memory
        for (int v = 0; v < 256; v++) { mem[v * 4] = v; mem[v * 4 + 1] = mem[v * 4 + 2] = mem[v * 4 + 3] = 0; }
        for (int k = 0; k < nr; k++) mem[rm[k] >> 8] = rm[k] & 0xFF;
        uint32_t gp[8]; uint16_t sg[6];
        for (int k = 0; k < 8; k++) gp[k] = ir[G386[k]];
        for (int k = 0; k < 6; k++) sg[k] = ir[S386[k]];
        S.init_regs32(gp, sg, ir[R_EIP], ir[R_EFL] & 0xFFFF);
        S.bus.reset(t + 1);
        wl.clear(); S.wtrack = &wl;
        S.a20m = 0; S.reset(); S.a20m = 1;
        long rt;
        bool done = S.run(1, true, 20000, &rt);
        S.wtrack = nullptr;
        cyc_sum += S.cyc;
        uint32_t dg[8], dip, dfl; uint16_t dsg[6];
        for (int k = 0; k < 8; k++) dg[k] = S.top->dbg_gpr[k];
        for (int k = 0; k < 6; k++) dsg[k] = (S.top->dbg_seg[k / 2] >> (16 * (k & 1))) & 0xFFFF;
        dip = S.top->dbg_ip; dfl = S.top->dbg_flags;
        const uint32_t FM = fmask & 0x7FD5;
        char buf[700]; int bl = 0; buf[0] = 0;
        bool ok = done;
        if (!done) bl += snprintf(buf, sizeof(buf), " TIMEOUT retired=%ld", rt);
        else {
            for (int k = 0; k < 8; k++)
                if (dg[k] != fr[G386[k]]) bl += snprintf(buf + bl, sizeof(buf) - bl, " %s=%08x/%08x", R3N[G386[k]], dg[k], fr[G386[k]]);
            for (int k = 0; k < 6; k++)
                if (dsg[k] != (fr[S386[k]] & 0xFFFF)) bl += snprintf(buf + bl, sizeof(buf) - bl, " %s=%04x/%04x", R3N[S386[k]], dsg[k], fr[S386[k]] & 0xFFFF);
            // the captured EIP is one past the HLT that ends the test (the tested HLT itself for F4)
            if (dip + (S.top->halted ? 0 : 1) != fr[R_EIP])
                bl += snprintf(buf + bl, sizeof(buf) - bl, " eip=%08x/%08x", dip + 1, fr[R_EIP]);
            if ((dfl & FM) != (fr[R_EFL] & FM)) bl += snprintf(buf + bl, sizeof(buf) - bl, " efl=%04x/%04x", dfl & FM, fr[R_EFL] & FM);
            for (int k = 0; k < nc; k++) {
                uint32_t a = ck[k] >> 8; uint8_t mm = 0xFF;
                if (ex[0] != 0xFF && a == faddr) mm = fmask & 0xD5;
                if (ex[0] != 0xFF && a == faddr + 1) mm = (fmask >> 8) & 0x7F;
                if ((mem[a] & mm) != (ck[k] & mm) && bl < 500)
                    bl += snprintf(buf + bl, sizeof(buf) - bl, " [%06x]=%02x/%02x", a, mem[a], ck[k] & 0xFF);
            }
            ok = (bl == 0);
        }
        bool rok = false;
        if (!ok && done) {
            // tie-breaker: the 86Box model on the same test
            ref_reset(); ref_set_a20(1);
            for (int v = 0; v < 256; v++) { rram[v * 4] = v; rram[v * 4 + 1] = rram[v * 4 + 2] = rram[v * 4 + 3] = 0; }
            for (int k = 0; k < nr; k++) rram[rm[k] >> 8] = rm[k] & 0xFF;
            ref_state_t rs; memset(&rs, 0, sizeof(rs));
            for (int k = 0; k < 8; k++) rs.gpr[k] = ir[G386[k]];
            rs.seg[REF_ES].sel = ir[R_ES]; rs.seg[REF_CS].sel = ir[R_CS]; rs.seg[REF_SS].sel = ir[R_SS];
            rs.seg[REF_DS].sel = ir[R_DS]; rs.seg[REF_FS].sel = ir[R_FS]; rs.seg[REF_GS].sel = ir[R_GS];
            rs.eip = ir[R_EIP]; rs.eflags = ir[R_EFL] & 0x00037FD7;
            ref_set(&rs, 1); ref_wlog_clear();
            ref_step(); ref_get(&rs);
            rok = true;
            for (int k = 0; k < 8; k++) if (dg[k] != rs.gpr[k]) rok = false;
            for (int k = 0; k < 6; k++) if (dsg[k] != rs.seg[k].sel) rok = false;      // same order: ES CS SS DS FS GS
            if (dip != rs.eip) rok = false;
            if ((dfl & FM) != (rs.eflags & FM)) rok = false;
            int nw; const ref_wr_t *rw = ref_wlog(&nw);
            for (int k = 0; k < nw && rok; k++) {
                uint8_t mm = 0xFF;
                if (ex[0] != 0xFF && rw[k].addr == faddr) mm = fmask & 0xD5;
                if (ex[0] != 0xFF && rw[k].addr == faddr + 1) mm = (fmask >> 8) & 0x7F;
                if ((mem[rw[k].addr] & mm) != (rram[rw[k].addr] & mm)) rok = false;
            }
            for (uint32_t a : wl) if (mem[a] != rram[a] && a != faddr && a != faddr + 1) rok = false;
            for (int k = 0; k < nw; k++) rram[rw[k].addr] = 0;
            for (int k = 0; k < nr; k++) rram[rm[k] >> 8] = 0;
        }
        if (ok) pass++;
        else if (rok) refok++;
        else {
            if (first < 0) first = t;
            if (verbose && shown < showf) { shown++; printf("  %s #%u (exc %02x):%s\n", name.c_str(), t, ex[0], buf); }
        }
        for (int k = 0; k < nr; k++) mem[rm[k] >> 8] = 0;
        for (int k = 0; k < nc; k++) mem[ck[k] >> 8] = 0;
        for (uint32_t a : wl) mem[a] = 0;
    }
    fclose(f);
    tp += pass + refok; tt += cnt;
    if (pass + refok == cnt)
        printf("%-9s PASS %d/%d ref=%d  avg_cyc=%.1f\n", name.c_str(), pass + refok, cnt, refok, cnt ? (double)cyc_sum / cnt : 0.0);
    else printf("%-9s FAIL %d/%d ref=%d first=%d\n", name.c_str(), pass + refok, cnt, refok, first);
    fflush(stdout);
}

// ------------------------------------------------------------------ benchmark (.COM, ends with HLT)
static const int NPERF = 25;
static const char *PN[NPERF] = {"uop_done", "m_valid", "e_valid", "e_busy", "hold_w", "m_stall", "sb_stall",
    "a_valid", "issue", "q_push", "flush_e", "redir_a", "redir_d", "if_fill", "df_fill", "retire", "q_empty", "ldwait", "pt_blk", "fl_ret", "fl_br", "fl_oth", "ra_eff", "ra_inval", "ba_drop"};

static FILE *ipt = nullptr;  // -ipt FILE: IP after every retired instruction (reference run)
static bool ipt_cs = false;  // -iptcs FILE: the same as CS:IP (selector:offset)
static bool run_until_halt(Sim &S, bool step, long maxcyc, long *ret, long *pc) {
    long r = 0;
    for (int i = 0; i < NPERF; i++) pc[i] = 0;
    S.top->sstep = step; S.top->stop_req = 0;
    int idle = 0;
    while (S.cyc < maxcyc) {
        S.tick();
        uint32_t p = S.top->dbg_perf;
        for (int i = 0; i < NPERF; i++) pc[i] += (p >> i) & 1;
        if (S.top->retire) {
            r++;
            if (ipt && step) {
                if (ipt_cs) fprintf(ipt, "%04x:%04x\n", (unsigned)(S.top->dbg_seg[0] >> 16), (unsigned)S.top->dbg_ip);
                else fprintf(ipt, "%04x\n", (unsigned)S.top->dbg_ip);
            }
        }
        // NMISHUT=1: an NMI pulse whenever the core is in shutdown (it leaves shutdown by NMI)
        static const bool nmishut = getenv("NMISHUT") != nullptr;
        S.top->nmi = nmishut && S.top->shutdown && !S.top->nmi;
        if (nmishut && S.top->shutdown) continue;
        if (S.top->halted && S.top->idle && S.bus.pend.empty()) { if (++idle > 2) { *ret = r; return true; } }
    }
    *ret = r;
    return false;
}

static void run_bench(Sim &S, const std::string &fn, int lat, int check, long irq, int rndbus = 0) {
    std::string name = fn.substr(fn.find_last_of('/') + 1);
    FILE *f = fopen(fn.c_str(), "rb");
    if (!f) { printf("%s LOADERR\n", name.c_str()); return; }
    static uint8_t img[0x10000];
    size_t n = fread(img, 1, sizeof(img), f);
    fclose(f);
    uint16_t regs[14] = {0, 0, 0, 0, 0x1000, 0x1000, 0x1000, 0x1000, 0xFFFE, 0, 0, 0, 0x100, 0xF002};
    static uint8_t ref[1 << 20];
    long ra = 0, ca = 0, pca[NPERF], pcb[NPERF];
    uint16_t sa[14], sb[14];
    if (check) {
        memset(mem, 0, MEM1M); memcpy(mem + 0x10000, img, n);
        S.init_regs(regs); S.bus.reset(1); S.bus.rnd = 0; S.bus.lat = 1; S.reset();
        run_until_halt(S, true, 200000000, &ra, pca);
        S.snap(sa); ca = S.cyc;
        memcpy(ref, mem, sizeof(ref));
    }
    memset(mem, 0, MEM1M); memcpy(mem + 0x10000, img, n);
    S.init_regs(regs); S.bus.reset(getenv("DMASEED") ? atoi(getenv("DMASEED")) : 1); S.bus.rnd = rndbus; S.bus.lat = lat;
    S.irq_per = irq; S.reset();
    long rb;
    bool ok = run_until_halt(S, false, 200000000, &rb, pcb);
    S.snap(sb);
    long cb = S.cyc;
    long ninta = S.n_inta;
    S.irq_per = 0;
    // with interrupts: DS:F000-FFFF (ISR counter, stack) and the retire count may differ
    bool memok = true;
    for (int a = 0; a < (1 << 20) && check; a++)
        if (mem[a] != ref[a] && !(irq && a >= 0x1F000 && a < 0x20000)) memok = false;
    const char *st = "";
    if (!ok) st = " TIMEOUT";
    else if (check && (memcmp(sa, sb, sizeof(sa)) || !memok || (!irq && ra != rb))) st = " MISMATCH";
    else if (irq && (ninta == 0 || mem[0x1F000] + 256 * mem[0x1F001] != (ninta & 0xFFFF))) st = " IRQCOUNT";   // 16-bit ISR counter
    if (irq) printf("%-10s interrupts=%ld isr_count=%d\n", name.c_str(), ninta, mem[0x1F000] + 256 * mem[0x1F001]);
    if (showcon) printf("%s", (const char *)mem + 0x20000);
    if (S.dma.n_dma) printf("%-10s dma=%ld snoops=%ld\n", name.c_str(), S.dma.n_dma, S.dma.n_snoop);
    printf("%-10s insns=%-9ld cycles=%-9ld IPC=%.3f  CPI=%.2f%s\n", name.c_str(), rb, cb, (double)rb / cb,
           (double)cb / (rb ? rb : 1), st);
    printf("           ");
    for (int i = 0; i < NPERF; i++) if (i != 15 && (i < 19 || getenv("PERFABS"))) { if (getenv("PERFABS")) printf(" %s=%ld", PN[i], (long)pcb[i]); else printf(" %s=%.1f%%", PN[i], 100.0 * pcb[i] / cb); }
    printf("\n");
    fflush(stdout);
}

// ------------------------------------------------------------------ lockstep vs 86Box (tb/x86ref)
// EFLAGS bits the instruction at 'p' leaves undefined (compared masked, then copied
// from the DUT into the model so they cannot propagate)
static uint32_t undef_flags(const uint8_t *p) {
    int i = 0;
    while (i < 14) {
        uint8_t b = p[i];
        if (b == 0x26 || b == 0x2E || b == 0x36 || b == 0x3E || b == 0x64 || b == 0x65 || b == 0x66 || b == 0x67 ||
            (b >= 0xF0 && b <= 0xF3 && b != 0xF1)) i++;
        else break;
    }
    uint8_t op = p[i], reg = (p[i + 1] >> 3) & 7;
    const uint32_t CF = 1, PF = 4, AF = 0x10, ZF = 0x40, SF = 0x80, OF = 0x800;
    if (op == 0x0F) {
        switch (p[i + 1]) {
            case 0xA3: case 0xAB: case 0xB3: case 0xBB: case 0xBA: return OF | SF | ZF | AF | PF;   // BT*
            case 0xBC: case 0xBD: return OF | SF | AF | PF | CF;                                    // BSF BSR
            case 0xA4: case 0xA5: case 0xAC: case 0xAD: return OF | AF;                             // SHLD SHRD
            case 0xAF: return SF | ZF | AF | PF;                                                    // IMUL
            default: return 0;
        }
    }
    if (op == 0x27 || op == 0x2F) return OF;                        // DAA DAS
    if (op == 0x37 || op == 0x3F) return OF | SF | ZF | PF;         // AAA AAS
    if ((op & 0xC4) == 0x00 || (op & 0xC6) == 0x04) {              // ALU block 00-3F
        int k = (op >> 3) & 7;
        if ((op & 7) < 6 && (k == 1 || k == 4 || k == 6)) return AF;   // OR AND XOR
        return 0;
    }
    switch (op) {
        case 0x80: case 0x81: case 0x82: case 0x83: return (reg == 1 || reg == 4 || reg == 6) ? AF : 0;
        case 0x84: case 0x85: case 0xA8: case 0xA9: return AF;
        case 0x69: case 0x6B: return SF | ZF | AF | PF;
        case 0xC0: case 0xC1: case 0xD2: case 0xD3: return OF | AF;
        case 0xD0: case 0xD1: return AF;
        case 0xD4: case 0xD5: return OF | AF | CF;
        case 0xF6: case 0xF7:
            if (reg <= 1) return AF;
            if (reg == 4 || reg == 5) return SF | ZF | AF | PF;
            if (reg >= 6) return OF | SF | ZF | AF | PF | CF;
            return 0;
        default: return 0;
    }
}

// MOV SS, r/m and POP SS: interrupts are held off for one instruction, 86Box executes
// that instruction in the same step
static bool ss_shadow(const uint8_t *p) {
    int i = 0;
    while (i < 14 && (p[i] == 0x26 || p[i] == 0x2E || p[i] == 0x36 || p[i] == 0x3E || p[i] == 0x64 || p[i] == 0x65 ||
                      p[i] == 0x66 || p[i] == 0x67 || p[i] == 0xF0 || p[i] == 0xF2 || p[i] == 0xF3)) i++;
    return p[i] == 0x17 || (p[i] == 0x8E && ((p[i + 1] >> 3) & 7) == 2);
}

// protected-mode random programs (rgen386.py --pm): GDT at 0x80000 whose selectors equal the
// real-mode segment values (base = selector << 4, 64 KB), test descriptors 08-48, IDT of
// 16-bit interrupt gates at 0x8C000
static void put_desc(uint32_t a, uint32_t base, uint32_t lim, uint8_t acc, uint8_t fl) {
    mem[a] = lim; mem[a + 1] = lim >> 8; mem[a + 2] = base; mem[a + 3] = base >> 8; mem[a + 4] = base >> 16;
    mem[a + 5] = acc; mem[a + 6] = ((lim >> 16) & 0xF) | (fl << 4); mem[a + 7] = base >> 24;
}
static void rpm_tables(const uint16_t *ivt, uint16_t cs) {
    const uint32_t G = 0x80000, I = 0x8C000;
    memset(mem + G, 0, 0xB008);
    put_desc(G + cs, cs << 4, 0xFFFF, 0x9B, 0);
    for (uint16_t sg : {0x3000, 0x4000, 0x5000, 0x7000, 0xB000}) put_desc(G + sg, sg << 4, 0xFFFF, 0x93, 0);
    put_desc(G + 0x08, 0x30000, 0xFFFF, 0x91, 0);         // read-only
    put_desc(G + 0x10, 0x30000, 0x7FFF, 0x97, 0);         // expand-down: 8000-FFFF
    put_desc(G + 0x18, 0x30000, 0xFFFF, 0x13, 0);         // not present
    put_desc(G + 0x20, 0x40000, 0xFFFF, 0xF3, 0);         // DPL 3
    put_desc(G + 0x28, 0x10000, 0xFFFF, 0x99, 0);         // execute-only code
    put_desc(G + 0x30, 0x50000, 0x1FFFF, 0x93, 4);        // 128 KB, B
    put_desc(G + 0x38, 0x10000, 0xFFFF, 0x9B, 0);         // readable code
    put_desc(G + 0x40, 0x30000, 0x00FF, 0x82, 0);         // LDT (system)
    put_desc(G + 0x48, 0x30000, 0xFFFF, 0x93, 0);         // (RPL 3 selector 4B: #GP)
    for (int v = 0; v < 256; v++) {
        uint32_t a = I + v * 8;
        mem[a] = ivt[v]; mem[a + 1] = ivt[v] >> 8; mem[a + 2] = cs; mem[a + 3] = cs >> 8;
        mem[a + 4] = 0; mem[a + 5] = 0x86; mem[a + 6] = 0; mem[a + 7] = 0;
    }
}

// paging (random programs 'RPG3', tests/rgen386.py --pg): directory 8D000, one table
// 8E000 for the first MB, identity with random twists from the seed: data pages not
// present / read-only / aliased (another data frame) / PCD, code pages not present
// (the program's #PF handler sets P and W); selectors 50 (flat) and 58 (the table)
static void rpg_tables(uint32_t seed) {
    const uint32_t G = 0x80000, PD = 0x8D000, PT = 0x8E000;
    put_desc(G + 0x50, 0, 0xFFFFF, 0x93, 0xC);
    put_desc(G + 0x58, PT, 0xFFF, 0x93, 0);
    memset(mem + PD, 0, 0x2000);
    uint32_t pde = PT | 7;
    memcpy(mem + PD, &pde, 4);
    uint32_t x = seed * 747796405u + 2891336453u;
    auto rnd = [&](uint32_t n) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x % n; };
    for (uint32_t p = 0; p < 256; p++) {
        uint32_t e = (p << 12) | 7;
        bool data = (p >= 0x30 && p < 0x60) || (p >= 0xB0 && p < 0xC0);
        if (data) {
            if (rnd(5) == 0) e = ((0x30 + rnd(0x30)) << 12) | 7;           // alias
            if (rnd(3) == 0) e &= ~1u;                                       // not present
            if (rnd(4) == 0) e &= ~2u;                                       // read-only
            if (rnd(6) == 0) e |= 0x10;                                      // PCD
        } else if (p >= 0x10 && p < 0x1F && rnd(3) == 0) e &= ~1u;          // code, not present
        memcpy(mem + PT + p * 4, &e, 4);
    }
}

static int lock_resync = 0;   // -kr
static int lock_step = 0;     // -ks: DUT single-stepped (flush + refetch after every instruction)
static long lock_nret = 0;     // -n N in lock mode: instructions to run of a random program
static int lock_rom = 0;       // -rom: a BIOS-style ROM image (test386) below 1 MB, started at F000:FFF0;
                               //   reports the POST codes (port 190h), port E9h text -> <image>.out
struct RefWr { uint32_t addr; uint8_t val; long grp; long npg; };
// (npg: with paging, the code page after the instruction when it ends within 16 bytes of
// its page: 86Box reads its opcode bytes ahead (fetchdat) and may translate that page,
// setting its accessed bit; the DUT walks a code page only when it fetches from it.  Such
// a PTE write is matched loosely, earlier or later: the SDM allows either.)

static void run_lock(Sim &S, const std::string &fn, int lat, int rnd, long irq) {
    std::string name = fn.substr(fn.find_last_of('/') + 1);
    FILE *f = fopen(fn.c_str(), "rb");
    if (!f) { printf("%s LOADERR\n", name.c_str()); return; }
    static uint8_t img[0x10000];
    // initial state: a .COM image at 1000:0100, or a random program (tests/rgen386.py):
    //   'R386' u32 seed, nretire, gpr[8], u16 seg[6], u32 eip, eflags, u16 ivt[256], u8 code[65536]
    uint32_t gp0[8] = {0, 0, 0, 0, 0xFFFE, 0, 0, 0}, eip0 = 0x100, efl0 = 0x0002, seed = 1, nret = 0;
    uint16_t sg0[6] = {0x1000, 0x1000, 0x1000, 0x1000, 0, 0}, ivt[256];
    char mg[4] = {0};
    static uint8_t romb[0x20000];
    size_t rn = 0;
    if (lock_rom) {
        rn = fread(romb, 1, sizeof(romb), f);
        if (rn != 0x10000 && rn != 0x20000) { printf("%s LOADERR\n", name.c_str()); fclose(f); return; }
        sg0[0] = sg0[2] = sg0[3] = 0; sg0[1] = 0xF000; eip0 = 0xFFF0; gp0[4] = 0;
        gp0[2] = CPU_SIG;                                   // i486 reset: EDX = signature
        fseek(f, 0, SEEK_END);
    }
    size_t n = lock_rom ? 0 : fread(mg, 1, 4, f);
    bool rpg = (n == 4) && !memcmp(mg, "RPG3", 4);          // ... with paging
    bool rpm = (n == 4) && (!memcmp(mg, "RPM3", 4) || rpg);  // the same in 16-bit protected mode
    bool rprog = (n == 4) && (!memcmp(mg, "R386", 4) || rpm);
    if (rprog) {
        bool okh = fread(&seed, 4, 1, f) == 1 && fread(&nret, 4, 1, f) == 1 && fread(gp0, 4, 8, f) == 8 &&
                   fread(sg0, 2, 6, f) == 6 && fread(&eip0, 4, 1, f) == 1 && fread(&efl0, 4, 1, f) == 1 &&
                   fread(ivt, 2, 256, f) == 256 && fread(img, 1, sizeof(img), f) == sizeof(img);
        if (!okh) { printf("%s LOADERR\n", name.c_str()); fclose(f); return; }
        if (lock_nret > 0) nret = lock_nret;
    } else {
        memcpy(img, mg, n);
        n += fread(img + n, 1, sizeof(img) - n, f);
    }
    fclose(f);
    static bool inited = false;
    if (!inited) {
        // the model's OUT: port 92h bit 1 = A20 gate, as on the DUT bus (86Box's own port 92
        // handler also recalculates the mask from inside the instruction)
        static const ref_io_t lio = { nullptr, [](uint16_t port, int size, uint32_t val) {
            for (int i = 0; i < size; i++) ref_o.push_back({(uint16_t)(port + i), (uint8_t)(val >> (8 * i))});
            if (port == 0x92) ref_set_a20(val & 2); } };
        if (ref_init(16384, &lio)) { printf("%s REFERR\n", name.c_str()); return; }
        ref_config(CPU_SIG, HAS_CPUID, DEBUG_REGS);
        inited = true;
    }
    const uint64_t ref_cyc0 = ref_cycles();
    // DUT
    memset(mem, 0, MEM1M + 0x10000);
    if (rprog) {
        // pseudo-random data everywhere, the code segment, IVT -> handlers in the code segment
        uint32_t x = seed * 2654435761u + 12345;
        for (uint32_t a = 0x400; a < MEM1M; a++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; mem[a] = x >> 11; }
        memcpy(mem + ((uint32_t)sg0[1] << 4), img, sizeof(img));
        // (a second copy at 0x800: programs switch the IDTR base with LIDT)
        for (int v = 0; v < 256; v++)
            for (uint32_t t : {0u, 0x800u}) {
                mem[t + v * 4] = ivt[v] & 0xFF; mem[t + v * 4 + 1] = ivt[v] >> 8;
                mem[t + v * 4 + 2] = sg0[1] & 0xFF; mem[t + v * 4 + 3] = sg0[1] >> 8;
            }
        if (rpm) rpm_tables(ivt, sg0[1]);
        if (rpg) rpg_tables(seed);
    } else if (lock_rom) memcpy(mem + MEM1M - rn, romb, rn);
    else memcpy(mem + 0x10000, img, n);
    io_log.clear(); io_rec = lock_rom; dut_o.clear(); ref_o.clear();
    S.init_regs32(gp0, sg0, eip0, efl0); S.bus.reset(seed); S.bus.rnd = rnd; S.bus.lat = lat;
    // -rom: the i486 reset (CS base FFFF0000, caches off); else caches on (as a BIOS leaves them)
    const uint32_t cr0_0 = getenv("CR0INIT") ? (uint32_t)strtoul(getenv("CR0INIT"), nullptr, 16) : lock_rom ? 0x60000010 : 0x00000010;
    if (lock_rom) S.top->init_csbase = 0xFFFF0000;
    S.top->init_cr0 = cr0_0;
    S.irq_per = irq; S.lock = true; S.dq.clear(); S.inta_seen = false;
    S.a20m = 0;
    S.reset();
    S.a20m = 1;
    S.top->sstep = lock_step; S.top->stop_req = 0;
    // model: same image, A20 enabled on both sides
    ref_reset();
    ref_set_a20(1);
    uint8_t *rram = ref_ram();
    memset(rram, 0, ref_ram_size()); memcpy(rram, mem, MEM1M + 0x10000);
    ref_state_t rs;
    memset(&rs, 0, sizeof(rs));
    for (int k = 0; k < 8; k++) rs.gpr[k] = gp0[k];
    for (int k = 0; k < 6; k++) rs.seg[k].sel = sg0[k];            // same order: ES CS SS DS FS GS
    rs.eip = eip0; rs.eflags = efl0 & 0x7FD5;
    ref_set(&rs, 1);
    if (lock_rom) ref_set_csbase(0xFFFF0000);
    ref_set_sys(cr0_0, 0, 0, 0, 0xFFFF, 0, 0x3FF);             // the core's reset values
    ref_wlog_clear();

    std::deque<RefWr> rq;
    std::map<uint32_t, uint8_t> loose;            // PTE bytes written by one side only so far (see RefWr)
    long ins = 0, nmis = 0, hist[256] = {0};
    bool trap_pending = false, ss_pending = false, done = false;
    bool shut_done = false;
    uint32_t dip_last = 0;
    // a delivery the DUT follows with a debug trap (data breakpoint / T bit): the model ran
    // both in one step; the DUT's #DB retire is then compared without stepping
    bool model_ahead = false;
    uint32_t prev_dip = eip0;
    char first[600]; first[0] = 0;
    const long maxcyc = getenv("LOCKMAXCYC") ? atol(getenv("LOCKMAXCYC")) : 400000000;
    static const char *GN[8] = {"eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"};
    static const char *SN[6] = {"es", "cs", "ss", "ds", "fs", "gs"};
    int idle = 0;
    long last_ret = 0;
    while (S.cyc < maxcyc && !done) {
        S.tick();
        // a hang: nothing retired for 200k cycles (not halted)
        if (S.top->retire) last_ret = S.cyc;
        else if (!S.top->halted && S.cyc - last_ret > 200000) {
            printf("%-12s HANG at cycle %ld after %ld instructions: ip=%08x cs=%04x\n", name.c_str(), S.cyc, ins,
                   (uint32_t)S.top->dbg_ip, (unsigned)(S.top->dbg_seg[0] >> 16));
            break;
        }
        if (S.top->retire) {
            bool inj = S.top->dbg_ret_inj;
            dip_last = S.top->dbg_ip;
            // DUT state (gpr and segment order as in the model)
            uint32_t dg[8], dip = S.top->dbg_ip, dfl = S.top->dbg_flags;
            uint16_t dsg[6];
            for (int k = 0; k < 8; k++) dg[k] = S.top->dbg_gpr[k];
            for (int k = 0; k < 6; k++) dsg[k] = (S.top->dbg_seg[k / 2] >> (16 * (k & 1))) & 0xFFFF;
            ref_state_t pre;
            ref_get(&pre);
            uint32_t lin0 = (pre.seg[REF_CS].base + pre.eip) & 0xFFFFF;
            uint8_t ib[16], dib[16];
            for (int k = 0; k < 16; k++) ib[k] = rram[(lin0 + k) & 0xFFFFF];
            uint32_t dlin = (pre.seg[REF_CS].base + (ss_pending ? prev_dip : pre.eip)) & 0xFFFFF;
            for (int k = 0; k < 16; k++) dib[k] = rram[(dlin + k) & 0xFFFFF];
            prev_dip = dip;
            uint32_t um = 0;
            int r = 0;
            bool skip = false;
            static const bool ltrace = getenv("LOCKTRACE") != nullptr;
            if (ltrace)
                printf("  %ld %04x:%04x [%02x %02x %02x %02x %02x %02x]%s c=%ld\n", ins + 1, pre.seg[REF_CS].sel, pre.eip,
                       ib[0], ib[1], ib[2], ib[3], ib[4], ib[5], inj ? " inj" : "", S.cyc);
            if (ltrace && getenv("LOCKTRACE")[0] == '2')
                printf("     eax=%08x ecx=%08x edx=%08x ebx=%08x esi=%08x edi=%08x ebp=%08x esp=%08x ds=%04x es=%04x ss=%04x"
                       " ds.lim=%08x\n", pre.gpr[0], pre.gpr[1], pre.gpr[2], pre.gpr[3], pre.gpr[6], pre.gpr[7], pre.gpr[5],
                       pre.gpr[4], pre.seg[REF_DS].sel, pre.seg[REF_ES].sel, pre.seg[REF_SS].sel, pre.seg[REF_DS].limit);
            if (inj && model_ahead) {
                model_ahead = false;                   // (the #DB delivery: done by the model)
            } else if (inj && S.inta_seen) {
                // external interrupt (possibly inside a REP string instruction: CX left = DUT's)
                S.inta_seen = false;
                ref_step_rep_partial(dg[1] & 0xFFFF);
                ref_interrupt(8);
                if (S.top->dbg_ret_dbt) { model_ahead = true; skip = true; }
            } else if (!inj && ((pre.eflags & 0x100) || S.top->dbg_ret_dbt)) {
                // (single step, a data breakpoint)
                trap_pending = true; skip = true;      // the model steps instruction + trap together
            } else if (!inj && ss_shadow(dib)) {
                // the model steps MOV / POP SS and the next instruction together (a chain of
                // them: the DUT's instruction is at its previous next IP)
                ss_pending = true; skip = true;
            } else {
                if (trap_pending && inj) trap_pending = false;
                ss_pending = false;
                um = inj && !(pre.eflags & 0x100) ? 0 : undef_flags(ib);
                if (!inj) um = undef_flags(ib);
                r = ref_step();
                if (inj && S.top->dbg_ret_dbt) { model_ahead = true; skip = true; }
            }
            ins++;
            if (!skip) {
                int nw; const ref_wr_t *wl = ref_wlog(&nw);
                if (ltrace && getenv("LOCKTRACE")[0] == '2')
                    for (int k = 0; k < nw; k++) printf("     ref wr [%06x]=%02x\n", wl[k].addr, wl[k].val);
                long npg = -1;
                {
                    uint32_t ia = pre.seg[REF_CS].base + pre.eip;
                    if (((ia + 15) >> 12) != (ia >> 12)) npg = (ia + 15) >> 12;
                }
                for (int k = 0; k < nw; k++) {
                    uint32_t a = wl[k].addr & 0xFFFFFF;
                    if (rpg && npg >= 0 && a >= 0x8E000 && a < 0x8F000 && (long)((a - 0x8E000) >> 2) == npg) loose[a] = wl[k].val;
                    else rq.push_back({a, wl[k].val, ins, npg});
                }
                ref_wlog_clear();
                ref_state_t post;
                ref_get(&post);
                if (r & REF_STEP_HALT) post.eip++;         // the model stays on the HLT
                char buf[600]; int bl = 0; buf[0] = 0;
                // registers
                for (int k = 0; k < 8; k++)
                    if (post.gpr[k] != dg[k])
                        bl += snprintf(buf + bl, sizeof(buf) - bl, " %s=%08x/%08x", GN[k], dg[k], post.gpr[k]);
                for (int k = 0; k < 6; k++)
                    if (post.seg[k].sel != dsg[k])
                        bl += snprintf(buf + bl, sizeof(buf) - bl, " %s=%04x/%04x", SN[k], dsg[k], post.seg[k].sel);
                if (post.eip != dip)
                    bl += snprintf(buf + bl, sizeof(buf) - bl, " eip=%08x/%08x", dip, post.eip);
                // protected mode: descriptor caches (non-null selectors), CR0, CPL, LDTR, TR
                if (post.creg0 & 1) {
                    for (int k = 0; k < 6; k++) {
                        if (!(post.seg[k].sel & 0xFFFC) && k != 1) continue;
                        uint32_t db = S.top->dbg_sbase[k], dl = S.top->dbg_slim[k];
                        uint32_t da = (uint32_t)(((uint64_t)S.top->dbg_sattr >> (k * 10)) & 0x3FF);
                        uint32_t dacc = da & 0xFF, ddb = (da >> 8) & 1;
                        uint32_t macc = post.seg[k].attr & 0xFF, mdb = (post.seg[k].attr >> 10) & 1;
                        if (db != post.seg[k].base || dl != post.seg[k].limit || dacc != macc || ddb != mdb)
                            bl += snprintf(buf + bl, sizeof(buf) - bl, " %s.desc=%08x/%08x,%02x%s/%08x/%08x,%02x%s", SN[k],
                                           db, dl, dacc, ddb ? "B" : "", post.seg[k].base, post.seg[k].limit, macc, mdb ? "B" : "");
                    }
                    uint32_t mcpl = (post.seg[1].attr >> 5) & 3;
                    if ((post.eflags & 0x20000) == 0 && S.top->dbg_cpl != mcpl)
                        bl += snprintf(buf + bl, sizeof(buf) - bl, " cpl=%d/%d", (int)S.top->dbg_cpl, (int)mcpl);
                    if ((S.top->dbg_sys & 0xFFFF) != post.ldtr.sel || (S.top->dbg_sys >> 16) != post.tr.sel)
                        bl += snprintf(buf + bl, sizeof(buf) - bl, " ldtr,tr=%04x,%04x/%04x,%04x", S.top->dbg_sys & 0xFFFF,
                                       S.top->dbg_sys >> 16, post.ldtr.sel, post.tr.sel);
                }
                if ((S.top->dbg_cr0 ^ post.creg0) & 0xE005002F)
                    bl += snprintf(buf + bl, sizeof(buf) - bl, " cr0=%08x/%08x", (uint32_t)S.top->dbg_cr0, post.creg0);
                // (with AC, ID; RF with the debug registers: 86Box clears it per instruction only then)
                uint32_t fm = (0x247FD5 | (DEBUG_REGS ? 0x10000 : 0)) & ~um;
                if (DEBUG_REGS) {
                    uint32_t mdr[8];
                    ref_get_dr(mdr);
                    if (S.top->dbg_dr6 != mdr[6] || S.top->dbg_dr7 != mdr[7])
                        bl += snprintf(buf + bl, sizeof(buf) - bl, " dr6,7=%08x,%08x/%08x,%08x", (uint32_t)S.top->dbg_dr6,
                                       (uint32_t)S.top->dbg_dr7, mdr[6], mdr[7]);
                }
                if ((post.eflags & fm) != (dfl & fm))
                    bl += snprintf(buf + bl, sizeof(buf) - bl, " fl=%06x/%06x", dfl & fm, post.eflags & fm);
                if (um) ref_set_flags(um, dfl);
                // stores: every DUT byte must be in the oldest unmatched model group
                while (!S.dq.empty() && !rq.empty()) {
                    auto d = S.dq.front();
                    long g = rq.front().grp;
                    auto it = rq.begin();
                    for (; it != rq.end() && it->grp == g; ++it) if (it->addr == d.first) break;
                    if (it == rq.end() || it->grp != g) {
                        auto lt = loose.find(d.first);
                        if (lt != loose.end() && lt->second == d.second) { loose.erase(lt); S.dq.pop_front(); continue; }
                        bl += snprintf(buf + bl, sizeof(buf) - bl, " st[%05x]=%02x/none", d.first, d.second);
                        S.dq.pop_front();
                        if (bl > 400) break;
                        continue;
                    }
                    if (it->val != d.second && bl < 400)
                        bl += snprintf(buf + bl, sizeof(buf) - bl, " st[%05x]=%02x/%02x", d.first, d.second, it->val);
                    rq.erase(it);
                    S.dq.pop_front();
                }
                // stores of instructions older than the previous one must all have left W
                while (!rq.empty() && rq.front().grp < ins - 1) {
                    if (bl < 400) bl += snprintf(buf + bl, sizeof(buf) - bl, " st[%05x]=none/%02x", rq.front().addr, rq.front().val);
                    rq.pop_front();
                }
                while (!dut_o.empty() && !ref_o.empty()) {
                    if (dut_o.front() != ref_o.front() && bl < 400)
                        bl += snprintf(buf + bl, sizeof(buf) - bl, " out[%03x]=%02x/[%03x]=%02x", dut_o.front().first,
                                       dut_o.front().second, ref_o.front().first, ref_o.front().second);
                    dut_o.pop_front(); ref_o.pop_front();
                }
                if (bl) {
                    nmis++;
                    int oi = 0;
                    while (oi < 14 && (ib[oi] == 0x26 || ib[oi] == 0x2E || ib[oi] == 0x36 || ib[oi] == 0x3E || ib[oi] == 0xF2 || ib[oi] == 0xF3 ||
                                       ib[oi] == 0xF0 || (ib[oi] >= 0x64 && ib[oi] <= 0x67))) oi++;
                    hist[ib[oi]]++;
                    if (!first[0])
                        snprintf(first, sizeof(first), "insn %ld at %04x:%04x [%02x %02x %02x %02x %02x %02x %02x %02x]%s%s", ins,
                                 pre.seg[REF_CS].sel, pre.eip & 0xFFFF, ib[0], ib[1], ib[2], ib[3], ib[4], ib[5], ib[6], ib[7],
                                 inj ? " (injected)" : "", buf);
                    if (getenv("LOCKPRE")) {
                        printf("  pre:");
                        for (int k = 0; k < 8; k++) printf(" %s=%08x", GN[k], pre.gpr[k]);
                        for (int k = 0; k < 6; k++) printf(" %s=%04x", SN[k], pre.seg[k].sel);
                        printf(" fl=%04x\n", pre.eflags & 0xFFFF);
                    }
                    if (getenv("LOCKDBG")) {
                        printf("  pre: ax=%04x cx=%04x dx=%04x bx=%04x sp=%04x bp=%04x si=%04x di=%04x ds=%04x es=%04x ss=%04x fl=%04x\n",
                               pre.gpr[0] & 0xFFFF, pre.gpr[1] & 0xFFFF, pre.gpr[2] & 0xFFFF, pre.gpr[3] & 0xFFFF, pre.gpr[4] & 0xFFFF,
                               pre.gpr[5] & 0xFFFF, pre.gpr[6] & 0xFFFF, pre.gpr[7] & 0xFFFF, pre.seg[REF_DS].sel, pre.seg[REF_ES].sel,
                               pre.seg[REF_SS].sel, pre.eflags & 0xFFFF);
                        uint32_t wa = strtoul(getenv("LOCKDBG"), nullptr, 16);
                        printf("  mem[%05x]: dut=%02x ref=%02x  cyc=%ld\n", wa, mem[wa & 0xFFFFF], rram[wa & 0xFFFFF], S.cyc);
                    }
                    if (!lock_resync) break;
                    // resynchronise the model to the DUT
                    for (int k = 0; k < 8; k++) post.gpr[k] = dg[k];
                    for (int k = 0; k < 6; k++) post.seg[k].sel = dsg[k];
                    post.eip = dip; post.eflags = dfl;
                    ref_set(&post, 1);
                    // (memory: the model's copy of the bytes the DUT stored)
                    for (auto &w : rq) rram[w.addr] = mem[w.addr];
                    rq.clear();
                    ref_wlog_clear();
                }
            }
        }
        if (S.top->halted && S.top->idle && S.bus.pend.empty()) {
            // shutdown (a fault while delivering #DF): the faulting instruction never retires;
            // the model steps it once (its fault and delivery attempts end in a reset), the
            // stores of the delivery attempts are checked by the final memory image
            if (S.top->shutdown && !shut_done) {
                shut_done = true;
                int r = ref_step();
                ref_wlog_clear();
                S.dq.clear();
                rq.clear();
                if (!(r & REF_STEP_RESET)) {
                    if (!nmis) snprintf(first, sizeof first, "shutdown at %08x: the model did not shut down", dip_last);
                    nmis++;
                }
            }
            if (++idle > 2) done = true;
        }
        if (rprog && ins >= (long)nret) done = true;
    }
    // final memory image (a random program is stopped mid-flight: its stores were compared above)
    long md = 0; uint32_t ma = 0;
    // LOCKMEMIGN=addr:len (hex): bytes the model cannot know (CR0.NW write hits kept in the cache)
    uint32_t iga = 0, ign = 0;
    if (const char *ig = getenv("LOCKMEMIGN")) sscanf(ig, "%x:%x", &iga, &ign);
    if (done && !rprog && (lock_resync || !nmis))
        for (uint32_t a = 0; a < (1u << 20); a++)
            if (mem[a] != rram[a] && !(a >= iga && a < iga + ign)) {
                if (!md) ma = a;
                md++;
                static const bool lmd = getenv("LOCKMEMDIFF") != nullptr;   // list them
                if (lmd && md <= 200) printf("  mem[%05x] dut=%02x ref=%02x\n", a, mem[a], rram[a]);
            }
    S.lock = false; S.irq_per = 0;
    if (lock_rom) {
        io_rec = false;
        std::string posts, txt;
        int last = -1;
        for (auto &w : io_log) {
            if (w.first == 0x190 && w.second != last) {
                char b[8]; snprintf(b, sizeof b, " %02X", w.second); posts += b; last = w.second;
            }
            if (w.first == 0xE9) txt += (char)w.second;
        }
        if (FILE *o = fopen((fn + ".out").c_str(), "wb")) { fwrite(txt.data(), 1, txt.size(), o); fclose(o); }
        printf("%-12s POST%s (last %02X)\n", name.c_str(), posts.c_str(), last & 0xFF);
    }
    if (const char *dp = getenv("LOCKDUMP")) {           // LOCKDUMP=addr:len (hex): DUT dwords at the end
        uint32_t da = 0, dn = 0;
        if (sscanf(dp, "%x:%x", &da, &dn) == 2)
            for (uint32_t k = 0; k < dn; k += 4)
                printf("%s  [%06x] %08x%s", k % 32 ? "" : "\n", da + k,
                       mem[da + k] | mem[da + k + 1] << 8 | mem[da + k + 2] << 16 | (uint32_t)mem[da + k + 3] << 24, "");
        printf("\n");
    }
    if (done && (dut_o.size() != ref_o.size())) {       // OUT bytes left over on one side
        if (!first[0]) snprintf(first, sizeof(first), "OUT bytes: dut %zu more, ref %zu more (first dut [%03x]=%02x, ref [%03x]=%02x)",
                                dut_o.size(), ref_o.size(), dut_o.empty() ? 0 : dut_o.front().first, dut_o.empty() ? 0 : dut_o.front().second,
                                ref_o.empty() ? 0 : ref_o.front().first, ref_o.empty() ? 0 : ref_o.front().second);
        nmis++;
    }
    if (!nmis && done && !md)
        printf("%-12s LOCK OK insns=%ld cycles=%ld ipc=%.3f ref486=%llu\n", name.c_str(), ins, S.cyc, (double)ins / S.cyc,
               (unsigned long long)(ref_cycles() - ref_cyc0));
    else {
        printf("%-12s LOCK MISMATCH n=%ld%s first: %s", name.c_str(), nmis, done ? "" : (nmis ? "" : " TIMEOUT"), first);
    if (!done && !nmis) printf(" (insns=%ld cycles=%ld)\n", ins, S.cyc);
        if (md) printf(" mem: %ld bytes differ, first [%05x]=%02x/%02x", md, ma, mem[ma], rram[ma]);
        printf("\n");
        if (lock_resync) {
            printf("             by opcode:");
            for (int k = 0; k < 256; k++) if (hist[k]) printf(" %02X:%ld", k, hist[k]);
            printf("\n");
        }
    }
    fflush(stdout);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<std::string> files;
    long irq = 0;
    int verbose = 0, maxn = 1 << 30, lat = 1, showf = 3, trace = 0, bmode = 0, check = 1, kmode = 0, rndbus = 0;
    long nover = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (!strcmp(argv[i], "-b")) bmode = 1;
        else if (!strcmp(argv[i], "-k")) kmode = 1;
        else if (!strcmp(argv[i], "-kr")) { kmode = 1; lock_resync = 1; }
        else if (!strcmp(argv[i], "-ks")) { kmode = 1; lock_step = 1; }
        else if (!strcmp(argv[i], "-rom")) { kmode = 1; lock_rom = 1; }
        else if (!strcmp(argv[i], "-rb")) rndbus = 1;
        else if (!strcmp(argv[i], "-nocheck")) check = 0;
        else if (!strcmp(argv[i], "-n")) { maxn = atoi(argv[++i]); nover = maxn; }
        else if (!strcmp(argv[i], "-l")) lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-i")) irq = atol(argv[++i]);
        else if (!strcmp(argv[i], "-ipt")) ipt = fopen(argv[++i], "w");
        else if (!strcmp(argv[i], "-iptcs")) { ipt = fopen(argv[++i], "w"); ipt_cs = true; }
        else if (!strcmp(argv[i], "-s")) skipn = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-con")) showcon = 1;
        else if (!strcmp(argv[i], "-f")) showf = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-t")) trace = 1;
        else if (argv[i][0] != '+') files.push_back(argv[i]);
    }
    Sim S;
    S.top = new Vtetrium_core;
#ifdef TRACE
    if (getenv("WAVE")) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedFstC;
        S.top->trace(tfp, 99);
        tfp->open(getenv("WAVE"));
        tstart = getenv("WSTART") ? atol(getenv("WSTART")) : 0;
        tlen = getenv("WLEN") ? atol(getenv("WLEN")) : 100000;
    }
#endif
    S.bus.lat = lat;
    S.trace = trace;
    long tp = 0, tt = 0;
    for (auto &fn : files) {
        if (kmode) { lock_nret = nover; run_lock(S, fn, lat, rndbus, irq); }
        else if (bmode) run_bench(S, fn, lat, check, irq, rndbus);
        else {
            // SingleStepTests/80386 files (tests/conv386.py)
            char mg[4] = {0}; FILE *tf = fopen(fn.c_str(), "rb");
            if (tf) { if (fread(mg, 1, 4, tf) != 4) mg[0] = 0; fclose(tf); }
            if (!memcmp(mg, "T386", 4)) run_t386(S, fn, verbose, maxn, showf, tp, tt);
            else printf("%s LOADERR\n", fn.c_str());
        }
    }
    if (!bmode && !kmode && files.size() > 1) printf("TOTAL %ld/%ld\n", tp, tt);
#ifdef TRACE
    if (tfp) tfp->close();
#endif
    delete S.top;
    return 0;
}
