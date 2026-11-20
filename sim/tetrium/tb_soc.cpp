// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
//
// ao486 SoC + Tetrium simulation (Verilator) with an SDL window showing the VGA output.
// Plays the MiSTer HPS (Main_MiSTer support/x86/x86.cpp): BIOS images into the DDR3 model,
// CMOS / floppy configuration through the mgmt bus, PS/2 keyboard host side; IDE: ide.cpp port
// (hdd image, -hd).  usage: Vsoc_sim [-rom <dir with boot0.rom boot1.rom>] [-hd <image>]
//        [-mhz N] [-lat ns] [-cycles N] [-nowin] [-shot file.ppm]
//        [-cdiv N] (CPU clock = clk / 2^N) [-cdivsw C] (step the divider every C cycles)
#include "Vsoc_sim.h"
#include "verilated.h"
#include "verilated_save.h"
#include <SDL2/SDL.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <chrono>
#include <deque>
#include <string>
#include <vector>
#include "ide_hps.h"

static Vsoc_sim *top;
static uint64_t cyc = 0, nret = 0;
static double mhz_g = 33.333333;
#ifdef _WIN32
double sc_time_stamp() { return (double)cyc; }   // no weak default on MinGW
#endif
static bool trace_ip = false;
bool trace_ide = false;          // -ide: IDE port I/O, controller requests and HPS replies
static uint8_t vga_shadow[0x20000];     // bytes as written on the L2 -> VGA bus

// ---------------------------------------------------------------- DDR3 model (64-bit words)
static const uint32_t DDR_WORDS = 1u << 25;    // 256 MB
static std::vector<uint64_t> ddr(DDR_WORDS, 0);
static int ddr_lat = 4;
struct DdrRd { uint32_t a; int left; uint64_t t; bool act; } drd = {0, 0, 0, false};

static void ddr_poke(uint32_t a, uint8_t v) {
    uint64_t &w = ddr[(a >> 3) & (DDR_WORDS - 1)];
    int s = (a & 7) * 8;
    w = (w & ~(0xFFull << s)) | ((uint64_t)v << s);
}
static uint8_t ddr_peek(uint32_t a) { return ddr[(a >> 3) & (DDR_WORDS - 1)] >> ((a & 7) * 8); }

// ---------------------------------------------------------------- clocking
static bool acc_rd, acc_wr;
static void mchk_pre();
static void ddr_pre() {                 // before the edge: what the L2 hands over at it
    acc_rd = top->DDRAM_RD && !top->DDRAM_BUSY;
    acc_wr = top->DDRAM_WE && !top->DDRAM_BUSY;
    mchk_pre();
}
static void ddr_post() {                // after the edge: model state and next-cycle inputs
    if (acc_wr) {
        uint64_t &w = ddr[top->DDRAM_ADDR & (DDR_WORDS - 1)];
        for (int b = 0; b < 8; b++)
            if (top->DDRAM_BE >> b & 1) w = (w & ~(0xFFull << (8 * b))) | (top->DDRAM_DIN & (0xFFull << (8 * b)));
    }
    if (acc_rd) drd = {(uint32_t)top->DDRAM_ADDR, (int)top->DDRAM_BURSTCNT, cyc + ddr_lat, true};
    top->DDRAM_DOUT_READY = 0;
    if (drd.act && cyc >= drd.t) {
        top->DDRAM_DOUT = ddr[drd.a & (DDR_WORDS - 1)];
        top->DDRAM_DOUT_READY = 1;
        drd.a++;
        if (--drd.left <= 0) drd.act = false;
    }
    top->DDRAM_BUSY = drd.act;
}

// ---------------------------------------------------------------- video capture + window
static const int FBW = 1024, FBH = 1024;
static std::vector<uint32_t> fb(FBW * FBH), shown(FBW * FBH);
static int vx = 0, vy = 0, line_w = 0, frame_w = 640, frame_h = 400, blank_lines = 0;
static bool line_act = false, old_blank = false, old_hs = false;
static bool frame_ready = false;
static long frames = 0;

static long blank_drops = 0;            // blank_n falling edges inside a line (diagnostic)
static void video_tick() {
    if (!top->video_ce) return;
    bool bl = top->video_blank_n, hs = top->video_hsync;
    if (bl) {
        if (vx < FBW && vy < FBH) fb[vy * FBW + vx] = 0xFF000000u | (top->video_r << 16) | (top->video_g << 8) | top->video_b;
        vx++;
        line_act = true;
    }
    if (old_blank && !bl) blank_drops++;
    if (hs && !old_hs) {                // one rising edge per line; a frame ends after two empty lines
        if (line_act) { line_w = vx; vy++; blank_lines = 0; }
        else if (++blank_lines == 2 && vy > 0) {
            frame_w = line_w > 0 ? std::min(line_w, FBW) : frame_w;
            frame_h = std::min(vy, FBH);
            shown = fb; frame_ready = true; frames++;
            vy = 0;
        }
        line_act = false; vx = 0;
    }
    old_blank = bl; old_hs = hs;
}

// ---------------------------------------------------------------- keyboard (PS/2 set 2)
static std::deque<uint8_t> kbd_out;
static std::vector<double> enter_at;
static std::vector<std::pair<double, std::string>> type_at;
static double shot_every = 0;
static int kbd_cmd = 0;                 // pending command waiting for its data byte
static void kbd_host() {
    top->kbd_we = 0;
    top->kbd_rd = 0;
    if (top->kbd_rdata >> 8 & 1) {
        uint8_t c = top->kbd_rdata & 0xFF;
        top->kbd_rd = 1;
        if (kbd_cmd) { kbd_cmd = 0; kbd_out.push_back(0xFA); }
        else if (c == 0xFF) { kbd_out.push_back(0xFA); kbd_out.push_back(0xAA); }
        else if (c == 0xF2) { kbd_out.push_back(0xFA); kbd_out.push_back(0xAB); kbd_out.push_back(0x83); }
        else if (c == 0xEE) kbd_out.push_back(0xEE);
        else { if (c == 0xED || c == 0xF3 || c == 0xF0) kbd_cmd = c; kbd_out.push_back(0xFA); }
        return;
    }
    // one byte per ~1 ms (a PS/2 byte takes ~0.7 ms on the wire; ps2_device has a short FIFO)
    static uint64_t klast;
    if (!kbd_out.empty() && cyc - klast >= (uint64_t)(mhz_g * 1000)) {
        klast = cyc;
        top->kbd_wdata = kbd_out.front(); kbd_out.pop_front();
        top->kbd_we = 1;
    }
}
// PS/2 mouse: Main_MiSTer user_io.cpp's host-command replies (no movement yet)
static std::deque<uint8_t> ms_out;
static uint8_t ms_cmd = 0, ms_byte = 0;
static void ms_host() {
    uint8_t &cmd = ms_cmd, &byte = ms_byte;
    top->ms_we = 0;
    top->ms_rd = 0;
    if (top->ms_rdata >> 8 & 1) {
        uint8_t c = top->ms_rdata & 0xFF;
        top->ms_rd = 1;
        if (!byte) {
            cmd = c;
            switch (c) {
            case 0xE8: case 0xF3: ms_out.push_back(0xFA); byte++; break;
            case 0xF2: ms_out.push_back(0xFA); ms_out.push_back(0x00); break;
            case 0xE6: case 0xEA: case 0xF0: case 0xF4: case 0xF5: case 0xF6: ms_out.push_back(0xFA); break;
            case 0xE9: for (uint8_t b : {0xFA, 0x00, 0x00, 0x00}) ms_out.push_back(b); break;
            case 0xFF: for (uint8_t b : {0xFA, 0xAA, 0x00}) ms_out.push_back(b); break;
            default: ms_out.push_back(0xFE); break;
            }
        } else {
            if (cmd == 0xF3 || cmd == 0xE8) ms_out.push_back(0xFA);
            byte = 0;
        }
        return;
    }
    static uint64_t mlast;
    if (!ms_out.empty() && cyc - mlast >= (uint64_t)(mhz_g * 1000)) {
        mlast = cyc;
        top->ms_wdata = ms_out.front(); ms_out.pop_front();
        top->ms_we = 1;
    }
}
static int sc2(SDL_Scancode s, bool &ext) {
    ext = false;
    switch (s) {
    case SDL_SCANCODE_A: return 0x1C; case SDL_SCANCODE_B: return 0x32; case SDL_SCANCODE_C: return 0x21;
    case SDL_SCANCODE_D: return 0x23; case SDL_SCANCODE_E: return 0x24; case SDL_SCANCODE_F: return 0x2B;
    case SDL_SCANCODE_G: return 0x34; case SDL_SCANCODE_H: return 0x33; case SDL_SCANCODE_I: return 0x43;
    case SDL_SCANCODE_J: return 0x3B; case SDL_SCANCODE_K: return 0x42; case SDL_SCANCODE_L: return 0x4B;
    case SDL_SCANCODE_M: return 0x3A; case SDL_SCANCODE_N: return 0x31; case SDL_SCANCODE_O: return 0x44;
    case SDL_SCANCODE_P: return 0x4D; case SDL_SCANCODE_Q: return 0x15; case SDL_SCANCODE_R: return 0x2D;
    case SDL_SCANCODE_S: return 0x1B; case SDL_SCANCODE_T: return 0x2C; case SDL_SCANCODE_U: return 0x3C;
    case SDL_SCANCODE_V: return 0x2A; case SDL_SCANCODE_W: return 0x1D; case SDL_SCANCODE_X: return 0x22;
    case SDL_SCANCODE_Y: return 0x35; case SDL_SCANCODE_Z: return 0x1A;
    case SDL_SCANCODE_1: return 0x16; case SDL_SCANCODE_2: return 0x1E; case SDL_SCANCODE_3: return 0x26;
    case SDL_SCANCODE_4: return 0x25; case SDL_SCANCODE_5: return 0x2E; case SDL_SCANCODE_6: return 0x36;
    case SDL_SCANCODE_7: return 0x3D; case SDL_SCANCODE_8: return 0x3E; case SDL_SCANCODE_9: return 0x46;
    case SDL_SCANCODE_0: return 0x45;
    case SDL_SCANCODE_RETURN: return 0x5A; case SDL_SCANCODE_ESCAPE: return 0x76; case SDL_SCANCODE_BACKSPACE: return 0x66;
    case SDL_SCANCODE_TAB: return 0x0D; case SDL_SCANCODE_SPACE: return 0x29; case SDL_SCANCODE_MINUS: return 0x4E;
    case SDL_SCANCODE_EQUALS: return 0x55; case SDL_SCANCODE_LEFTBRACKET: return 0x54; case SDL_SCANCODE_RIGHTBRACKET: return 0x5B;
    case SDL_SCANCODE_BACKSLASH: return 0x5D; case SDL_SCANCODE_SEMICOLON: return 0x4C; case SDL_SCANCODE_APOSTROPHE: return 0x52;
    case SDL_SCANCODE_GRAVE: return 0x0E; case SDL_SCANCODE_COMMA: return 0x41; case SDL_SCANCODE_PERIOD: return 0x49;
    case SDL_SCANCODE_SLASH: return 0x4A; case SDL_SCANCODE_CAPSLOCK: return 0x58;
    case SDL_SCANCODE_F1: return 0x05; case SDL_SCANCODE_F2: return 0x06; case SDL_SCANCODE_F3: return 0x04;
    case SDL_SCANCODE_F4: return 0x0C; case SDL_SCANCODE_F5: return 0x03; case SDL_SCANCODE_F6: return 0x0B;
    case SDL_SCANCODE_F7: return 0x83; case SDL_SCANCODE_F8: return 0x0A; case SDL_SCANCODE_F9: return 0x01;
    case SDL_SCANCODE_F10: return 0x09; case SDL_SCANCODE_F11: return 0x78; case SDL_SCANCODE_F12: return 0x07;
    case SDL_SCANCODE_LSHIFT: return 0x12; case SDL_SCANCODE_RSHIFT: return 0x59; case SDL_SCANCODE_LCTRL: return 0x14;
    case SDL_SCANCODE_LALT: return 0x11;
    case SDL_SCANCODE_RCTRL: ext = true; return 0x14; case SDL_SCANCODE_RALT: ext = true; return 0x11;
    case SDL_SCANCODE_UP: ext = true; return 0x75; case SDL_SCANCODE_DOWN: ext = true; return 0x72;
    case SDL_SCANCODE_LEFT: ext = true; return 0x6B; case SDL_SCANCODE_RIGHT: ext = true; return 0x74;
    case SDL_SCANCODE_HOME: ext = true; return 0x6C; case SDL_SCANCODE_END: ext = true; return 0x69;
    case SDL_SCANCODE_PAGEUP: ext = true; return 0x7D; case SDL_SCANCODE_PAGEDOWN: ext = true; return 0x7A;
    case SDL_SCANCODE_INSERT: ext = true; return 0x70; case SDL_SCANCODE_DELETE: ext = true; return 0x71;
    default: return 0;
    }
}

// ---------------------------------------------------------------- mgmt bus (HPS -> SoC)
static void tick();
void mgmt_write(uint16_t a, uint16_t d) {
    top->mgmt_address = a; top->mgmt_writedata = d; top->mgmt_write = 1;
    tick();
    top->mgmt_write = 0;
    tick();       // strobe low between writes: ide.v / floppy.v step their buffer address on its falling edge
}
uint16_t mgmt_read(uint16_t a) {
    top->mgmt_address = a;
    tick(); tick();
    uint16_t d = top->mgmt_readdata;     // the data at the address, then the read strobe
    top->mgmt_read = 1;
    tick();
    top->mgmt_read = 0;
    tick();       // strobe falls at this address (ide.v counts data-port accesses on the falling edge)
    return d;
}

// ---------------------------------------------------------------- HPS init (x86_init)
static std::string romdir = "releases";
static std::string hdimg;
static bool load_rom(const std::string &f, uint32_t at) {
    FILE *fp = fopen(f.c_str(), "rb");
    if (!fp) { printf("cannot open %s\n", f.c_str()); return false; }
    int c; uint32_t a = at;
    while ((c = fgetc(fp)) != EOF) ddr_poke(a++, (uint8_t)c);
    fclose(fp);
    printf("BIOS: %s at %05x (%u bytes)\n", f.c_str(), at, a - at);
    return true;
}
static uint8_t bcd(int v) { return ((v / 10) << 4) + (v % 10); }

static void mchk_init();
static void hps_init() {
    top->reset = 1;
    for (int i = 0; i < 16; i++) tick();
    for (uint32_t a = 0xA0000; a < 0x100000; a++) ddr_poke(a, 0xFF);
    for (uint32_t a = 0xA0000; a < 0xC0000; a++) ddr_poke(a, 0x00);
    for (uint32_t a = 0xCE000; a < 0xD0000; a++) ddr_poke(a, 0x00);
    load_rom(romdir + "/boot1.rom", 0xC0000);
    load_rom(romdir + "/boot0.rom", 0xF0000);
    ide_hps_reset();
    // floppy A: / B: none
    for (int n = 0; n < 2; n++) {
        uint16_t b = 0xF200 + (n << 7);
        mgmt_write(b + 0, 0); mgmt_write(b + 0, 0); mgmt_write(b + 1, 1);
        mgmt_write(b + 2, 0); mgmt_write(b + 3, 0); mgmt_write(b + 4, 0);
        mgmt_write(b + 5, 0); mgmt_write(b + 6, 0); mgmt_write(b + 0xC, 0);
    }
    bool hd = ide_hps_mount(0, hdimg);
    time_t t = time(nullptr);
    struct tm tm = *localtime(&t);
    uint8_t memcfg = 1;                  // 16 MB
    uint8_t tr = 1; tr = (tr << 6) | (tr << 4) | (tr << 2) | tr;
    uint8_t cmos[128] = {
        bcd(tm.tm_sec), 0, bcd(tm.tm_min), 0, bcd(tm.tm_hour), 0x12, (uint8_t)(tm.tm_wday + 1),
        bcd(tm.tm_mday), bcd(tm.tm_mon + 1), bcd(tm.tm_year < 117 ? 17 : tm.tm_year - 100),
        0x26, 0x02, 0x00, 0x80, 0x00, 0x00,
        0x11,                            // 0x10 floppy types (get_fdd_bios_type(none) = 1)
        0x00, (uint8_t)(hd ? 0xF0 : 0x00), 0x00, 0x4D, 0x80, 0x02, 0x00,
        (uint8_t)(memcfg ? 0x3C : 0xFC), (uint8_t)(hd ? 0x2F : 0x00), 0x00,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0x00,                            // 0x2D boot sequence
        0x00, 0x00, 0x00, (uint8_t)(memcfg ? 0x3C : 0xFC), 0x20, 0x00,
        (uint8_t)(memcfg ? 0x00 : 0x80), (uint8_t)(memcfg ? 0x00 : 0x0E), 0x00, 0x20, 0x00, tr, 0x00,
        0x00, 0x00, 0x02, 0x00, 0x00 };
    uint16_t sum = 0;
    for (int i = 0x10; i <= 0x2D; i++) sum += cmos[i];
    cmos[0x2E] = sum >> 8; cmos[0x2F] = sum & 0xFF;
    for (int i = 0; i < 128; i++) mgmt_write(0xF400 + i, cmos[i]);
    for (int i = 0; i < 16; i++) tick();
    top->reset = 0;
    mchk_init();
}

static void save_ppm(const std::string &fn) {
    FILE *f = fopen(fn.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6 %d %d 255\n", frame_w, frame_h);
    for (int y = 0; y < frame_h; y++)
        for (int x = 0; x < frame_w; x++) { uint32_t p = shown[y * FBW + x]; fputc(p >> 16, f); fputc(p >> 8, f); fputc(p, f); }
    fclose(f);
}
// ---------------------------------------------------------------- save / restore (-save T file, -load file)
// Model (Verilator --savable) + testbench state: cycle counters, DDR, DDR read in flight,
// keyboard / mouse queues, the HPS IDE state; the disk image is copied to <file>.vhd at the save.
static bool copy_file(const std::string &a, const std::string &b) {
    FILE *i = fopen(a.c_str(), "rb"), *o = i ? fopen(b.c_str(), "wb") : nullptr;
    if (!i || !o) { if (i) fclose(i); return false; }
    static char cb[1 << 20]; size_t n;
    while ((n = fread(cb, 1, sizeof cb, i)) > 0) fwrite(cb, 1, n, o);
    fclose(i); fclose(o); return true;
}
static void put_q(VerilatedSave &os, const std::deque<uint8_t> &q) {
    uint32_t n = q.size(); os.write(&n, 4); for (uint8_t b : q) os.write(&b, 1);
}
static void get_q(VerilatedRestore &is, std::deque<uint8_t> &q) {
    uint32_t n; is.read(&n, 4); q.clear(); for (uint32_t k = 0; k < n; k++) { uint8_t b; is.read(&b, 1); q.push_back(b); }
}
static void state_save(const std::string &fn) {
    VerilatedSave os;
    os.open(fn.c_str());
    os << *top;
    os.write(&cyc, 8); os.write(&nret, 8);
    os.write(ddr.data(), ddr.size() * 8);
    os.write(&drd, sizeof drd);
    os.write(vga_shadow, sizeof vga_shadow);
    put_q(os, kbd_out); put_q(os, ms_out);
    os.write(&kbd_cmd, sizeof kbd_cmd); os.write(&ms_cmd, 1); os.write(&ms_byte, 1);
    std::vector<uint8_t> ide = ide_hps_state();
    uint32_t n = ide.size(); os.write(&n, 4); os.write(ide.data(), n);
    os.close();
    bool ok = hdimg.empty() || copy_file(hdimg, fn + ".vhd");
    printf("[state saved to %s at %.3f s%s]\n", fn.c_str(), cyc / (mhz_g * 1e6), ok ? "" : " (disk image copy FAILED)");
    fflush(stdout);
}
static bool state_load(const std::string &fn) {
    VerilatedRestore is;
    is.open(fn.c_str());
    if (!is.isOpen()) { printf("cannot open %s\n", fn.c_str()); return false; }
    is >> *top;
    is.read(&cyc, 8); is.read(&nret, 8);
    is.read(ddr.data(), ddr.size() * 8);
    is.read(&drd, sizeof drd);
    is.read(vga_shadow, sizeof vga_shadow);
    get_q(is, kbd_out); get_q(is, ms_out);
    is.read(&kbd_cmd, sizeof kbd_cmd); is.read(&ms_cmd, 1); is.read(&ms_byte, 1);
    uint32_t n; is.read(&n, 4);
    std::vector<uint8_t> ide(n); is.read(ide.data(), n);
    is.close();
    if (!ide_hps_set_state(ide)) { printf("IDE state size mismatch\n"); return false; }
    mchk_init();
    printf("[state loaded from %s: %.3f s, insn %llu]\n", fn.c_str(), cyc / (mhz_g * 1e6), (unsigned long long)nret);
    return true;
}
// -type T text: type a string at sim time T (\n = Enter)
static int sc_ascii(char c, bool &shift) {
    static const char *lo = "abcdefghijklmnopqrstuvwxyz";
    static const uint8_t let[26] = {0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,0x42,0x4B,0x3A,
                                    0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,0x3C,0x2A,0x1D,0x22,0x35,0x1A};
    static const uint8_t dig[10] = {0x45,0x16,0x1E,0x26,0x25,0x2E,0x36,0x3D,0x3E,0x46};
    shift = false;
    if (c >= 'A' && c <= 'Z') { shift = true; c = c - 'A' + 'a'; }
    if (c >= 'a' && c <= 'z') return let[strchr(lo, c) - lo];
    if (c >= '0' && c <= '9') return dig[c - '0'];
    switch (c) {
    case ' ': return 0x29; case '\n': return 0x5A; case '.': return 0x49; case '\\': return 0x5D;
    case '-': return 0x4E; case '/': return 0x4A; case ':': shift = true; return 0x4C; case '_': shift = true; return 0x4E;
    case '*': shift = true; return 0x3E; case '>': shift = true; return 0x49; case '<': shift = true; return 0x41;
    case '?': shift = true; return 0x4A; case '=': return 0x55; case ',': return 0x41; case ';': return 0x4C;
    }
    return 0;
}
static void type_text(const std::string &t) {
    for (char c : t) {
        bool sh; int k = sc_ascii(c, sh);
        if (!k) continue;
        if (sh) kbd_out.push_back(0x12);
        kbd_out.push_back(k); kbd_out.push_back(0xF0); kbd_out.push_back(k);
        if (sh) { kbd_out.push_back(0xF0); kbd_out.push_back(0x12); }
    }
}
// ---------------------------------------------------------------- memory checker
// Reference copy of RAM (below A0000h and 1-16 MB) kept from the writes the L2 accepts
// (CPU and ISA DMA), compared with every read beat the L2 returns.
static std::vector<uint8_t> refm;
static std::deque<std::pair<uint32_t, int>> mrq;     // accepted reads: word address, beats
static uint64_t mchk_n = 0, mchk_bad = 0;
static bool mchk_on = true;
static inline bool mchk_rgn(uint32_t a) { return a < 0xA0000 || (a >= 0x100000 && a < (16u << 20)); }
static void mchk_init() {
    refm.assign(16u << 20, 0);
    memcpy(refm.data(), ddr.data(), 16u << 20);
    mrq.clear();
}
static void mchk_edge(bool acc_r, bool acc_w, uint32_t addr, uint64_t wd, uint8_t be, int bc) {
    // (values sampled before the edge: what the L2 took at it)
    if (acc_w)
        for (int b = 0; b < 8; b++)
            if (be >> b & 1) { uint32_t a = addr * 8 + b; if (mchk_rgn(a)) refm[a] = wd >> (8 * b); }
    if (acc_r) mrq.push_back({addr, bc ? bc : 1});
}
static void mchk_rvalid(uint64_t rd) {
    if (mrq.empty()) { if (mchk_bad++ < 20) printf("MEMCHK: read data without a request at %llu\n", (unsigned long long)cyc); return; }
    uint32_t wa = mrq.front().first;
    if (--mrq.front().second == 0) mrq.pop_front(); else mrq.front().first++;
    mchk_n++;
    for (int b = 0; b < 8; b++) {
        uint32_t a = wa * 8 + b;
        if (!mchk_rgn(a)) continue;
        uint8_t got = rd >> (8 * b), exp = refm[a];
        if (got != exp) {
            if (mchk_bad++ < 40)
                printf("MEMCHK: %.4f s cycle %llu addr %06x: read %02x, last written %02x (word %016llx) CS:EIP %04x:%08x\n",
                       cyc / (mhz_g * 1e6), (unsigned long long)cyc, a, got, exp, (unsigned long long)rd, top->dbg_cs, top->dbg_ip);
            refm[a] = got;          // report each corruption once
        }
    }
}
static bool mc_r, mc_w, mc_rv; static uint32_t mc_a; static uint64_t mc_wd, mc_rd; static uint8_t mc_be; static int mc_bc;
static void mchk_pre() {
    if (!mchk_on || refm.empty() || top->reset) return;
    mc_r = top->dbg_m_rd && !top->dbg_m_wait; mc_w = top->dbg_m_wr && !top->dbg_m_wait;
    mc_a = top->dbg_m_addr; mc_wd = top->dbg_m_wdata; mc_be = top->dbg_m_be; mc_bc = top->dbg_m_bc;
    mc_rv = top->dbg_m_rvalid; mc_rd = top->dbg_m_rdata;
    if (mc_rv) mchk_rvalid(mc_rd);          // data valid in the cycle before the edge
    mchk_edge(mc_r, mc_w, mc_a, mc_wd, mc_be, mc_bc);
}
// ---------------------------------------------------------------- main loop
static void sys_edge() {
    if (top->dbg_vga_we) {
        vga_shadow[top->dbg_vga_addr] = top->dbg_vga_data;
    }
    ddr_post();
    kbd_host();
    ms_host();
    if (top->dbg_io_wr) {
        static bool newl = true;
        uint16_t a = top->dbg_io_addr;
        if (a == 0x8888 || a == 0xE9) { char c = top->dbg_io_data & 0xFF; putchar(c); newl = (c == '\n'); fflush(stdout); }   // E9: tests486/hwstress console
        else if (a == 0x80) {           // POST codes: changes only (the BIOS also uses port 80h for delays)
            static int last = -1;
            int v = top->dbg_io_data & 0xFF;
            if (v != last) { printf("%sPOST %02X at %.3f s\n", newl ? "" : "\n", v, cyc / 33.3e6); newl = true; last = v; }
        }
    }
    if (trace_ide) {
        auto ideport = [](uint16_t a) { return (a >= 0x1F0 && a <= 0x1F7) || a == 0x3F6 || a == 0x3F7 || (a >= 0x170 && a <= 0x177) || a == 0x376 || a == 0x377; };
        if (top->dbg_io_wr && ideport(top->dbg_io_addr))
            printf("%.4f IOW %03x/%d %0*x\n", cyc / 33.3e6, top->dbg_io_addr, top->dbg_io_len, top->dbg_io_len * 2, top->dbg_io_data);
        if (top->dbg_ior_done && ideport(top->dbg_ior_addr)) {
            static uint16_t la; static uint32_t ld, rep;
            uint32_t dm = top->dbg_ior_len >= 4 ? top->dbg_ior_data : top->dbg_ior_data & ((1u << (8 * top->dbg_ior_len)) - 1);
            if (top->dbg_ior_addr == 0x1F0) { printf("D%d:%0*x ", top->dbg_ior_len, top->dbg_ior_len * 2, dm); goto ide_rd_done; }
            bool same = top->dbg_ior_addr == la && top->dbg_ior_data == ld;
            if (same) rep++;
            else {
                if (rep) printf("        (x%u)\n", rep);
                rep = 0; la = top->dbg_ior_addr; ld = top->dbg_ior_data;
                printf("%.4f IOR %03x/%d %0*x\n", cyc / 33.3e6, top->dbg_ior_addr, top->dbg_ior_len, top->dbg_ior_len * 2, dm);
            }
        }
        ide_rd_done:
        static int lreq = -1;
        if (top->ide0_request != lreq) { printf("%.4f ide0_request %d\n", cyc / 33.3e6, top->ide0_request); lreq = top->ide0_request; }
    }
    {   // rings of the last exceptions / INT n and retired CS:IPs, dumped at a shutdown (triple fault)
        struct Inj { uint64_t cyc; uint16_t cs; uint32_t ip; uint8_t vec, flt; uint16_t err; };
        static Inj inj[64]; static unsigned ni;
        static uint32_t rip[64]; static uint16_t rcs[64]; static unsigned nr;
        static bool lshut;
        if (top->dbg_inj) inj[ni++ & 63] = {cyc, top->dbg_cs, top->dbg_inj_ip, top->dbg_inj_vec, top->dbg_inj_flt, top->dbg_inj_err};
        if (top->dbg_retire) { rcs[nr & 63] = top->dbg_cs; rip[nr++ & 63] = top->dbg_ip; }
        if (top->dbg_shutdown && !lshut) {
            printf("\n*** SHUTDOWN (triple fault) at %.4f s, insn %llu\n", cyc / (mhz_g * 1e6), (unsigned long long)nret);
            printf("last deliveries (cycle, CS:EIP of the instruction, vector, fault, error code):\n");
            for (unsigned k = ni > 64 ? ni - 64 : 0; k < ni; k++) {
                Inj &e = inj[k & 63];
                printf("  %llu %04x:%08x vec %02x %s err %04x\n", (unsigned long long)e.cyc, e.cs, e.ip, e.vec, e.flt ? "fault" : "int", e.err);
            }
            printf("last retired:");
            for (unsigned k = nr > 32 ? nr - 32 : 0; k < nr; k++) printf("%s%04x:%08x", (k % 4) ? " " : "\n  ", rcs[k & 63], rip[k & 63]);
            printf("\n");
            static const char *gn[8] = {"EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI"};
            for (int r = 0; r < 8; r++) printf("%s %08x%s", gn[r], top->dbg_gpr[r], r == 3 ? "\n" : " ");
            static const char *sn[6] = {"ES", "CS", "SS", "DS", "FS", "GS"};
            printf("\n");
            for (int r = 0; r < 6; r++) printf("%s %04x ", sn[r], (top->dbg_seg[r / 2] >> (16 * (r & 1))) & 0xFFFF);
            printf("\nEFLAGS %08x CR0 %08x CR2 %08x CR3 %08x IDT %08x GDT %08x TR.base %08x TR/LDTR %08x\n",
                   top->dbg_flags, top->dbg_cr0, top->dbg_cr2, top->dbg_cr3, top->dbg_idtb, top->dbg_gdtb, top->dbg_trb, top->dbg_sys);
            FILE *mf = fopen("shutdown.mem", "wb");      // first 16 MB of physical memory
            if (mf) { fwrite(ddr.data(), 8, (16u << 20) / 8, mf); fclose(mf); printf("memory: shutdown.mem (16 MB)\n"); }
            fflush(stdout);
        }
        lshut = top->dbg_shutdown;
    }
    if (top->dbg_retire) {
        nret++;
        if (trace_ip) printf("  ret %llu %04x:%08x\n", (unsigned long long)nret, top->dbg_cs, top->dbg_ip);
    }
}
// one clk_sys cycle = two clk_vga cycles: sys+vga rise, vga fall, sys fall + vga rise, vga fall
static long long cdivsw = 0;
static void tick() {
    ddr_pre();
    if (cdivsw && cyc && cyc % cdivsw == 0) top->cpu_clk_div = (top->cpu_clk_div + 1) & 3;
    top->clk = 1; top->clk_vga = 1; top->eval();
    cyc++;
    video_tick();
    sys_edge();
    top->clk_vga = 0; top->eval();
    top->clk = 0; top->clk_vga = 1; top->eval();
    video_tick();
    top->clk_vga = 0; top->eval();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    double mhz = 33.333333;
    int cdiv = 0;
    long long maxcyc = 0;
    double save_t = -1; std::string save_fn, load_fn;
    bool win = true;
    std::string shot;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-rom" && i + 1 < argc) romdir = argv[++i];
        else if (a == "-hd" && i + 1 < argc) hdimg = argv[++i];
        else if (a == "-mhz" && i + 1 < argc) mhz = atof(argv[++i]);
        else if (a == "-cdiv" && i + 1 < argc) cdiv = atoi(argv[++i]) & 3;
        else if (a == "-cdivsw" && i + 1 < argc) cdivsw = atoll(argv[++i]);
        else if (a == "-lat" && i + 1 < argc) ddr_lat = 0;   // set below from ns
        else if (a == "-cycles" && i + 1 < argc) maxcyc = atoll(argv[++i]);
        else if (a == "-nowin") win = false;
        else if (a == "-trace") trace_ip = true;
        else if (a == "-ide") trace_ide = true;
        else if (a == "-shot" && i + 1 < argc) shot = argv[++i];
        else if (a == "-enter" && i + 1 < argc) enter_at.push_back(atof(argv[++i]));   // press Enter at sim time T s
        else if (a == "-shotevery" && i + 1 < argc) shot_every = atof(argv[++i]);     // live.ppm every S sim seconds
        else if (a == "-save" && i + 2 < argc) { save_t = atof(argv[++i]); save_fn = argv[++i]; }  // save the state at T s
        else if (a == "-load" && i + 1 < argc) load_fn = argv[++i];
        else if (a == "-type" && i + 2 < argc) {                                      // -type T "text" (\n = Enter)
            double t = atof(argv[++i]); std::string x;
            for (const char *q = argv[++i]; *q; q++) {
                if (q[0] == '\\' && q[1] == 'n') { x += '\n'; q++; } else x += *q;
            }
            type_at.push_back({t, x});
        }
    }
    mhz_g = mhz;
    ddr_lat = (int)(120e-9 * mhz * 1e6 + 0.999);       // ~120 ns first-word latency
    top = new Vsoc_sim;
    top->clock_rate = (uint32_t)(mhz * 1e6);
    top->cpu_clk_div = cdiv;
    top->DDRAM_BUSY = 0; top->DDRAM_DOUT_READY = 0;
    top->mgmt_read = 0; top->mgmt_write = 0; top->kbd_we = 0; top->kbd_rd = 0; top->ms_we = 0; top->ms_rd = 0;
    top->clk = 0; top->clk_vga = 0; top->eval();

    SDL_Window *w = nullptr; SDL_Renderer *rnd = nullptr; SDL_Texture *tex = nullptr;
    if (win) {
        if (SDL_Init(SDL_INIT_VIDEO) != 0) { printf("SDL: %s\n", SDL_GetError()); win = false; }
        else {
            w = SDL_CreateWindow("Tetrium on ao486 SoC (simulation)", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                 1280, 800, SDL_WINDOW_RESIZABLE);
            rnd = SDL_CreateRenderer(w, -1, 0);
            tex = SDL_CreateTexture(rnd, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, FBW, FBH);
        }
    }
    if (!load_fn.empty()) {
        if (hdimg.empty()) { hdimg = load_fn + ".run.vhd"; copy_file(load_fn + ".vhd", hdimg); }
        ide_hps_reset();
        ide_hps_mount(0, hdimg);
        if (!state_load(load_fn)) return 1;
    } else hps_init();
    auto t0 = std::chrono::steady_clock::now(), tlast = t0;
    uint64_t clast = cyc;
    bool quit = false;
    while (!quit && !Verilated::gotFinish() && (!maxcyc || (long long)cyc < maxcyc)) {
        for (int k = 0; k < 4096; k++) {
            tick();
            if ((cyc & 2047) == 0) ide_hps_poll(top->ide0_request);   // the HPS polls every ~60 us
            if (!top->ps2_reset_n) { printf("keyboard controller reset\n"); hps_init(); }
        }
        {
            double t = cyc / (mhz * 1e6);
            for (auto &ea : enter_at)
                if (ea >= 0 && t >= ea) { for (uint8_t b : {0x5A, 0xF0, 0x5A}) kbd_out.push_back(b); printf("[Enter at %.2f s]\n", t); ea = -1; }
            for (auto &ta : type_at)
                if (ta.first >= 0 && t >= ta.first) { type_text(ta.second); printf("[typed at %.2f s]\n", t); ta.first = -1; }
            if (save_t >= 0 && t >= save_t && !drd.act && kbd_out.empty() && ms_out.empty() && ide_hps_idle()
                && !top->ide0_request) { state_save(save_fn); save_t = -1; }
            static double next_shot = 0;
            if (shot_every > 0 && t >= next_shot) { next_shot = t + shot_every; save_ppm("live.ppm"); }
        }
        if (win) {
            SDL_Event e;
            while (SDL_PollEvent(&e)) {
                if (e.type == SDL_QUIT) quit = true;
                else if ((e.type == SDL_KEYDOWN && !e.key.repeat) || e.type == SDL_KEYUP) {
                    bool ext; int c = sc2(e.key.keysym.scancode, ext);
                    if (c) {
                        if (ext) kbd_out.push_back(0xE0);
                        if (e.type == SDL_KEYUP) kbd_out.push_back(0xF0);
                        kbd_out.push_back(c);
                    }
                }
            }
            if (frame_ready) {
                frame_ready = false;
                SDL_UpdateTexture(tex, nullptr, shown.data(), FBW * 4);
                SDL_Rect src = {0, 0, frame_w, frame_h};
                SDL_RenderClear(rnd);
                SDL_RenderCopy(rnd, tex, &src, nullptr);
                SDL_RenderPresent(rnd);
            }
        }
        auto now = std::chrono::steady_clock::now();
        double dt = std::chrono::duration<double>(now - tlast).count();
        if (dt >= 5.0) {
            printf("[sim %.2f s, %.0f kHz, frames %ld, %dx%d, insns %llu, at %04x:%08x%s, ticks %u]\n", cyc / (mhz * 1e6), (cyc - clast) / dt / 1e3,
                   frames, frame_w, frame_h, (unsigned long long)nret, top->dbg_cs, top->dbg_ip, top->dbg_halted ? " HLT" : "",
                   ddr_peek(0x46C) | ddr_peek(0x46D) << 8 | ddr_peek(0x46E) << 16);
            fflush(stdout);
            if (w) {
                char title[128];
                snprintf(title, sizeof title, "Tetrium on ao486 SoC  -  sim %.1f s  (%.0f kHz)", cyc / (mhz * 1e6), (cyc - clast) / dt / 1e3);
                SDL_SetWindowTitle(w, title);
            }
            tlast = now; clast = cyc;
        }
    }
    if (!shot.empty()) save_ppm(shot);
    {   // text screen as the VGA bus received it (B8000 window: VGA_ADDR offset 0x18000 in mode 3?)
        FILE *f = fopen("build/sim/vgabus.bin", "wb");
        if (f) { fwrite(vga_shadow, 1, sizeof vga_shadow, f); fclose(f); }
        printf("vga memmode %d\n", top->dbg_vga_mode);
    }
    {
        double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        printf("cycles %llu, wall %.2f s, %.1f kHz\n", (unsigned long long)cyc, wall, cyc / wall / 1e3);
        printf("memory checker: %llu read beats, %llu mismatching bytes\n", (unsigned long long)mchk_n, (unsigned long long)mchk_bad);
    }
    top->final();
    delete top;
    if (win) SDL_Quit();
    return 0;
}
