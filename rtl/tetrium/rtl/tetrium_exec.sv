// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium execute stage (E)
//  * architectural register file, segment registers, flags, temporaries
//  * operands are selected during M from the register file and registered;
//    a registered bypass (last E writes) covers the M->E read-after-write
//  * ALU (1 cycle) at operand size 8 / 16 / 32, shifter (1 cycle by one and a 32-bit
//    register by imm8 prepared in M, else 2 by CL / imm8), multiplier (4 cycles),
//    divider (radix 2), BCD (2)
//  * resolves conditional and indirect branches, far transfers
//  * raises interrupts / exceptions by asking decode to inject the INT
//    microcode sequence; I/O and INTA bus cycles are performed here.  A fault
//    leaves no register / flag / memory change and restarts at the instruction's
//    first byte.
import tetrium_pkg::*;
module tetrium_exec #(
    parameter bit          HAS_CPUID = 1'b1,   // CPUID (else #UD) and a writable EFLAGS.ID
    parameter logic [31:0] CPU_SIG   = 32'h0000_0422
) (
    input  logic        clk,
    input  logic        rst,
    // reset / initial architectural state
    input  logic [31:0] init_gpr [8],
    input  logic [15:0] init_seg [6],
    input  logic [31:0] init_csbase,
    input  logic [31:0] init_cr0,
    input  logic [31:0] init_ip,
    input  logic [15:0] init_flags,
    // from A/M (captured into the E input register when E accepts)
    input  logic        m_adv,
    input  logic        m_valid,
    input  logic [UW_BITS-1:0] m_uw,
    input  logic        m_last,
    input  logic        m_bnd,
    input  logic        m_w,
    input  logic [1:0]  m_sz,           // operand size: 0 byte, 1 word, 2 dword
    input  logic [1:0]  m_msz,          // size of the memory load
    input  logic [7:0]  m_op,
    input  logic        m_pg,
    input  logic        m_lock,         // LOCK prefix
    input  logic [7:0]  m_modrm,
    input  logic [31:0] m_imm,
    input  logic [31:0] m_disp,
    input  logic [31:0] m_ip_start,
    input  logic [31:0] m_ip_next,
    input  logic [2:0]  m_sreg,
    input  logic [1:0]  m_rep,
    input  logic        m_as32,
    input  logic        m_os32,
    input  logic        m_pt,
    input  logic [31:0] m_ptgt,
    input  logic [3:0]  m_bid,
    input  logic        m_inj,
    input  logic [2:0]  m_abr,
    input  logic [31:0] m_off,
    input  logic        m_spw, input logic [31:0] m_spv,
    input  logic        m_siw, input logic [31:0] m_siv,
    input  logic        m_diw, input logic [31:0] m_div,
    input  logic        m_cxw, input logic [31:0] m_cxv,
    input  logic [31:0] m_tgt,
    input  logic        m_tbad,
    input  logic [31:0] m_brlin,
    input  logic        m_cxnz,
    input  logic        m_ataken,
    input  logic        m_aex,
    input  logic [15:0] m_dmask,
    input  logic [7:0]  m_ldm,        // the uop is a plain 16/32-bit load into this GPR (one-hot)
    input  logic        m_ld32,
    input  logic [2:0]  m_xc,           // exception found before E: 1 #UD, 2 #GP, 3 #SS
    input  logic [1:0]  m_amis,         // {secondary, primary} access misaligned
    input  logic        m_xs,           // ... on the store address only (the load goes first)
    input  logic [31:0] m_data,
    input  logic        m_ldwait,
    input  logic [15:0] m_fwd,          // per load byte {valid, entry, lane[1:0]} owed by the store in E
    input  logic [31:0] m_lin,
    input  logic [31:2] m_lin4,
    input  logic [31:0] m_slin,
    input  logic [31:2] m_slin4,
    // paging: physical pages of the primary / secondary access from the data micro-TLB
    // (A2; a miss replayed in M through the TLB) and whether M found them usable (hit,
    // rights, D for a write)
    input  logic [31:12] m_pppn,
    input  logic        m_pok,
    input  logic        m_ppcd,
    input  logic [31:12] m_sppn,
    input  logic        m_sok,
    input  logic [1:0]  m_ucpl,         // CPL the rights were checked with
    output logic        e_st_xp,        // the store in E is not translated yet (a load in M waits)
    // MMU: TLB management, test registers, walker (data), micro-TLB loads
    output logic        mm_flush,       // CR3 written
    output logic        mm_invlpg,
    output logic [31:12] mm_inva,
    output logic        mm_lpkill,      // CR0 written
    output logic [31:12] e_cr3,
    output logic        tr_we,
    output logic        tr_sel7,
    output logic [31:0] tr_d,
    input  logic [31:0] tr6,
    input  logic [31:0] tr7,
    output logic        e_preq,
    output logic [31:12] e_pa,
    output logic        e_pwr,
    output logic        e_puser,
    output logic        e_pcpl3,
    input  logic        e_pdone,
    input  logic        w_ok,
    input  logic [2:0]  w_err,
    input  logic [41:0] w_e,
    output logic        e_lpp_ld,       // load the micro-TLB with a walk result (primary / secondary access)
    output logic        e_lps_ld,
    output logic        x_pcd,          // the late load's page is uncacheable (PCD)
    output logic        lk_hold,        // locked read-modify-write: bus locked (read .. store drained)
    // instruction fetch page fault (fetch stopped, pipeline drained, decode starved)
    input  logic        ff_go,
    input  logic [2:0]  ff_err,
    input  logic [31:0] ff_lin,
    // late load port (D-cache re-read / fill) and uncached reads
    output logic        x_act,
    output logic [31:0] x_lin,
    output logic [31:2] x_lin4,
    output logic [1:0]  x_sz,
    input  logic [31:0] x_data,
    input  logic        x_hit,
    input  logic [3:0]  x_hb,
    input  logic        x_cached,
    output logic        x_fill,
    input  logic        x_fill_done,
    output logic        du_req,
    input  logic        du_done,
    input  logic [31:0] du_data,
    input  logic        l_st_v,
    // pipeline control
    output logic        hold_e,
    input  logic        hold_w,
    input  logic        io_ok,          // W and store buffer empty
    // INVD / WBINVD: invalidate both caches (the reset tag sweep), then refetch
    output logic        e_cinv,         // one-cycle request (with e_cwb: WBINVD)
    output logic        e_cwb,
    input  logic        c_busy,         // a cache sweep is pending or running
    input  logic        smc_hit,        // a store hit a valid I-cache line
    input  logic        snp_hit,        // an external snoop hit a valid I-cache line
    output logic        e_busy_valid,   // E holds a valid uop
    output logic [15:0] e_dmask,
    output logic        ce_push,      // committed near CALL (return address ce_rip) / RET
    output logic        ce_pop,
    output logic [31:0] ce_rip,
    // A1 bypasses: GPR destinations of the uop in E, and the data of a plain load
    // in E once it is final (A1 may use it while the load is still in E)
    output logic [7:0]  e_dm_e,
    output logic [7:0]  e_byp_m,        // plain load in E: its GPR (selects only; e_byp_ok: final)
    output logic        e_byp_ok,
    output logic        e_byp_32,
    output logic [31:0] e_byp_d,
    output logic        e_st_v,
    output logic [31:2] e_st_a0,        // aligned words of the store in E and their byte enables
    output logic [31:2] e_st_a1,
    output logic [3:0]  e_st_be0,
    output logic [3:0]  e_st_be1,
    // architectural state (A-copy restore, debug)
    output logic [255:0] e_gpr,
    output logic [95:0] e_seg,
    output logic        e_df,
    output logic [31:0] e_t0,
    output logic        e_byp_t0,       // plain load into T0 in E with final data (A1 bypass)
    input  logic        m_ldt0,         // the uop in M is such a load
    output logic [31:0] e_idtb,         // IDTR base (real-mode interrupt vectors)
    output logic [31:0] e_gdtb,         // GDTR / LDTR / TR bases (system table accesses in A2)
    output logic [31:0] e_ldtb,
    output logic [31:0] e_trb,
    output logic [31:0] e_trl,          // TSS limit (A2: a TSS access beyond it is not made)
    output logic [15:0] e_gdtl,         // GDTR / IDTR / LDTR limits (descriptor reads beyond: no access)
    output logic [15:0] e_idtl,
    output logic [31:0] e_ldtl,
    input  logic        m_noacc,        // the uop's access lies beyond its table: not done
    output logic        e_tss32,        // TR is a 386 TSS
    output logic        e_ldtw,         // the uop in E loads LDTR (A2 interlock)
    input  logic [31:0] a_ssbase,       // SS base and the access bytes of the descriptor caches (A)
    input  logic [47:0] a_sacc,
    output logic [31:0] e_flags,
    output logic [31:0] e_ip,
    // mode (changes only through serializing instructions)
    output logic        e_pm,           // protected mode: CR0.PE and not V86
    output logic [1:0]  e_cpl,
    output logic        e_csd,          // CS.D: default operand / address size 32
    output logic        e_iochk,        // I/O instructions check the permission bitmap
    output logic        e_pgq,          // CR0.PG && CR0.PE, a register of its own (M / A2 paths)
    output logic [31:0] e_cr0,
    output logic [31:0] e_sysdbg,       // {TR, LDTR} selectors (debug)
    // E-computed writes for the A-copy
    output logic [23:0] ewh0, output logic [23:0] ewh1,     // one-hot [3*reg+lane], delayed 1 cycle
    output logic [31:0] ewv0, output logic [31:0] ewv1,     // lanes: [7:0], [15:8], [31:16]
    // segment register write: descriptor cache data for A (kind 0 descriptor, 1 real-mode
    // data, 2 real-mode CS, 3 V86)
    output logic        esw_en, output logic [2:0] esw_r, output logic [1:0] esw_k,
    output logic [31:0] esw_base, output logic [31:0] esw_lim,
    output logic [7:0]  esw_acc, output logic esw_db, output logic esw_nul,
    output logic        edf_en, output logic edf_v,
    // SS checkpoint: snapshot the descriptor cache at an instruction's first uop / restore it
    // (one cycle after a fault, as a segment write)
    output logic        ss_snap, output logic ss_rest,
    // store hit check (tags read for the E-stage store address)
    output logic [31:0] e_st_lin,
    output logic [31:2] e_st_lin4,
    input  logic        e_st_hlo,
    input  logic        e_st_hhi,
    input  logic [1:0]  e_st_wlo,       // D-cache way of the store's bytes
    input  logic [1:0]  e_st_whi,
    output logic        w_hlo,
    output logic        w_hhi,
    output logic [1:0]  w_wlo,
    output logic [1:0]  w_whi,
    // to W stage
    output logic        w_v,
    output logic [31:0] w_lin,
    output logic [31:2] w_lin4,
    output logic [1:0]  w_sz,
    output logic [31:0] w_data,
    output logic        w_two,
    output logic        w_nowr,         // the W store writes nothing (accessed bit already set, ARPL no change)
    input  logic [31:0] w_d0,           // aligned data of the store in W (late forwarding)
    input  logic [31:0] w_d1,
    // redirect / flush (registered)
    output logic        flush_r,
    output logic        rd_fetch,       // redirect fetch to rd_csb + rd_ip
    output logic [31:0] rd_csb,         // code segment base
    output logic [31:0] rd_ip,
    output logic        rd_inject,
    // injected sequence: entry id, immediate (vector), restart / next IP, operand size,
    // opcode, delivery (not an instruction micro-jump)
    output logic [4:0]  rd_injid,
    output logic [31:0] rd_imm,
    output logic [31:0] rd_ips,
    output logic [31:0] rd_ipn,
    output logic        rd_os32,
    output logic [7:0]  rd_op,
    output logic        rd_int,
    output logic        rd_ecvx,        // the delivery pushes an error code (for the injected uops)
    output logic [4:0]  rd_cnt,         // micro-loop count (call gate parameters)
    output logic        rd_stop,        // stop fetch (HLT / inject)
    // BTB training
    output logic        be_we,
    output logic [31:0] be_lin,
    output logic        be_taken,
    output logic [31:0] be_tgt,
    output logic [1:0]  be_kind,
    output logic        be_ind,         // indirect near JMP / CALL (fetch target cache)
    output logic        be_tcw,         //   ... mispredicted (write the target cache)
    output logic        be_inval,
    output logic [3:0]  be_bid,         // predictor snapshot id (training and redirects)
    output logic        rd_br,          // redirect from a trained branch, actual direction rd_tk
    output logic        rd_tk,
    output logic        rd_rpush,
    output logic        rd_rpop,
    output logic [31:0] rd_rip,
    // I/O + INTA bus
    output logic        io_req,
    output logic        io_we,
    output logic        io_inta,
    output logic [15:0] io_port,
    output logic [1:0]  io_sz,
    output logic [31:0] io_wdata,
    input  logic        io_done,
    input  logic [31:0] io_rdata,
    // interrupts
    input  logic        intr,
    input  logic        nmi,
    input  logic        sstep,          // serialize: flush + refetch after every instruction
    input  logic        stop_req,       // stop fetching after the next instruction
    output logic        halted,
    output logic        shutdown,       // triple fault (sticky, with halted)
    output logic        retire,
    output logic        retire_inj,     // the retired sequence was injected (interrupt / exception entry)
    output logic        retire_dbt,     // the retired instruction is followed by a debug trap (TF / data breakpoint)
    output logic        nmi_ack,        // an NMI is taken (its delivery follows; testbench)
    output logic [31:0] dbg_dr6,
    output logic [31:0] dbg_dr7
);
  genvar i;
  // ================================================================ architectural state
  logic [31:0] g [8];
  logic [15:0] s [6];
  logic [31:0] t0, t1, t2, t3;
  logic [31:0] tx [6];         // T4..T9 (operand pre-select only; a distributed RAM costs more)
  logic [5:0]  tx_we;
  logic        ss_b;           // SS.B (E copy: stack size of LDSP / OLDSP)
  logic [4:0]  gcnt;           // call gate parameter count
  logic [1:0]  tsk_op;         // task switch in progress: 0 JMP, 1 CALL, 2 INT, 3 IRET
  wire         tsk_lnk = (tsk_op == 2'd1) || (tsk_op == 2'd2);   // CALL / INT: nested (link, NT)
  wire [31:0]  tsk_eip;        // the new task's EIP (by its TSS type)
  logic cf, pf, af, zf, sf, tf, ifl, df, of, nt, rf, vm, ac, idf;
  logic ifst;      // the uop in E is the first of its instruction (not of a REP iteration)
  logic ssp_q;     // the instruction in E follows MOV / POP SS (no instruction breakpoint)
  logic dbdel;     // delivering #DB (its accesses match no data breakpoint)
  logic [1:0]  iopl;
  logic [1:0]  cpl;
  // CS descriptor cache copy for redirects and EIP limit checks (A has the full caches)
  logic [31:0] cs_base, cs_lim;
  logic        cs_d;
  logic [31:0] ip_arch;
  // GPR writes computed in E land one cycle after completion (from lw0/lw1);
  // gm is the architectural view including that pending write.
  logic        pend;
  logic [23:0] pwh0, pwh1;
  logic [15:0] p_dmask;
  logic [31:0] lw0, lw1;
  logic [31:0] gm [8];
  always_comb begin
    for (int i = 0; i < 8; i++) begin
      gm[i] = g[i];
      if (pend && pwh0[3*i])   gm[i][7:0]   = lw0[7:0];
      if (pend && pwh0[3*i+1]) gm[i][15:8]  = lw0[15:8];
      if (pend && pwh0[3*i+2]) gm[i][31:16] = lw0[31:16];
      if (pend && pwh1[3*i])   gm[i][7:0]   = lw1[7:0];
      if (pend && pwh1[3*i+1]) gm[i][15:8]  = lw1[15:8];
      if (pend && pwh1[3*i+2]) gm[i][31:16] = lw1[31:16];
    end
  end
  generate
  for (i = 0; i < 8; i = i + 1) begin : g_egpr assign e_gpr[i*32 +: 32] = gm[i]; end
  for (i = 0; i < 6; i = i + 1) begin : g_eseg assign e_seg[i*16 +: 16] = s[i]; end
  endgenerate
  assign e_df = df;
  assign e_t0 = t0;
  // SF/ZF/PF of result-producing uops are derived one cycle late from the
  // registered result (fres); *_e are the effective architectural values.
  logic        fres_v;
  logic [1:0]  fres_sz;
  logic [31:0] fres;
  function automatic logic par(input logic [7:0] x); return ~^x; endfunction
  // zero / sign of a value at an operand size
  function automatic logic zsz(input logic [31:0] x, input logic [1:0] z);
    return (x[7:0] == 8'h0) && ((z == 2'd0) || (x[15:8] == 8'h0)) && ((z != 2'd2) || (x[31:16] == 16'h0));
  endfunction
  function automatic logic ssz(input logic [31:0] x, input logic [1:0] z);
    return (z == 2'd0) ? x[7] : (z == 2'd1) ? x[15] : x[31];
  endfunction
  wire zf_e = fres_v ? zsz(fres, fres_sz) : zf;
  wire sf_e = fres_v ? ssz(fres, fres_sz) : sf;
  wire pf_e = fres_v ? par(fres[7:0]) : pf;
  // FLAGS image: bit 15 reads 0, NT and IOPL are plain bits in real mode
  wire [15:0] fimg = {1'b0, nt, iopl, of, df, ifl, tf, sf_e, zf_e, 1'b0, af, 1'b0, pf_e, 1'b1, cf};
  assign e_flags = {10'h0, idf, 2'b0, ac, vm, rf, fimg};
  assign e_ip = ip_arch;
  assign e_pm  = cr0[0] && !vm;
  assign e_cpl = cpl;
  assign e_csd = cs_d;
  assign e_cr0 = cr0 | 32'h10;
  assign e_sysdbg = {tr_sel, ldt_sel};

  // ================================================================ E-stage registers
  logic        v;
  logic [6:0]  eop;
  logic [1:0]  wrk;
  logic        last, bnd, pt, inj, spw, siw, diw, cxw, cxnz, ataken, repz, tgteq, ldwait, aex, pg, as32;
  logic [7:0]  op, modrm;
  logic [31:0] ip_start, ip_next, ptgt, tgt;
  logic        tbad;
  logic [31:0] imm;
  logic [31:0] spv, siv, divv, cxv;
  logic [31:0] mdat;
  logic        ld32;
  logic [1:0]  sz;             // operand size of the uop in E: 0 byte, 1 word, 2 dword
  logic [1:0]  msz;            // size of its memory load
  logic [3:0]  bid;
  logic [2:0]  abr_e;
  logic [31:0] R, R2;          // ALU results (computed below)
  logic [2:0]  sreg;
  logic [1:0]  rep;
  logic [31:0] brlin, st_lin, ld_lin;      // linear addresses
  logic [31:2] st_lin4, ld_lin4;
  // physical pages: first byte / next word of the load and of the store
  logic [31:12] ld_ppn0, ld_ppn1, st_ppn0, st_ppn1;
  logic        ld_pcd, sv_q, mrd_q;
  logic        lcross_q, scross_q;   // the load / store crosses into the next page
  logic [15:0] dmask;
  logic [2:0]  xc;             // exception found before E
  logic [1:0]  amis;           // misaligned accesses (alignment check)
  logic        xs_q;           // ... on the store address only
  logic [2:0]  srf;            // system register select (SRD / SWR)
  logic        os32;
  // system registers (CR0 ET reads as 1)
  logic [31:0] cr0, cr2, cr3, gdtb, idtb;
  logic [31:0] dr [4];         // debug registers DR0-3 (linear breakpoint addresses)
  logic [31:2] drm1 [4];       // DRi word address - 1 (a breakpoint in the next word of an access)
  logic [31:0] dr7;
  logic [3:0]  dr6_b, dr6_h;   // DR6 [3:0] (B0-3), [15:12] (BT BS BD, bit 12); the rest reads 1
  wire  [31:0] dr6 = {16'hFFFF, dr6_h, 8'hFF, dr6_b};
  logic [31:0] tr345 [4];      // TR3, TR4, TR5 (index modrm.reg[1:0]; cache test registers: storage only)
  logic [15:0] gdtl, idtl;
  // LDTR, TR: selector, base, limit (TR: TSS type, busy)
  logic [15:0] ldt_sel, tr_sel;
  logic [31:0] ldt_base, ldt_lim, tr_base, tr_lim;
  logic [7:0]  tr_acc;
  assign e_idtb = idtb;
  assign e_gdtb = gdtb;
  assign e_ldtb = ldt_base;
  assign e_trb  = tr_base;
  assign e_trl  = tr_lim;
  assign e_gdtl = gdtl;
  assign e_idtl = idtl;
  assign e_ldtl = ldt_lim;
  assign e_tss32 = tr_acc[3];
  assign e_ldtw  = v && (eop == E_DHI) && ((ck == CK_LDT) || (ck == CK_TLDT));

  logic [4:0]  ck;             // descriptor check kind of the uop in E
  // exception / interrupt delivery in progress (the injected sequence): software
  // INT n / INT3 / INTO (no EXT bit in error codes, gate DPL checked), error code to
  // push, trap gate (IF kept)
  logic        x_soft, x_ecv, gtrap;
  logic [15:0] x_errc;
  logic [1:0]  chk;            // static check
  // operand pre-values and lane selects
  logic [31:0] preA, preB;
  logic [5:0]  sA0, sB0;     // lane 0 [7:0]:   pre, lw0.b0, lw0.b1, lw1.b0, lw1.b1, mem
  logic [3:0]  sA1, sB1;     // lane 1 [15:8]:  pre, lw0.b1, lw1.b1, mem
  logic [3:0]  sA2, sB2;     // lane 2 [31:16]: pre, lw0.hi, lw1.hi, mem
  // static destination descriptors
  logic        p0_en, p1_en, p0_hi, p1_hi, sw_en, wr_en;
  logic [3:0]  tw_we, tw_r2;   // T0..T3 written by the uop in E (from R / from R2)
  logic [2:0]  p0_r, p1_r;
  logic [2:0]  p0_be, p1_be;  // lanes written: [0] [7:0], [1] [15:8], [2] [31:16]
  logic [2:0]  sw_r;
  logic        p1_sp;         // special value (not R2)
  logic [23:0] wh0, wh1;      // one-hot write enables: [3*reg+lane]
  // predecoded ALU control
  logic        c_asub, c_acf, c_logic;
  logic [1:0]  c_lop;          // 0 and, 1 or, 2 xor
  logic [9:0]  c_rsel;         // one-hot: logic, arith, ~A, A, shift, ip_next, flags, B, special, flag-dependent special

  // ---------------------------------------------------------------- M-stage operand fetch
  wire [6:0] m_eop  = m_uw[UW_EOP_L +: UW_EOP_W];
  wire [4:0] m_sa   = m_uw[UW_SA_L +: UW_SA_W];
  wire [4:0] m_sb   = m_uw[UW_SB_L +: UW_SB_W];
  wire [4:0] m_d1   = m_uw[UW_D1_L +: UW_D1_W];
  wire [4:0] m_d2   = m_uw[UW_D2_L +: UW_D2_W];
  wire [1:0] m_wr   = m_uw[UW_WR_L +: UW_WR_W];
  wire [2:0] m_rfix = m_uw[UW_RFIX_L +: UW_RFIX_W];
  wire       m_cmp  = ((m_eop == E_ALUOP) && (m_op[5:3] == 3'd7)) ||
                      ((m_eop == E_ALUREG) && (m_modrm[5:3] == 3'd7));

  // register file as seen by the uop in M: includes A-origin updates of the
  // uop in E (E-computed results come through the lw bypass)
  logic [31:0] ge [8];
  always_comb begin
    for (int i = 0; i < 8; i++) ge[i] = gm[i];
    if (v && spw) ge[4] = spv;
    if (v && siw) ge[6] = siv;
    if (v && diw) ge[7] = divv;
    if (v && cxw) ge[1] = cxv;
  end

  // source descriptor: kind, register, width, lane
  typedef struct packed {
    logic [2:0]  k;      // 0 pre-only, 1 gpr, 2 seg, 3 mem, 4 t0, 5 t1
    logic [2:0]  r;      // gpr index (16-bit register) / seg index
    logic        wd;     // word / dword read (all lanes)
    logic        hl;     // byte read of the [15:8] lane
    logic [31:0] pv;     // pre value
  } sdesc_t;

  // pa: port A, which the microcode reads only from REG RM ACC OPR FIX DX IMM MEM T0 T1 T3
  // ZERO (ucgen checks it): the other sources are left out of its pre-select
  function automatic sdesc_t sdec(input logic [4:0] sel, input logic pa);
    sdesc_t d;
    logic [2:0] rc;
    d.k = 3'd0; d.r = 3'd0; d.wd = m_w; d.hl = 1'b0; d.pv = 32'h0;
    rc = 3'd0;
    case (sel)
      S_REG:  begin d.k = 3'd1; rc = m_modrm[5:3]; end
      // MOVZX / MOVSX read their source at its own size (byte / word by op[0])
      S_RM:   begin d.k = 3'd1; rc = m_modrm[2:0]; if (m_eop == E_MOVX) d.wd = m_op[0]; end
      S_ACC:  begin d.k = 3'd1; rc = 3'd0; end
      S_OPR:  begin d.k = 3'd1; rc = m_op[2:0]; end
      S_FIX:  begin d.k = 3'd1; rc = m_rfix; d.wd = 1'b1; end
      S_BP:   if (!pa) begin d.k = 3'd1; rc = 3'd5; d.wd = 1'b1; end
      S_DX:   begin d.k = 3'd1; rc = 3'd2; d.wd = 1'b1; end
      S_MEM:  d.k = 3'd3;
      S_T0:   begin d.k = 3'd4; d.wd = 1'b1; end
      S_T1:   begin d.k = 3'd5; d.wd = 1'b1; end
      S_T2:   if (!pa) begin d.k = 3'd6; d.wd = 1'b1; end
      S_T3:   begin d.k = 3'd7; d.wd = 1'b1; end
      S_SEG:  if (!pa) begin d.k = 3'd2; d.r = m_sreg; d.wd = 1'b1; end
      S_CS:   if (!pa) begin d.k = 3'd2; d.r = 3'd1; d.wd = 1'b1; end
      S_SEGF: if (!pa) begin d.k = 3'd2; d.r = m_rfix; d.wd = 1'b1; end
      S_IMM:  d.pv = m_w ? m_imm : {24'h0, m_imm[7:0]};
      S_IPN:  if (!pa) d.pv = m_ip_next;
      S_DISP: if (!pa) d.pv = m_disp;
      S_OPSZ: if (!pa) d.pv = ((m_sz == 2'd2) && m_os32) ? 32'd4 : 32'd2;   // (a D32 address step of a 16-bit operand: 2)
      S_ERRC: if (!pa) d.pv = {16'h0, x_errc};
      S_T4:   if (!pa) d.pv = tx[0];
      S_T5:   if (!pa) d.pv = tx[1];
      S_T6:   if (!pa) d.pv = tx[2];
      S_T7:   if (!pa) d.pv = tx[3];
      S_T8:   if (!pa) d.pv = tx[4];
      S_T9:   if (!pa) d.pv = tx[5];
      S_SSR:  if (!pa) d.pv = {16'h0, s[2]};
      S_TRS:  if (!pa) d.pv = {16'h0, tr_sel};
      default: ;
    endcase
    if (d.k == 3'd1) begin
      if (d.wd) begin
        d.r = rc;
        d.pv = ge[rc];
      end else begin
        d.r = {1'b0, rc[1:0]};
        d.hl = rc[2];
        d.pv = {24'h0, rc[2] ? ge[{1'b0, rc[1:0]}][15:8] : ge[{1'b0, rc[1:0]}][7:0]};
      end
    end else if (d.k == 3'd2) begin
      d.pv = {16'h0, s[d.r]};        // segment RAW hazards are interlocked in A
    end else if (d.k[2]) begin
      d.pv = (d.k[1:0] == 2'd0) ? t0 : (d.k[1:0] == 2'd1) ? t1 : (d.k[1:0] == 2'd2) ? t2 : t3;
    end
    return d;
  endfunction

  // lane selects given the descriptor and the E-stage write descriptors
  function automatic logic [13:0] lsel(input sdesc_t d);
    logic [5:0] l0;
    logic [3:0] l1, l2;
    logic       m0, m1, m2, n0, n1, n2;   // p0 / p1 match the lane 0 / 1 / 2 source
    l0 = 6'b000001; l1 = 4'b0001; l2 = 4'b0001;
    case (d.k)
      3'd1: begin
        // lane 0 source: (reg, lane hl);  lanes 1, 2: (reg, lane) for word / dword reads
        m0 = v && p0_en && (p0_r == d.r) && p0_be[d.hl];
        n0 = v && p1_en && (p1_r == d.r) && p1_be[d.hl];
        if (n0)      l0 = d.hl ? 6'b010000 : 6'b001000;
        else if (m0) l0 = d.hl ? 6'b000100 : 6'b000010;
        if (d.wd) begin
          m1 = v && p0_en && (p0_r == d.r) && p0_be[1];
          n1 = v && p1_en && (p1_r == d.r) && p1_be[1];
          if (n1)      l1 = 4'b0100;
          else if (m1) l1 = 4'b0010;
          m2 = v && p0_en && (p0_r == d.r) && p0_be[2];
          n2 = v && p1_en && (p1_r == d.r) && p1_be[2];
          if (n2)      l2 = 4'b0100;
          else if (m2) l2 = 4'b0010;
        end else begin l1 = 4'b0000; l2 = 4'b0000; end
      end
      3'd3: begin
        l0 = 6'b100000; l1 = (m_msz != 2'd0) ? 4'b1000 : 4'b0000; l2 = (m_msz == 2'd2) ? 4'b1000 : 4'b0000;
      end
      // T0..T3 written by the uop in E: from lw0 (d1) or lw1 (d2)
      3'd4, 3'd5, 3'd6, 3'd7: if (v && tw_we[d.k[1:0]]) begin
        l0 = tw_r2[d.k[1:0]] ? 6'b001000 : 6'b000010;
        l1 = tw_r2[d.k[1:0]] ? 4'b0100 : 4'b0010; l2 = tw_r2[d.k[1:0]] ? 4'b0100 : 4'b0010;
      end
      default: ;
    endcase
    return {l2, l1, l0};
  endfunction

  sdesc_t da, db;
  logic [13:0] la, lb;
  always_comb begin
    da = sdec(m_sa, 1'b1);
    db = sdec(m_sb, 1'b0);
    if (m_eop == E_LEA) begin db = '0; db.pv = m_off; end
    if (m_eop == E_BTADR) begin da = '0; da.pv = m_off; end
    if (m_eop == E_INC || m_eop == E_DEC) begin db = '0; db.pv = 32'd1; end
    if (m_eop == E_NEG) begin db = da; da = '0; end
    la = lsel(da);
    lb = lsel(db);
  end

  // static destination decode for the uop in M
  function automatic logic [2:0] dreg(input logic [4:0] d);
    case (d)
      D_REG: return m_modrm[5:3];
      D_RM:  return m_modrm[2:0];
      D_OPR: return m_op[2:0];
      D_FIX: return m_rfix;
      default: return 3'd0;
    endcase
  endfunction
  function automatic logic isgpr(input logic [4:0] d);
    return (d == D_REG) || (d == D_RM) || (d == D_ACC) || (d == D_OPR) || (d == D_FIX);
  endfunction
  logic       n_p0_en, n_p1_en, n_p0_hi, n_p1_hi, n_p1_sp, n_sw_en;
  logic [2:0] n_p0_r, n_p1_r;
  logic [2:0] n_p0_be, n_p1_be;
  logic [2:0] n_sw_r;
  wire  [2:0] m_wbe = {m_sz == 2'd2, 2'b11};          // lanes of a word / dword register write
  always_comb begin
    logic [2:0] r1, r2;
    logic       f1, f2;
    r1 = dreg(m_d1); r2 = dreg(m_d2);
    f1 = (m_d1 == D_FIX); f2 = (m_d2 == D_FIX);        // fixed registers are never byte registers
    n_p0_en = isgpr(m_d1) && !m_cmp;
    n_p0_r  = (m_w || f1) ? r1 : {1'b0, r1[1:0]};
    n_p0_be = (m_w || f1) ? m_wbe : (r1[2] ? 3'b010 : 3'b001);
    n_p0_hi = !m_w && !f1 && r1[2];
    n_p1_en = isgpr(m_d2);
    n_p1_r  = (m_w || f2) ? r2 : {1'b0, r2[1:0]};
    n_p1_be = (m_w || f2) ? m_wbe : (r2[2] ? 3'b010 : 3'b001);
    n_p1_hi = !m_w && !f2 && r2[2];
    n_p1_sp = 1'b0;
    n_sw_en = (m_d1 == D_SEG) || (m_d1 == D_SSR) || (m_d1 == D_SEGF) || (m_eop == E_SEGVAL) || (m_eop == E_SEGNUL) ||
              (m_eop == E_LDV86);
    n_sw_r  = (m_d1 == D_SSR) ? 3'd2 : ((m_d1 == D_SEGF) || (m_eop == E_SEGVAL) || (m_eop == E_SEGNUL)) ? m_rfix :
              (m_eop == E_LDV86) ? 3'd1 : m_sreg;
    case (m_eop)
      E_MUL, E_DIV: begin
        n_p0_en = 1'b1; n_p0_r = 3'd0; n_p0_be = m_w ? m_wbe : 3'b011;
        n_p1_en = m_w;  n_p1_r = 3'd2; n_p1_be = m_wbe; n_p1_sp = 1'b1;
      end
      E_AAM, E_AAD, E_AAA, E_AAS: begin n_p0_en = 1'b1; n_p0_r = 3'd0; n_p0_be = 3'b011; end
      E_DAA, E_DAS, E_SALC:       begin n_p0_en = 1'b1; n_p0_r = 3'd0; n_p0_be = 3'b001; end
      E_LAHF:                     begin n_p0_en = 1'b1; n_p0_r = 3'd0; n_p0_be = 3'b010; end
      // CBW: AH <- sign(AL);  CWDE: EAX[31:16] <- sign(AX)
      E_CBW: begin n_p0_en = 1'b1; n_p0_r = 3'd0; n_p0_be = (m_sz == 2'd2) ? 3'b100 : 3'b010; end
      // CWD: DX <- sign(AX);  CDQ: EDX <- sign(EAX)
      E_CWD: begin n_p0_en = 1'b1; n_p0_r = 3'd2; n_p0_be = m_wbe; end
      E_IN:  if (m_d1 == D_ACC) begin n_p0_r = 3'd0; n_p0_be = m_w ? m_wbe : 3'b001; end
      E_JFAR, E_IRET, E_LDCS: begin n_sw_en = 1'b1; n_sw_r = 3'd1; end
      // XADD r, r with one register: the sum is written last
      E_XADD: if (m_modrm[7:6] == 2'd3 && m_modrm[5:3] == m_modrm[2:0]) n_p1_en = 1'b0;
      default: ;
    endcase
  end

  // ALU control decode for the uop in M
  logic       n_asub, n_acf, n_logic;
  logic [1:0] n_lop;
  logic [9:0] n_rsel;
  always_comb begin
    logic [2:0] mo3;
    mo3 = (m_eop == E_ALUREG) ? m_modrm[5:3] : (m_eop == E_CMP || m_eop == E_BOUND) ? 3'd7 :
          (m_eop == E_SUB) ? 3'd5 : (m_eop == E_ADD || m_eop == E_XADD) ? 3'd0 : m_op[5:3];
    n_asub = 1'b0; n_acf = 1'b0;
    n_logic = 1'b0; n_lop = 2'd0; n_rsel = 10'b00_1000_0000;
    case (m_eop)
      E_INC: n_rsel = 10'b00_0000_0010;
      E_DEC: begin n_asub = 1'b1; n_rsel = 10'b00_0000_0010; end
      E_NEG, E_SUBNF: begin n_asub = 1'b1; n_rsel = 10'b00_0000_0010; end
      E_ADDNF: n_rsel = 10'b00_0000_0010;
      E_ALUOP, E_ALUREG, E_CMP, E_ADD, E_SUB, E_TEST, E_XADD, E_BOUND: begin
        n_asub  = (mo3 == 3'd3) || (mo3 == 3'd5) || (mo3 == 3'd7);
        n_acf   = (mo3 == 3'd2) || (mo3 == 3'd3);
        n_logic = (m_eop == E_TEST) || (mo3 == 3'd1) || (mo3 == 3'd4) || (mo3 == 3'd6);
        n_lop   = (m_eop == E_TEST) ? 2'd0 : (mo3 == 3'd1) ? 2'd1 : (mo3 == 3'd6) ? 2'd2 : 2'd0;
        n_rsel  = n_logic ? 10'b00_0000_0001 : 10'b00_0000_0010;
      end
      E_NOT:   n_rsel = 10'b00_0000_0100;
      E_PASSA: n_rsel = 10'b00_0000_1000;
      E_SHIFT: n_rsel = 10'b00_0001_0000;
      E_JNEAR, E_JFAR, E_LDCS: n_rsel = 10'b00_0010_0000;
      E_PUSHF, E_INTFL: n_rsel = 10'b00_0100_0000;
      E_MUL, E_DIV, E_AAM, E_AAD, E_DAA, E_DAS, E_AAA, E_AAS, E_CBW, E_CWD, E_SALC, E_LAHF, E_IN,
      E_MOVX, E_BSWAP, E_IMUL2, E_BT, E_BTADR, E_BSF, E_SRD, E_DHI, E_EFL, E_GATE, E_TSSOFF, E_OLDSP, E_PADDR,
      E_LDSP, E_IOMAP, E_LARV, E_ARPL, E_TSSDESC, E_TFLG, E_TLDW, E_LDTSK, E_TRD, E_CPUID:
        n_rsel = 10'b01_0000_0000;
      E_SETCC, E_CSEL: n_rsel = 10'b10_0000_0000;
      E_SHXD:  n_rsel = 10'b00_0001_0000;
      default: ;
    endcase
  end

  // an access of size z at page offset o crosses into the next page
  function automatic logic xpage(input logic [11:0] o, input logic [1:0] z);
    return (z == 2'd1) ? (o == 12'hFFF) : (z == 2'd2) ? (o > 12'hFFC) : 1'b0;
  endfunction
  // ---------------------------------------------------------------- breakpoint compares (M)
  // instruction: the linear address of the instruction's first byte against DRi (an
  // enabled breakpoint of type execute); data: the bytes of the load / store against the
  // breakpoint's bytes (LEN: address bits ignored) in its word, or in the next word of an
  // access crossing into it.  Registered with the uop, acted on in E.
  logic [3:0] ibm, dbr, dbw;
  logic [3:0] n_ibm, n_dbr, n_dbw;
  logic       ibh, gdq;              // (registered: an enabled instruction breakpoint matches; MOV DRn with GD)
  logic       dbtr, dbtw;            // (registered: an enabled data breakpoint matches the load / the store)
  logic [3:0] ib_en, db_en;          // breakpoint enabled (L / G), and of type execute
  always_comb
    for (int i = 0; i < 4; i++) begin
      db_en[i] = |dr7[2*i +: 2];
      ib_en[i] = db_en[i] && (dr7[16 + 4*i +: 2] == 2'b00);
    end
  wire  [31:0] m_ilin = m_ip_start + cs_base;
  wire        n_rd   = m_uw[UW_MRD_L] && !m_noacc;
  wire        n_wr   = (m_wr != WR_NONE) && !m_cmp;
  wire  [31:0] m_stl = (m_wr == WR_SEC) ? m_slin : m_lin;
  wire  [UW_CK_W-1:0] m_ck = m_uw[UW_CK_L +: UW_CK_W];
  wire        n_stsup = (m_eop == E_PROBE) ||
                        ((m_eop == E_DHI) && (m_ck == UW_CK_W'(CK_TBSY)) && (tsk_op == 2'd3)) ||
                        ((m_eop == E_DHI) && (m_ck == UW_CK_W'(CK_TFRE)) && tsk_lnk) ||
                        ((m_eop == E_TLNK) && !tsk_lnk);
  function automatic logic [7:0] abytes(input logic [1:0] a, input logic [1:0] n);
    return ((n == 2'd0) ? 8'h01 : (n == 2'd1) ? 8'h03 : 8'h0F) << a;
  endfunction
  always_comb begin
    logic [7:0] bk_ld, bk_st;
    logic [3:0] bk_bp;
    bk_ld = abytes(m_lin[1:0], m_msz);
    bk_st = abytes(m_stl[1:0], m_sz);
    for (int i = 0; i < 4; i++) begin
      for (int b = 0; b < 4; b++)
        bk_bp[b] = ((2'(b) ^ dr[i][1:0]) & ~dr7[18 + 4*i +: 2]) == 2'b00;
      n_ibm[i] = (m_ilin == dr[i]);
      n_dbr[i] = n_rd && (dr7[16 + 4*i +: 2] == 2'b11) &&
                 (((m_lin[31:2] == dr[i][31:2]) && |(bk_ld[3:0] & bk_bp)) || ((m_lin[31:2] == drm1[i]) && |(bk_ld[7:4] & bk_bp)));
      n_dbw[i] = n_wr && dr7[16 + 4*i] &&
                 (((m_stl[31:2] == dr[i][31:2]) && |(bk_st[3:0] & bk_bp)) || ((m_stl[31:2] == drm1[i]) && |(bk_st[7:4] & bk_bp)));
    end
  end
  // ---------------------------------------------------------------- E input register
  always_ff @(posedge clk) begin
    if (rst) v <= 1'b0;
    else if (!hold_e) v <= m_adv && !flush_r;
    else if (flush_r) v <= 1'b0;
  end
  always_ff @(posedge clk) begin
    if (!hold_e) begin
      eop <= m_eop; wrk <= m_wr; repz <= m_uw[UW_REPZ_L];
      last <= m_last; bnd <= m_bnd; sz <= m_sz; msz <= m_msz; op <= m_op; pg <= m_pg; modrm <= m_modrm;
      as32 <= m_as32;
      imm <= m_imm; ip_start <= m_ip_start; ip_next <= m_ip_next;
      sreg <= m_sreg; rep <= m_rep; pt <= m_pt; ptgt <= m_ptgt; inj <= m_inj; bid <= m_bid;
      abr_e <= m_abr;
      srf <= m_rfix; os32 <= m_os32;
      spw <= m_spw; spv <= m_spv; siw <= m_siw; siv <= m_siv; diw <= m_diw;
      divv <= m_div; cxw <= m_cxw; cxv <= m_cxv; tgt <= m_tgt; tbad <= m_tbad; brlin <= m_brlin;
      tgteq <= (m_tgt == m_ptgt);
      cxnz <= m_cxnz; ataken <= m_ataken; dmask <= m_dmask; aex <= m_aex; xc <= m_xc; amis <= m_amis;
      ld32 <= m_ld32;
      ld_lin <= m_lin; ld_lin4 <= m_lin4;
      // (paging off: the next word's page is its own)
      ld_ppn0 <= m_pppn; ld_ppn1 <= pgon ? m_pppn : m_lin4[31:12]; ld_pcd <= m_ppcd; xs_q <= m_xs;
      st_ppn0 <= (m_wr == WR_SEC) ? m_sppn : m_pppn;
      st_ppn1 <= !pgon ? ((m_wr == WR_SEC) ? m_slin4[31:12] : m_lin4[31:12]) : (m_wr == WR_SEC) ? m_sppn : m_pppn;
      lcross_q <= xpage(m_lin[11:0], m_msz);
      scross_q <= xpage((m_wr == WR_SEC) ? m_slin[11:0] : m_lin[11:0], m_sz);
      sv_q  <= m_uw[UW_SV_L]; mrd_q <= m_uw[UW_MRD_L] && !m_noacc;
      st_lin  <= (m_wr == WR_SEC) ? m_slin  : m_lin;
      st_lin4 <= (m_wr == WR_SEC) ? m_slin4 : m_lin4;
      preA <= da.pv; preB <= db.pv;
      sA0 <= la[5:0]; sA1 <= la[9:6]; sA2 <= la[13:10];
      sB0 <= lb[5:0]; sB1 <= lb[9:6]; sB2 <= lb[13:10];
      for (int i = 0; i < 8; i++)
        for (int l = 0; l < 3; l++) begin
          wh0[3*i+l] <= n_p0_en && n_p0_r == 3'(i) && n_p0_be[l];
          wh1[3*i+l] <= n_p1_en && n_p1_r == 3'(i) && n_p1_be[l];
        end
      p0_en <= n_p0_en; p0_r <= n_p0_r; p0_be <= n_p0_be; p0_hi <= n_p0_hi;
      p1_en <= n_p1_en; p1_r <= n_p1_r; p1_be <= n_p1_be; p1_hi <= n_p1_hi; p1_sp <= n_p1_sp;
      sw_en <= n_sw_en; sw_r <= n_sw_r;
      tx_we <= {m_d1 == D_T9, m_d1 == D_T8, m_d1 == D_T7, m_d1 == D_T6, m_d1 == D_T5, m_d1 == D_T4};
      tw_we <= {(m_d1 == D_T3) || (m_d2 == D_T3), (m_d1 == D_T2) || (m_d2 == D_T2),
                (m_d1 == D_T1) || (m_d2 == D_T1), (m_d1 == D_T0) || (m_d2 == D_T0)};
      tw_r2 <= {m_d2 == D_T3, m_d2 == D_T2, m_d2 == D_T1, m_d2 == D_T0};
      ck    <= m_uw[UW_CK_L +: UW_CK_W];
      chk   <= m_uw[UW_CHK_L +: UW_CHK_W];
      wr_en <= (m_wr != WR_NONE) && !m_cmp;
      // (B bits once any breakpoint is enabled; no store: probes, suppressed descriptor /
      // TSS writes (the task-switch kind is fixed while the uop is in M))
      ibm <= n_ibm; dbr <= |dr7[7:0] ? n_dbr : 4'h0; dbw <= (|dr7[7:0] && !n_stsup) ? n_dbw : 4'h0;
      dbtr <= |(n_dbr & db_en); dbtw <= |(n_dbw & db_en) && !n_stsup;
      ibh <= |(n_ibm & ib_en);
      gdq <= ((m_eop == E_TRD) || (m_eop == E_TWR)) && !m_op[2] && dr7[13];
      c_asub <= n_asub; c_acf <= n_acf;
      c_logic <= n_logic; c_lop <= n_lop; c_rsel <= n_rsel;
    end else if (e_pdone && w_ok)
      // a walk result (translation slow path below)
      case (tstep)
        2'd0: begin ld_ppn0 <= w_e[24:5]; if (!lcross) ld_ppn1 <= w_e[24:5]; ld_pcd <= w_e[1]; end
        2'd1: ld_ppn1 <= w_e[24:5];
        2'd2: begin st_ppn0 <= w_e[24:5]; if (!scross) st_ppn1 <= w_e[24:5]; end
        default: st_ppn1 <= w_e[24:5];
      endcase
  end
  wire act = v && !flush_r;
  assign e_busy_valid = v;

  // ---------------------------------------------------------------- address translation (paging)
  // M uses the micro-TLB entries looked up in A2.  When they missed (and the TLB in the
  // M replay too), lack the rights, a write needs D, or an access crosses into the next
  // page, E translates here through the walker (TLB first) before the access, in
  // 86Box's order: load (low page, high page), then store (low, high).  The store's
  // steps wait until the uop is known to store (load data final, no fault, not
  // suppressed: one registered evaluation cycle).  A walk that fails raises #PF.
  wire        pgon   = cr0[31] && cr0[0];
  // instruction fetch page fault: taken when nothing older is left (E empty)
  // (E idle for 3 cycles: the instruction-breakpoint compare on the architectural EIP below
  // has settled; the fetch walk takes longer anyway)
  logic [2:0] e_idle;
  always_ff @(posedge clk) e_idle <= rst ? 3'b000 : {e_idle[1:0], !v && !flush_r};
  wire        ff_take = ff_go && !v && !flush_r && !halted && (xs == X_IDLE) && &e_idle;
  // an instruction breakpoint on an instruction whose fetch faults: #DB first (a code
  // breakpoint ranks above the faults of fetching the instruction); the architectural
  // EIP's linear address against DR0-3, registered (only used once E has drained)
  logic [31:0] ilin_a;
  logic [3:0]  ffbm;
  always_ff @(posedge clk) begin
    ilin_a <= cs_base + ip_arch;
    for (int i = 0; i < 4; i++) ffbm[i] <= (ilin_a == dr[i]) && ib_en[i];
  end
  wire ffbp     = |ffbm && !rf && !ssp_q;
  wire ff_db    = ff_take && ffbp;
  // crossing into the next page: load (size msz) / store (size sz)
  // (the needs are registered at E entry: they feed the stall network)
  wire        lcross = lcross_q;
  wire        scross = scross_q;
  // last byte of a crossing access (CR2 of a high-page #PF): its page is the next one,
  // which the next word's address (ld_lin4 / st_lin4) already has; a 12-bit add
  wire [11:0] lend_o = ld_lin[11:0] + ((msz == 2'd2) ? 12'd3 : (msz == 2'd1) ? 12'd1 : 12'd0);
  wire [11:0] send_o = st_lin[11:0] + ((sz == 2'd2) ? 12'd3 : (sz == 2'd1) ? 12'd1 : 12'd0);
  wire [31:0] lend   = {ld_lin4[31:12], lend_o};
  wire [31:0] send   = {st_lin4[31:12], send_o};

  logic       pf_q;                             // a walk failed: #PF
  logic [2:0] pf_err;
  logic [31:0] pf_cr2;
  logic       s_ev, s_will;                     // store steps evaluated / the uop stores
  // (a static check fault (chk_flt) stops the translation: the walk is not requested,
  // the hold drops one cycle later)
  // translation steps still needed, kept in a register (it feeds the stall network):
  // loaded at E entry, a step cleared when its walk succeeds, all on a static check fault.
  // At entry the low-page steps are also needed when the CPL changed after M checked
  // the rights: M saw another CPL (m_ucpl), or the uop leaving E now is one that writes
  // the CPL (conservative: a TLB lookup when it kept the CPL).
  logic [3:0] tn;
  wire        cplw   = (eop == E_LDCS) || (eop == E_LDV86) || (eop == E_TLFL) ||
                       ((eop == E_PASSB) && (ck == CK_SELO));
  wire        n_stl  = (m_ucpl != cpl) || (v && cplw);
  wire        n_tv   = m_adv && !flush_r && pgon && (m_xc == 3'd0);
  wire        n_tl   = m_adv && !flush_r && pgon && ((m_xc == 3'd0) || m_xs);   // (loads)
  always_ff @(posedge clk) begin
    if (rst) tn <= 4'h0;
    else if (!hold_e) begin
      tn[0] <= n_tl && n_rd && (!m_pok || n_stl);
      tn[1] <= n_tl && n_rd && xpage(m_lin[11:0], m_msz);
      tn[2] <= n_tv && n_wr && (!((m_wr == WR_SEC) ? m_sok : m_pok) || n_stl);
      tn[3] <= n_tv && n_wr && xpage((m_wr == WR_SEC) ? m_slin[11:0] : m_lin[11:0], m_sz);
    end else if (flush_r || (act && tstop)) tn <= 4'h0;
    else if (e_pdone && w_ok) tn[tstep] <= 1'b0;
  end
  wire [3:0]  tneed  = tn;
  wire        st_tok = !(tneed[2] || tneed[3]);
  wire        l_pend = (tneed[0] || tneed[1]) && !pf_q;
  wire        s_pend = !st_tok && !pf_q;     // (#AC of the store: st_will is 0, no walk)
  wire        s_go   = s_ev && s_will;
  wire [1:0]  tstep  = tneed[0] ? 2'd0 : tneed[1] ? 2'd1 : tneed[2] ? 2'd2 : 2'd3;
  wire        tbusy  = l_pend || (s_pend && s_go);
  // completion waits for the walks, and a store needing translation for its evaluation
  wire        tblock = l_pend || (s_pend && !(s_ev && !s_will));
  assign e_preq  = act && tbusy && !tstop;
  assign e_pa    = (tstep == 2'd0) ? ld_lin[31:12] : (tstep == 2'd1) ? ld_lin4[31:12] :
                   (tstep == 2'd2) ? st_lin[31:12] : st_lin4[31:12];
  assign e_pwr   = tstep[1];
  assign e_puser = (cpl == 2'd3) && !sv_q;
  assign e_pcpl3 = (cpl == 2'd3);
  assign e_lpp_ld = e_pdone && w_ok && (!tstep[1] || (wrk == WR_PRI));
  assign e_lps_ld = e_pdone && w_ok && tstep[1] && (wrk == WR_SEC);
  // the uop stores (evaluated once the load data is final)
  wire        st_will = wr_en && !fault_x && ((eop == E_PROBE) ||
                        (!st_sup && !sup_d && !((eop == E_SHIFT || eop == E_SHXD) && shb && sh_z)));
  always_ff @(posedge clk) begin
    if (rst || flush_r || !hold_e) begin
      pf_q <= 1'b0; s_ev <= 1'b0; s_will <= 1'b0;
    end else begin
      // (INS: ES:EDI is translated before the port read, as the 386 check-write)
      if (act && s_pend && !s_ev && !l_pend && (done || eop == E_IN) && !ldwait && !fsel_any) begin
        s_ev <= 1'b1; s_will <= st_will;
      end
      if (e_pdone) begin
        if (!w_ok) begin
          pf_q <= 1'b1; pf_err <= w_err;
          pf_cr2 <= (tstep == 2'd0) ? ld_lin : (tstep == 2'd1) ? lend : (tstep == 2'd2) ? st_lin : send;
        end
      end
    end
  end

  // ---------------------------------------------------------------- locked read-modify-write
  // A load of a LOCK instruction (or XCHG with memory) is read on the bus (uncached, after
  // the store buffer has drained) with the bus locked; the lock is held until the
  // instruction has ended and its store has reached the bus (io_ok).
  wire  m_lk = (m_lock || (!m_pg && (m_op[7:1] == 7'b1000011) && (m_modrm[7:6] != 2'b11))) && m_uw[UW_MRD_L];
  logic lk_q, lk_end;
  always_ff @(posedge clk) if (!hold_e) lk_q <= m_lk && m_adv && !flush_r;
  always_ff @(posedge clk) begin
    if (rst) begin lk_hold <= 1'b0; lk_end <= 1'b0; end
    else begin
      if (lst == L_UW && io_ok && lk_q && act) lk_hold <= 1'b1;
      if (lk_hold && ((complete && (last || fault)) || flush_r)) lk_end <= 1'b1;
      if (lk_end && io_ok) begin lk_hold <= 1'b0; lk_end <= 1'b0; end
    end
  end

  // ---------------------------------------------------------------- late loads
  // a load that was not satisfied in M (miss, store conflict, uncacheable)
  typedef enum logic [3:0] {L_IDLE, L_WAIT, L_RD, L_CHK, L_DEC, L_FW, L_FILL, L_UW, L_UNC} ls_t;
  logic        xr_hit;
  logic [31:0] xr_data;
  logic [3:0]  xr_hb;
  logic        xr_part;
  always_ff @(posedge clk) if (lst == L_CHK) begin xr_hit <= x_hit; xr_hb <= x_hb; xr_data <= x_data; end
  // CR0.CD + NW: a line-crossing load with one line cached reads that line's bytes from
  // the cache (newer than memory) and only the other line's bytes from the bus (as the
  // i486 splits the access); with NW clear the two agree
  always_ff @(posedge clk)
    if (lst == L_IDLE) xr_part <= 1'b0;
    else if (lst == L_DEC) xr_part <= cr0[30] && cr0[29];
  ls_t lst;
  logic [15:0] fsel;
  wire         fsel_any = fsel[3] | fsel[7] | fsel[11] | fsel[15];
  // A1 bypass of a plain load in E: its GPR / T0 (byp_q, byp_t0q: selects only) and whether
  // mdat is final (byp_ok: set with the update that makes it so)
  logic [7:0]  byp_q;
  logic        byp_ok, byp_t0q;
  wire         mfwd_any = m_fwd[3] | m_fwd[7] | m_fwd[11] | m_fwd[15];
  wire         m_fin    = m_adv && !flush_r && !m_ldwait && !mfwd_any && !m_lk;
  // whether the data is final (the D-cache hit) matters to the scoreboard alone, which holds
  // readers of a load still waiting in E
  always_ff @(posedge clk) begin
    if (rst || flush_r) begin byp_q <= 8'h0; byp_t0q <= 1'b0; end
    else if (!hold_e) begin
      // (a uop held in M (replay) may show up here too: its destination is pending in M)
      byp_q   <= m_valid ? m_ldm  : 8'h0;
      byp_t0q <= m_valid && m_ldt0;
    end
    if (rst) byp_ok <= 1'b0;
    else if (!hold_e) byp_ok <= m_fin;
    else if (flush_r) byp_ok <= 1'b0;
    else if (fsel_any ? !ldwait : ((lst == L_DEC && xr_hit) || (lst == L_UNC && du_done))) byp_ok <= 1'b1;
    else if (fsel_any) byp_ok <= 1'b0;
  end
  assign e_byp_t0 = byp_t0q;
  always_ff @(posedge clk) begin
    if (!hold_e) begin
      mdat   <= m_data;
      fsel   <= (m_xc == 3'd0) ? m_fwd : 16'h0;   // bytes owed by the store now completing in E
      ldwait <= (m_ldwait || m_lk) && m_adv && !flush_r && (m_xc == 3'd0) && !m_noacc;   // a faulting uop needs no data
    end else if (fsel_any) begin
      // that store is in W now: merge its bytes (one extra cycle)
      for (int k = 0; k < 4; k++)
        if (fsel[k*4 + 3])
          mdat[k*8 +: 8] <= fsel[k*4 + 2] ? w_d1[fsel[k*4 +: 2]*8 +: 8] : w_d0[fsel[k*4 +: 2]*8 +: 8];
      fsel <= 16'h0;
    end else if ((e_pdone && !w_ok) || (act && tstop)) begin
      ldwait <= 1'b0;                  // #PF / a static check fault: the load does not happen
    end else if (lst == L_DEC) begin
      mdat   <= xr_data;               // (a miss: the bytes of a line that hit, kept for CD + NW)
      if (xr_hit) ldwait <= 1'b0;
    end else if (lst == L_UNC && du_done) begin
      for (int k = 0; k < 4; k++)
        if (!(xr_part && xr_hb[k])) mdat[k*8 +: 8] <= du_data[k*8 +: 8];
      ldwait <= 1'b0;
    end
    if (rst) begin ldwait <= 1'b0; fsel <= 16'h0; end
  end
  always_ff @(posedge clk) begin
    if (rst || flush_r) lst <= L_IDLE;
    else case (lst)
      L_IDLE: if (act && ldwait && !l_pend && !pf_q && !tstop) lst <= L_WAIT;   // (after the translation)
      // older stores written and store buffer drained
      // (CR0.NW: PCD / uncacheable reads look in the cache first, as on the i486 where
      // PCD and KEN# only stop fills; the cache can hold data newer than memory)
      L_WAIT: if (!w_v && !l_st_v) lst <= ((x_cached || cr0[29]) && !lk_q) ? L_RD : L_UW;
      L_UW:   if (io_ok) lst <= L_UNC;
      L_FW:   if (io_ok) lst <= L_FILL;
      L_RD:   lst <= L_CHK;
      L_CHK:  lst <= L_DEC;
      L_DEC:  lst <= xr_hit ? L_IDLE : cr0[30] ? L_UW : L_FW;     // CR0.CD: a miss does not fill
      L_FILL: if (x_fill_done) lst <= L_RD;
      L_UNC:  if (du_done) lst <= L_IDLE;
      default: lst <= L_IDLE;
    endcase
  end
  assign x_act  = (lst == L_RD);
  assign x_lin  = {ld_ppn0, ld_lin[11:0]};
  assign x_lin4 = {ld_ppn1, ld_lin4[11:2]};
  assign x_pcd  = ld_pcd;
  assign x_sz   = msz;
  assign x_fill = (lst == L_FW) && io_ok;
  assign du_req = (lst == L_UNC);
  logic pdm_v;
  assign e_dmask = (v ? dmask : 16'd0) | (pend ? {8'd0, p_dmask[7:0]} : 16'd0) |
                   (pdm_v ? {p_dmask[15:8], 8'd0} : 16'd0);
  assign e_st_lin  = {st_ppn0, st_lin[11:0]};
  assign e_st_lin4 = {st_ppn1, st_lin4[11:2]};
  assign e_st_v  = v && wr_en && !st_sup && st_tok;      // (CMP never stores)
  assign e_st_xp = v && wr_en && !st_sup && !st_tok;
  assign e_st_a0 = e_st_lin[31:2];
  assign e_st_a1 = e_st_lin4;
  wire [3:0] st_bm  = (sz == 2'd0) ? 4'b0001 : (sz == 2'd1) ? 4'b0011 : 4'b1111;
  wire [7:0] st_be8 = 8'({4'b0000, st_bm} << st_lin[1:0]);
  assign e_st_be0 = st_be8[3:0];
  assign e_st_be1 = st_be8[7:4];

  // ---------------------------------------------------------------- final operand mux
  function automatic logic [31:0] omux(input logic [5:0] s0, input logic [3:0] s1, input logic [3:0] s2,
                                       input logic [31:0] pre);
    logic [7:0]  a0, a1;
    logic [15:0] a2;
    a0 = ({8{s0[0]}} & pre[7:0]) | ({8{s0[1]}} & lw0[7:0]) | ({8{s0[2]}} & lw0[15:8]) |
         ({8{s0[3]}} & lw1[7:0]) | ({8{s0[4]}} & lw1[15:8]) | ({8{s0[5]}} & mdat[7:0]);
    a1 = ({8{s1[0]}} & pre[15:8]) | ({8{s1[1]}} & lw0[15:8]) | ({8{s1[2]}} & lw1[15:8]) |
         ({8{s1[3]}} & mdat[15:8]);
    a2 = ({16{s2[0]}} & pre[31:16]) | ({16{s2[1]}} & lw0[31:16]) | ({16{s2[2]}} & lw1[31:16]) |
         ({16{s2[3]}} & mdat[31:16]);
    return {a2, a1, a0};
  endfunction
  logic [31:0] A, B;
  always_comb begin
    A = omux(sA0, sA1, sA2, preA);
    B = omux(sB0, sB1, sB2, preB);
  end

  // ================================================================ ALU

  // add/sub core at an operand size: returns {r[31:0], cf, af, of}
  function automatic logic [34:0] addsub(input logic [31:0] a, input logic [31:0] b,
                                          input logic cin, input logic sub, input logic [1:0] z);
    logic [32:0] r33;
    logic [31:0] bb, r;
    logic c, acy, o, cy;
    bb  = sub ? ~b : b;
    r33 = {1'b0, a} + {1'b0, bb} + {32'd0, cin ^ sub};
    r   = r33[31:0];
    // carry out of bit 7 / 15: sum bit 8 / 16 against the operand bits
    cy  = (z == 2'd0) ? (a[8] ^ bb[8] ^ r[8]) : (z == 2'd1) ? (a[16] ^ bb[16] ^ r[16]) : r33[32];
    c   = cy ^ sub;
    acy  = a[4] ^ b[4] ^ r[4];
    case (z)
      2'd0:    o = (a[7] == bb[7]) && (r[7] != a[7]);
      2'd1:    o = (a[15] == bb[15]) && (r[15] != a[15]);
      default: o = (a[31] == bb[31]) && (r[31] != a[31]);
    endcase
    return {r, c, acy, o};
  endfunction

  // ALU (all controls predecoded in M)
  wire [34:0] ar = addsub(A, B, c_acf & cf, c_asub, sz);
  // zero flag without the carry chain: (a + b + c) == 0  <=>  (a ^ b) == {(a | b) << 1, c}
  wire [31:0] zb  = c_asub ? ~B : B;
  wire        zc  = (c_acf & cf) ^ c_asub;
  wire [31:0] zp  = A ^ zb;
  wire [31:0] zk  = {A[30:0] | zb[30:0], zc};
  wire        az  = (zp[7:0] == zk[7:0]) && ((sz == 2'd0) || (zp[15:8] == zk[15:8])) &&
                    ((sz != 2'd2) || (zp[31:16] == zk[31:16]));
  logic [31:0] lr;
  always_comb begin
    case (c_lop)
      2'd1:    lr = A | B;
      2'd2:    lr = A ^ B;
      default: lr = A & B;
    endcase
  end
  wire is_logic = c_logic;

  // ---------------------------------------------------------------- shifter
  // count: 1 (D0 / D1), CL (D2 / D3) or imm8 (C0 / C1), masked to 5 bits.
  // shf: the single-cycle shift by one (a variable count goes through the funnel
  // shifter below).  Returns {of, cf, result}.
`include "modtab.svh"
  function automatic logic [33:0] shf(input logic [31:0] xin, input logic [4:0] n, input logic [2:0] o,
                                      input logic [1:0] z, input logic c);
    logic [31:0] x, res;
    logic [63:0] rep64, t64;
    logic [65:0] dd;
    logic [64:0] u65;
    logic [5:0]  r;
    logic        co, ov, msb, msb1, xm;
    x  = (z == 2'd0) ? {24'h0, xin[7:0]} : (z == 2'd1) ? {16'h0, xin[15:0]} : xin;
    xm = (z == 2'd0) ? x[7] : (z == 2'd1) ? x[15] : x[31];
    rep64 = (z == 2'd0) ? {8{x[7:0]}} : (z == 2'd1) ? {4{x[15:0]}} : {2{x}};
    res = x; co = c;
    case (o)
      3'd0: begin                                                     // ROL
        t64 = (rep64 << n) | (rep64 >> (7'd64 - {2'b0, n}));
        res = (n == 5'd0) ? x : t64[31:0];
      end
      3'd1: begin                                                     // ROR
        t64 = (rep64 >> n) | (rep64 << (7'd64 - {2'b0, n}));
        res = (n == 5'd0) ? x : t64[31:0];
      end
      3'd2, 3'd3: begin                                               // RCL / RCR through CF
        case (z)
          2'd0: begin
            r  = {1'b0, mod9({3'b0, n})};
            dd = {48'h0, c, x[7:0], c, x[7:0]};
            dd = (o == 3'd2) ? ((dd << r) >> 9) : (dd >> r);
            res = {24'h0, dd[7:0]}; co = dd[8];
          end
          2'd1: begin
            r  = {1'b0, mod17({3'b0, n})};
            dd = {32'h0, c, x[15:0], c, x[15:0]};
            dd = (o == 3'd2) ? ((dd << r) >> 17) : (dd >> r);
            res = {16'h0, dd[15:0]}; co = dd[16];
          end
          default: begin
            r  = {1'b0, n};
            dd = {c, x, c, x};
            dd = (o == 3'd2) ? ((dd << r) >> 33) : (dd >> r);
            res = dd[31:0]; co = dd[32];
          end
        endcase
      end
      3'd4, 3'd6: begin                                               // SHL / SAL
        t64 = {32'h0, x} << n;
        res = t64[31:0];
        co  = (z == 2'd0) ? t64[8] : (z == 2'd1) ? t64[16] : t64[32];
      end
      default: begin                                                  // SHR / SAR
        u65 = {((o == 3'd7) ? {32{xm}} : 32'h0),
               ((z == 2'd0) ? {{24{(o == 3'd7) && xm}}, x[7:0]} :
                (z == 2'd1) ? {{16{(o == 3'd7) && xm}}, x[15:0]} : x), 1'b0} >> n;
        res = u65[32:1];
        co  = u65[0];
      end
    endcase
    if (z == 2'd0) res = {24'h0, res[7:0]};
    else if (z == 2'd1) res = {16'h0, res[15:0]};
    msb  = (z == 2'd0) ? res[7] : (z == 2'd1) ? res[15] : res[31];
    msb1 = (z == 2'd0) ? res[6] : (z == 2'd1) ? res[14] : res[30];
    case (o)
      3'd0: begin co = res[0]; ov = msb ^ res[0]; end
      3'd1: begin co = msb;    ov = msb ^ msb1; end
      3'd2: ov = msb ^ co;
      3'd3: ov = msb ^ msb1;
      3'd4, 3'd6: ov = msb ^ co;
      3'd5: ov = msb ^ msb1;
      default: ov = 1'b0;
    endcase
    return {ov, co, res};
  endfunction
  wire [2:0]  shop = modrm[5:3];
  logic       shb;           // variable count (CL / imm8): the registered path
  logic       sh_z;          // count is zero: nothing changes
  // SHL / SHR / SAR / SHLD of a 32-bit register by imm8 (not 0), no source written by the uop in
  // E: the funnel's inputs are prepared in M, E takes one cycle (sh_m)
  logic       sh_m;
  wire [2:0]  ms_o   = m_modrm[5:3];
  wire        ms_x   = (m_eop == E_SHXD) && !m_op[0] && !m_op[3];      // SHLD
  wire        ms_s   = (m_eop == E_SHIFT) && (m_op[7:4] == 4'hC) && ms_o[2];
  wire        ms_l   = ms_x || !ms_o[0];
  wire [32:0] ms_f   = {33{!ms_x && (ms_o == 3'd7) && da.pv[31]}};
  wire        ms_rdy = (ms_x || ms_s) && (m_sz == 2'd2) && (m_modrm[7:6] == 2'd3) && (m_imm[4:0] != 5'd0) &&
                       (la == 14'b0001_0001_000001) && (!ms_x || lb == 14'b0001_0001_000001);
  wire        sh_e   = v && !flush_r && shb && !sh_m && (xs == X_IDLE);   // prepared in E (E holds)
  logic [31:0] shx;          // operand captured for the shift cycle (result of a zero count)
  // Variable-count shifts, rotates, SHLD / SHRD: one funnel shifter.  At capture
  // every operation is turned into a 65-bit pattern fw and a right-shift amount
  // fk (0..33); the result is ({fw, 0} >> fk)[32:1], the bit below it is the
  // carry of the right-going operations, the bit above the operand size the
  // carry of SHL / SHLD.
  //   ROR n   {rep, rep} >> n           ROL n   {rep, rep} >> 32 - n    (rep: the operand repeated)
  //   SHR n   {0, x} >> n               SAR n   {sign, x} >> n
  //   SHL n   {x, 0} >> 32 - n
  //   RCR r   {x, c, x} >> r (r = 0: s + 1)    RCL r   {x, c, x} >> s + 1 - r      (r = n mod s + 1)
  //   SHRD n  {src, dst} >> n  (16 bit: {src, src, dst})     SHLD n  {dst, src} >> 32 - n  (16 bit: {dst, src, src})
  logic [64:0] fw;
  logic [5:0]  fk;
  logic [64:0] n_fw;
  logic [5:0]  n_fk;
  // count from imm8: C0 / C1, SHLD / SHRD imm (0F A4 / AC), else CL; masked to 5 bits
  wire         sh_imm = (eop == E_SHXD) ? !op[0] : (op[7:4] == 4'hC);
  wire  [4:0]  shc  = sh_imm ? imm[4:0] : gm[1][4:0];
  always_comb begin
    logic [31:0] x, xs, rep;
    logic [4:0]  r;
    logic [5:0]  s1;
    x   = (sz == 2'd0) ? {24'h0, A[7:0]} : (sz == 2'd1) ? {16'h0, A[15:0]} : A;
    xs  = (sz == 2'd0) ? {{24{A[7]}}, A[7:0]} : (sz == 2'd1) ? {{16{A[15]}}, A[15:0]} : A;
    rep = (sz == 2'd0) ? {4{A[7:0]}} : (sz == 2'd1) ? {2{A[15:0]}} : A;
    s1  = (sz == 2'd0) ? 6'd9 : (sz == 2'd1) ? 6'd17 : 6'd33;
    r   = (sz == 2'd0) ? mod9({3'b0, shc}) : (sz == 2'd1) ? mod17({3'b0, shc}) : shc;
    if (eop == E_SHXD) begin
      if (op[3]) begin
        n_fw = (sz == 2'd2) ? {1'b0, B, A} : {17'h0, B[15:0], B[15:0], A[15:0]};
        n_fk = {1'b0, shc};
      end else begin
        n_fw = (sz == 2'd2) ? {1'b0, A, B} : {17'h0, A[15:0], B[15:0], B[15:0]};
        n_fk = 6'd32 - {1'b0, shc};
      end
    end else
      case (shop)
        3'd0:    begin n_fw = {1'b0, rep, rep}; n_fk = 6'd32 - {1'b0, shc}; end
        3'd1:    begin n_fw = {1'b0, rep, rep}; n_fk = {1'b0, shc}; end
        3'd2, 3'd3: begin
          n_fw = (sz == 2'd0) ? {48'h0, A[7:0], cf, A[7:0]} :
                 (sz == 2'd1) ? {32'h0, A[15:0], cf, A[15:0]} : {A, cf, A};
          n_fk = (shop == 3'd2) ? s1 - {1'b0, r} : (r == 5'd0) ? s1 : {1'b0, r};
        end
        3'd4, 3'd6: begin n_fw = {1'b0, x, 32'h0}; n_fk = 6'd32 - {1'b0, shc}; end
        3'd5:    begin n_fw = {33'h0, x}; n_fk = {1'b0, shc}; end
        default: begin n_fw = {{33{xs[31]}}, xs}; n_fk = {1'b0, shc}; end
      endcase
  end
  wire [65:0] fo = {fw, 1'b0} >> fk;
  logic [33:0] bs_q;
  always_comb begin
    logic [31:0] res;
    logic        msb, msb1, co, ov, left, rgt;
    res  = (sz == 2'd0) ? {24'h0, fo[8:1]} : (sz == 2'd1) ? {16'h0, fo[16:1]} : fo[32:1];
    msb  = (sz == 2'd0) ? res[7] : (sz == 2'd1) ? res[15] : res[31];
    msb1 = (sz == 2'd0) ? res[6] : (sz == 2'd1) ? res[14] : res[30];
    left = (eop == E_SHXD) ? !op[3] : (shop == 3'd4) || (shop == 3'd6);
    rgt  = (eop == E_SHXD) ? op[3] : (shop == 3'd2) || (shop == 3'd3) || (shop == 3'd5) || (shop == 3'd7);
    co   = left ? ((sz == 2'd0) ? fo[9] : (sz == 2'd1) ? fo[17] : fo[33]) :
           rgt  ? fo[0] : (shop == 3'd0) ? res[0] : msb;
    if (eop == E_SHXD) ov = op[3] ? (msb ^ msb1) : (msb ^ co);
    else
      case (shop)
        3'd0, 3'd2, 3'd4, 3'd6: ov = msb ^ co;
        3'd7:    ov = 1'b0;
        default: ov = msb ^ msb1;
      endcase
    bs_q = {ov, co, res};
  end
  wire  [33:0] s1_q = shf(A, 5'd1, shop, sz, cf);
  // variable count: the funnel result is used directly in the second cycle (its inputs are
  // registers), so a shift by imm8 / CL takes 2 clocks as on the i486 (by 1, and those prepared
  // in M: 1 clock)
  wire  [33:0] sh_q = shb ? bs_q : s1_q;
  wire  [31:0] sh_r = (shb && sh_z) ? shx : sh_q[31:0];
  wire         sh_szp = shop[2] || (eop == E_SHXD);   // SHL / SHR / SAR / SHLD / SHRD set SF ZF PF

  // ================================================================ multi-cycle units
  // (the final state of each multi-cycle class has bit 3 set, the others not: done is
  // xs[3] for a uop of any multi-cycle class, as xs only takes its own class's states)
  typedef enum logic [3:0] {X_IDLE, X_MUL1, X_MUL1B, X_DIV0, X_DIV, X_IO, X_INTA, X_CF,
                            X_MUL2, X_DIVF, X_IOD, X_SH2, X_B2, X_CK2, X_JN2} xs_t;
  logic [31:0] io_rd_r;      // I/O read data, registered (completion one cycle after the ack)
  always_ff @(posedge clk) if (io_done) io_rd_r <= io_rdata;
  xs_t xs;
  logic [32:0] ma, mb;
  logic [65:0] mq, mp;
  logic [32:0] drem;
  logic [31:0] dq, ddv;
  logic [5:0]  dcnt;
  logic        dneg_q, dneg_r, derr_pre, dsigned;
  logic        dv_sgn;
  logic [1:0]  dsz;          // size of the divide in progress
  logic [63:0] dv_dd;
  logic [31:0] dv_dvs;
  logic        bnd_lt;       // BOUND: A < B (signed), registered
  logic [4:0]  bs_idx;       // BSF / BSR result, registered
  logic        bs_zero;

  // ================================================================ result / flags
  logic [31:0] x0, x1;   // special values (MUL/DIV/BCD/...) for p0 / p1
  // Rn: results that do not depend on the lazily evaluated SF / ZF / PF (the only
  // ones that can go to segment registers and temporaries); R: all
  logic [31:0] Rn, xf;
  always_comb begin
    Rn = ({32{c_rsel[0]}} & lr) | ({32{c_rsel[1]}} & ar[34:3]) | ({32{c_rsel[2]}} & ~A) |
         ({32{c_rsel[3]}} & A)  | ({32{c_rsel[4]}} & sh_r) | ({32{c_rsel[5]}} & ip_next) |
         ({32{c_rsel[7]}} & B) | ({32{c_rsel[8]}} & x0);
    xf = (eop == E_CSEL) ? (zf_e ? B : A) : {31'h0, jcc(op[3:0])};
    R  = Rn | ({32{c_rsel[6]}} & {10'h0, idf, 2'b0, ac, 2'b0, fimg}) | ({32{c_rsel[9]}} & xf);
    R2 = (eop == E_XCHG || eop == E_XADD || eop == E_DLO) ? A :
         (eop == E_DHI && ck == CK_INTG) ? {16'h0, t1[31:16]} :          // gate: the selector
         (eop == E_GATE) ? {16'h0, A[31:16]} : B;
  end

  // special register write values
  // BCD adjust: computed in the first cycle, registered, used in the second
  logic [7:0] bcd_al0, bcd_ah0, rb_al, rb_ah;
  logic       bcd_c10, bcd_c20, rb_c1, rb_c2;
  always_comb begin
    logic [7:0] al;
    logic [15:0] ax;
    al = A[7:0];
    bcd_c10 = af || (al[3:0] > 4'd9);
    bcd_c20 = cf || (al > 8'h99);
    // AAA / AAS adjust AX as a whole (the carry / borrow of AL reaches AH)
    ax = (eop == E_AAA) ? A[15:0] + 16'h0106 : A[15:0] - 16'h0106;
    bcd_ah0 = bcd_c10 ? ax[15:8] : A[15:8];
    case (eop)
      E_DAA: bcd_al0 = al + (bcd_c10 ? 8'h06 : 8'h00) + (bcd_c20 ? 8'h60 : 8'h00);
      E_DAS: begin
        bcd_al0 = al - (bcd_c10 ? 8'h06 : 8'h00) - (bcd_c20 ? 8'h60 : 8'h00);
        if (bcd_c10 && al < 8'h06) bcd_c20 = 1'b1;          // borrow of the low adjust
      end
      default: bcd_al0 = bcd_c10 ? ax[7:0] : al;
    endcase
  end
  wire [7:0] bcd_al = rb_al, bcd_ah = rb_ah;
  wire       bcd_c1 = rb_c1, bcd_c2 = rb_c2;
  (* use_dsp = "no" *) logic [7:0] aad_al;
  assign aad_al = A[7:0] + mp[7:0];

  always_comb begin
    case (eop)
      E_MUL:  x0 = mp[31:0];
      E_DIV:  x0 = (sz == 2'd0) ? {16'h0, drem[7:0], dq[7:0]} : dq;
      E_AAM:  x0 = {16'h0, dq[7:0], drem[7:0]};
      E_AAD:  x0 = {24'h0, aad_al};
      E_DAA, E_DAS: x0 = {24'h0, bcd_al};
      E_AAA, E_AAS: x0 = {16'h0, bcd_ah, 4'h0, bcd_al[3:0]};
      E_CBW:  x0 = {{16{A[15]}}, {8{A[7]}}, 8'h00};
      E_CWD:  x0 = (sz == 2'd2) ? {32{A[31]}} : {16'h0, {16{A[15]}}};
      E_SALC: x0 = {24'h0, {8{cf}}};
      E_LAHF: x0 = {16'h0, fimg[7:0], 8'h00};
      // MOVZX / MOVSX: byte (op[0] = 0) or word source, sign extension if op[3]
      E_MOVX: x0 = op[0] ? {{16{op[3] && B[15]}}, B[15:0]} : {{24{op[3] && B[7]}}, B[7:0]};
      E_IMUL2: x0 = mp[31:0];
      E_BT:    x0 = (bt_kind == 2'd1) ? (A | bt_m) : (bt_kind == 2'd2) ? (A & ~bt_m) : (A ^ bt_m);
      // bit string: the word that holds bit B of the string at EA (in A)
      E_BTADR: x0 = (A + ((sz == 2'd2) ? {{3{B[31]}}, B[31:5], 2'b00} : {{19{B[15]}}, B[15:4], 1'b0})) &
                    (as32 ? 32'hFFFF_FFFF : 32'h0000_FFFF);
      E_BSF:   x0 = bs_zero ? A : {27'd0, bs_idx};
      E_BSWAP: x0 = {A[7:0], A[15:8], A[23:16], A[31:24]};
      // protected-mode result uops (two-cycle class): computed in the first cycle
      E_DHI, E_EFL, E_GATE, E_TSSOFF, E_OLDSP, E_PADDR, E_LDSP, E_IOMAP, E_LARV, E_ARPL, E_TSSDESC, E_TFLG, E_TLDW,
      E_LDTSK: x0 = x0p;
      E_SRD, E_TRD, E_CPUID: x0 = srd_q;      // (registered in the uop's first cycle)
      default: x0 = io_rd_r;             // IN
    endcase
    x1 = (eop == E_MUL) ? ((sz == 2'd2) ? mp[63:32] : {16'h0, mp[31:16]}) : drem[31:0];
  end
  // system register reads (SMSW SLDT STR SGDT SIDT, MOV r,CRn / DRn / TRn, CPUID): two E
  // cycles, the value registered in the first (keeps these sources off the result mux)
  logic [31:0] srd_n, srd_q;
  always_comb begin
    srd_n = '0;
    case (eop)
      E_SRD:
        case (srf)
          3'd0: srd_n = cr0 | 32'h10;
          3'd1: srd_n = {16'h0, gdtl};
          3'd2: srd_n = gdtb;
          3'd3: srd_n = {16'h0, idtl};
          3'd4: srd_n = idtb;
          3'd5: srd_n = {16'h0, ldt_sel};
          3'd6: srd_n = {16'h0, tr_sel};
          default: srd_n = (modrm[5:3] == 3'd2) ? cr2 : (modrm[5:3] == 3'd3) ? cr3 : (cr0 | 32'h10);
        endcase
      E_TRD:   srd_n = !op[2] ? (!modrm[5] ? dr[modrm[4:3]] : modrm[3] ? dr7 : dr6) :
                       (modrm[5:3] == 3'd6) ? tr6 : (modrm[5:3] == 3'd7) ? tr7 : tr345[modrm[4:3]];
      // CPUID: the register rfix (0 EAX, 1 ECX, 2 EDX, 3 EBX) of leaf A (EAX): leaf 0 = highest
      // leaf 1, "GenuineIntel"; leaf 1 = the signature, no feature flags; others 0
      E_CPUID:
        if (A == 32'd0)
          case (srf[1:0])
            2'd0: srd_n = 32'd1;
            2'd1: srd_n = 32'h6C65_746E;
            2'd2: srd_n = 32'h4965_6E69;
            default: srd_n = 32'h756E_6547;
          endcase
        else if (A == 32'd1 && srf[1:0] == 2'd0) srd_n = CPU_SIG;
      default: ;
    endcase
  end
  always_ff @(posedge clk) if (xs == X_IDLE) srd_q <= srd_n;
  // bit test operands
  wire [1:0]  bt_kind = (op == 8'hBA) ? modrm[4:3] : op[4:3];       // 0 BT, 1 BTS, 2 BTR, 3 BTC
  wire [4:0]  bt_i    = (sz == 2'd2) ? B[4:0] : {1'b0, B[3:0]};
  wire [31:0] bt_m    = 32'd1 << bt_i;
  wire [31:0] p0_v = {R[31:16], p0_hi ? R[7:0]  : R[15:8],  R[7:0]};
  wire [31:0] p1_v = p1_sp ? x1 : {R2[31:16], p1_hi ? R2[7:0] : R2[15:8], R2[7:0]};

  // new flag values (selected by eop; inputs are ALU outputs or registers).
  // f_we: direct writes.  sres: SF/ZF/PF derived from fsv (size fssz) next cycle.
  logic [8:0]  f_we;           // {of, df, if, tf, sf, zf, af, pf, cf}
  logic        n_cf, n_pf, n_af, n_zf, n_sf, n_tf, n_if, n_df, n_of;
  logic        sres;
  logic [1:0]  fssz;
  logic [31:0] fsv;
  always_comb begin
    logic hi_ne, mul_s;
    mul_s = modrm[3] || (eop == E_IMUL2);
    {n_cf, n_pf, n_af, n_zf, n_sf, n_tf, n_if, n_df, n_of} = {cf, pf_e, af, zf_e, sf_e, tf, ifl, df, of};
    f_we = '0; sres = 1'b0; fsv = R; fssz = sz;
    case (sz)
      2'd0:    hi_ne = mul_s ? (mp[15:8] != {8{mp[7]}}) : (mp[15:8] != 8'h0);
      2'd1:    hi_ne = mul_s ? (mp[31:16] != {16{mp[15]}}) : (mp[31:16] != 16'h0);
      default: hi_ne = mul_s ? (mp[63:32] != {32{mp[31]}}) : (mp[63:32] != 32'h0);
    endcase
    case (eop)
      E_ALUOP, E_ALUREG, E_TEST: begin
        if (is_logic) begin n_cf = 1'b0; n_af = 1'b0; n_of = 1'b0; end
        else {n_cf, n_af, n_of} = ar[2:0];
        f_we = 9'b1_0000_0101; sres = 1'b1;
      end
      E_ADD, E_SUB, E_NEG, E_XADD: begin {n_cf, n_af, n_of} = ar[2:0]; f_we = 9'b1_0000_0101; sres = 1'b1; end
      E_CMP: begin {n_cf, n_af, n_of} = ar[2:0]; f_we = 9'b1_0000_0101; sres = 1'b1; fsv = ar[34:3]; end
      E_BT:  begin n_cf = A[bt_i]; f_we = 9'b0_0000_0001; end
      E_BSF: begin n_zf = bs_zero; f_we = 9'b0_0000_1000; end
      E_INC, E_DEC: begin {n_af, n_of} = ar[1:0]; f_we = 9'b1_0000_0100; sres = 1'b1; end
      E_SHIFT, E_SHXD: begin
        n_cf = sh_q[32]; n_of = sh_q[33];
        f_we = (shb && sh_z) ? 9'd0 : 9'b1_0000_0001;
        sres = !(shb && sh_z) && sh_szp;
      end
      E_DAA, E_DAS: begin
        n_af = bcd_c1; n_cf = bcd_c2; f_we = 9'b0_0000_0101;
        sres = 1'b1; fssz = 2'd0;
      end
      E_AAA, E_AAS: begin
        n_af = bcd_c1; n_cf = bcd_c1; f_we = 9'b0_0000_0101;
        sres = 1'b1; fssz = 2'd0;
      end
      E_SAHF: begin
        {n_sf, n_zf, n_af, n_pf, n_cf} = {A[15], A[14], A[12], A[10], A[8]};
        f_we = 9'b0_0001_1111;
      end
      E_POPF, E_IRET: begin
        {n_of, n_df, n_if, n_tf, n_sf, n_zf, n_af, n_pf, n_cf} =
          {B[11], B[10], B[9], B[8], B[7], B[6], B[4], B[2], B[0]};
        f_we = 9'h1FF;
        if (!if_ok) n_if = ifl;
      end
      E_TLFL: begin                                      // task switch: all flags from B
        {n_of, n_df, n_if, n_tf, n_sf, n_zf, n_af, n_pf, n_cf} =
          {B[11], B[10], B[9], B[8], B[7], B[6], B[4], B[2], B[0]};
        f_we = 9'h1FF;
      end
      E_LDV86: begin                                     // return to V86: all flags from B (T4)
        {n_of, n_df, n_if, n_tf, n_sf, n_zf, n_af, n_pf, n_cf} =
          {B[11], B[10], B[9], B[8], B[7], B[6], B[4], B[2], B[0]};
        f_we = 9'h1FF;
      end
      E_LDCS:
        if (ck == CK_CSI) begin                          // protected-mode IRET: flags from B (T4)
          {n_of, n_df, n_if, n_tf, n_sf, n_zf, n_af, n_pf, n_cf} =
            {B[11], B[10], B[9], B[8], B[7], B[6], B[4], B[2], B[0]};
          f_we = 9'h1FF;
          if (!if_ok) n_if = ifl;
        end else if (ck == CK_INTCS || ck == CK_INTI) begin   // interrupt entry: IF (interrupt gate), TF
          n_if = gtrap && ifl; n_tf = 1'b0; f_we = 9'b0_0110_0000;
        end
      E_INTFL: begin n_if = 1'b0; n_tf = 1'b0; f_we = 9'b0_0110_0000; end
      E_FLAGOP: begin
        case (op)
          8'hF5: begin n_cf = ~cf; f_we[0] = 1'b1; end
          8'hF8: begin n_cf = 1'b0; f_we[0] = 1'b1; end
          8'hF9: begin n_cf = 1'b1; f_we[0] = 1'b1; end
          8'hFA: begin n_if = 1'b0; f_we[6] = 1'b1; end
          8'hFB: begin n_if = 1'b1; f_we[6] = 1'b1; end
          8'hFC: begin n_df = 1'b0; f_we[7] = 1'b1; end
          default: begin n_df = 1'b1; f_we[7] = 1'b1; end
        endcase
      end
      E_MUL, E_IMUL2: begin n_cf = hi_ne; n_of = hi_ne; f_we = 9'b1_0000_0001; end
      E_LARV: begin n_zf = lv_ok; f_we = 9'b0_0000_1000; end
      E_ARPL: begin n_zf = arpl_c; f_we = 9'b0_0000_1000; end
      E_AAD, E_AAM: begin sres = 1'b1; fssz = 2'd0; end
      default: ;
    endcase
  end

  // POPF / IRET in protected mode: IOPL only at CPL 0, IF only at CPL <= IOPL
  // (V86: CPL is 3, IOPL never changes)
  wire iopl_ok = !cr0[0] || (!vm && (cpl == 2'd0));
  wire if_ok   = !cr0[0] || (cpl <= iopl);
  // (registered: one cycle behind its sources.  POPF can change IOPL only at CPL 0, where it
  //  does not change this; the other sources change through a refetch, the decoder (the
  //  user) sees the next instruction later)
  always_ff @(posedge clk) e_iochk <= cr0[0] && (vm || (cpl > iopl));
`ifdef SIM
  always_ff @(posedge clk) if (!rst && e_pgq != (cr0[31] && cr0[0])) $fatal(1, "exec: e_pgq differs from CR0.PG && PE");
`endif
  wire pfl_ld  = (eop == E_POPF) || (eop == E_IRET) || ((eop == E_LDCS) && (ck == CK_CSI)) || (eop == E_LDV86);

  // ================================================================ control
  function automatic logic jcc(input logic [3:0] c);
    logic r;
    case (c[3:1])
      3'd0: r = of;
      3'd1: r = cf;
      3'd2: r = zf_e;
      3'd3: r = cf | zf_e;
      3'd4: r = sf_e;
      3'd5: r = pf_e;
      3'd6: r = sf_e ^ of;
      default: r = zf_e | (sf_e ^ of);
    endcase
    return r ^ c[0];
  endfunction

  logic        done, start_mul, start_div, start_io;
  // multi-cycle class of the uop in E (one-hot, registered at capture): done is
  // then a compare of xs against the class's final state (short stall path)
  logic        c_mul, c_div, c_io, c_sh, c_b2, c_ck, c_jn;
  logic        c_mc;           // any of them
  logic        xc_nz;          // xc != 0
  // near indirect JMP / CALL / RET in protected mode whose target can be beyond the CS
  // limit (limit not FFFFFFFF; a 16-bit target only below FFFF): two E cycles, the
  // target / limit compare registered in the first (jn_q)
  // (real mode / V86: limit FFFF, so a 32-bit operand; the same rule as protected mode.
  // A real-mode / V86 far transfer (JFAR) with a 32-bit operand also takes two cycles:
  // jn_q is then its offset above FFFF.  Keeps load data out of the fault logic.)
  wire         jn_chk = (cs_lim != 32'hFFFF_FFFF) &&
                        (m_os32 || ((cs_lim[31:16] == 16'h0) && (cs_lim[15:0] != 16'hFFFF)));
  always_ff @(posedge clk)
    if (!hold_e) begin
      c_mul <= (m_eop == E_MUL) || (m_eop == E_AAD) || (m_eop == E_IMUL2);
      c_div <= (m_eop == E_DIV) || (m_eop == E_AAM);
      // (INVD / WBINVD: the I/O class, its sweep ends in X_IOD too)
      c_io  <= (m_eop == E_IN) || (m_eop == E_OUT) || (m_eop == E_CINV);
      c_sh  <= (((m_eop == E_SHIFT) && (m_op[1] || m_op[7:4] == 4'hC)) || (m_eop == E_SHXD)) && !ms_rdy;
      c_b2  <= (m_eop == E_DAA) || (m_eop == E_DAS) || (m_eop == E_AAA) || (m_eop == E_AAS) ||
               (m_eop == E_SRD) || (m_eop == E_TRD) || (m_eop == E_CPUID) ||
               (m_eop == E_BOUND) || (m_eop == E_BSF);
      c_ck  <= (m_eop == E_DLO) || (m_eop == E_DHI) || (m_eop == E_IOMAP) || (m_eop == E_IOBIT) || (m_eop == E_LARV) ||
               (m_eop == E_ARPL) || (m_eop == E_TSSOFF) || (m_eop == E_IRVM) || (m_eop == E_TLFL) || (m_eop == E_TSSDESC) ||
               (m_eop == E_IRNT) || (m_eop == E_LDTSK) || (m_eop == E_SEGVAL) || (m_eop == E_GATE) ||
               (m_eop == E_OLDSP) || (m_eop == E_PADDR) || (m_eop == E_LDSP) || (m_eop == E_EFL) ||
               (m_eop == E_TFLG) || (m_eop == E_TLDW) || ((m_eop == E_LDCS) && (m_uw[UW_CK_L +: UW_CK_W] == 5'(CK_TCS)));
      c_jn  <= ((m_eop == E_JNEAR) && jn_chk) || ((m_eop == E_JFAR) && m_os32 && (!cr0[0] || vm));
      c_mc  <= (m_eop == E_MUL) || (m_eop == E_AAD) || (m_eop == E_IMUL2) || (m_eop == E_DIV) || (m_eop == E_AAM) ||
               (m_eop == E_IN) || (m_eop == E_OUT) || (m_eop == E_CINV) ||
               ((((m_eop == E_SHIFT) && (m_op[1] || m_op[7:4] == 4'hC)) || (m_eop == E_SHXD)) && !ms_rdy) ||
               (m_eop == E_DAA) || (m_eop == E_DAS) || (m_eop == E_AAA) || (m_eop == E_AAS) ||
               (m_eop == E_SRD) || (m_eop == E_TRD) || (m_eop == E_CPUID) || (m_eop == E_BOUND) || (m_eop == E_BSF) ||
               (m_eop == E_DLO) || (m_eop == E_DHI) || (m_eop == E_IOMAP) || (m_eop == E_IOBIT) || (m_eop == E_LARV) ||
               (m_eop == E_ARPL) || (m_eop == E_TSSOFF) || (m_eop == E_IRVM) || (m_eop == E_TLFL) || (m_eop == E_TSSDESC) ||
               (m_eop == E_IRNT) || (m_eop == E_LDTSK) || (m_eop == E_SEGVAL) || (m_eop == E_GATE) ||
               (m_eop == E_OLDSP) || (m_eop == E_PADDR) || (m_eop == E_LDSP) || (m_eop == E_EFL) ||
               (m_eop == E_TFLG) || (m_eop == E_TLDW) || ((m_eop == E_LDCS) && (m_uw[UW_CK_L +: UW_CK_W] == 5'(CK_TCS))) ||
               ((m_eop == E_JNEAR) && jn_chk) || ((m_eop == E_JFAR) && m_os32 && (!cr0[0] || vm));
      xc_nz <= (m_xc != 3'd0);
    end
  always_comb begin
    done = xc_nz || !c_mc || xs[3];
    start_mul = 1'b0; start_div = 1'b0; start_io = 1'b0;
    case (eop)
      E_MUL, E_AAD, E_IMUL2: start_mul = (xs == X_IDLE);
      E_DIV, E_AAM: start_div = (xs == X_IDLE);
      E_IN, E_OUT:  start_io = (xs == X_IDLE);
      default: ;
    endcase
    if (xc != 3'd0) begin start_mul = 1'b0; start_div = 1'b0; start_io = 1'b0; end
  end

`ifdef SIM
  always_ff @(posedge clk)
    if (!rst && v && !xc_nz && c_mc && xs[3] &&
        !((c_mul && xs == X_MUL2) || (c_div && xs == X_DIVF) || (c_io && xs == X_IOD) || (c_sh && xs == X_SH2) ||
          (c_b2 && xs == X_B2) || (c_ck && xs == X_CK2) || (c_jn && xs == X_JN2)))
      $error("E: multi-cycle uop sees another class's final state %0d", xs);
`endif

  // branches / transfers
  wire        is_br    = (eop == E_JCC) || (eop == E_LOOPCC);
  wire        br_cond  = (eop == E_JCC) ? jcc(op[3:0]) : (cxnz && (zf_e == op[0]));
  // new EIP of an indirect / far transfer: 16 bits with a 16-bit operand size
  function automatic logic [31:0] ipz(input logic [31:0] x);
    return (sz == 2'd2) ? x : {16'h0, x[15:0]};
  endfunction
  wire [31:0] ip_a     = ipz(A);
  wire [31:0] ip_b     = ipz(B);
  wire [31:0] ip_t     = ipz(t0);
  wire        tgt_hit  = (ptgt == ip_a);
  // real mode / V86 far transfer: the predictor's target is the offset when CS stays,
  // else {selector, offset} (offsets fit 16 bits; selector 0 is not predicted)
  wire        fsame    = (A[15:0] == s[1]);
  wire [31:0] far_t    = fsame ? ip_b : {A[15:0], ip_b[15:0]};
  // (the predicted target against both forms in parallel with the CS compare)
  wire        fhit_n   = (ptgt == ip_b);
  wire        fhit_f   = (ptgt == {A[15:0], ip_b[15:0]});
  // (far CALL / JMP / RETF only: not the interrupt sequence's JFAR)
  wire        far_p    = (fsame || (A[15:0] != 16'h0)) && !pg &&
                         (op == 8'h9A || op == 8'hEA || op == 8'hCA || op == 8'hCB || op == 8'hFF);
  // Protected mode: a far JMP / CALL / RETF to the code segment already in CS (same
  // selector, the descriptor as last loaded: base, G, D, limit, type) changes nothing
  // the front end uses, so a predicted one needs no redirect.  The descriptor compare is
  // registered at the DHI uop (pfs); LDCS checks the predicted target against the new EIP.
  logic        csr_v, pfs;
  logic [58:0] csr_d;
  wire  [58:0] dhi_raw = {B[31:24], B[7:0], t1[31:16], B[23], B[22], B[19:16], t1[15:0], B[12:8]};
  wire  [58:0] ldcs_raw = {t3[31:24], t3[7:0], t1[31:16], t3[23], t3[22], t3[19:16], t1[15:0], t3[12:8]};
  always_ff @(posedge clk) if (complete && eop == E_DHI) pfs <= csr_v && (A[15:0] == s[1]) && (dhi_raw == csr_d);
  // (valid from a protected-mode CS load until CS is written any other way)
  always_ff @(posedge clk)
    if (rst) csr_v <= 1'b0;
    else if (complete && !fault_x && eop == E_LDCS) csr_v <= 1'b1;
    else if (complete && !fault_x && sw_en && sw_r == 3'd1) csr_v <= 1'b0;
  wire        pfar     = pfs && (abr_e == 3'(ABR_BRI)) && !pg &&
                         ((ck == CK_CSJ) || (ck == CK_CSC) || (ck == CK_CSR)) &&
                         (op == 8'h9A || op == 8'hEA || op == 8'hCA || op == 8'hCB || op == 8'hFF);
  wire        fhit_l   = (ptgt == ipz(t2));
  logic        redir, br_taken, brtrain;
  // (REPZ ended by the compare always flushes and refetches from ip_arch anyway,
  // a REP ended by CX reaches E as A's RETIRE marker with last set)
  wire         nbmisp = pt && (abr_e == 3'(ABR_NONE)) && !is_br && (eop != E_JNEAR) && last;
  logic [31:0] br_tgt;
  always_comb begin
    redir = 1'b0;
    br_taken = 1'b0; br_tgt = tgt; brtrain = 1'b0;
    case (eop)
      E_JCC, E_LOOPCC: begin
        br_taken = br_cond; brtrain = 1'b1;
        redir = pt ? (!br_cond || !tgteq) : br_cond;
      end
      E_JNEAR: begin
        br_taken = 1'b1; br_tgt = ip_a; brtrain = 1'b1;
        redir = !pt || !tgt_hit;
      end
      // real mode / V86 far transfer: one that keeps CS is a near transfer for the
      // predictor (BTB / return stack, trained as call / ret / jump); no redirect when it
      // was predicted
      E_JFAR: begin
        br_taken = 1'b1; br_tgt = far_t; brtrain = far_p;
        redir = !(far_p && pt && (fsame ? fhit_n : fhit_f));
      end
      E_IRET:  redir = 1'b1;
      E_LDCS: begin
        br_taken = 1'b1; br_tgt = ipz(t2); brtrain = pfar;
        redir = !(pfar && pt && fhit_l);
      end
      E_LDV86: redir = 1'b1;
      // LTR: serializing (A uses the TR base); LLDT: interlocked in A2
      E_DHI:  redir = (ck == CK_TSS);
      E_SWR, E_TWR, E_INVLPG, E_CINV: redir = 1'b1;      // serializing: refetch the next instruction
      default: ;
    endcase
    // backstop: an instruction that ends with a taken prediction but is not a
    // branch resolved here or in A (stale / aliased BTB entry on e.g. a REP
    // string instruction, which A cannot check): continue at the next IP and
    // drop the BTB entry
    if (nbmisp) redir = 1'b1;
  end
  wire         redir_nj = !is_br && redir;
  wire [15:0] sw_v = (eop == E_JFAR) ? A[15:0] : (eop == E_IRET) ? t1[15:0] : (eop == E_DHI) ? A[15:0] :
                     (eop == E_LDCS) ? {t0[15:2], ncpl} : (eop == E_SEGVAL || eop == E_SEGNUL) ? 16'h0 :
                     (eop == E_LDV86) ? t0[15:0] : Rn[15:0];

  // ================================================================ descriptor checks
  // (check order and error codes as 86Box x86seg.c / x86_ops_pmode.h)
  // DLO: selector in A: null and table limit.  DHI: selector A, high dword B, low dword
  // T1: type, privilege, present.  LDCS: the new EIP (T2) against the new CS limit.
  wire [15:0] dsel  = A[15:0];
  wire        dnull = (dsel[15:2] == 14'h0);
  wire        dti   = dsel[2];
  wire [15:0] dsec  = {dsel[15:2], 2'b00};          // error code: the selector's index and TI
  wire        d_ss  = (sreg == 3'd2);
  wire [31:0] dtl   = dti ? ldt_lim : {16'h0, gdtl};
  wire        dover = ({16'h0, dsel[15:3], 3'b111} > dtl);
  wire [1:0]  ddpl  = B[14:13];
  wire        dpr   = B[15];
  wire        dsy   = !B[12];                       // system descriptor
  wire [3:0]  dty   = B[11:8];
  wire [1:0]  drpl  = dsel[1:0];
  // the code segment of a far transfer's DHI (high dword B, low dword T1) and its new EIP
  wire        dxfer  = (ck == CK_CSJ) || (ck == CK_CSC) || (ck == CK_CGJ) || (ck == CK_CGC) ||
                       (ck == CK_CSR) || (ck == CK_CSI) || (ck == CK_INTCS);
  wire [19:0] dlim20 = {B[19:16], t1[15:0]};
  wire [31:0] dlim   = B[23] ? {dlim20, 12'hFFF} : {12'h0, dlim20};
  wire [31:0] deip   = os32 ? t2 : {16'h0, t2[15:0]};
  // the new code segment of LDCS (descriptor in T1 / T3)
  wire [19:0] nlim20 = {t3[19:16], t1[15:0]};
  wire [31:0] nlim   = t3[23] ? {nlim20, 12'hFFF} : {12'h0, nlim20};
  // error codes of a delivery carry the EXT bit (not a software INT)
  wire        dext  = inj && !x_soft;
  wire [15:0] gerr  = {5'h0, imm[7:0], 3'b010};       // IDT gate: vector * 8 + 2
  wire [1:0]  tdpl  = t3[14:13];                      // DPL of the code segment in T3 (stack switch)
  wire        dnc   = dty[3] && !dty[2];              // non-conforming code
  wire        dcf   = dty[3] && dty[2];               // conforming code
  wire        dcg   = dsy && (dty[2:0] == 3'b100);    // call gate (16 / 32 bit)
  // SS:ESP slot of the target privilege level in the TSS (A: the code segment's high dword)
  wire [31:0] tss_off = tr_acc[3] ? {27'd0, A[14:13], 3'b100} : {28'd0, A[14:13], 2'b10};
  wire [31:0] tss_end = tss_off + (tr_acc[3] ? 32'd7 : 32'd3);
  assign      tsk_eip = t3[11] ? t2 : {16'h0, tx[3][15:0]};
  // (raw: from the operands; registered in the uop's first cycle, used in its second)
  logic       d_f_r, d_e0_r, d_eg_r, d_et_r;   // fault; error code 0 / the gate's / TR's (else the selector)
  logic [7:0] d_v_r;
  logic [4:0] uj_k_r;          // micro-jump (valid without a fault)
  logic       uj_c_r;
  always_comb begin
    d_f_r = 1'b0; d_v_r = 8'd13; d_e0_r = 1'b0; d_eg_r = 1'b0; d_et_r = 1'b0; uj_c_r = 1'b0; uj_k_r = 5'd0;
    case (eop)
      E_DLO:
        case (ck)
          CK_SEG:  if (dnull) begin d_f_r = d_ss; d_e0_r = 1'b1; end else d_f_r = dover;
          CK_LDT:  d_f_r = !dnull && (dti || dover);
          CK_TSS:  if (dnull) begin d_f_r = 1'b1; d_e0_r = 1'b1; end else d_f_r = dti || dover;
          CK_INTG: begin d_f_r = ({5'h0, imm[7:0], 3'b111} > idtl); d_eg_r = 1'b1; end
          CK_INTCS: d_f_r = dover;
          CK_NSS:  begin d_v_r = 8'd10; if (dnull) begin d_f_r = 1'b1; d_e0_r = 1'b1; end else d_f_r = dover; end
          CK_TTSS: begin d_v_r = (tsk_op == 2'd0) ? 8'd13 : 8'd10; d_f_r = dnull || dti || dover; end
          CK_TLDT: begin d_v_r = 8'd10; d_f_r = !dnull && (dti || dover); end
          CK_TCS, CK_TSSS: begin d_v_r = 8'd10; d_f_r = dnull || dover; end
          CK_TDS:  begin d_v_r = 8'd10; d_f_r = !dnull && dover; end
          CK_ACC:  ;
          CK_CSR:  if (drpl < cpl) d_f_r = 1'b1; else if (dnull) begin d_f_r = 1'b1; d_e0_r = 1'b1; end else d_f_r = dover;
          CK_CSI:  if (dnull) begin d_f_r = 1'b1; d_e0_r = 1'b1; end else d_f_r = dover || (drpl < cpl);
          default: if (dnull) begin d_f_r = 1'b1; d_e0_r = 1'b1; end else d_f_r = dover;     // CS, RSS
        endcase
      E_DHI:
        case (ck)
          CK_SEG:
            if (d_ss) begin
              if ((drpl != cpl) || (ddpl != cpl) || dsy || dty[3] || !dty[1]) d_f_r = 1'b1;
              else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd12; end
            end else if (!dnull) begin
              // data or readable code; data and non-conforming code: max(RPL, CPL) <= DPL
              if (dsy || (dty[3] && !dty[1])) d_f_r = 1'b1;
              else if ((!dty[3] || !dty[2]) && ((drpl > ddpl) || (cpl > ddpl))) d_f_r = 1'b1;
              else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
            end
          CK_NSS: begin                                  // inner stack from the TSS
            d_v_r = 8'd10;
            if ((drpl != tdpl) || (ddpl != tdpl) || dsy || dty[3] || !dty[1]) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd12; end
          end
          CK_RSS:                                        // outer stack of RET / IRET (RPL of the new CS in T6)
            if ((drpl != tx[2][1:0]) || dsy || dty[3] || !dty[1] || (ddpl != tx[2][1:0])) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd12; end
          CK_LDT:
            if (!dnull) begin
              if (!dsy || (dty != 4'h2)) d_f_r = 1'b1;
              else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
            end
          CK_TSS:
            if (!dsy || dty[2] || !dty[0]) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
            else if (dty[1]) d_f_r = 1'b1;                 // busy
          CK_INTG: begin                                 // interrupt / trap / task gate
            d_eg_r = 1'b1;
            if (!dsy || !((dty[2:1] == 2'b11) || (dty == 4'h5)) || (x_soft && (ddpl < cpl))) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
            else begin uj_c_r = 1'b1; uj_k_r = (dty == 4'h5) ? 5'(INJ_TASKI) : 5'(INJ_INTF); end
          end
          CK_INTCS:
            // data (expand-up) as non-conforming code (real CPUs allow it, MS CodeView uses it);
            // conforming code keeps CPL; a more privileged non-conforming segment: stack switch
            // (from V86 only to DPL 0)
            if ((ddpl > cpl) || dsy || (!dty[3] && dty[2]) || (dcf && vm)) d_f_r = 1'b1;
            else if (!dty[2] && (ddpl < cpl)) begin
              if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
              else if (vm && (ddpl != 2'd0)) d_f_r = 1'b1;
              // (from V86 through a 16-bit gate too: GS FS DS ES pushed as words, 80386
              // microcode PUSH_V86_SREGS / SDM; 86Box pushed none)
              else begin uj_c_r = 1'b1; uj_k_r = vm ? 5'(INJ_INTV) : 5'(INJ_INTI); end
            end else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
            else if (vm) d_f_r = 1'b1;
          CK_ACC, CK_TBSY, CK_TFRE: ;
          CK_TTSS: begin                                 // target TSS: available (IRET: busy) 386 / 286 TSS
            d_v_r = (tsk_op == 2'd0) ? 8'd13 : 8'd10;
            if (!dsy || (dty[2] != 1'b0) || !dty[0] || (dty[1] != (tsk_op == 2'd3))) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
            else begin uj_c_r = 1'b1; uj_k_r = tr_acc[3] ? 5'(INJ_TSWS32) : 5'(INJ_TSWS16); end
          end
          CK_TLDT: begin
            d_v_r = 8'd10;
            if (!dnull && (!dsy || (dty != 4'h2) || !dpr)) d_f_r = 1'b1;
          end
          CK_TCS: begin                                  // the new task's code segment (CPL = its RPL)
            d_v_r = 8'd10;
            if (dsy || !dty[3] || (dty[2] ? (ddpl > cpl) : (ddpl != cpl))) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
          end
          CK_TSSS: begin
            d_v_r = 8'd10;
            if (dsy || dty[3] || !dty[1] || (ddpl != cpl) || (ddpl != drpl)) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd12; end
          end
          CK_TDS:
            if (!dnull) begin
              d_v_r = 8'd10;
              if (dsy || (dty[3] && !dty[1])) d_f_r = 1'b1;
              else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
              else if (!(dty[3] && dty[2]) && ((ddpl < cpl) || (ddpl < drpl))) d_f_r = 1'b1;
            end
          CK_CGJ, CK_CGC:                                // a call gate's code segment
            if ((ddpl > cpl) || dsy || !dty[3] || (ck == CK_CGJ && dnc && (ddpl < cpl))) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
            else if (dnc && (ddpl < cpl)) begin uj_c_r = 1'b1; uj_k_r = 5'(INJ_CALLGI); end
          CK_CSR:                                        // non-conforming: RPL = DPL, conforming: RPL >= DPL
            if (dsy || !dty[3] || (dnc && (drpl != ddpl)) || (dcf && (ddpl > drpl))) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
            else if (drpl > cpl) begin uj_c_r = 1'b1; uj_k_r = 5'(INJ_RETO); end
          CK_CSI:                                        // data (expand-up) as non-conforming code
            if (dsy || (!dty[3] && dty[2]) || (!dty[2] && (drpl != ddpl)) || (dcf && (drpl < ddpl))) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
            else if (drpl > cpl) begin uj_c_r = 1'b1; uj_k_r = 5'(INJ_IRETO); end
          default:                                       // far JMP / CALL target
            if (dsy) begin
              if (dcg) begin                             // call gate
                if ((ddpl < cpl) || (ddpl < drpl)) d_f_r = 1'b1;
                else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
                else begin uj_c_r = 1'b1; uj_k_r = (ck == CK_CSC) ? 5'(INJ_CALLG) : 5'(INJ_JMPG); end
              end else if ((dty == 4'h5) || ((dty[2:0] == 3'b001))) begin   // task gate, TSS: task switch
                d_v_r = (ck == CK_CSC) ? 8'd10 : 8'd13;
                if ((ddpl < cpl) || (ddpl < drpl)) d_f_r = 1'b1;
                else if ((dty != 4'h5) && (dti || dty[1])) d_f_r = 1'b1;     // TSS: in the GDT, available
                else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
                else begin
                  uj_c_r = 1'b1;
                  uj_k_r = (dty == 4'h5) ? 5'(INJ_TASKG) : tr_acc[3] ? 5'(INJ_TSWS32) : 5'(INJ_TSWS16);
                end
              end else d_f_r = 1'b1;
            end else if (!dty[3]) d_f_r = 1'b1;
            else if (!dty[2] && ((drpl > cpl) || (cpl != ddpl))) d_f_r = 1'b1;
            else if (dty[2] && (ddpl > cpl)) d_f_r = 1'b1;
            else if (!dpr) begin d_f_r = 1'b1; d_v_r = 8'd11; end
        endcase
      E_TSSOFF: if (tss_end > tr_lim) begin d_f_r = 1'b1; d_v_r = 8'd10; d_et_r = 1'b1; end
      E_IRNT: if (nt) begin uj_c_r = 1'b1; uj_k_r = 5'(INJ_IRETT); end
      E_TSSDESC: if (nlim < (t3[11] ? 32'd103 : 32'd43)) begin d_f_r = 1'b1; d_v_r = 8'd10; end
      E_LDTSK: begin uj_c_r = 1'b1; uj_k_r = t3[11] ? 5'(INJ_TSWL32) : 5'(INJ_TSWL16); end
      E_TLFL: if ((sz == 2'd2) && B[17] && !vm) begin uj_c_r = 1'b1; uj_k_r = 5'(INJ_TSWV86); end
      E_LDCS: if ((ck == CK_TCS) && (ipz(t2) > nlim)) begin d_f_r = 1'b1; d_e0_r = 1'b1; d_v_r = (tsk_op == 2'd1) ? 8'd10 : 8'd13; end
      // IRETD at CPL 0 with VM in the popped EFLAGS: return to V86
      E_IRVM: if (cr0[0] && !vm && (cpl == 2'd0) && os32 && B[17]) begin uj_c_r = 1'b1; uj_k_r = 5'(INJ_IRETV); end
      default: ;
    endcase
  end
  // a far transfer's new EIP (T2) beyond the limit of the code segment just checked:
  // #GP(0) (EXT during a delivery), before the stack switch / pushes / CS load; the
  // lowest-priority check of the DHI uop (registered on its own, merged in the 2nd cycle)
  wire eipx_r = (eop == E_DHI) && dxfer && !dsy && (deip > dlim);
  // descriptor low dword of DHI (T5 for the stack of a privilege change)
  wire [31:0] dlo_v = (eop == E_DHI && (ck == CK_NSS || ck == CK_RSS || ck == CK_TSSS || ck == CK_TDS)) ? tx[1] : t1;
  // CPL after LDCS: inner CALL / interrupt: the segment's DPL; RET / IRET: the selector's RPL
  wire [1:0]  ncpl  = ((ck == CK_CGI) || (ck == CK_INTI)) ? t3[14:13] :
                      ((ck == CK_CSR) || (ck == CK_CSI) || (ck == CK_TCS)) ? t0[1:0] : cpl;
  // new (E)SP of LDSP: B + A (the ALU's sum; A: imm16 of RET n, else zero)
  wire [31:0] spn   = ar[34:3];
  // SEGVAL: data segment register srf still valid at the new CPL (RPL of the CS in T6)
  wire [15:0] sv_sel = s[srf];
  wire [7:0]  sv_acc = a_sacc[srf*8 +: 8];
  wire [1:0]  sv_cpl = tx[2][1:0];
  // (a null selector with RPL > 0 is nulled too, as 86Box and Bochs do: its hidden access byte
  // is not a descriptor's)
  wire        sv_ok_r = (sv_sel[15:2] != 14'h0) &&
                       ({16'h0, sv_sel[15:3], 3'b111} <= (sv_sel[2] ? ldt_lim : {16'h0, gdtl})) &&
                       sv_acc[4] && (!sv_acc[3] || sv_acc[1]) &&                       // data / readable code
                       ((sv_acc[3] && sv_acc[2]) ||                                    // conforming
                        ((sv_sel[1:0] <= sv_acc[6:5]) && (sv_cpl <= sv_acc[6:5])));
  // results of the protected-mode uops (registered in their first cycle)
  logic [31:0] x0p_r, x0p;
  always_comb begin
    x0p_r = '0;
    case (eop)
      // the descriptor's access byte with the accessed (TSS: busy) bit set
      E_DHI:   x0p_r = (ck == CK_INTG) ? (B[11] ? {B[31:16], t1[15:0]} : {16'h0, t1[15:0]}) :   // gate: the new EIP
                    (ck == CK_TFRE) ? {24'h0, B[15:8] & 8'hFD} :                              // busy bit
                    {24'h0, B[15:8] | (((ck == CK_TSS) || (ck == CK_TBSY)) ? 8'h02 : 8'h01)};
      E_EFL:   x0p_r = {10'h0, idf, 2'b0, ac, vm, rf, fimg};
      E_GATE:  x0p_r = B[11] ? {B[31:16], A[15:0]} : {16'h0, A[15:0]};          // call gate: target EIP
      E_TSSOFF: x0p_r = tss_off;
      E_OLDSP: x0p_r = ss_b ? gm[4] : {16'h0, gm[4][15:0]};
      E_PADDR: x0p_r = a_ssbase + (ss_b ? gm[4] : {16'h0, gm[4][15:0]}) + ({27'd0, gcnt} << (os32 ? 2 : 1));
      E_LDSP:  x0p_r = ss_b ? spn : {gm[4][31:16], spn[15:0]};
      E_IOMAP: x0p_r = {16'h0, B[15:0]} + {19'h0, A[15:3]};
      E_LARV:  x0p_r = (ck == CK_LSL) ? (B[23] ? {B[19:16], t1[15:0], 12'hFFF} : {12'h0, B[19:16], t1[15:0]}) :
                    (sz == 2'd2) ? {8'h0, B[23:8], 8'h0} : {16'h0, B[15:8], 8'h0};
      E_ARPL:  x0p_r = arpl_c_r ? {16'h0, A[15:2], B[1:0]} : {16'h0, A[15:0]};
      E_TSSDESC: x0p_r = {t3[31:24], t3[7:0], t1[31:16]};
      E_TFLG:  x0p_r = {10'h0, idf, 2'b0, ac, vm, rf, (tsk_op == 2'd3) ? {1'b0, 1'b0, fimg[13:0]} : fimg};
      E_TLDW:  x0p_r = {16'hFFFF, B[15:0]};
      E_LDTSK: x0p_r = tsk_eip;
      default: ;
    endcase
  end
  // descriptor-check uops take two E cycles: the checks (from the operands) are registered
  // in the first, the uop commits in the second (keeps the operands off the commit enables)
  // (only valid for those uops: the flags are qualified with their class)
  logic       d_f_q, uj_c_q, io_flt_q, sup_d_q, eipx_q, jn_q;
  logic       d_e0, d_eg, d_et, lv_ok, arpl_c, uj_b11, dcg_q, sv_ok;
  logic [7:0] d_v;
  logic [4:0] uj_k;
  always_ff @(posedge clk)
    if (xs == X_IDLE) begin
      d_f_q <= d_f_r; d_e0 <= d_e0_r; d_eg <= d_eg_r; d_et <= d_et_r; d_v <= d_v_r;
      uj_c_q <= uj_c_r; uj_k <= uj_k_r; lv_ok <= lv_ok_r; arpl_c <= arpl_c_r; io_flt_q <= io_flt_r;
      sup_d_q <= sup_d_r; uj_b11 <= B[11]; dcg_q <= dcg; sv_ok <= sv_ok_r; x0p <= x0p_r; eipx_q <= eipx_r;
      jn_q <= (eop == E_JFAR) ? (B[31:16] != 16'h0) : (ip_a > cs_lim);
    end
  wire d_f    = c_ck && (d_f_q || eipx_q);
  wire d_fx   = !d_f_q && eipx_q;          // (the EIP check alone: #GP(0))
  wire uj_c   = c_ck && uj_c_q && !eipx_q;
  wire io_flt = c_ck && io_flt_q;
  wire sup_d  = c_ck && sup_d_q;
  // the accessed bit is set only if clear (a 486 skips the locked write otherwise)
  // (skipped also when the uop micro-jumps: the routine sets it in 86Box's order)
  // st_sup: no store at all (from registers); sup_d: the store keeps its W slot (store to
  // load forwarding: its data equals memory) but writes nothing (from the operands)
  wire st_sup  = (eop == E_PROBE) ||                                              // (write check only)
                 ((eop == E_DHI) && (ck == CK_TBSY) && (tsk_op == 2'd3)) ||       // (IRET: target already busy)
                 ((eop == E_DHI) && (ck == CK_TFRE) && tsk_lnk) ||                // (CALL / INT: old stays busy)
                 ((eop == E_TLNK) && !tsk_lnk);
  wire sup_d_r = ((eop == E_DHI) && (((ck != CK_TSS) && (ck != CK_TBSY) && (ck != CK_TFRE) && (dnull || B[8])) || uj_c_r)) ||
                 ((eop == E_ARPL) && !arpl_c_r);
  // ARPL: the destination's RPL raised;  LAR / LSL / VERR / VERW: valid descriptor
  wire arpl_c_r = (A[1:0] < B[1:0]);
  // system descriptor types LAR / LSL accept (bit per type)
  localparam logic [15:0] LAR_TY = 16'h1A3E, LSL_TY = 16'h0A0E;
  logic lv_ok_r;
  always_comb begin
    logic nc;
    nc = !(dty[3] && dty[2]) || dsy;                     // not a conforming code segment
    lv_ok_r = !dnull && !dover;
    case (ck)
      CK_LAR:  if (dsy && !LAR_TY[dty]) lv_ok_r = 1'b0;
      CK_LSL:  if (dsy && !LSL_TY[dty]) lv_ok_r = 1'b0;
      CK_VERR: if (dsy || (dty[3] && !dty[1])) lv_ok_r = 1'b0;
      default: if (dsy || dty[3] || !dty[1]) lv_ok_r = 1'b0;     // VERW
    endcase
    if (((ck == CK_VERW) || nc) && ((ddpl < cpl) || (ddpl < drpl))) lv_ok_r = 1'b0;
  end
  // LAR / LSL / ARPL write their register only if valid / changed
  wire gpr_sup = ((eop == E_LARV) && !lv_ok) || ((eop == E_ARPL) && !arpl_c);
  // I/O permission bitmap (IOBIT: port A, map word B at TSS offset T0)
  wire [2:0]  io_n   = !op[0] ? 3'd1 : os32 ? 3'd4 : 3'd2;
  wire [10:0] io_m   = 11'(((8'd1 << io_n) - 8'd1)) << A[2:0];
  wire        io_two = |io_m[10:8];
  wire        io_flt_r = ((eop == E_IOMAP) && !tr_acc[3] && (cpl > iopl)) ||
                       ((eop == E_IOBIT) && tr_acc[3] &&
                        ((io_two ? (t0 >= tr_lim) : (t0 > tr_lim)) || |(io_m & {B[10:8] & {3{io_two}}, B[7:0]})));
  // CPL 0 instructions: #GP(0) at CPL > 0 and in V86
  // (the static checks alone: the uop does no memory access then, nothing is translated)
  wire chk_flt  = ((chk == CHK_CPL0) && ((cr0[0] && (cpl != 2'd0)) || vm)) ||
                  ((chk == CHK_IOPL) && cr0[0] && (cpl > iopl)) ||
                  ((chk == CHK_V86IOPL) && vm && (iopl != 2'd3));
  wire cpl0_flt = chk_flt || io_flt;
  // alignment check (#AC(0)): CR0.AM, EFLAGS.AC, CPL 3 (V86 too), not an implicit supervisor
  // access; before the access is translated: primary (the load) first, the store after the
  // load's translation and the store's segment check (as 86Box's readmem / writemem order)
  wire acchk    = cr0[18] && ac && (cpl == 2'd3) && !sv_q;
  wire acp      = acchk && amis[0];
  wire acs      = acchk && amis[1];
  // debug: an instruction breakpoint (fault before the instruction, RF clear, not during an
  // exception delivery), MOV DRn with DR7.GD (fault, DR6.BD)
  // (not on the instruction after MOV / POP SS: 86Box runs the pair as one, as the 486
  // holds debug exceptions over it)
  wire  ibf    = ifst && !inj && !rf && !ssp_q && ibh;
  wire  gdflt  = gdq;
  wire  tstop  = chk_flt || acp || ibf;
  // IN / OUT / INS / OUTS: a fault found before the port access (#PF or #AC of the memory
  // operand, instruction breakpoint)
  wire  io_stop = pf_q || tstop || acs;
  // INVD / WBINVD (CPL 0): once the store buffer has drained, request the sweep
  logic cf_1st;
  wire  cf_go = act && (eop == E_CINV) && (xs == X_IDLE) && io_ok && !chk_flt && !hold_w;
  always_ff @(posedge clk) begin
    e_cinv <= !rst && cf_go;
    e_cwb  <= op[0];
  end

  // exceptions raised by the uop itself
  wire derr    = (eop == E_DIV || eop == E_AAM) && derr_pre;
  wire xflt    = (xc != 3'd0);
  // BOUND: the first uop (low bound) only records its compare; the second (high bound)
  // raises #BR for either, after both loads (its own limit fault comes first: #SS / #GP
  // of the high dword before #BR, as the 486 / 86Box)
  logic bnd_lo_q;
  always_ff @(posedge clk) if (complete && (eop == E_BOUND) && !last) bnd_lo_q <= bnd_lt;
  wire brflt   = (eop == E_BOUND) && last && (bnd_lt || bnd_lo_q);   // (valid in the uop's second cycle)
  // a transfer to an EIP beyond the code segment limit (real mode: FFFF) is a #GP
  // of the transferring instruction
  // (ipflt_b: a taken Jcc / LOOPcc, which depends on the flags; such a uop writes no
  // segment, temporary, flag or memory, so those commit on fault_x)
  // (JFAR / IRET here are the real-mode / V86 forms: the new CS limit is FFFF)
  // (an indirect near target: protected mode against the CS limit, real mode / V86 (limit
  // FFFF) only with a 32-bit operand)
  wire rmv     = !cr0[0] || vm;
  // (protected mode: the compare is registered in the uop's first cycle, c_jn below)
  wire jn_bad  = c_jn && jn_q;
  wire ipflt_x = (tbad && ataken) || ((eop == E_JNEAR) && jn_bad) ||
                 ((eop == E_JFAR) && c_jn && jn_q) ||
                 (rmv && (sz == 2'd2) && (eop == E_IRET) && (t0[31:16] != 16'h0));
  wire ipflt_b = tbad && is_br && br_cond;
  // MOV CR0 with PG and not PE, or NW and not CD: #GP;  ESC with CR0.EM / TS, WAIT with MP and TS: #NM
  wire crflt   = (eop == E_SWR) && (srf == 3'd7) && (modrm[5:3] == 3'd0) &&
                 ((B[31] && !B[0]) || (B[29] && !B[30]));
  wire nmflt   = (eop == E_ESC) && ((op == 8'h9B) ? (cr0[1] && cr0[3]) : (cr0[2] || cr0[3]));
  // (crflt depends on the operand: it only blocks the CR0 write, the SWR uop writes nothing else)
  // MOV TR0-2: #UD (the i486 has TR3-TR7)
  wire trflt   = ((eop == E_TRD) || (eop == E_TWR)) && op[2] && (modrm[5:3] < 3'd3) ||
                 ((eop == E_CPUID) && !HAS_CPUID);
  wire fault_x = ibf || gdflt || xflt || acp || acs || pf_q || (eop == E_UD) || trflt || derr || brflt || ipflt_x || nmflt || cpl0_flt || d_f;
  wire fault   = fault_x || ipflt_b || crflt;                          // restart at the instruction's first byte
  // (do_inj_a: the same without the #GP of a taken Jcc's target beyond the limit (ipflt_b,
  // from the lazy flags: the latest term), which the delivery registers take at their last
  // mux (vector 13, error code 0); a Jcc is never part of a delivery, nor an INT)
  wire fault_a  = fault_x || crflt;
  wire do_inj_a = ((eop == E_INT) || ((eop == E_INTO) && of) || fault_a) && !triple;
  wire do_inj   = do_inj_a || ipflt_b;
  // vector and error code (in priority order)
  logic [7:0]  inj_vec, inj_vec0;
  logic [15:0] inj_err, inj_err0;
  // a fault while delivering an exception (SDM "Interrupt 8"): #DF after a contributory
  // exception (#DE #TS #NP #SS #GP) unless the new one is a #PF, and after a #PF; a benign
  // first exception: the new one is delivered on its own; while delivering #DF: shutdown
  logic        x_exc, x_df;
  logic [7:0]  x_vec;
  // (f_pf: the new fault is a #PF; no source before paging)
  wire  f_pf   = pf_q;
  wire  x_ctb  = (x_vec == 8'd0) || ((x_vec >= 8'd10) && (x_vec <= 8'd13));
  wire  dflt2  = fault_a && inj && x_exc && !x_df && ((x_ctb && !f_pf) || (x_vec == 8'd14));
  wire  triple = fault_a && inj && x_exc && x_df;
  assign inj_vec = dflt2 ? 8'd8 : inj_vec0;
  assign inj_err = dflt2 ? 16'h0 : inj_err0;
  always_comb begin
    inj_err0 = 16'h0;
    if (ibf)                  inj_vec0 = 8'd1;
    else if (xflt && !xs_q)   inj_vec0 = (xc == 3'd1) ? 8'd6 : (xc == 3'd3) ? 8'd12 : 8'd13;
    else if (acp)             inj_vec0 = 8'd17;
    else if (xflt && !pf_q)   inj_vec0 = (xc == 3'd3) ? 8'd12 : 8'd13;          // the store's
    else if (pf_q)            begin inj_vec0 = 8'd14; inj_err0 = {13'h0, pf_err}; end
    else if (acs)             inj_vec0 = 8'd17;
    else if (eop == E_UD || trflt) inj_vec0 = 8'd6;
    else if (cpl0_flt)        inj_vec0 = 8'd13;
    else if (gdflt)           inj_vec0 = 8'd1;
    else if (d_f)             begin
      inj_vec0 = d_fx ? 8'd13 : d_v;
      inj_err0 = (d_fx ? 16'h0 : d_eg ? gerr : d_et ? {tr_sel[15:2], 2'b00} : d_e0 ? 16'h0 : dsec) | {15'h0, dext};
    end
    else if (ipflt_x || crflt) inj_vec0 = 8'd13;              // (ipflt_b: at the use)
    else if (nmflt)           inj_vec0 = 8'd7;
    else if (eop == E_BOUND)  inj_vec0 = 8'd5;
    else if (eop == E_INT)    inj_vec0 = (op == 8'hCC) ? 8'd3 : imm[7:0];
    else if (eop == E_INTO)   inj_vec0 = 8'd4;
    else                      inj_vec0 = 8'd0;                  // #DE
    
  end
  // exceptions with an error code (protected mode): #DF, #TS, #NP, #SS, #GP, #PF, #AC
  // (from the vector before the #DF substitution: #DF pushes one too)
  // (the same from the fault terms in priority order, with the branch-condition term last:
  // only a #GP of a branch target follows the others that take an error code)
  logic ec_hi, any_hi;
  always_comb begin
    any_hi = 1'b1; ec_hi = 1'b0;
    if (ibf)                       ec_hi = 1'b0;
    else if (xflt && !xs_q)        ec_hi = (xc != 3'd1);
    else if (acp || (xflt && !pf_q) || pf_q || acs) ec_hi = 1'b1;
    else if (eop == E_UD || trflt) ec_hi = 1'b0;
    else if (cpl0_flt)             ec_hi = 1'b1;
    else if (gdflt)                ec_hi = 1'b0;
    else if (d_f)                  ec_hi = d_fx || ((d_v >= 8'd10) && (d_v <= 8'd14)) || (d_v == 8'd17);
    else                           any_hi = 1'b0;
  end
  wire inj_ecv = dflt2 || (any_hi ? ec_hi : (ipflt_x || crflt));      // (with do_inj_a)
  wire do_halt = ((eop == E_HLT) && !fault) || triple;     // (HLT at CPL > 0: #GP, no halt)
  // E micro-jump (descriptor checks above): an IDT / call gate continues with the
  // sequence of its size (operand size = the gate's), a privilege change with the
  // stack switch
  wire        uj_take = complete && !fault_x && uj_c;     // (a micro-jumping uop is no Jcc / MOV CR0)
  wire [4:0]  uj_id   = uj_k;
  // (into a new task: its TSS size, for the error code push)
  // (dcg_q reads B as a descriptor: only a DHI's B is one; an IRET's EFLAGS can look like a call gate)
  wire        uj_os32 = (eop == E_LDTSK) ? t3[11] : ((ck == CK_INTG) || (dcg_q && (eop == E_DHI))) ? uj_b11 : os32;
  // interrupt / exception entry by mode
  wire [4:0]  int_id  = (cr0[0] || vm) ? 5'(INJ_INT_PM) : 5'(INJ_INT_RM);
  // CALL r/m (pushes), far CALL (9A, FF /3; not the interrupt sequence's JFAR); near RET, RETF
  wire is_call = ((eop == E_JNEAR) && (wrk == WR_SEC)) ||
                 ((eop == E_JFAR) && (wrk == WR_SEC) && !pg && (op == 8'h9A || op == 8'hFF)) ||
                 ((eop == E_LDCS) && (wrk == WR_SEC) && pfar && (op == 8'h9A || op == 8'hFF));
  // (a far CALL that changes CS: its return address is {this CS, offset})
  wire fcall_x = (eop == E_JFAR) && !fsame;
  wire is_ret  = ((eop == E_JNEAR) && !pg && (op == 8'hC2 || op == 8'hC3)) ||
                 ((eop == E_JFAR) && !pg && (op == 8'hCA || op == 8'hCB)) ||
                 ((eop == E_LDCS) && pfar && (op == 8'hCA || op == 8'hCB));
  wire repz_end = repz && rep[1] && (az != rep[0]) && cxnz;   // ZF of the compare

  // interrupts
  logic nmi_q, nmi_pend, nmi_blk;
  // (a REP iteration that counted (E)CX down to 0 is no boundary: the RETIRE marker behind it
  // ends the instruction, with its traps and interrupts)
  wire boundary  = last || (bnd && cxnz);
  // the end of an instruction (REP iteration): not a micro-jump (the sequence's last uop
  // that continues the same instruction elsewhere in the ROM)
  wire iend      = boundary && !uj_c;
  wire ret_here  = bnd && !last;           // REP iteration interrupted: restart insn
  // MOV / POP SS (not LSS) and STI hold off interrupts for one instruction, MOV / POP SS the
  // debug traps too
  wire inh_ss    = sw_en && sw_r == 3'd2 && !pg && eop != E_JFAR && eop != E_IRET;
  wire sets_inh  = inh_ss || ((eop == E_FLAGOP) && (op == 8'hFB) && !ifl);
  // (NMI is blocked from its delivery up to the next IRET, which itself ends unblocked: a
  // pending NMI is taken right after it)
  wire iret_end  = last && !pg && (op == 8'hCF);
  wire take_nmi  = nmi_pend && (!nmi_blk || iret_end);
  // (out of HLT; shutdown is left by NMI in any case)
  wire nmi_go    = nmi_pend && (!nmi_blk || shutdown);
  wire take_intr = intr && n_if;
  // data breakpoints: the matches of the instruction's accesses (a store that is really
  // made), collected up to its end (a REP iteration's end; held over the instruction after
  // MOV SS with its trap); DR6.B set for every match once any breakpoint is enabled,
  // a trap after the instruction for an enabled one (also after an interrupt / exception
  // delivery, not after that of #DB itself).
  // (the rest of the store gating from registers: sup_d, a shift by 0 (shb: shifts only))
  wire        st_real = !sup_d && !(shb && sh_z);
  logic [3:0] dbacc;
  wire  [3:0] db_cur  = !dbdel ? (dbr | (st_real ? dbw : 4'h0)) : 4'h0;
  wire  [3:0] dbacc_n = dbacc | db_cur;
  wire        take_dbt = !dbdel && (|(dbacc & db_en) || dbtr || (dbtw && st_real));
  // the T bit of a new 386 TSS: a trap after the task switch (any cause)
  logic       tsk_tb;
  // (data breakpoints and the T bit also at the end of an interrupt / exception delivery:
  // before the handler's first instruction)
  logic        first;          // the uop in E is the first of its instruction / iteration
  logic        tswl;           // the state of a new task is being loaded (TSWL)
  // (single step: TF as the instruction started; a task switch loads the new task's TF
  // before its last uop, and that TF traps after the new task's first instruction)
  logic tf_st;
  wire  tf_start  = (first && !tswl) ? tf : tf_st;
  always_ff @(posedge clk) if (complete && first && !tswl) tf_st <= tf;
  wire take_trap = (tf_start && !inj) || take_dbt || tsk_tb;
  wire want_int  = iend && ((!sets_inh && (take_nmi || take_intr)) || (!inh_ss && take_trap));

  // ================================================================ commit
  assign hold_e = hold_w || (act && (!done || ldwait || fsel_any || tblock)) || (xs == X_INTA);
  wire complete = act && done && !ldwait && !fsel_any && !hold_w && !tblock;
  // load data is final in mdat: no late load / store merge outstanding
  assign e_dm_e   = v ? dmask[7:0] : 8'h0;
  assign e_byp_m  = byp_q;
  assign e_byp_ok = byp_ok;
  assign e_byp_32 = ld32;
  assign e_byp_d  = mdat;
  wire ext_int  = complete && !do_inj && want_int;
  // priority at an instruction end (i486 / SDM): the debug traps of the instruction (TF,
  // data breakpoint, T bit) first, then NMI, then INTR; those stay pending and are taken
  // at the end of the #DB delivery (INTR only if its gate left IF set)
  wire retire_dbt_n = ext_int && take_trap;   // #DB trap delivered
  wire ext_nmi      = ext_int && !take_trap && take_nmi;
  wire ext_intr     = ext_int && !take_trap && !take_nmi && take_intr;
  wire wcommit  = complete && !fault;
  wire wcommit_x = complete && !fault_x;     // commit of the writes a conditional branch never makes

  // IP after this uop: selected by uop type only (independent of mispredict)
  logic [31:0] nxt_ip;
  always_comb begin
    case (eop)
      E_JCC, E_LOOPCC: nxt_ip = br_cond ? tgt : ip_next;
      E_JNEAR: nxt_ip = ip_a;
      E_JFAR:  nxt_ip = ip_b;
      E_IRET:  nxt_ip = ip_t;
      E_LDCS:  nxt_ip = ipz(t2);
      E_LDV86: nxt_ip = {16'h0, t2[15:0]};
      default: nxt_ip = ataken ? tgt : ip_next;
    endcase
  end
  wire [31:0] fin_ip = (fault || (ret_here && !repz_end)) ? ip_start : nxt_ip;
  // (the same without the flag-dependent #GP of a taken Jcc beyond the CS limit: that
  // case selects with br_cond directly, keeping the flags out of the fault select)
  wire        fault_nb = fault_x || crflt;
  wire        tb_br    = tbad && is_br && !fault_nb;
  wire        fin_st   = tb_br ? br_cond : (fault_nb || (ret_here && !repz_end));   // = fin_ip is ip_start

  // register file next state: pending (older) E writes, then A-origin
  // writes of the uop completing now (younger)
  logic [31:0] gn [8];
  wire popa = !pg && (op == 8'h61);
  always_comb begin
    for (int i = 0; i < 8; i++) gn[i] = gm[i];
    // (a conditional branch writes only (E)CX: LOOPcc)
    if (wcommit_x && spw) gn[4] = spv;
    if (wcommit_x && siw) gn[6] = siv;
    if (wcommit_x && diw) gn[7] = divv;
    if (wcommit && cxw) gn[1] = cxv;
    // a fault undoes the stack pointer changes of the instruction's earlier uops
    if (complete && fault_x) begin
      gn[4] = first ? gm[4] : esp0;
      gn[7] = (first || popa) ? gm[7] : edi0;   // (CMPS: its first uop advanced EDI; POPA
                                                 //  keeps the registers it popped: 386EX)
    end
    if (complete && fault) gn[1] = (first || popa) ? gm[1] : ecx0;
  end
  // (E)SP, (E)DI and (E)CX at the start of the instruction (or REP iteration) in E:
  // the registers an earlier uop of the same instruction may have advanced
  logic        uj_q;           // flush of a micro-jump (the instruction continues)
  always_ff @(posedge clk) uj_q <= !rst && uj_take && (eop != E_LDTSK);
  logic [31:0] esp0, edi0, ecx0;
  logic [5:0]  fl0;            // arithmetic flags {OF SF ZF AF PF CF} at the instruction's start
  // SS at the instruction's start: a fault after an SS load of the same instruction (stack
  // switch of a call gate / interrupt, return to an outer level) restores it
  logic [15:0] ss0_sel;
  logic        ss0_b, ss_chg;
  assign ss_snap = v && first;
  always_ff @(posedge clk) begin
    if (rst || (flush_r && !uj_q)) first <= 1'b1;
    else if (complete)  first <= last || bnd || tswl;   // (a faulting load of a new task keeps what it loaded)
    if (rst || (flush_r && !uj_q)) ifst <= 1'b1;
    else if (complete)  ifst <= last && !uj_c;
    if (rst || (flush_r && !uj_q)) ssp_q <= 1'b0;
    else if (complete && iend) ssp_q <= !fault_x && sw_en && (sw_r == 3'd2) && !pg && ((op == 8'h8E) || (op == 8'h17));
    if (rst) tsk_tb <= 1'b0;
    else if (complete) tsk_tb <= (eop == E_TBIT) ? (wcommit_x && B[0]) : (tsk_tb && !fault_x && !iend);
    if (rst) dbacc <= 4'h0;
    else if (complete) dbacc <= (fault_x || (iend && !inh_ss)) ? 4'h0 : dbacc_n;
    if (rst) tswl <= 1'b0;
    else if (complete) tswl <= (uj_take && (eop == E_LDTSK)) || (tswl && !last && !fault_x);
    if (v && first) begin esp0 <= gm[4]; edi0 <= gm[7]; ecx0 <= gm[1]; fl0 <= {of, sf_e, zf_e, af, pf_e, cf}; end
    if (v && first) begin ss0_sel <= s[2]; ss0_b <= ss_b; end
    if (rst || (flush_r && !uj_q)) ss_chg <= 1'b0;
    else if (complete) ss_chg <= !(last || bnd) && !fault_x && (ss_chg || (wcommit_x && sw_en && sw_r == 3'd2));
    ss_rest <= !rst && complete && fault_x && ss_chg;
  end

  // A-executed uops already wrote their result into the A-copy
  // (registered: pwh0/1 of a pending write (pend) not made by A, the A1 bypass reads them)
  always_ff @(posedge clk) begin
    ewh0 <= (!rst && wcommit_x && !aex && !gpr_sup) ? wh0 : 24'h0;
    ewh1 <= (!rst && wcommit_x && !aex && !gpr_sup) ? wh1 : 24'h0;
  end
  assign ewv0 = lw0;
  assign ewv1 = lw1;
  // segment / DF writes reach the A-copy one cycle later (covered by p_dmask)
  always_ff @(posedge clk) begin
    if (rst) begin esw_en <= 1'b0; edf_en <= 1'b0; end
    else begin
      esw_en <= wcommit_x && sw_en && !(eop == E_SEGVAL && sv_ok) && (ck != CK_SELO);
      edf_en <= wcommit_x && f_we[7];
    end
    esw_r <= sw_r; edf_v <= n_df;
    // real mode / V86: base = selector << 4; DHI / LDCS: the descriptor
    if (eop == E_DHI || eop == E_LDCS) begin
      esw_k    <= 2'd0;
      esw_base <= {dhi_v[31:24], dhi_v[7:0], dlo_v[31:16]};
      esw_lim  <= dhi_v[23] ? {dhi_v[19:16], dlo_v[15:0], 12'hFFF} : {12'h0, dhi_v[19:16], dlo_v[15:0]};
      esw_acc  <= (eop == E_LDCS) ? {dhi_v[15], ncpl, dhi_v[12:8]} : dhi_v[15:8];   // (as read: 86Box)
      esw_db   <= dhi_v[22];
      esw_nul  <= (eop == E_DHI) && dnull;
    end else if (eop == E_SEGVAL || eop == E_SEGNUL) begin   // not valid at the new CPL / from V86: null
      esw_k <= 2'd0; esw_base <= '0; esw_lim <= '0; esw_acc <= 8'h80; esw_db <= 1'b0; esw_nul <= 1'b1;
    end else begin
      esw_k    <= (vm || ck == CK_V86 || eop == E_LDV86) ? 2'd3 : (sw_r == 3'd1) ? 2'd2 : 2'd1;
      esw_base <= {12'h0, sw_v, 4'h0};
      esw_lim  <= 32'h0000_FFFF;
      esw_acc  <= 8'hE2;
      esw_db   <= 1'b0;
      esw_nul  <= 1'b0;
    end
  end
  wire [31:0] dhi_v = (eop == E_LDCS) ? t3 : B;      // descriptor high dword of a segment load

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 8; i++) g[i] <= init_gpr[i];
      for (int i = 0; i < 6; i++) s[i] <= init_seg[i];
      {nt, iopl, of, df, ifl, tf, af, cf} <=
        {init_flags[14:12], init_flags[11], init_flags[10], init_flags[9], init_flags[8], init_flags[4], init_flags[0]};
      ip_arch <= init_ip;
      t0 <= '0; t1 <= '0; t2 <= '0; t3 <= '0;
      ldt_sel <= '0; ldt_base <= '0; ldt_lim <= '0;
      tr_sel <= '0; tr_base <= '0; tr_lim <= '0; tr_acc <= 8'h8B;
      rf <= 1'b0; vm <= 1'b0; ac <= 1'b0; idf <= 1'b0; cpl <= 2'd0; ss_b <= 1'b0; gcnt <= '0;
      cs_base <= init_csbase; cs_lim <= 32'h0000_FFFF; cs_d <= 1'b0;
      cr0 <= init_cr0; cr2 <= '0; cr3 <= '0; e_pgq <= init_cr0[31] && init_cr0[0];
      gdtb <= '0; gdtl <= 16'hFFFF; idtb <= '0; idtl <= 16'h03FF;
    end else begin
      for (int i = 0; i < 8; i++) g[i] <= gn[i];
    end
    if (!rst && complete) begin
      // RF: cleared as an instruction (REP iteration) starts; set in the image an
      // instruction breakpoint pushes (86Box's debug-register path)
      // (not in the load of a new task, whose uops all count as first: RF comes from its TSS)
      if (first && !inj && !tswl) rf <= ibf;
      // a fault after an SS load of the same instruction: SS (selector, B) back to its start value
      if (fault_x && ss_chg) begin s[2] <= ss0_sel; ss_b <= ss0_b; end
      // a task switch whose LDT selector faults (#TS) leaves it in LDTR, the cache unusable
      // (SDM task switch: the selector is loaded, then checked)
      if (fault_x && ck == CK_TLDT && (eop == E_DLO || eop == E_DHI)) begin
        ldt_sel <= dsel; ldt_base <= 32'h0; ldt_lim <= 32'h0;
      end
      if (wcommit_x) begin
        if (sw_en && !(eop == E_SEGVAL && sv_ok)) s[sw_r] <= sw_v;
        if (sw_en && sw_r == 3'd2) ss_b <= (eop == E_DHI) ? B[22] : (vm || ck == CK_V86) ? 1'b0 : ss_b;
        if (eop == E_GATE) gcnt <= B[4:0];
        if (eop == E_LDCS) begin                       // protected-mode CS
          cs_base <= {t3[31:24], t3[7:0], t1[31:16]}; cs_lim <= nlim; cs_d <= t3[22];
          cpl     <= ncpl;
          csr_d   <= ldcs_raw;
        end else if (sw_en && sw_r == 3'd1 && ck != CK_SELO) begin   // real mode / V86 CS: limit FFFF
          cs_base <= {12'h0, sw_v, 4'h0}; cs_lim <= 32'h0000_FFFF;
          if (vm || eop == E_LDV86) cs_d <= 1'b0;
        end
        if (eop == E_LDV86) begin cpl <= 2'd3; vm <= 1'b1; rf <= B[16]; end
        // LLDT / LTR
        if (eop == E_LDTSK) begin                      // task switch: the new TR (busy), CR0.TS
          tr_sel  <= t0[15:0];
          tr_base <= {t3[31:24], t3[7:0], t1[31:16]};
          tr_lim  <= nlim;
          tr_acc  <= t3[15:8] | 8'h02;
          cr0[3]  <= 1'b1;
        end
        if (eop == E_LDCR3) cr3 <= B;
        if (eop == E_TWR && op[2] && modrm[5:3] >= 3'd3 && modrm[5:3] <= 3'd5) tr345[modrm[4:3]] <= B;
        if (eop == E_TLFL) begin
          nt <= B[14] || tsk_lnk; iopl <= B[13:12];
          rf <= (sz == 2'd2) && B[16];
          vm <= (sz == 2'd2) && B[17];
          ac <= (sz == 2'd2) && B[18];
          idf <= HAS_CPUID && (sz == 2'd2) && B[21];
          if ((sz == 2'd2) && B[17]) cpl <= 2'd3;
        end
        if (eop == E_PASSB && ck == CK_SELO && sw_en && sw_r == 3'd1) cpl <= vm ? 2'd3 : Rn[1:0];
        if (eop == E_DHI && (ck == CK_LDT || ck == CK_TLDT)) begin
          ldt_sel  <= dsel;
          ldt_base <= dnull ? 32'h0 : {B[31:24], B[7:0], t1[31:16]};
          ldt_lim  <= dnull ? 32'h0 : B[23] ? {B[19:16], t1[15:0], 12'hFFF} : {12'h0, B[19:16], t1[15:0]};
        end
        if (eop == E_DHI && ck == CK_TSS) begin
          tr_sel  <= dsel;
          tr_base <= {B[31:24], B[7:0], t1[31:16]};
          tr_lim  <= B[23] ? {B[19:16], t1[15:0], 12'hFFF} : {12'h0, B[19:16], t1[15:0]};
          tr_acc  <= B[15:8] | 8'h02;
        end
        if (tw_we[0]) t0 <= tw_r2[0] ? R2 : Rn;
        if (tw_we[1]) t1 <= tw_r2[1] ? R2 : Rn;
        if (tw_we[2]) t2 <= tw_r2[2] ? R2 : Rn;
        if (tw_we[3]) t3 <= tw_r2[3] ? R2 : Rn;
        for (int k = 0; k < 6; k++) if (tx_we[k]) tx[k] <= Rn;
        if (f_we[0]) cf <= n_cf;
        if (f_we[2]) af <= n_af;
        if (f_we[5]) tf <= n_tf;
        if (f_we[6]) ifl <= n_if;
        if (f_we[7]) df <= n_df;
        if (f_we[8]) of <= n_of;
        if (pfl_ld) begin
          nt <= B[14];
          if (iopl_ok) iopl <= B[13:12];
          if (eop == E_LDCS && sz == 2'd2) rf <= B[16];           // IRETD: RF (VM: separate path)
          if (sz == 2'd2) begin ac <= B[18]; idf <= HAS_CPUID && B[21]; end   // 32-bit: AC, ID
        end
        if (eop == E_LDCS && (ck == CK_INTCS || ck == CK_INTI)) begin nt <= 1'b0; vm <= 1'b0; rf <= 1'b0; end
        if (eop == E_INTFL) rf <= 1'b0;                          // real-mode delivery (after the image)
        if (eop == E_SWR)
          case (srf)
            3'd0: begin cr0[3:0] <= {B[3:1], B[0] | cr0[0]}; e_pgq <= cr0[31] && (B[0] | cr0[0]); end   // LMSW: PE cannot be cleared
            3'd1: cr0[3] <= 1'b0;                                       // CLTS
            3'd2: begin gdtl <= t1[15:0]; gdtb <= os32 ? B : {8'h0, B[23:0]}; end
            3'd3: begin idtl <= t1[15:0]; idtb <= os32 ? B : {8'h0, B[23:0]}; end
            default:
              case (modrm[5:3])
                3'd0: if (!crflt) begin cr0 <= B; e_pgq <= B[31] && B[0]; end
                3'd2: cr2 <= B;
                3'd3: cr3 <= B;
                default: ;
              endcase
          endcase
      end
      // (a Jcc ends its instruction: tb_br always updates; one 2:1 data mux.  JCC / LOOPCC
      // are one-uop instructions, so boundary covers their redirect: the flag-dependent
      // redirect stays out of the enable)
      if (tb_br || boundary || redir_nj || fault_nb) ip_arch <= fin_st ? ip_start : nxt_ip;
      if (pf_q) cr2 <= pf_cr2;
      // a fault after an earlier uop of the instruction wrote the flags (CMPXCHG: the
      // compare, then the store faults): the instruction leaves them unchanged
      // (fault_x: the Jcc target / MOV CR0 faults are single-uop instructions, never !first)
      if (fault_x && !first) begin of <= fl0[5]; af <= fl0[2]; cf <= fl0[0]; end
      if (fault) rf <= 1'b1;             // every fault pushes RF = 1 (386 / 486 manuals)
    end
    if (!rst && ff_take && !ffbp) cr2 <= ff_lin;
    // a trap or interrupt between two iterations of a REP instruction pushes RF = 1: the
    // instruction goes on without meeting its breakpoint again (SDM 17.3.1.1)
    if (!rst && ext_int && ret_here && !repz_end) rf <= 1'b1;
    if (!rst && ff_take) rf <= 1'b1;   // (a fault of the fetch, an instruction breakpoint)
  end
  // debug registers: MOV DRn (DR4 / DR5 are DR6 / DR7), DR6 status (B bits of the
  // breakpoints matched, BS single step, BD general detect), DR7.GD cleared as #DB is
  // delivered (the handler may use the debug registers)
  // (#DB fault delivered: an instruction breakpoint (highest priority, never while
  // delivering), or GD with no fault before it; kept off the branch-condition fault term)
  wire db_flt   = complete && (ibf || (gdflt && !(xflt || acp || acs || pf_q || cpl0_flt)));
  wire db_entry = db_flt || retire_dbt_n || ff_db;
  // delivering #DB: its own accesses match no data breakpoint (no endless #DB on a
  // breakpoint in the stack)
  always_ff @(posedge clk)
    if (rst) dbdel <= 1'b0;
    else if (db_entry) dbdel <= 1'b1;
    else if ((complete && (do_inj || want_int || (iend && inj))) || ff_take || (xs == X_INTA)) dbdel <= 1'b0;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 4; i++) begin dr[i] <= '0; drm1[i] <= '1; end
      dr6_b <= 4'h0; dr6_h <= 4'h1; dr7 <= 32'h0000_0400;
    end else begin
      if (complete && !fault_x && iend) dr6_b <= dr6_b | dbacc_n;     // (B bits of a completed uop)
      if (complete && ibf) dr6_b <= dr6_b | (ibm & ib_en);
      if (ff_db) dr6_b <= dr6_b | ffbm;
      if (db_flt && !ibf) dr6_h[1] <= 1'b1;
      if (retire_dbt_n && tf) dr6_h[2] <= 1'b1;
      if (retire_dbt_n && tsk_tb) dr6_h[3] <= 1'b1;
      if (db_entry) dr7[13] <= 1'b0;
      // (a task switch clears the local enables L0-L3)
      if (wcommit && (eop == E_LDTSK)) begin dr7[0] <= 1'b0; dr7[2] <= 1'b0; dr7[4] <= 1'b0; dr7[6] <= 1'b0; end
      if (wcommit_x && (eop == E_TWR) && !op[2])
        if (!modrm[5]) begin
          dr[modrm[4:3]] <= B; drm1[modrm[4:3]] <= B[31:2] - 30'd1;
        end else if (modrm[3]) dr7 <= B | 32'h0000_0400;
        else begin dr6_b <= B[3:0]; dr6_h <= B[15:12]; end
    end
  end
  assign dbg_dr6 = dr6;
  assign dbg_dr7 = dr7;
  // MMU controls (registered: the instructions are serializing)
  assign e_cr3 = cr3[31:12];
  always_ff @(posedge clk) begin
    mm_flush  <= !rst && wcommit && (((eop == E_SWR) && (srf == 3'd7) && (modrm[5:3] == 3'd3)) || (eop == E_LDCR3));
    mm_lpkill <= !rst && wcommit && (eop == E_SWR) && (srf == 3'd7) && (modrm[5:3] == 3'd0);
    mm_invlpg <= !rst && wcommit && (eop == E_INVLPG);
    mm_inva   <= ld_lin[31:12];
    tr_we     <= !rst && wcommit && (eop == E_TWR) && op[2] && (modrm[5:3] >= 3'd6);
    tr_sel7   <= modrm[3];
    tr_d      <= B;
  end

  always_ff @(posedge clk) begin
    if (!hold_e) begin
      shb  <= ((m_eop == E_SHIFT) && (m_op[1] || m_op[7:4] == 4'hC)) || (m_eop == E_SHXD);
      sh_z <= 1'b0;
      sh_m <= ms_rdy;
    end else if (sh_e) begin
      shx  <= A;
      sh_z <= (shc == 5'd0);
    end
    // (the select from registers only)
    if (sh_e || !hold_e) begin
      fw <= sh_e ? n_fw : {ms_f | ({33{ms_l}} & {1'b0, da.pv}), ({32{!ms_l}} & da.pv) | ({32{ms_x}} & db.pv)};
      fk <= sh_e ? n_fk : {1'b0, ms_l ? 5'd0 - m_imm[4:0] : m_imm[4:0]};
    end
  end
`ifdef SIM
  always_ff @(posedge clk)
    if (!rst && act && sh_m && shb && (n_fw != fw || n_fk != fk))
      $fatal(1, "exec: shift prepared in M differs: fw %x/%x fk %d/%d", fw, n_fw, fk, n_fk);
`endif
  // BOUND compare / bit scan: registered in the uop's first cycle
  always_ff @(posedge clk)
    if (xs == X_IDLE) begin
      logic [31:0] bm_;
      bnd_lt  <= ssz(ar[34:3], sz) ^ ar[0];
      bm_     = (sz == 2'd2) ? B : {16'h0, B[15:0]};
      bs_zero <= (bm_ == 32'h0);
      bs_idx  <= 5'd0;
      if (op[0]) begin for (int i = 0; i < 32; i++) if (bm_[i]) bs_idx <= 5'(i); end           // BSR: highest
      else       begin for (int i = 31; i >= 0; i--) if (bm_[i]) bs_idx <= 5'(i); end          // BSF: lowest
    end
  always_ff @(posedge clk) begin
    if (xs == X_IDLE) begin
      rb_al <= bcd_al0; rb_ah <= bcd_ah0; rb_c1 <= bcd_c10; rb_c2 <= bcd_c20;
    end
  end
  // bypass registers: values written by the uop that just completed
  // SF/ZF/PF: fold the pending result every cycle; direct writes override
  always_ff @(posedge clk) begin
    if (rst) begin
      fres_v <= 1'b0;
      zf <= init_flags[6]; sf <= init_flags[7]; pf <= init_flags[2];
    end else begin
      zf <= (wcommit_x && f_we[3]) ? n_zf : zf_e;
      sf <= (wcommit_x && f_we[4]) ? n_sf : sf_e;
      pf <= (wcommit_x && f_we[1]) ? n_pf : pf_e;
      fres_v <= wcommit_x && sres;
      if (complete && fault_x && !first) begin sf <= fl0[4]; zf <= fl0[3]; pf <= fl0[1]; fres_v <= 1'b0; end
    end
    if (wcommit_x && sres) begin
      fres    <= fsv;
      fres_sz <= fssz;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin pend <= 1'b0; pdm_v <= 1'b0; end
    else begin
      pend  <= wcommit_x && !gpr_sup && (|wh0 || |wh1);
      pdm_v <= complete;
    end
    if (complete) begin
      lw0 <= p0_v;
      lw1 <= p1_v;
      pwh0 <= wh0;
      pwh1 <= wh1;
      p_dmask <= dmask;
    end
  end

  // ---------------------------------------------------------------- multi-cycle FSM
  // size masks / sign of a value at the operand size
  wire mul_sg = modrm[3] || (eop == E_IMUL2);     // signed multiply
  function automatic logic [31:0] msk(input logic [31:0] x, input logic [1:0] z);
    return (z == 2'd0) ? {24'h0, x[7:0]} : (z == 2'd1) ? {16'h0, x[15:0]} : x;
  endfunction
  always_ff @(posedge clk) begin
    if (rst) begin
      xs <= X_IDLE;
      halted <= 1'b0;
      shutdown <= 1'b0;
      nmi_q <= 1'b0;
      nmi_pend <= 1'b0;
      nmi_blk <= 1'b0;
      nmi_ack <= 1'b0;
    end else begin
      nmi_q <= nmi;
      if (nmi && !nmi_q) nmi_pend <= 1'b1;
      nmi_ack <= ext_nmi || (halted && nmi_go);
      if (ext_nmi || (halted && nmi_go)) nmi_blk <= 1'b1;
      else if (complete && !do_inj && !uj_take && iret_end) nmi_blk <= 1'b0;
      case (xs)
        X_IDLE: begin
          if (act && !ldwait && !fsel_any && start_mul && !hold_w) begin
            xs <= X_MUL1;
            if (eop == E_AAD) begin
              ma <= {25'd0, A[15:8]}; mb <= {25'd0, imm[7:0]};
            end else begin
              // IMUL (modrm.reg bit 0): sign-extended operands
              ma <= {mul_sg & ssz(A, sz), mul_sg ? ((sz == 2'd0) ? {{24{A[7]}}, A[7:0]} :
                                                        (sz == 2'd1) ? {{16{A[15]}}, A[15:0]} : A) : msk(A, sz)};
              mb <= {mul_sg & ssz(B, sz), mul_sg ? ((sz == 2'd0) ? {{24{B[7]}}, B[7:0]} :
                                                        (sz == 2'd1) ? {{16{B[15]}}, B[15:0]} : B) : msk(B, sz)};
            end
          end
          if (act && !ldwait && !fsel_any && start_div && !hold_w) begin
            dv_sgn <= (eop == E_DIV) && modrm[3];
            dsz    <= (eop == E_AAM) ? 2'd0 : sz;                 // AAM is an 8-bit divide
            dv_dd  <= (eop == E_AAM) ? {56'd0, A[7:0]} :
                      (sz == 2'd0) ? {48'd0, gm[0][15:0]} :
                      (sz == 2'd1) ? {32'd0, gm[2][15:0], gm[0][15:0]} : {gm[2], gm[0]};
            dv_dvs <= (eop == E_AAM) ? {24'd0, imm[7:0]} : msk(B, sz);
            xs     <= X_DIV0;
          end
          // (OUTS: the data is a load; a late one (ldwait) or a forwarded one (fsel) is in B
          // only afterwards, as for the other multi-cycle starts)
          // (a fault of the instruction comes before the port access: none is made)
          if (act && !ldwait && !fsel_any && start_io && io_ok && !hold_w && !tblock) xs <= io_stop ? X_IOD : X_IO;
          if (act && !ldwait && !fsel_any && (eop == E_SHIFT || eop == E_SHXD) && shb && !sh_m && !xflt && !hold_w) xs <= X_SH2;
          if (act && !ldwait && !fsel_any && !xflt && (eop == E_DAA || eop == E_DAS || eop == E_AAA || eop == E_AAS ||
                                                       eop == E_BOUND || eop == E_BSF || eop == E_SRD || eop == E_TRD ||
                                                       eop == E_CPUID) && !hold_w)
            xs <= X_B2;
          if (act && !ldwait && !fsel_any && !xflt && c_ck && !hold_w) xs <= X_CK2;
          if (act && !ldwait && !fsel_any && !xflt && c_jn && !hold_w) xs <= X_JN2;
          if (cf_go) begin xs <= X_CF; cf_1st <= 1'b1; end
          // (at CPL > 0 / V86: no sweep, the #GP is raised one cycle later in X_IOD, which
          // keeps the CPL check out of done)
          if (act && (eop == E_CINV) && chk_flt && !hold_w) xs <= X_IOD;
        end
        X_MUL1:  begin mq <= 66'($signed(ma) * $signed(mb)); xs <= X_MUL1B; end
        X_MUL1B: begin mp <= mq; xs <= X_MUL2; end
        X_MUL2: if (!hold_e) xs <= X_IDLE;
        X_DIV0: begin
          logic [63:0] dd;
          logic [31:0] dvs, hi, lo;
          logic        dn, vn;
          dd = dv_dd; dvs = dv_dvs;
          dn = dv_sgn && ((dsz == 2'd0) ? dd[15] : (dsz == 2'd1) ? dd[31] : dd[63]);
          vn = dv_sgn && ssz(dvs, dsz);
          if (dn) dd = ~dd + 64'd1;
          if (vn) dvs = msk(~dvs + 32'd1, dsz);
          case (dsz)
            2'd0:    begin hi = {24'd0, dd[15:8]};  lo = {dd[7:0], 24'h0}; end
            2'd1:    begin hi = {16'd0, dd[31:16]}; lo = {dd[15:0], 16'h0}; end
            default: begin hi = dd[63:32];          lo = dd[31:0]; end
          endcase
          derr_pre <= (hi >= dvs);                    // quotient overflow, divide by zero
          dsigned  <= dv_sgn;
          dneg_q   <= dn ^ vn;
          dneg_r   <= dn;
          drem     <= {1'b0, hi};
          dq       <= lo;                             // left aligned: dq[31] shifts into the remainder
          ddv      <= dvs;
          dcnt     <= (dsz == 2'd0) ? 6'd8 : (dsz == 2'd1) ? 6'd16 : 6'd32;
          xs       <= X_DIV;
        end
        X_DIV: begin
          if (derr_pre || dcnt == 6'd0) begin
            xs <= X_DIVF;
            if (!derr_pre) begin
              // signed range: -2^(n-1) .. 2^(n-1)-1
              logic qm, lz;
              qm = (dsz == 2'd0) ? dq[7] : (dsz == 2'd1) ? dq[15] : dq[31];
              lz = (dsz == 2'd0) ? (dq[6:0] == 7'd0) : (dsz == 2'd1) ? (dq[14:0] == 15'd0) : (dq[30:0] == 31'd0);
              if (dsigned && qm && !(dneg_q && lz)) derr_pre <= 1'b1;
              if (dneg_q) dq <= ~dq + 32'd1;
              if (dneg_r) drem <= {1'b0, ~drem[31:0] + 32'd1};
            end
          end else begin
            logic [32:0] r2;
            r2 = {drem[31:0], dq[31]};
            if (r2 >= {1'b0, ddv}) begin
              drem <= r2 - {1'b0, ddv};
              dq   <= {dq[30:0], 1'b1};
            end else begin
              drem <= r2;
              dq   <= {dq[30:0], 1'b0};
            end
            dcnt <= dcnt - 6'd1;
          end
        end
        X_DIVF: if (!hold_e) xs <= X_IDLE;
        X_SH2:  if (!hold_e) xs <= X_IDLE;
        X_B2:   if (!hold_e) xs <= X_IDLE;
        X_CK2:  if (!hold_e) xs <= X_IDLE;
        X_JN2:  if (!hold_e) xs <= X_IDLE;
        // INVD / WBINVD: the caches take the request this cycle (busy from the next)
        X_CF:   begin cf_1st <= 1'b0; if (!cf_1st && !c_busy) xs <= X_IOD; end
        X_IO: if (io_done) xs <= X_IOD;
        X_IOD: if (!hold_e) xs <= X_IDLE;
        X_INTA: if (io_done) xs <= X_IDLE;
        default: xs <= X_IDLE;
      endcase
      if (flush_r && xs != X_IO && xs != X_IOD && xs != X_INTA) xs <= X_IDLE;
      if (ext_nmi) nmi_pend <= 1'b0;
      if (ext_intr) xs <= X_INTA;
      if (complete && do_halt && !want_int) halted <= 1'b1;
      if (complete && triple) begin halted <= 1'b1; shutdown <= 1'b1; end
      // (shutdown: left by NMI (or RESET) only, as on the 486)
      if (halted && (nmi_go || (!shutdown && intr && ifl))) begin
        halted <= 1'b0; shutdown <= 1'b0;
        if (!nmi_go) xs <= X_INTA;
        else nmi_pend <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------- I/O + INTA
  // redirect / return addresses: the architectural CS:IP written by the uop
  // that completed in the previous cycle (no further completion can happen
  // while a flush is pending)
  assign rd_ip  = ip_arch;
  assign rd_csb = cs_base;
  // INTA waits for io_ok one cycle late (registered off the BIU / store buffer
  // status; io_ok cannot drop while E sits in X_INTA, no new stores arrive)
  logic io_ok_r;
  always_ff @(posedge clk) io_ok_r <= io_ok && (xs == X_INTA);   // sampled inside X_INTA only
  assign io_req   = (xs == X_IO) || ((xs == X_INTA) && io_ok_r);
  assign io_inta  = (xs == X_INTA);
  assign io_we    = (eop == E_OUT);
  // I/O request fields latched when the bus cycle starts
  always_ff @(posedge clk)
    if (xs == X_IDLE && act && !ldwait && !fsel_any && start_io && io_ok && !hold_w && !tblock) begin
      io_port  <= A[15:0];
      io_wdata <= B;
    end
  assign io_sz    = sz;

  // ---------------------------------------------------------------- W stage register
  always_ff @(posedge clk) begin
    if (rst) w_v <= 1'b0;
    // (a shift / rotate by a zero count stores nothing)
    else if (!hold_w) w_v <= complete && wr_en && !fault_x && !st_sup && !((eop == E_SHIFT || eop == E_SHXD) && shb && sh_z);
  end
  always_ff @(posedge clk) begin
    if (!hold_w) begin
      w_lin  <= e_st_lin;
      w_lin4 <= e_st_lin4;
      w_data <= R;
      w_sz   <= sz;
      w_two  <= st_be8[4];
      w_nowr <= sup_d;
      w_hlo  <= e_st_hlo;
      w_hhi  <= e_st_hhi;
      w_wlo  <= e_st_wlo;
      w_whi  <= e_st_whi;
    end
  end

  // ---------------------------------------------------------------- redirect / inject
  // self-modifying code: refetch after the first instruction boundary at or
  // after the store's W cycle, so that code fetched before the store is not
  // executed
  // (fetch stalls while the invalidations are queued, so the refetch sees them)
  logic smc_p;
  wire  smcf = (smc_p || smc_hit) && (last || repz_end);
  always_ff @(posedge clk)
    if (rst) smc_p <= 1'b0;
    else if (complete && smcf) smc_p <= 1'b0;
    else if (smc_hit || snp_hit) smc_p <= 1'b1;
  always_ff @(posedge clk) begin
    if (rst) begin
      flush_r <= 1'b0; rd_fetch <= 1'b0; rd_inject <= 1'b0; rd_stop <= 1'b0;
      be_we <= 1'b0; retire <= 1'b0;
    end else begin
      flush_r   <= 1'b0;
      rd_fetch  <= 1'b0;
      rd_inject <= 1'b0;
      rd_stop   <= 1'b0;
      be_we     <= complete && (brtrain || nbmisp);
      retire    <= complete && (last || repz_end) && !do_inj && !uj_take && !triple;   // (shutdown: none)
      retire_inj <= inj;
      retire_dbt <= retire_dbt_n;
      if (complete) begin
        // data registers: simple enables; control flags carry the conditions
        rd_injid <= uj_take ? uj_id : int_id;
        rd_imm   <= uj_take ? imm : {24'h0, do_inj_a ? inj_vec : ipflt_b ? 8'd13 : ((take_nmi && !take_trap) ? 8'd2 : 8'd1)};
        // (the load part of a task switch restarts and faults at the new task's EIP)
        rd_ips   <= (uj_take && eop == E_LDTSK) ? tsk_eip : (uj_take || do_inj) ? ip_start : fin_ip;   // restart
        // (the task load's uops run before the new CS is loaded: next IP 0 for the old CS
        // limit check in M, nothing pushes it)
        rd_ipn   <= (uj_take && eop == E_LDTSK) ? 32'h0 : uj_take ? ip_next : fin_ip;                 // pushed
        rd_ecvx  <= uj_take ? (inj && x_ecv) : do_inj_a ? inj_ecv : ipflt_b;
        rd_os32  <= uj_take && uj_os32;
        rd_op    <= uj_take ? op : 8'hCD;
        rd_int   <= !uj_take || inj;
        rd_cnt   <= gcnt;
        if (uj_take) begin flush_r <= 1'b1; rd_stop <= 1'b1; rd_inject <= 1'b1; end
        flush_r  <= do_inj || want_int || stop_req && (last || repz_end) || sstep && (last || repz_end) ||
                    do_halt || redir || repz_end || smcf || uj_take;
        rd_stop  <= do_inj || want_int || stop_req && (last || repz_end) ||
                    do_halt || uj_take;
        rd_inject <= do_inj || (want_int && (take_trap || take_nmi || !take_intr)) || uj_take;
        rd_fetch <= !do_inj && !want_int && !uj_take && !(stop_req && (last || repz_end)) &&
                    ((sstep && (last || repz_end) && !do_halt) || (!do_halt && (redir || repz_end || smcf)));
      end
      if (halted && (nmi_go || (!shutdown && intr && ifl))) begin
        flush_r <= 1'b1; rd_stop <= 1'b1;
        rd_inject <= nmi_go;
        rd_imm <= 32'd2;
        rd_injid <= int_id; rd_ips <= ip_arch; rd_ipn <= ip_arch; rd_os32 <= 1'b0; rd_op <= 8'hCD; rd_int <= 1'b1;
        rd_ecvx <= 1'b0;
      end
      if (ff_take) begin                            // fetch #PF (or the #DB of a breakpoint there)
        flush_r <= 1'b1; rd_stop <= 1'b1; rd_inject <= 1'b1;
        rd_imm <= ffbp ? 32'd1 : 32'd14;
        rd_injid <= int_id; rd_ips <= ip_arch; rd_ipn <= ip_arch; rd_os32 <= 1'b0; rd_op <= 8'hCD; rd_int <= 1'b1;
        rd_ecvx <= !ffbp;
      end
      if (xs == X_INTA && io_done) begin
        flush_r <= 1'b1; rd_stop <= 1'b1; rd_inject <= 1'b1;
        rd_imm <= {24'h0, io_rdata[7:0]};
        rd_injid <= int_id; rd_ips <= ip_arch; rd_ipn <= ip_arch; rd_os32 <= 1'b0; rd_op <= 8'hCD; rd_int <= 1'b1;
        rd_ecvx <= 1'b0;
      end
    end
    be_lin   <= brlin;
    be_taken <= br_taken;
    be_tgt   <= br_tgt;
    // BTB kind: 0 conditional, 1 call, 2 return, 3 other unconditional
    be_kind  <= is_ret ? 2'd2 : is_call ? 2'd1 : is_br ? 2'd0 : 2'd3;
    be_ind   <= (eop == E_JNEAR) && !pg && (op == 8'hFF);
    be_tcw   <= (eop == E_JNEAR) && !pg && (op == 8'hFF) && (!pt || !tgt_hit);   // (not via redir)
    be_inval <= nbmisp;
    be_bid   <= bid;
    rd_br    <= brtrain;
    rd_tk    <= br_taken;
    // the return stack is restored to before this uop's block on a redirect,
    // so a redirecting CALL / RET always applies its own push / pop
    rd_rpush <= is_call;
    rd_rpop  <= is_ret;
    rd_rip   <= fcall_x ? {s[1], ip_next[15:0]} : ip_next;
  end
`ifdef SIM
  // +etrace: one line per completed uop
  logic etr;
  initial etr = $test$plusargs("etrace");
  int ecyc = 0;
  always_ff @(posedge clk) ecyc <= ecyc + 1;
  always_ff @(posedge clk)
    if (etr && complete)
      $display("E %0t %08x eop=%0d ck=%0d A=%08x B=%08x t0..3=%08x %08x %08x %08x flt=%0d vec=%0d err=%04x xc=%0d",
               ecyc, ip_start, eop, ck, A, B, t0, t1, t2, t3, fault, inj_vec, inj_err, xc);
  always_ff @(posedge clk)
    if (etr && complete)
      $display("  db: dbr=%h dbw=%h dbtr=%0d dbtw=%0d dbacc=%h dbdel=%0d last=%0d bnd=%0d inj=%0d uj=%0d want=%0d tdbt=%0d ld_lin=%08x mrd=%0d",
               dbr, dbw, dbtr, dbtw, dbacc, dbdel, last, bnd, inj, uj_take, want_int, take_dbt, ld_lin, mrd_q);
`endif
`ifdef SIM
  logic ptr;
  initial ptr = $test$plusargs("ptrace");
  always_ff @(posedge clk) if (ptr) begin
    if (!hold_e && m_adv && !flush_r && (m_uw[UW_MRD_L] || m_wr != WR_NONE))
      $display("E in %08x lin=%08x/%08x ppn=%05x/%05x ok=%0d/%0d ldw=%0d fwd=%04x data=%08x", m_ip_start, m_lin, m_slin, m_pppn, m_sppn,
               m_pok, m_sok, m_ldwait, m_fwd, m_data);
    if (lst == L_DEC) $display("E late x_lin=%08x hit=%0d data=%08x", x_lin, xr_hit, xr_data);
    if (lst == L_UNC && du_done) $display("E unc x_lin=%08x data=%08x", x_lin, du_data);
  end
`endif
  // delivery state: set when an interrupt / exception sequence is injected
  always_ff @(posedge clk) begin
    if (rst) begin
      x_soft <= 1'b0; x_ecv <= 1'b0; x_errc <= 16'h0; gtrap <= 1'b0; x_exc <= 1'b0; x_df <= 1'b0; x_vec <= '0; tsk_op <= '0;
    end else if (complete && do_inj_a) begin
      x_soft <= !fault_a;                  // INT n / INT3 / INTO
      x_ecv  <= inj_ecv;
      x_errc <= inj_err;
      x_exc  <= fault_a;
      x_df   <= dflt2;
      x_vec  <= inj_vec;
    end else if (complete && ipflt_b) begin   // (a taken Jcc's target beyond the limit: #GP(0))
      x_soft <= 1'b0; x_ecv <= 1'b1; x_errc <= 16'h0; x_exc <= 1'b1; x_df <= 1'b0; x_vec <= 8'd13;
    end else if (complete && want_int) begin
      x_soft <= 1'b0; x_ecv <= 1'b0; x_exc <= 1'b0; x_df <= 1'b0;
    end else if (ff_take) begin
      x_soft <= 1'b0; x_ecv <= !ffbp; x_errc <= {13'h0, ff_err}; x_exc <= 1'b1; x_df <= 1'b0; x_vec <= ffbp ? 8'd1 : 8'd14;
    end else if (xs == X_INTA || halted) begin
      x_soft <= 1'b0; x_ecv <= 1'b0; x_exc <= 1'b0; x_df <= 1'b0;
    end
    if (uj_take && ck == CK_INTG) gtrap <= B[8];
    if (uj_take)
      case (uj_k)
        5'(INJ_TASKG), 5'(INJ_TSWS32), 5'(INJ_TSWS16):
          if (ck == CK_CSJ || ck == CK_CSC) tsk_op <= (ck == CK_CSC) ? 2'd1 : 2'd0;
        5'(INJ_TASKI): tsk_op <= 2'd2;
        5'(INJ_IRETT): tsk_op <= 2'd3;
        default: ;
      endcase
  end

  // completed near CALL (rel: the JMPD uop with its push; r/m) and RET, for the
  // committed copy of the return stack in fetch
  always_ff @(posedge clk) begin
    ce_push <= !rst && complete && !fault && (is_call || (abr_e == 3'(ABR_JMPD) && wrk == WR_SEC && !pg));
    ce_pop  <= !rst && complete && !fault && is_ret;
    ce_rip  <= fcall_x ? {s[1], ip_next[15:0]} : ip_next;
  end
endmodule
