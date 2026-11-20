// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium cache configuration (override with +define+NAME=value)
`ifndef TETRIUM_CFG_SVH
`define TETRIUM_CFG_SVH
`ifndef LINE_B
`define LINE_B 32          // cache line bytes (16 or 32), both caches
`endif
`ifndef IC_KB
`define IC_KB 16           // I-cache size
`endif
`ifndef IC_WAYS
`define IC_WAYS 4          // 1, 2 or 4
`endif
`ifndef DC_KB
`define DC_KB 16           // D-cache size
`endif
`ifndef DC_WAYS
`define DC_WAYS 4          // 1, 2 or 4
`endif
// processor identification: the reset EDX value (type / family / model / stepping) and
// whether CPUID exists (it returns the same signature; EFLAGS.ID is writable with it)
`ifndef CPU_SIG
`define CPU_SIG 32'h0000_0422
`endif
`ifndef HAS_CPUID
`define HAS_CPUID 1
`endif
// i486 debug registers with instruction / data breakpoints (0: DR0-3 / DR6 / DR7 are storage only)
`ifndef DEBUG_REGS
`define DEBUG_REGS 1
`endif
// data micro-TLB in front of the TLB (A2 lookup): 2^UT_SB sets (linear[12 +: UT_SB]) x
// UT_WAYS ways (1, 2 or 4); UT_SB 0: fully associative
`ifndef UT_SB
`define UT_SB 3
`endif
`ifndef UT_WAYS
`define UT_WAYS 1
`endif
// L2 TLB behind the TLB, looked up by the walker: 2^L2TLB_AB entries direct-mapped in
// block RAM (0: none)
// fetch micro-TLB (replaces the fetch last-page register): 2^FUT_SB entries direct-mapped
// by linear[12 +: FUT_SB], LUT RAM; a fetch from a page it holds needs no TLB lookup
`ifndef FUT_SB
`define FUT_SB 4
`endif
`ifndef L2TLB_AB
`define L2TLB_AB 10
`endif
`ifndef BUS_DW
`define BUS_DW 32          // default Wishbone data width (16, 32, 64, 128)
`endif
`endif
