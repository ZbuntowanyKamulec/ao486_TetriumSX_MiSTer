// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium address stages A1 and A2
`include "tetrium_cfg.svh"
//  A1: register reads, offset = base + index * scale + displacement (16-bit wrap
//      applied), A-origin register updates, A-executed ops, early branches,
//      scoreboard for the GPR / CS / DF / T0 sources
//  A2: linear address = segment base + offset, D-cache row address (into the BRAM),
//      secondary (store) address; segment interlock (same distance from E as the
//      old single A stage)
//  A1 register view: the A-copy plus the E write being applied this cycle and the
//  A-executed result of the previous uop (no wait for the A-copy write), plus the
//  data of a plain load in E once it is final (load -> address: 2 stall cycles)
//  * keeps a speculative copy of GPRs / segment regs / DF ("A-copy").
//    (E)SP, (E)SI, (E)DI and (E)CX are updated here directly by stack, string
//    and loop uops (68040-style EA-stage register update), so push/pop/string
//    sequences never interlock.  Everything else is written from E.
//  * scoreboard: A-stage sources vs. E-computed destinations in M and E
//  * effective/linear address generation (primary load/RMW address and
//    secondary store address for PUSH / STOS / MOVS), 16- and 32-bit
//    addressing (base + index * scale + displacement)
//  * resolves direct jumps, LOOP and JCXZ early (2-cycle penalty)
import tetrium_pkg::*;
module tetrium_agu (
    input  logic        clk,
    input  logic        rst,
    // from decode
    input  logic        a_vld_eff,
    input  logic        a_last,
    input  logic [AF_BITS-1:0] a_af,
    input  logic [44:0] a_sel,
    input  logic [UW_BITS-1:0] a_uw,
    input  logic [7:0]  c_op,
    input  logic        c_pg,
    input  logic [7:0]  c_modrm,
    input  logic [31:0] c_disp,
    input  logic [31:0] c_imm,
    input  logic [31:0] c_ip_start,
    input  logic [31:0] c_ip_op,
    input  logic [3:0]  c_len,
    input  logic [31:0] c_ip_nx,
    input  logic [1:0]  c_rep,
    input  logic        c_os32,
    input  logic        c_as32,
    input  logic        c_lock,
    input  logic        c_ud,
    input  logic [2:0]  c_sreg,
    input  logic        c_pt,
    input  logic [31:0] c_ptgt,
    input  logic [3:0]  c_bid,
    input  logic        c_inj,
    input  logic [5:0]  c_srdm,
    output logic        a_repkill,
    // stall / flush
    input  logic        hold_m,
    output logic        hold_a,
    input  logic        a20m,          // force linear address bit 20 to 0
    input  logic [15:0] init_seg [6],  // reset selectors (descriptor cache bases)
    input  logic [31:0] init_csbase,   // reset CS base
    input  logic        flush_e,       // restore A-copy from E-copy
    input  logic [255:0] e_gpr,
    input  logic        e_df,
    input  logic        e_pm,          // protected mode (CR0.PE, not V86): access rights checked
    input  logic [31:0] e_t0,          // microcode temporary T0 (address of an AM_TA uop)
    input  logic        e_byp_t0,      // plain load into T0 in E with final data (e_byp_d)
    input  logic [31:0] e_idtb,        // IDTR base (interrupt vector reads)
    input  logic [31:0] e_gdtb,        // GDTR / LDTR / TR bases (system table accesses)
    input  logic [31:0] e_ldtb,
    input  logic [31:0] e_trb,
    input  logic [15:0] e_gdtl,        // table limits: a descriptor / gate read beyond is not done
    input  logic [15:0] e_idtl,        //   (E raises the #GP; no translation, no A bit, no #PF)
    input  logic [31:0] e_ldtl,
    output logic        m_noacc,
    input  logic        e_tss32,       // TR is a 386 TSS (TSZ size, TSS slot offsets)
    input  logic        c_ecv,         // the delivery in progress pushes an error code (ifec uops)
    input  logic        e_ldtw,        // the uop in E loads LDTR
    output logic [31:0] a_ssbase,      // SS base and access bytes for E
    output logic [47:0] a_sacc,
    // E-computed register writes (also applied to the A-copy)
    input  logic [23:0] ewh0, input logic [23:0] ewh1,    // [3*reg+lane]
    input  logic [31:0] ewv0, input logic [31:0] ewv1,
    // segment register writes (the descriptor cache lives here only; E keeps the selectors)
    input  logic        esw_en, input logic [2:0] esw_r,
    input  logic [1:0]  esw_k,          // 0 descriptor, 1 real-mode data, 2 real-mode CS, 3 V86
    input  logic [31:0] esw_base, input logic [31:0] esw_lim,
    input  logic [7:0]  esw_acc, input logic esw_db, input logic esw_nul,
    input  logic        edf_en, input logic edf_v,
    input  logic        ss_snap, input logic ss_rest,   // SS checkpoint (see exec)
    // scoreboard: destinations of uops in M and E ([7:0] GPR, [13:8] segment, [14] DF, [15] T0)
    input  logic [15:0] m_dmask_in,
    input  logic [15:0] e_dmask_in,     // E uop + pending (written next cycle) destinations
    input  logic [7:0]  e_dm_e,         // GPR destinations of the uop in E alone
    input  logic [7:0]  e_byp_m,        // plain load in E with final data: its GPR
    input  logic        e_byp_32,
    input  logic [31:0] e_byp_d,
    // combinational address for the D-cache BRAM
    output logic [9:0]  ac_row,        // D-cache rows (odd-word bank: lin, even-word bank: lin + 4)
    output logic [9:0]  ac_row1,
    // A -> M pipeline register
    output logic        m_valid,
    output logic [UW_BITS-1:0] m_uw,
    output logic        m_last,
    output logic        m_bnd,
    output logic        m_w,
    output logic [1:0]  m_sz,          // operand size of the uop: 0 byte, 1 word, 2 dword
    output logic [1:0]  m_msz,         // size of its memory load
    output logic [7:0]  m_op,
    output logic        m_pg,
    output logic [7:0]  m_modrm,
    output logic [31:0] m_imm,
    output logic [31:0] m_disp,
    output logic [31:0] m_ip_start,
    output logic [31:0] m_ip_next,
    output logic [2:0]  m_sreg,
    output logic [1:0]  m_rep,
    output logic        m_os32,
    output logic        m_as32,
    output logic        m_lock,
    output logic        m_pt,
    output logic [31:0] m_ptgt,
    output logic [3:0]  m_bid,
    output logic        m_inj,
    output logic [2:0]  m_abr,
    output logic [31:0] m_lin,         // linear address of the first byte
    output logic [31:2] m_lin4,        // word address of the next word (lin + 4)
    // D-cache tag sets per line-parity bank: the set of whichever of the two lines (lin,
    // lin + 4) has that parity (registered here: the tag LUTRAM address comes from a register)
    output logic [$clog2(`DC_KB * 1024 / `DC_WAYS) - $clog2(`LINE_B) - 2:0] m_tset0, m_tset1,
    output logic [31:0] m_off,         // effective address (offset), for LEA
    output logic [31:0] m_slin,        // secondary (store) address
    output logic [31:2] m_slin4,
    output logic        m_spw, output logic [31:0] m_spv,
    output logic        m_siw, output logic [31:0] m_siv,
    output logic        m_diw, output logic [31:0] m_div,
    output logic        m_cxw, output logic [31:0] m_cxv,
    output logic [31:0] m_tgt,
    output logic        m_tbad,        // the direct branch target is beyond the code segment limit
    output logic [31:0] m_brlin,
    output logic        m_cxnz,
    output logic        m_ataken,
    output logic        m_aex,
    output logic [15:0] m_dmask,
    output logic [7:0]  m_ldm,         // plain 16/32-bit load into this GPR (one-hot)
    output logic        m_ld32,
    output logic        m_ldt0,        // plain load into T0
    output logic [1:0]  m_amis,        // {secondary, primary} access misaligned (#AC if enabled, decided in E)
    output logic [2:0]  m_xc,          // exception of the uop: 0 none, 1 #UD, 2 #GP, 3 #SS (combinational in M)
    output logic        m_xs,          // ... found only on the secondary (store) address
    // paging: last-page registers (MMU) checked in A2; M replays a miss through the TLB
    input  logic        pg,            // CR0.PG (and PE)
    input  logic        wp,            // CR0.WP
    input  logic [1:0]  e_cpl,
    input  logic [(1<<`UT_SB)*`UT_WAYS-1:0]    ut_v,   // data micro-TLB (MMU), [set * UT_WAYS + way]
    input  logic [(1<<`UT_SB)*`UT_WAYS*42-1:0] ut_e,
    input  logic [(1<<`UT_SB)*`UT_WAYS*3-1:0]  ut_lo,
    input  logic [(1<<`UT_SB)*`UT_WAYS*2-1:0]  ut_w,
    output logic [1:0]  ut_tv,         // its hits used (uop leaving M): {secondary, primary}
    output logic [7:0]  ut_tsw,        //   entry index each
    output logic [31:12] dl_a,         // TLB D port (M replay)
    input  logic        dl_hit,
    input  logic [1:0]  dl_way,
    input  logic [41:0] dl_e,
    output logic        dl_user,       // rights of the replayed access (checked per TLB way)
    output logic        dl_wr,
    input  logic        dl_okp,
    input  logic        dl_okw,
    output logic        m_rp,          // M replays a last-page miss this cycle (M holds)
    input  logic        x_act,         // E's late port has the D-cache read port this cycle
    output logic        mlp_p_ld,      // load the micro-TLB from the replay lookup (primary / secondary)
    output logic        mlp_s_ld,
    output logic [31:12] mlp_vpn,
    output logic [2:0]  lt_v,          // LRU touches of last-page hits {-, secondary, primary}
    output logic [14:0] lt_sw,
    output logic [31:12] m_pppn,       // physical page of the primary / secondary access
    output logic        m_pok,         //   usable: rights (and D for a write) checked
    output logic        m_ppcd,
    output logic [31:12] m_sppn,
    output logic        m_sok,
    output logic [1:0]  m_ucpl,
    // early redirect + BTB training
    output logic        ra_v,
    output logic [31:0] ra_csb,        // code segment base of the redirect
    output logic [31:0] ra_ip,
    output logic        ba_we,
    output logic [31:0] ba_lin,
    output logic        ba_taken,
    output logic        ba_inval,
    output logic [1:0]  ba_kind,
    output logic        ba_pt,
    output logic [3:0]  ba_bid,        // predictor snapshot id (training and A redirects)
    output logic        ra_rpush,
    output logic [31:0] ra_rip,
    output logic [31:0] ba_tgt,
    output logic        a2_valid,      // a uop in A2 (pipeline-empty checks)
    // A-copy for debug
    output logic [15:0] a_sp_dbg,
    output logic [191:0] dbg_sbase,
    output logic [191:0] dbg_slim,
    output logic [59:0]  dbg_sattr      // per segment {nul, db, acc[7:0]}
);
  wire [31:0] c_ip_next = c_ip_nx;
`include "tetrium_asel.svh"

  // A20 gate on every linear address formed here
  // (paging: A20M# masks the physical address, after translation: tetrium_mmu)
  function automatic logic [31:0] a20(input logic [31:0] x);
    return {x[31:21], x[20] && !(a20m && !pg), x[19:0]};
  endfunction

  // ---------------------------------------------------------------- A-copy
  logic [31:0] g [8];
  logic        df;
  assign a_sp_dbg = g[4][15:0];
  // descriptor caches (ES CS SS DS FS GS): base, limit, access byte, B/D, null (protected-mode
  // null selector: every access faults); cs_lim1 = CS limit + 1 (instruction end check)
  logic [31:0] sb [6], sl [6];
  logic [7:0]  sa [6];
  logic [5:0]  sd, sn;
  logic [32:0] cs_lim1;
  genvar gi;

  // A1 register view (see header): gb = A-copy + E write of this cycle + A-executed
  // result of the last uop, ga = gb + plain-load bypass from E
  logic        aexp_v, aexp_d32;
  logic [2:0]  aexp_r;
  logic [31:0] aexp_val;
  logic [31:0] gb [8], ga [8];
  always_comb begin
    for (int i = 0; i < 8; i++) gb[i] = g[i];
    if (aexp_v) begin
      gb[aexp_r][15:0] = aexp_val[15:0];
      if (aexp_d32) gb[aexp_r][31:16] = aexp_val[31:16];
    end
    for (int i = 0; i < 8; i++) begin
      if (ewh0[3*i])   gb[i][7:0]   = ewv0[7:0];
      if (ewh0[3*i+1]) gb[i][15:8]  = ewv0[15:8];
      if (ewh0[3*i+2]) gb[i][31:16] = ewv0[31:16];
      if (ewh1[3*i])   gb[i][7:0]   = ewv1[7:0];
      if (ewh1[3*i+1]) gb[i][15:8]  = ewv1[15:8];
      if (ewh1[3*i+2]) gb[i][31:16] = ewv1[31:16];
    end
    for (int i = 0; i < 8; i++)
      ga[i] = !e_byp_m[i] ? gb[i] : e_byp_32 ? e_byp_d : {gb[i][31:16], e_byp_d[15:0]};
  end

  // ---------------------------------------------------------------- fields
  wire [4:0] amode  = a_af[AF_AMODE_L +: AF_AMODE_W];
  wire [6:0] aoff0  = a_af[AF_AOFF_L +: AF_AOFF_W];
  // (a 286 TSS: the SS:SP slots are at half the 386 offsets)
  wire [6:0] aoff   = ((amode == AM_TSS) && !e_tss32) ? {1'b0, aoff0[6:1]} : aoff0;
  // error code push of a delivery without one: a no-op
  wire       uskip  = a_af[AF_IFEC_L] && !c_ecv;
  wire [1:0] sec    = a_af[AF_SEC_L +: AF_SEC_W];
  wire       repchk = a_af[AF_REPCHK_L];
  wire [2:0] abr    = a_af[AF_ABR_L +: AF_ABR_W];
  wire       rep    = c_rep[1];
  wire [6:0] eop    = a_uw[UW_EOP_L +: UW_EOP_W];
  wire [4:0] d1     = a_uw[UW_D1_L +: UW_D1_W];
  wire [4:0] d2     = a_uw[UW_D2_L +: UW_D2_W];
  wire [3:0] esz    = a_uw[UW_ESZ_L +: UW_ESZ_W];
  wire [2:0] rfix   = a_uw[UW_RFIX_L +: UW_RFIX_W];
  wire       um16   = a_uw[UW_M16_L];
  // operand size of the uop
  wire       w      = (esz == SZ_W0) ? c_op[0] : (esz == SZ_W3) ? c_op[3] : (esz != SZ_B);
  wire       st32   = sd[2];                       // 32-bit stack (SS.B)
  // (SS: the stack size, for SP / ESP and BP / EBP of ENTER / LEAVE)
  wire [1:0] sz     = !w ? 2'd0 : (esz == SZ_W16 || esz == SZ_SEL) ? 2'd1 : (esz == SZ_D32) ? 2'd2 :
                      (esz == SZ_SS) ? (st32 ? 2'd2 : 2'd1) :
                      (esz == SZ_TSZ) ? (e_tss32 ? 2'd2 : 2'd1) :
                      c_os32 ? 2'd2 : 2'd1;
  // step size of stack / string uops (bytes), from the A fields: 0 byte or operand
  // size by opcode bit 0, 1 operand size, 2 16 bit
  wire [1:0] asz    = a_af[AF_ASZ_L +: AF_ASZ_W];
  wire [2:0] szb    = (asz == 2'd2) ? 3'd2 : ((asz == 2'd0) && !c_op[0]) ? 3'd1 : c_os32 ? 3'd4 : 3'd2;
  // address sizes: the instruction's for memory operands, strings and the
  // count register; the stack's for push / pop (16 bit until protected mode)
  wire       is_ea  = (amode == AM_EA) || (amode == AM_EA2) || (amode == AM_EAC);
  wire       is_stk = (amode == AM_POP) || (amode == AM_POPN);
  wire       is_dsc = (amode == AM_DSCR) || (amode == AM_DSCI) || (amode == AM_DSCT);
  // T0 as the base: TA / TAS (segment-relative), DSCT (selector), TSS / LIN (system)
  wire       is_ta  = (amode == AM_TA) || (amode == AM_TAS) || (amode == AM_DSCT) ||
                      (amode == AM_TSS) || (amode == AM_LIN);
  // (vector and system table reads: 32-bit, the tables may lie anywhere)
  wire       is_vec = (amode == AM_VEC) || (amode == AM_VEC2);
  wire       is_sys = is_vec || is_dsc || (amode == AM_IDT) || (amode == AM_TSS) || (amode == AM_LIN) ||
                      (amode == AM_TSSA);
  wire       a32    = (is_stk || (amode == AM_TAS)) ? st32 : is_sys ? 1'b1 : c_as32;
  wire [31:0] amask = a32 ? 32'hFFFF_FFFF : 32'h0000_FFFF;

  // ---------------------------------------------------------------- EA
  logic [31:0] disp2;      // displacement of the second part of a far pointer
  // (0F 01: SGDT / SIDT / LGDT / LIDT, the base after the 16-bit limit at either size)
  always_ff @(posedge clk) disp2 <= c_disp + ((c_os32 && !(c_pg && c_op == 8'h01)) ? 32'd4 : 32'd2);

  wire [7:0]  bsel = a_sel[AS_B +: 8];
  wire [8:0]  isel = a_sel[AS_I +: 9];
  wire [10:0] dsel = a_sel[AS_D +: AS_DW];
  wire [8:0]  ssel = a_sel[AS_S +: AS_SW];      // ES CS SS DS FS GS, descriptor table, IDT, TSS
  wire        aex  = a_sel[AS_AEX];             // A-executed register op (tetrium_asel.svh)
  wire        asub = a_sel[AS_ASUB];
  wire [2:0]  areg = a_sel[AS_AREG +: 3];
  wire [1:0]  scl  = a_sel[AS_SCL +: 2];
  wire        dscm = a_sel[AS_DSCM];            // base = selector: masked to its index
  // T0 with the plain-load bypass from E
  wire [31:0] t0v  = !e_byp_t0 ? e_t0 : e_byp_32 ? e_byp_d : {16'h0, e_byp_d[15:0]};
  logic [31:0] bv, iv0, iv, dv, xb, xi;
  // Base / index read: the register is selected from the A-copy, in parallel
  // with whether the selected register has a newer value (registered one-hot
  // terms), and that value replaces it per lane.  Age, oldest first: A-copy,
  // pending E write (port 0, port 1), plain load in E, A-executed result (the
  // last two never target a register that is also in an older pending write).
  logic [31:0] rsel [2];
  // (rsl: a local name must not hide a module-level one, Quartus 17 crashes)
  always_comb
    for (int k = 0; k < 2; k++) begin
      logic [7:0]  rsl;
      logic [31:0] gv, r;
      logic [2:0]  h0, h1;
      logic        hl, hx;
      rsl = (k == 0) ? bsel : (isel[7:0] | {7'd0, isel[8]});
      gv = '0; h0 = '0; h1 = '0;
      for (int i = 0; i < 8; i++) begin
        gv = gv | ({32{rsl[i]}} & g[i]);
        for (int l = 0; l < 3; l++) begin
          h0[l] = h0[l] | (rsl[i] & ewh0[3*i+l]);
          h1[l] = h1[l] | (rsl[i] & ewh1[3*i+l]);
        end
      end
      hl = |(rsl & e_byp_m);
      hx = aexp_v && rsl[aexp_r];
      r = gv;
      if (hx)         r[7:0] = aexp_val[7:0];
      else if (hl)    r[7:0] = e_byp_d[7:0];
      else if (h1[0]) r[7:0] = ewv1[7:0];
      else if (h0[0]) r[7:0] = ewv0[7:0];
      if (hx)         r[15:8] = aexp_val[15:8];
      else if (hl)    r[15:8] = e_byp_d[15:8];
      else if (h1[1]) r[15:8] = ewv1[15:8];
      else if (h0[1]) r[15:8] = ewv0[15:8];
      if (hx && aexp_d32)      r[31:16] = aexp_val[31:16];
      else if (hl && e_byp_32) r[31:16] = e_byp_d[31:16];
      else if (h1[2])          r[31:16] = ewv1[31:16];
      else if (h0[2])          r[31:16] = ewv0[31:16];
      rsel[k] = r;
    end
  always_comb begin
    bv = rsel[0]; iv0 = rsel[1];
    // A-executed ops use the same selects unmasked (full registers)
    xb = bv; xi = iv0 << scl;      // scl: SHL r,imm count (0 for the other A-executed ops)
    // T0 (bit-string / ENTER / system addresses, a selector) takes the base register's place
    if (is_ta) bv = bv | t0v;
    if (dscm) bv = bv & 32'h0000_FFF8;
    // XLAT: AL as the index
    if (isel[8]) iv0 = {24'h0, iv0[7:0]};
    bv  = bv & amask;
    iv  = (iv0 & amask) << scl;
    dv = ({32{dsel[0]}} & c_disp) | ({32{dsel[1]}} & disp2) |
         ({32{dsel[2]}} & {22'd0, c_imm[7:0], 2'b00}) | ({32{dsel[3]}} & {22'd0, c_imm[7:0], 2'b10}) |
         ({32{dsel[4]}} & c_imm) | ({32{dsel[5]}} & ~c_imm) |
         ({32{dsel[6]}} & 32'h0000_0001) | ({32{dsel[7]}} & 32'hFFFF_FFFF) |
         ({32{dsel[8]}} & {25'd0, aoff}) | ({32{dsel[9]}} & {16'd0, c_imm[15:3], aoff[2:0]}) |
         ({32{dsel[10]}} & {21'd0, c_imm[7:0], aoff[2:0]});
  end
  // displacement as an address term (the A-executed ops use dv unmasked)
  wire [31:0] dva   = dv & amask;
  // offset: carry-save (3:2) + one adder; 16-bit addressing wraps at 64 KB here
  wire [31:0] o_s   = bv ^ iv ^ dva;
  wire [31:0] o_m   = (bv & iv) | (bv & dva) | (iv & dva);
  wire [31:0] off   = (o_s + {o_m[30:0], 1'b0}) & amask;

  // secondary (store) address offset: PUSH (SP - size) or (E)DI; segment SS / ES
  wire        s_push = (sec == SEC_PUSH);
  wire        s_dsca = (sec == SEC_DSCA);
  // selector of a descriptor access (DSC* modes): its TI picks the GDT or LDT; the
  // secondary address of DSCA is its access byte
  wire [15:0] dsc_sel = (amode == AM_DSCI) ? c_imm[15:0] : (amode == AM_DSCT) ? t0v[15:0] : rsel[0][15:0];
  wire        dsc_ti  = dsc_sel[2];
  // (E)SP - size at the stack address size (16 bit: the upper half is kept)
  wire [31:0] sp_d32 = ga[4] - {29'd0, szb};
  wire [31:0] sp_dec = st32 ? sp_d32 : {ga[4][31:16], sp_d32[15:0]};
  wire [31:0] soff   = s_dsca ? {16'h0, dsc_sel[15:3], 3'b101} :
                       s_push ? (st32 ? sp_d32 : {16'h0, sp_d32[15:0]}) : (c_as32 ? ga[7] : {16'h0, ga[7][15:0]});

  // ---------------------------------------------------------------- segment limit / rights
  // An access [offset, offset + n] (n = size - 1) outside the segment faults: #SS(0)
  // through SS, #GP(0) otherwise; so does a write to a read-only (or, in protected
  // mode, code) segment, a read of an execute-only code segment and any access
  // through a null selector.  A2 selects the descriptor (limit already reduced by n)
  // and registers it; M compares the registered offset (the fault is acted on in E).
  //   expand-up:   fault = o > lim - n  (or lim < n)
  //   expand-down: fault = o <= lim  or  o + n beyond FFFF / FFFFFFFF (B)
  wire        u_mrd  = a_uw[UW_MRD_L];
  wire [1:0]  u_wr   = a_uw[UW_WR_L +: UW_WR_W];
  // (DHI reads the descriptor's high dword and stores its access byte)
  wire [1:0]  psz    = um16 ? 2'd1 : (eop == E_MOVX) ? {1'b0, c_op[0]} : (eop == E_DHI) ? 2'd2 : sz;
  wire        pchk   = (u_mrd || (u_wr == WR_PRI)) &&
                       ((amode == AM_EA) || (amode == AM_EA2) || (amode == AM_TA) || (amode == AM_TAS) || is_stk ||
                        (amode == AM_SI) || (amode == AM_DI));
  logic        q_pchk, q_pss, q_schk, q_sss, q_ud;     // (M stage, from mp)
  logic [31:0] q_soff;
  // per access, registered in A2: compare value, expand-down, B, limit < n, high-end check, rights fault
  // (a flat vector: Quartus 17 fails on struct-typed function arguments)
  localparam int LC_X = 0, LC_N = 32, LC_RF = 34, LC_LT = 35, LC_BIG = 36, LC_ED = 37, LC_W = 38;
  logic [LC_W-1:0] q_pl, q_sl;
  function automatic logic hiend(input logic [31:0] o, input logic [1:0] n, input logic b);
    return b ? ((o[31:2] == 30'h3FFF_FFFF) && ({1'b0, o[1:0]} + {1'b0, n} > 3'd3))
             : ((o[31:16] != 16'h0) || ((o[15:2] == 14'h3FFF) && ({1'b0, o[1:0]} + {1'b0, n} > 3'd3)));
  endfunction
  function automatic logic lflt(input logic [31:0] o, input logic [LC_W-1:0] c);
    logic gt;
    gt = (o > c[LC_X +: 32]);
    return c[LC_RF] || (c[LC_ED] ? (!gt || hiend(o, c[LC_N +: 2], c[LC_BIG])) : (gt || c[LC_LT]));
  endfunction
  wire        cflt   = !m_inj && ({1'b0, m_ip_next} > cs_lim1);
  wire        pflt   = q_pchk && lflt(m_off, q_pl);
  wire        sflt   = q_schk && lflt(q_soff, q_sl);
  // alignment (#AC): a word not at an even, a dword not at a multiple-of-4 linear address
  function automatic logic misal(input logic [1:0] a, input logic [1:0] n);
    return (n == 2'd1) ? a[0] : (n == 2'd3) ? (a != 2'd0) : 1'b0;
  endfunction
  assign m_amis = {q_schk && misal(m_slin[1:0], q_sl[LC_N +: 2]), q_pchk && misal(m_lin[1:0], q_pl[LC_N +: 2])};
  assign m_xc = cflt ? 3'd2 : q_ud ? 3'd1 : pflt ? (q_pss ? 3'd3 : 3'd2) : sflt ? (q_sss ? 3'd3 : 3'd2) : 3'd0;
  // (the load of such a uop is translated first: its #PF comes before the store's fault,
  // as the 386 microcode reads before it forms the store address: MOVS, PUSH m)
  assign m_xs = !cflt && !q_ud && !pflt && sflt;

  // ---------------------------------------------------------------- A-origin register updates
  logic        spw, siw, diw, cxw;
  logic [31:0] spv, siv, div_, cxv;
  wire  [31:0] step = df ? -{29'd0, szb} : {29'd0, szb};
  // count register: (E)CX by the address size
  // (E)CX of REP / LOOP / JCXZ from the A-copy itself (no bypass: the count
  // feeds the REP kill to decode); such uops wait for every older CX write
  wire  [31:0] cnt   = c_as32 ? g[1] : {16'h0, g[1][15:0]};
  wire         cnt_z = (cnt == 32'd0);
  wire         cnt_1 = (cnt == 32'd1);
  always_comb begin
    logic [31:0] spi;
    // (E)SP + size (+ imm16: RET n) at the stack address size
    spw = 1'b0;
    spi = ga[4] + {29'd0, szb} + ((amode == AM_POPN) ? {16'h0, c_imm[15:0]} : 32'h0);
    spv = st32 ? spi : {ga[4][31:16], spi[15:0]};
    if (amode == AM_POP || amode == AM_POPN) spw = 1'b1;
    if (s_push) begin spw = 1'b1; spv = sp_dec; end
    siw  = (amode == AM_SI);
    siv  = c_as32 ? ga[6] + step : {ga[6][31:16], ga[6][15:0] + step[15:0]};
    diw  = (amode == AM_DI) || (sec == SEC_STDI);
    div_ = c_as32 ? ga[7] + step : {ga[7][31:16], ga[7][15:0] + step[15:0]};
    cxw  = (repchk && rep) || (abr == ABR_LOOP) || (abr == ABR_LOOPZ) || (abr == ABR_LOOPNZ);
    cxv  = c_as32 ? g[1] - 32'd1 : {g[1][31:16], g[1][15:0] - 16'd1};
  end

  // ---------------------------------------------------------------- scoreboard
  // A1 sources: GPRs (bypassed: the pending E write and a final plain load in E),
  // CS / DF / T0; A-origin destinations wait for every older E write of the
  // register (the A-copy write order).  Segment sources are checked in A2.
  logic [7:0]  srcg, dsta;
  logic [15:0] srco;              // CS, DF, T0
  logic [5:0]  srcs;              // segments (A2)
  always_comb begin
    srcg = '0; srco = '0; srcs = '0;
    // address sources only when the uop really forms an address here
    if (amode != AM_NONE) srcg = bsel | isel[7:0] | {7'd0, isel[8]};
    srco[15] = is_ta;
    srcs = ssel[5:0] | c_srdm;
    case (amode)
      AM_POP, AM_POPN: begin srcg[4] = 1'b1; srcs[2] = 1'b1; end
      AM_SI: begin srcg[6] = 1'b1; srco[14] = 1'b1; end
      AM_DI: begin srcg[7] = 1'b1; srco[14] = 1'b1; end
      default: ;
    endcase
    if (s_push) begin srcg[4] = 1'b1; srcs[2] = 1'b1; end
    // stack uops use SS.B here (stack address size): wait for a pending SS write
    if (is_stk || s_push || amode == AM_TAS) srco[10] = 1'b1;
    if (sec == SEC_STDI) begin srcg[7] = 1'b1; srcs[0] = 1'b1; srco[14] = 1'b1; end
    if (cxw || abr == ABR_JCXZ || (repchk && rep)) srcg[1] = 1'b1;
    if (abr == ABR_JMPD || abr == ABR_LOOP || abr == ABR_JCXZ || (abr == ABR_NONE && c_pt))
      srco[9] = 1'b1;   // CS for redirect / BTB address
    dsta = {diw, siw, 1'b0, spw, 2'b00, cxw, 1'b0};
  end
  // destinations of the older uops in A2 / M / E (+ pending)
  logic        b_valid;
  logic [15:0] b_dmask_q;
  wire  [15:0] pm_b   = b_valid ? b_dmask_q : 16'h0;
  // The E write being applied this cycle is in gb and an A1 write of the same
  // register is younger (it overrides it in gn): only writes still in A2 / M / E
  // matter.  A plain load in E serves as a source (bypass), but an A1 write of
  // its register must wait (the load's write lands after it).
  // (T0: a plain load into T0 in E is bypassed, see t0v)
  wire  [15:0] pend_f = pm_b | m_dmask_in | {e_dmask_in[15] && !e_byp_t0, e_dmask_in[14:0]};
  wire  [7:0]  pend_g = pm_b[7:0] | m_dmask_in[7:0] | e_dm_e;
  wire  [7:0]  pend_s = pm_b[7:0] | m_dmask_in[7:0] | (e_dm_e & ~e_byp_m);
  wire cx_rd    = cxw || (abr == ABR_JCXZ) || (repchk && rep);
  wire cx_pend  = pend_f[1] || (aexp_v && aexp_r == 3'd1);
  wire sb_stall = |(srcg & pend_s) || |(dsta & pend_g) || |(srco & pend_f) || (cx_rd && cx_pend);
  // A-execute opportunistically: only if its sources and destination have no
  // older pending E-computed write; otherwise it runs in E as usual (no stall)
  wire [7:0] aex_src = bsel | isel[7:0] | {7'd0, isel[8]};
  wire       aex_ok  = aex && !(|(aex_src & pend_s)) && !pend_g[areg];
  logic hold_a2;
  assign hold_a = hold_a2 || (a_vld_eff && sb_stall);
  wire adv = a_vld_eff && !hold_a;

  // REP exhausted: kill the iteration, it becomes a retire marker
  assign a_repkill = a_vld_eff && repchk && rep && cnt_z;

  // ---------------------------------------------------------------- dmask of this uop
  function automatic logic [15:0] dbit(input logic [4:0] d);
    logic [15:0] r;
    r = '0;
    case (d)
      D_REG: r[w ? c_modrm[5:3] : {1'b0, c_modrm[4:3]}] = 1'b1;
      D_RM:  r[w ? c_modrm[2:0] : {1'b0, c_modrm[1:0]}] = 1'b1;
      D_ACC: r[0] = 1'b1;
      D_OPR: r[w ? c_op[2:0] : {1'b0, c_op[1:0]}] = 1'b1;
      D_FIX: r[rfix] = 1'b1;
      D_SEG: r[8 + c_sreg] = 1'b1;
      D_SSR: r[10] = 1'b1;
      D_SEGF: r[8 + rfix] = 1'b1;
      D_T0:  r[15] = 1'b1;
      default: ;
    endcase
    return r;
  endfunction
  logic [15:0] dmask;
  wire u_cmp = ((eop == E_ALUOP) && (c_op[5:3] == 3'd7)) || ((eop == E_ALUREG) && (c_modrm[5:3] == 3'd7));
  always_comb begin
    dmask = (u_cmp ? 16'd0 : dbit(d1)) | dbit(d2);
    if (aex_ok) dmask[areg] = 1'b0;
    case (eop)
      E_MUL, E_DIV, E_CWD: dmask[2:0] = dmask[2:0] | 3'b101;
      E_AAM, E_AAD, E_DAA, E_DAS, E_AAA, E_AAS, E_CBW, E_SALC, E_LAHF, E_IN:
        dmask[0] = 1'b1;
      E_POPF, E_IRET, E_FLAGOP: dmask[14] = 1'b1;
      default: ;
    endcase
    // JFAR: one that changes CS unpredicted redirects and flushes everything younger, one
    // that keeps CS writes the same value; one predicted to change it sets A's speculative
    // CS base (csb_a, for addresses) but the selector is read as a value (PUSH CS, CALL
    // FAR, MOV r, CS: c_srdm) only once E has written it
    // (a predicted protected-mode far JMP / CALL / RETF (LDCS, abr BRI) is verified in E to
    // keep CS, else E redirects)
    if (eop == E_IRET || (eop == E_LDCS && !(c_pt && abr == ABR_BRI)) ||
        (eop == E_JFAR && c_pt && c_ptgt[31:16] != 16'h0))
      dmask[9] = 1'b1;
    if (eop == E_SEGVAL || eop == E_SEGNUL) dmask[8 + rfix] = 1'b1;
    if (eop == E_LDV86) dmask[9] = 1'b1;
  end

  // ---------------------------------------------------------------- early branches
  // relative target: truncated to 16 bits with a 16-bit operand size
  wire [31:0] tgt32  = c_ip_next + c_imm;
  wire [31:0] tgt    = c_os32 ? tgt32 : {16'h0, tgt32[15:0]};
  // Speculative CS base (real mode / V86): a far transfer predicted to change CS (JFAR,
  // predicted target {selector, offset}) sets it when it leaves A1; any flush clears it.
  // A1 (branch redirect / BTB addresses) and A2 (CS-relative data, from the uop after
  // that JFAR on) use it in place of the CS copy E writes later.
  logic        a_csv, b_setcs;
  logic [31:0] a_csb;
  wire  [31:0] csb_a  = a_csv ? a_csb : sb[1];
  wire         setcs  = adv && !killrep && (eop == E_JFAR) && c_pt && (c_ptgt[31:16] != 16'h0);
  always_ff @(posedge clk) begin
    if (rst || flush_e) a_csv <= 1'b0;
    else if (setcs) begin a_csv <= 1'b1; a_csb <= {12'h0, c_ptgt[31:16], 4'h0}; end
  end
  wire [31:0] brlin  = a20(csb_a + c_ip_next - 32'd1);
  logic a_res, a_taken;
  always_comb begin
    a_res = 1'b0; a_taken = 1'b0;
    case (abr)
      ABR_JMPD: begin a_res = 1'b1; a_taken = 1'b1; end
      ABR_LOOP: begin a_res = 1'b1; a_taken = !cnt_1; end
      ABR_JCXZ: begin a_res = 1'b1; a_taken = cnt_z; end
      default: ;
    endcase
  end
  // predicted target == ip_next + imm without the carry chain:
  //   a + b == c  <=>  a ^ b ^ c == maj(a, b, ~c) << 1
  wire [31:0] te_x = c_ip_next ^ c_imm ^ c_ptgt;
  wire [31:0] te_m = (c_ip_next & c_imm) | (c_ip_next & ~c_ptgt) | (c_imm & ~c_ptgt);
  wire        te16 = (te_x[15:0] == {te_m[14:0], 1'b0});
  wire        t_eq = c_os32 ? (te16 && (te_x[31:16] == te_m[30:15])) : (te16 && (c_ptgt[31:16] == 16'h0));
  wire a_misp  = a_res ? ((a_taken != c_pt) || (a_taken && !t_eq))
                       : ((abr == ABR_NONE) && c_pt && a_last);
  wire killrep = a_repkill;

  // ---------------------------------------------------------------- registers
  always_ff @(posedge clk) begin
    if (rst) begin
      ra_v  <= 1'b0;
      ba_we <= 1'b0;
    end else begin
      ra_v  <= adv && !killrep && a_misp;
      ba_we <= adv && !killrep && (a_res || ((abr == ABR_NONE) && c_pt && a_last));
    end
    ra_csb   <= csb_a;
    ra_ip    <= (a_res && a_taken) ? tgt : c_ip_next;
    ba_lin   <= brlin;
    ba_taken <= a_taken;
    ba_inval <= !a_res;
    ba_tgt   <= tgt;
    ba_kind  <= (abr == ABR_JMPD) ? (s_push ? 2'd1 : 2'd3) : 2'd0;   // call / jmp rel / LOOP, JCXZ
    ba_pt    <= c_pt;
    ba_bid   <= c_bid;
    ra_rpush <= (abr == ABR_JMPD && s_push);    // redirecting CALL rel (stack restored first)
    ra_rip   <= c_ip_next;
  end

  // ---------------------------------------------------------------- A1 -> A2 -> M
  typedef struct packed {
    logic [UW_BITS-1:0] uw;
    logic        last, bnd, w;
    logic [1:0]  sz, msz;
    logic [7:0]  op;
    logic        pg;
    logic [7:0]  modrm;
    logic [31:0] imm, disp, ip_start, ip_next;
    logic [2:0]  sreg;
    logic [1:0]  rep;
    logic        os32, as32, lock, pt;
    logic [31:0] ptgt;
    logic [3:0]  bid;
    logic        inj;
    logic [2:0]  abr;
    logic [31:0] off;
    logic        spw;  logic [31:0] spv;
    logic        siw;  logic [31:0] siv;
    logic        diw;  logic [31:0] dvv;
    logic        cxw;  logic [31:0] cxv;
    logic [31:0] tgt;
    logic [31:0] brlin;
    logic        cxnz, ataken, aex;
    logic [15:0] dmask;
    logic        ud, pchk, pss;
    logic [1:0]  pnb1;
    logic        prd, pwr;     // the primary access reads / writes
    logic        schk, sss;
    logic [1:0]  snb1;
    logic [31:0] soff;
    logic [7:0]  ldm;
    logic        ld32, ldt0;
    logic        ldtw;         // loads LDTR (LLDT, task switch): the LDT base changes
  } ap_t;
  ap_t a1p, bp, mp;
  // plain 16/32-bit load into a GPR (E passes the memory operand unchanged)
  wire ldp = u_mrd && (eop == E_PASSB) && (a_uw[UW_SB_L +: UW_SB_W] == 5'(S_MEM)) && (d2 == 5'(D_NONE)) && w &&
             ((d1 == 5'(D_REG)) || (d1 == 5'(D_OPR)) || (d1 == 5'(D_ACC)));
  wire [15:0] d1bit = dbit(d1);
  always_comb begin
    a1p.uw = a_uw;
    if (uskip) begin
      a1p.uw[UW_EOP_L +: UW_EOP_W] = 7'(E_NOP);
      a1p.uw[UW_MRD_L]             = 1'b0;
      a1p.uw[UW_WR_L +: UW_WR_W]   = 2'(WR_NONE);
      a1p.uw[UW_D1_L +: UW_D1_W]   = 5'(D_NONE);
      a1p.uw[UW_D2_L +: UW_D2_W]   = 5'(D_NONE);
    end
    if (killrep) begin
      a1p.uw[UW_EOP_L +: UW_EOP_W] = 7'(E_RETIRE);
      a1p.uw[UW_MRD_L]             = 1'b0;
      a1p.uw[UW_WR_L +: UW_WR_W]   = 2'(WR_NONE);
      a1p.uw[UW_D1_L +: UW_D1_W]   = 5'(D_NONE);
      a1p.uw[UW_D2_L +: UW_D2_W]   = 5'(D_NONE);
    end
    a1p.last     = a_last;
    a1p.bnd      = a_af[AF_ENDNR_L] && rep;
    a1p.w        = w;
    a1p.sz       = sz;
    // (MOVZX / MOVSX load their source size, a far pointer's selector is 16 bits)
    a1p.msz      = psz;
    a1p.op       = c_op;
    a1p.pg       = c_pg;
    a1p.modrm    = c_modrm;
    a1p.imm      = c_imm;
    a1p.disp     = c_disp;
    a1p.ip_start = c_ip_start;
    a1p.ip_next  = c_ip_next;
    a1p.sreg     = c_sreg;
    a1p.rep      = c_rep;
    a1p.os32     = c_os32;
    a1p.as32     = c_as32;
    a1p.lock     = c_lock;
    // a non-branch with a taken prediction is redirected here; E must not repeat it
    a1p.pt       = c_pt && !(!killrep && (abr == ABR_NONE) && a_last);
    a1p.ptgt     = c_ptgt;
    a1p.bid      = c_bid;
    a1p.inj      = c_inj;
    a1p.abr      = killrep ? 3'(ABR_NONE) : abr;
    a1p.off      = off;
    a1p.spw      = spw && !killrep && !uskip;  a1p.spv = spv;
    a1p.siw      = siw && !killrep;  a1p.siv = siv;
    a1p.diw      = diw && !killrep;  a1p.dvv = div_;
    a1p.cxw      = cxw && !killrep;  a1p.cxv = cxv;
    a1p.tgt      = tgt;
    a1p.brlin    = brlin;
    a1p.cxnz     = !cnt_1;
    a1p.ataken   = a_res && a_taken && !killrep;
    a1p.aex      = aex_ok;
    a1p.dmask    = (killrep || uskip) ? 16'd0 : dmask;
    // (an exhausted REP still raises the faults of the instruction itself)
    a1p.ud       = c_ud;
    a1p.pchk     = pchk && !killrep;
    a1p.pss      = ssel[2];
    a1p.pnb1     = (psz == 2'd0) ? 2'd0 : (psz == 2'd1) ? 2'd1 : 2'd3;
    a1p.prd      = u_mrd;
    a1p.pwr      = (u_wr == WR_PRI) && !u_cmp;   // (CMP r/m: the uop has a W slot, never writes)
    a1p.schk     = (u_wr == WR_SEC) && !s_dsca && !killrep && !uskip;
    a1p.sss      = s_push;
    a1p.snb1     = (szb == 3'd1) ? 2'd0 : (szb == 3'd2) ? 2'd1 : 2'd3;
    a1p.soff     = soff;
    a1p.ldm      = (ldp && !killrep) ? d1bit[7:0] : 8'h0;
    a1p.ld32     = (sz == 2'd2);
    a1p.ldtw     = (eop == E_DHI) && ((a_uw[UW_CK_L +: UW_CK_W] == 5'(CK_LDT)) || (a_uw[UW_CK_L +: UW_CK_W] == 5'(CK_TLDT)));
    a1p.ldt0     = u_mrd && (eop == E_PASSB) && (a_uw[UW_SB_L +: UW_SB_W] == 5'(S_MEM)) &&
                   (d1 == 5'(D_T0)) && (d2 == 5'(D_NONE)) && !killrep;
  end

  // A2 registers: the uop, its segment selects and interlock sources
  logic [9:0]  b_ssel;           // ES CS SS DS FS GS, GDT, LDT, IDT, TR
  logic [5:0]  b_srcs;
  logic        b_spush, b_sdsc, b_dti;
  // (a descriptor access through the LDT waits for an older LDTR load in M / E)
  wire  seg_stall = b_valid && (|(b_srcs & (m_dmask_in[13:8] | e_dmask_in[13:8])) ||
                                ((b_ssel[7] || (b_sdsc && b_dti)) && ((m_valid && mp.ldtw) || e_ldtw)));
  assign hold_a2 = hold_m || seg_stall;
  wire  b_adv = b_valid && !hold_a2;
  assign b_dmask_q = bp.dmask;
  assign a2_valid  = b_valid;
  assign a_ssbase  = sb[2];
  generate
  for (gi = 0; gi < 6; gi = gi + 1) begin : g_sacc assign a_sacc[gi*8 +: 8] = sa[gi]; end
  endgenerate
  always_ff @(posedge clk) begin
    if (rst || flush_e) b_valid <= 1'b0;
    else if (!hold_a2)  b_valid <= adv;
  end
  always_ff @(posedge clk) begin
    if (!hold_a2) begin
      bp      <= a1p;
      b_ssel  <= {ssel[8:7], ssel[6] && dsc_ti, ssel[6] && !dsc_ti, ssel[5:0]};
      b_srcs  <= srcs;
      b_spush <= s_push;
      b_sdsc  <= s_dsca;
      b_dti   <= dsc_ti;
      b_setcs <= setcs;
    end
  end
  wire [31:0] csb_b = (a_csv && !b_setcs) ? a_csb : sb[1];     // CS base for A2

  // A2: segment base + offset
  logic [31:0] sbase, plim, slim_s;
  logic [7:0]  pacc, sacc;
  logic        pdb, pnul, sdb, snul;
  always_comb begin
    sbase = ({32{b_ssel[6]}} & e_gdtb) | ({32{b_ssel[7]}} & e_ldtb) | ({32{b_ssel[8]}} & e_idtb) |
            ({32{b_ssel[9]}} & e_trb);
    plim = '0; pacc = '0; pdb = 1'b0; pnul = 1'b0;
    for (int i = 0; i < 6; i++) begin
      sbase = sbase | ({32{b_ssel[i]}} & ((i == 1) ? csb_b : sb[i]));
      plim  = plim  | ({32{b_ssel[i]}} & sl[i]);
      pacc  = pacc  | ({8{b_ssel[i]}} & sa[i]);
      pdb   = pdb   | (b_ssel[i] & sd[i]);
      pnul  = pnul  | (b_ssel[i] & sn[i]);
    end
    // secondary (store) address: SS (push) or ES (string destination)
    slim_s = b_spush ? sl[2] : sl[0];
    sacc   = b_spush ? sa[2] : sa[0];
    sdb    = b_spush ? sd[2] : sd[0];
    snul   = b_spush ? sn[2] : sn[0];
  end
  wire [31:0] ac_lin  = a20(sbase + bp.off);
  wire [31:0] ac_lin4 = a20(sbase + bp.off + 32'd4);
  localparam int TLB = $clog2(`LINE_B);                 // D-cache geometry (tetrium_mem.sv)
  localparam int TWB = $clog2(`DC_KB * 1024 / `DC_WAYS);
  // D-cache rows (the BRAM read address): low 13 bits only
  wire [12:0] rsum0 = bp.off[12:0] + sbase[12:0];
  wire [12:0] rsum4 = bp.off[12:0] + sbase[12:0] + 13'd4;
  assign ac_row  = rsum0[12:3];
  assign ac_row1 = rsum4[12:3];
  wire [31:0] ssb   = b_sdsc ? (b_dti ? e_ldtb : e_gdtb) : b_spush ? sb[2] : sb[0];
  wire [31:0] slin  = a20(ssb + bp.soff);
  wire [31:0] slin4 = a20(ssb + bp.soff + 32'd4);
  // limit / rights descriptors of both accesses (see the limit check above)
  //   writable: access bit 1 (and, in protected mode, not code); execute-only: code without R
  function automatic logic [LC_W-1:0] lcd(input logic [31:0] lm, input logic [7:0] ac, input logic db,
                                          input logic nul, input logic [1:0] n, input logic rd,
                                          input logic wr, input logic pm);
    logic [LC_W-1:0] c;
    logic ed;
    ed = (ac[4:3] == 2'b10) && ac[2];
    c[LC_ED]      = ed;
    c[LC_BIG]     = db;
    c[LC_N +: 2]  = n;
    c[LC_LT]      = (lm < {30'd0, n});
    c[LC_X +: 32] = ed ? lm : lm - {30'd0, n};
    c[LC_RF]      = nul || (wr && (!ac[1] || (pm && ac[3]))) || (rd && pm && (ac[3] && !ac[1]));
    return c;
  endfunction
  logic [LC_W-1:0] n_pl, n_sl;
  assign n_pl = lcd(plim, pacc, pdb, pnul, bp.pnb1, bp.prd, bp.pwr, e_pm);
  assign n_sl = lcd(slim_s, sacc, sdb, snul, bp.snb1, 1'b0, 1'b1, e_pm);
  // direct branch target beyond the code segment limit
  wire  n_tbad = (bp.tgt > sl[1]);

  // ---------------------------------------------------------------- paging: micro-TLB check
  // The page of each access is looked up in the data micro-TLB (set linear[14:12]); the
  // physical page and the rights check for the uop's access go to M with it.  A miss
  // (paging on) makes M replay the uop through the TLB (one cycle per address).
  //   entry {tag[16:0], ppn[19:0], U, W, D, PCD, PWT}
  localparam int PE_U = 4, PE_W = 3, PE_D = 2, PE_PCD = 1;
  function automatic logic lp_ok(input logic [41:0] e, input logic user, input logic rd, input logic wr,
                                 input logic wpb);
    return !(user && !e[PE_U]) && !(wr && ((!e[PE_W] && (user || wpb)) || !e[PE_D]));
  endfunction
  wire        b_mrd  = bp.uw[UW_MRD_L];
  wire [1:0]  b_wr   = bp.uw[UW_WR_L +: UW_WR_W];
  wire        b_user = (e_cpl == 2'd3) && !bp.uw[UW_SV_L];
  // (protected mode: a descriptor or IDT gate beyond its table's limit is not read)
  // (a GDT access with the null selector is not done either: the 486 loads a null selector
  // without reading the GDT, which with paging would set the page's accessed bit)
  wire        b_oob  = e_pm && ((b_ssel[6] && (((bp.off | 32'd7) > {16'h0, e_gdtl}) || (bp.off[31:3] == 29'h0))) ||
                                (b_ssel[7] && ((bp.off | 32'd7) > e_ldtl)) ||
                                (b_ssel[8] && ((bp.off | 32'd7) > {16'h0, e_idtl})));
  wire        pgacc  = (b_mrd || bp.pwr) && !b_oob;   // the uop accesses its primary / secondary address
  wire        sgacc  = (b_wr == WR_SEC);
  // micro-TLB lookup: {ok (hit with the rights of the access), hit, micro way, TLB way, entry};
  // the rights are checked on both ways of the set in parallel with the tag compares
  localparam int USB = `UT_SB, UWY = `UT_WAYS, UNS = 1 << USB;
  function automatic logic [49:0] ulook(input logic [31:12] a, input logic user, input logic rd, input logic wr,
                                        input logic wpb);
    // {ok, hit, entry index, TLB way, entry}: the ways of set a[12 +: USB]
    // (entries selected by compares with constants: an index times the entry width became
    //  DSP multipliers in Quartus)
    logic [41:0] e; logic h, hi, ok; logic [3:0] ix; logic [1:0] tw; int s;
    s = (USB == 0) ? 0 : (int'(a[14:12]) & (UNS - 1));
    e = '0; h = 1'b0; ok = 1'b0; ix = '0; tw = '0;
    for (int q = 0; q < UNS * UWY; q++)
      if ((q / UWY) == s && (q % UWY) == 0) begin e = ut_e[q * 42 +: 42]; ix = 4'(q); tw = ut_w[q * 2 +: 2]; end
    for (int q = 0; q < UNS * UWY; q++)
      if ((q / UWY) == s) begin
        hi = ut_v[q] && (ut_e[q * 42 + 25 +: 17] == a[31:15]) && (USB == 3 || ut_lo[q * 3 +: 3] == a[14:12]);
        ok = ok || (hi && lp_ok(ut_e[q * 42 +: 42], user, rd, wr, wpb));
        h = h || hi;
        if (hi) begin e = ut_e[q * 42 +: 42]; ix = 4'(q); tw = ut_w[q * 2 +: 2]; end
      end
    return {ok, h, ix, tw, e};
  endfunction
  // One way, 8 sets (the default): sum-addressed.  The set linear[14:12] is base[14:12] +
  // off[14:12] + c12 (c12: carry out of the low 12 bits); both candidate sets are read in
  // parallel with the add and their tags compared with base + off without the carry chain
  // (a + b + cin == t: at each bit a ^ b ^ t is the carry in, which a, b, t of the bit
  // below determine); c12 picks one at the end.  (Paging only: no A20 mask then.)
  function automatic logic sumeq(input logic [16:0] x, input logic [16:0] y, input logic [16:0] t,
                                 input logic cin);
    logic [16:0] k;
    k = (x & y) | ((x ^ y) & ~t);
    return ~|((x ^ y ^ t) ^ {k[15:0], cin});
  endfunction
  function automatic logic [49:0] ufast(input logic [31:0] bs, input logic [31:0] of);
    logic [3:0] s0, s1; logic [12:0] lo; logic [41:0] e0, e1; logic [1:0] w0, w1; logic v0, v1, h0, h1;
    lo = {1'b0, bs[11:0]} + {1'b0, of[11:0]};
    s0 = {1'b0, bs[14:12]} + {1'b0, of[14:12]};
    s1 = s0 + 4'd1;
    e0 = '0; e1 = '0; w0 = '0; w1 = '0; v0 = 1'b0; v1 = 1'b0;
    for (int q = 0; q < 8; q++) begin
      if (s0[2:0] == 3'(q)) begin e0 = ut_e[q * 42 +: 42]; w0 = ut_w[q * 2 +: 2]; v0 = ut_v[q]; end
      if (s1[2:0] == 3'(q)) begin e1 = ut_e[q * 42 +: 42]; w1 = ut_w[q * 2 +: 2]; v1 = ut_v[q]; end
    end
    h0 = v0 && sumeq(bs[31:15], of[31:15], e0[41:25], s0[3]);
    h1 = v1 && sumeq(bs[31:15], of[31:15], e1[41:25], s1[3]);
    return lo[12] ? {1'b0, h1, 1'b0, s1[2:0], w1, e1} : {1'b0, h0, 1'b0, s0[2:0], w0, e0};
  endfunction
  localparam bit UFAST = (UWY == 1) && (USB == 3);
  wire [49:0] upl_n  = UFAST ? ufast(sbase, bp.off) : ulook(ac_lin[31:12], b_user, b_mrd, bp.pwr, wp);
  wire [49:0] usl_n  = UFAST ? ufast(ssb, bp.soff)  : ulook(slin[31:12], b_user, 1'b0, 1'b1, wp);
`ifdef SIM
  // (the sum-addressed lookup must agree with the plain one whenever paging is on)
  wire [49:0] upl_r = ulook(ac_lin[31:12], b_user, b_mrd, bp.pwr, wp);
  wire [49:0] usl_r = ulook(slin[31:12], b_user, 1'b0, 1'b1, wp);
  always_ff @(posedge clk)
    if (UFAST && pg && b_adv && !hold_m && !rst && (upl_n[48:0] != upl_r[48:0] || usl_n[48:0] != usl_r[48:0]))
      $fatal(1, "agu: sum-addressed micro-TLB lookup differs: lin %08x %08x p %013x/%013x s %013x/%013x base %08x off %08x ssb %08x soff %08x", ac_lin, slin, upl_n, upl_r, usl_n, usl_r, sbase, bp.off, ssb, bp.soff);
`endif
  wire        php    = upl_n[48];
  wire        shp    = usl_n[48];
  wire [41:0] pe_n   = upl_n[41:0];
  wire [41:0] se_n   = usl_n[41:0];
  // rights of the access, registered into M: with one way the set's entry is the only
  // candidate, so its rights are taken without the tag compare (a miss is replayed in M,
  // which writes the TLB's result, or 0 when the TLB misses too: the walk is left to E)
  wire        pok_n  = (UWY == 1) ? lp_ok(pe_n, b_user, b_mrd, bp.pwr, wp) : upl_n[49];
  wire        sok_n  = (UWY == 1) ? lp_ok(se_n, b_user, 1'b0, 1'b1, wp) : usl_n[49];
  logic        q_rpp, q_rps, q_phit, q_shit, q_pacc, q_sacc;
  logic [1:0]  q_pway, q_sway;
  logic [3:0]  q_puw, q_suw;     // micro-TLB entry of the hits
  logic [41:0] q_pe, q_se;     // (for the M recheck after a replay)
  // (the replay ends with a re-read of the uop's own rows: one more cycle if E's late
  // port had the read port)
  logic        q_rr;
  assign m_rp   = m_valid && (q_rpp || q_rps || q_rr);
  always_ff @(posedge clk) q_rr <= hold_m && m_valid && m_rp && x_act;
  assign dl_a   = q_rpp ? m_lin[31:12] : m_slin[31:12];
  wire   m_user = (e_cpl == 2'd3) && !mp.uw[UW_SV_L];
  wire   m_wpri = mp.pwr;
  assign dl_user = m_user;
  assign dl_wr   = q_rpp ? m_wpri : 1'b1;
  assign mlp_p_ld = m_valid && q_rpp && dl_hit;
  assign mlp_s_ld = m_valid && !q_rpp && q_rps && dl_hit;
  assign mlp_vpn  = dl_a;
  // last-page hits touch the TLB LRU bits when the uop leaves M
  wire   m_go   = m_valid && !hold_m;
  assign lt_v   = {1'b0, pg && m_go && q_sacc && q_shit, pg && m_go && q_pacc && q_phit};
  assign lt_sw  = {5'd0, m_slin[14:12], q_sway, m_lin[14:12], q_pway};
  assign ut_tv  = {m_go && q_sacc && q_shit, m_go && q_pacc && q_phit};
  assign ut_tsw = {q_suw, q_puw};

  always_ff @(posedge clk) begin
    if (rst || flush_e) m_valid <= 1'b0;
    else if (!hold_m)   m_valid <= b_adv;
  end
  always_ff @(posedge clk) begin
    if (!hold_m) begin
      mp      <= bp;
      q_pl    <= n_pl;
      q_sl    <= n_sl;
      m_tbad  <= n_tbad;
      m_lin   <= ac_lin;
      m_lin4  <= ac_lin4[31:2];
      m_tset0 <= ac_lin[TLB] ? ac_lin4[TWB-1:TLB+1] : ac_lin[TWB-1:TLB+1];
      m_tset1 <= ac_lin[TLB] ? ac_lin[TWB-1:TLB+1] : ac_lin4[TWB-1:TLB+1];
      m_slin  <= slin;
      m_slin4 <= slin4[31:2];
      // paging (off: identity, all rights)
      q_pacc  <= pgacc;
      m_noacc <= b_oob;
      q_sacc  <= sgacc;
      q_phit  <= php;
      q_shit  <= shp;
      q_pway  <= upl_n[43:42];
      q_sway  <= usl_n[43:42];
      q_puw   <= upl_n[47:44];
      q_suw   <= usl_n[47:44];
      q_rpp   <= pg && pgacc && !php;
      q_rps   <= pg && sgacc && !shp;
      m_pppn  <= pg ? pe_n[24:5] : ac_lin[31:12];
      m_pok   <= !pg || pok_n;
      m_ppcd  <= pg && pe_n[PE_PCD];
      m_sppn  <= pg ? se_n[24:5] : slin[31:12];
      m_sok   <= !pg || sok_n;
      m_ucpl  <= e_cpl;
    end else if (m_valid && q_rpp) begin
      // replay of the primary access: the TLB result (a miss leaves it to E)
      q_rpp <= 1'b0;
      q_phit <= 1'b0;                       // (the lookup touched the LRU bits)
      m_pok <= 1'b0;
      if (dl_hit) begin
        m_pppn <= dl_e[24:5];
        m_pok  <= dl_okp;
        m_ppcd <= dl_e[PE_PCD];
        m_ucpl <= e_cpl;
        // (an untranslated secondary on the same page needs no second lookup)
        if (q_rps && dl_a == m_slin[31:12]) begin
          q_rps <= 1'b0; q_shit <= 1'b0;
          m_sppn <= dl_e[24:5];
          m_sok  <= dl_okw;
        end
      end
    end else if (m_valid && q_rps) begin
      q_rps <= 1'b0;
      q_shit <= 1'b0;
      m_sok <= 1'b0;
      if (dl_hit) begin
        m_sppn <= dl_e[24:5];
        m_sok  <= dl_okw;
        m_ucpl <= e_cpl;
      end
    end
  end
  assign m_uw = mp.uw;       assign m_last = mp.last;     assign m_bnd = mp.bnd;
  assign m_w = mp.w;         assign m_sz = mp.sz;         assign m_msz = mp.msz;
  assign m_op = mp.op;       assign m_pg = mp.pg;         assign m_modrm = mp.modrm;
  assign m_imm = mp.imm;     assign m_disp = mp.disp;     assign m_ip_start = mp.ip_start;
  assign m_ip_next = mp.ip_next;  assign m_sreg = mp.sreg; assign m_rep = mp.rep;
  assign m_os32 = mp.os32;   assign m_as32 = mp.as32;     assign m_lock = mp.lock;
  assign m_pt = mp.pt;       assign m_ptgt = mp.ptgt;     assign m_bid = mp.bid;
  assign m_inj = mp.inj;     assign m_abr = mp.abr;       assign m_off = mp.off;
  assign m_spw = mp.spw;     assign m_spv = mp.spv;       assign m_siw = mp.siw;
  assign m_siv = mp.siv;     assign m_diw = mp.diw;       assign m_div = mp.dvv;
  assign m_cxw = mp.cxw;     assign m_cxv = mp.cxv;       assign m_tgt = mp.tgt;
  assign m_brlin = mp.brlin;   assign m_cxnz = mp.cxnz;
  assign m_ataken = mp.ataken; assign m_aex = mp.aex;     assign m_dmask = mp.dmask;
  assign m_ldm = mp.ldm;     assign m_ld32 = mp.ld32;     assign m_ldt0 = mp.ldt0;
  assign q_ud = mp.ud;       assign q_pchk = mp.pchk;     assign q_pss = mp.pss;
  assign q_schk = mp.schk;     assign q_sss = mp.sss;
  assign q_soff = mp.soff;

  // ---------------------------------------------------------------- A-copy update
  // A-origin writes are younger than the E write / A-executed result in gb (an
  // A-origin destination waits for older E writes of the same register)
  logic [31:0] gn [8];
  always_comb begin
    for (int i = 0; i < 8; i++) gn[i] = gb[i];
    if (adv && !killrep) begin
      if (spw && !uskip) gn[4] = spv;
      if (siw) gn[6] = siv;
      if (diw) gn[7] = div_;
      if (cxw) gn[1] = cxv;
    end
  end
  always_ff @(posedge clk) begin
    if (rst || flush_e) aexp_v <= 1'b0;
    else                aexp_v <= adv && !killrep && aex_ok;
    aexp_r   <= areg;
    aexp_d32 <= c_os32;
    aexp_val <= (amode == AM_EAC) ? off :                 // LEA: the effective address
                xb + xi + dv + {31'd0, asub};      // (xb / xi read ga)
  end
  always_ff @(posedge clk) begin
    if (rst || flush_e) begin
      for (int i = 0; i < 8; i++) g[i] <= e_gpr[i*32 +: 32];
      df <= e_df;
    end else begin
      for (int i = 0; i < 8; i++) g[i] <= gn[i];
      if (edf_en) df <= edf_v;
    end
  end
  // descriptor caches: written by E only (one cycle after the write completes; the
  // segment interlocks cover the delay), so a flush needs no restore.  Reset: real
  // mode, base = selector << 4, limit FFFF, writable data (86Box's real-mode access
  // bytes: data E2, CS 82).  The debug outputs show the next state (the write in flight).
  logic [31:0] sb_n [6], sl_n [6];
  logic [7:0]  sa_n [6];
  logic [5:0]  sd_n, sn_n;
  logic [32:0] cs_lim1_n;
  logic [31:0] ss0_base, ss0_lim;
  logic [7:0]  ss0_acc;
  logic        ss0_db, ss0_nul;
  // (per element: Quartus 17 crashes on variable-index writes to these arrays)
  always_comb begin
    for (int i = 0; i < 6; i++) begin
      sb_n[i] = sb[i]; sl_n[i] = sl[i]; sa_n[i] = sa[i]; sd_n[i] = sd[i]; sn_n[i] = sn[i];
      if (esw_en && (esw_r == 3'(i))) begin
        sb_n[i] = esw_base;
        case (esw_k)
          2'd0: begin                                  // descriptor (protected mode)
            sl_n[i] = esw_lim; sa_n[i] = esw_acc; sd_n[i] = esw_db; sn_n[i] = esw_nul;
          end
          2'd1: begin sa_n[i] = 8'hE2; sn_n[i] = 1'b0; end                  // real mode: limit and B kept
          2'd2: begin sl_n[i] = 32'h0000_FFFF; sa_n[i] = 8'h82; sn_n[i] = 1'b0; end   // real-mode CS
          default: begin                               // V86
            sl_n[i] = 32'h0000_FFFF; sa_n[i] = 8'hE2; sd_n[i] = 1'b0; sn_n[i] = 1'b0;
          end
        endcase
      end
    end
    if (ss_rest) begin
      sb_n[2] = ss0_base; sl_n[2] = ss0_lim; sa_n[2] = ss0_acc; sd_n[2] = ss0_db; sn_n[2] = ss0_nul;
    end
    cs_lim1_n = (esw_en && (esw_r == 3'd1)) ? {1'b0, sl_n[1]} + 33'd1 : cs_lim1;
  end
  // SS descriptor cache at the start of the instruction in E (next state: includes the
  // write of the previous instruction still in flight)
  always_ff @(posedge clk)
    if (ss_snap) begin
      ss0_base <= sb_n[2]; ss0_lim <= sl_n[2]; ss0_acc <= sa_n[2]; ss0_db <= sd_n[2]; ss0_nul <= sn_n[2];
    end
  generate
  for (gi = 0; gi < 6; gi = gi + 1) begin : g_dsc
    assign dbg_sbase[gi*32 +: 32] = sb_n[gi];
    assign dbg_slim[gi*32 +: 32]  = sl_n[gi];
    assign dbg_sattr[gi*10 +: 10] = {sn_n[gi], sd_n[gi], sa_n[gi]};
  end
  endgenerate
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 6; i++) begin
        sb[i] <= (i == 1) ? init_csbase : {12'h0, init_seg[i], 4'h0}; sl[i] <= 32'h0000_FFFF; sa[i] <= (i == 1) ? 8'h82 : 8'hE2;
      end
      sd <= '0; sn <= '0;
      cs_lim1 <= 33'h0_0001_0000;
    end else begin
      for (int i = 0; i < 6; i++) begin sb[i] <= sb_n[i]; sl[i] <= sl_n[i]; sa[i] <= sa_n[i]; end
      sd <= sd_n; sn <= sn_n; cs_lim1 <= cs_lim1_n;
    end
  end
endmodule
