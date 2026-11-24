// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium configuration: caches, CPU identification, TLBs, bus width
// (override with +define+NAME=value)
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
// data micro-TLB in front of the TLB (A2 lookup): 2^UT_SB sets (linear[12 +: UT_SB], UT_SB <= 4) x
// UT_WAYS ways (1, 2 or 4; at most 16 entries); UT_SB 0: fully associative
`ifndef UT_SB
`define UT_SB 4
`endif
`ifndef UT_WAYS
`define UT_WAYS 1
`endif
// fetch micro-TLB: 2^FUT_SB entries (FUT_SB >= 1) direct-mapped by linear[12 +: FUT_SB],
// LUT RAM; a fetch from a page it holds needs no TLB lookup
`ifndef FUT_SB
`define FUT_SB 4
`endif
// L2 TLB behind the TLB, looked up by the walker: 2^L2TLB_AB entries in all (0: none) in
// L2TLB_WAYS ways (1, 2 or 4), one block RAM each (Cyclone V: 1024 entries in 4 ways =
// 4 M10K, the same as direct-mapped)
`ifndef L2TLB_AB
`define L2TLB_AB 10
`endif
`ifndef L2TLB_WAYS
`define L2TLB_WAYS 4
`endif
`ifndef BUS_DW
`define BUS_DW 32          // default Wishbone data width (16, 32, 64, 128)
`endif
`endif
