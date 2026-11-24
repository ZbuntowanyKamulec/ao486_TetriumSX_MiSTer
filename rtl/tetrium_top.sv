// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
`include "tetrium_cfg.svh"
// Tetrium synthesis top: core with the i486 reset state, debug ports removed.
// Reset: CS F000 with base RESET_CSBASE (FFFF0000: the first fetch is at FFFFFFF0, the
// chipset aliases the BIOS there), EIP FFF0, EDX = CPU_SIG, EFLAGS 2, other registers 0.
module tetrium_top #(
    parameter logic [63:0] CACHEABLE = 64'hFFFF_00FF_FFFF_FFFF,
    parameter logic [63:0] WCOMB     = 64'h0000_FF00_0000_0000,
    // memory types above 1 MB: up to 4 ranges {base, mask} of address bits [31:12]
    // (20 bits each, range 0 in the low bits), type {wcomb, cacheable} per range
    parameter int          MT_N    = 0,
    parameter logic [79:0] MT_BASE = '0,
    parameter logic [79:0] MT_MASK = '0,
    parameter logic [7:0]  MT_TYPE = '0,
    parameter int BUS_DW = `BUS_DW,
    parameter logic [31:0] RESET_CSBASE = 32'hFFFF_0000,
    // CR0 after reset: the i486's 6000_0010 (CD, NW: caches off until the BIOS enables them);
    // a system whose BIOS never clears CD / NW (e.g. the Bochs BIOS) resets with 0000_0010
    parameter logic [31:0] RESET_CR0    = 32'h6000_0010,
    parameter logic [31:0] CPU_SIG      = `CPU_SIG,
    parameter bit          HAS_CPUID    = `HAS_CPUID
) (
    input  logic        clk,
    input  logic        rst,
    output logic        wb_cyc,
    output logic        wb_stb,
    output logic        wb_we,
    output logic [31:$clog2(BUS_DW/8)] wb_adr,
    output logic [BUS_DW/8-1:0]        wb_sel,
    output logic [BUS_DW-1:0]          wb_dato,
    output logic [1:0]  wb_tga,
    output logic        wb_lock,
    input  logic [BUS_DW-1:0]          wb_dati,
    input  logic        wb_ack,
    input  logic        wb_stall,
    input  logic        intr,
    input  logic        nmi,
    input  logic        a20m,
    input  logic        snoop_v,
    input  logic [31:4] snoop_line,
    input  logic        flush,        // FLUSH: invalidate the caches
    output logic        cflush,       // INVD / WBINVD executed (one cycle): flush external caches
    output logic        cwback,       // ... WBINVD: write them back first
    output logic        halted,
    output logic        shutdown      // triple fault (left by NMI or reset)
);
  logic [31:0] init_gpr [8];
  logic [15:0] init_seg [6];
  always_comb begin
    for (int i = 0; i < 8; i++) init_gpr[i] = 32'h0000_0000;
    init_gpr[2] = CPU_SIG;    // EDX
    init_seg[0] = 16'h0000;
    init_seg[1] = 16'hF000;   // CS
    init_seg[2] = 16'h0000;
    init_seg[3] = 16'h0000;
    init_seg[4] = 16'h0000;
    init_seg[5] = 16'h0000;
  end

  tetrium_core #(.CACHEABLE(CACHEABLE), .WCOMB(WCOMB), .MT_N(MT_N), .MT_BASE(MT_BASE), .MT_MASK(MT_MASK), .MT_TYPE(MT_TYPE), .BUS_DW(BUS_DW),
                .CPU_SIG(CPU_SIG), .HAS_CPUID(HAS_CPUID)) u_core (
      .clk, .rst,
      .init_gpr, .init_seg, .init_csbase(RESET_CSBASE), .init_cr0(RESET_CR0), .init_ip(32'h0000_FFF0), .init_flags(16'h0002),
      .wb_cyc, .wb_stb, .wb_we, .wb_adr, .wb_sel, .wb_dato, .wb_tga, .wb_lock, .wb_dati, .wb_ack, .wb_stall,
      .intr, .nmi, .sstep(1'b0), .stop_req(1'b0), .a20m, .snoop_v, .snoop_line, .flush, .cflush, .cwback,
      .halted, .shutdown, .retire(), .idle(), .dbg_gpr(), .dbg_seg(), .dbg_ip(), .dbg_flags(), .dbg_perf(),
      .dbg_sbase(), .dbg_slim(), .dbg_sattr(), .dbg_cr0(), .dbg_cpl(), .dbg_sys(),
      .dbg_ret_inj(), .dbg_ret_dbt(), .dbg_nmi_ack(), .dbg_dr6(), .dbg_dr7(), .dbg_st_v(), .dbg_st_sz(), .dbg_st_lin(), .dbg_st_lin4(), .dbg_st_data(),
      .dbg_pw_v(), .dbg_pw_adr(), .dbg_pw_dat());
endmodule
