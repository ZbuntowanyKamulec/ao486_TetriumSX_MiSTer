// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium core: pipelined i486-class CPU (no FPU)
//   F (fetch, I$, BTB) -> D1 (queue, prefixes, lengths) -> D2 (decode, ucode ROM)
//   -> A1 (EA, A-regs) -> A2 (linear address, limits, micro-TLB) -> M (D$ read, TLB replay)
//   -> E (execute) -> W (D$ write, store buffer)
`include "tetrium_cfg.svh"
import tetrium_pkg::*;
module tetrium_core #(
    // memory types per 16 KB region below 1 MB (index = address[19:14]; above: the MT_*
    // ranges, else cached):
    //   cached (write-through L1) / write-combining (uncached reads, merged
    //   writes: video RAM) / strongly uncached (neither bit set: MMIO)
    parameter logic [63:0] CACHEABLE = 64'hFFFF_00FF_FFFF_FFFF,
    parameter logic [63:0] WCOMB     = 64'h0000_FF00_0000_0000,
    // memory types above 1 MB: up to 4 ranges {base, mask} of address bits [31:12]
    // (20 bits each, range 0 in the low bits), type {wcomb, cacheable} per range
    parameter int          MT_N    = 0,
    parameter logic [79:0] MT_BASE = '0,
    parameter logic [79:0] MT_MASK = '0,
    parameter logic [7:0]  MT_TYPE = '0,
    // Wishbone data width: 16, 32, 64 or 128 (line fills use the full width)
    parameter int BUS_DW = `BUS_DW,
    // identification (reset EDX, CPUID), see tetrium_cfg.svh
    parameter logic [31:0] CPU_SIG    = `CPU_SIG,
    parameter bit          HAS_CPUID  = `HAS_CPUID
) (
    input  logic        clk,
    input  logic        rst,
    // initial architectural state (applied while rst is high)
    input  logic [31:0] init_gpr [8],
    input  logic [15:0] init_seg [6],        // ES CS SS DS FS GS
    input  logic [31:0] init_csbase,         // CS base (real mode: CS << 4; i486 reset: FFFF0000)
    input  logic [31:0] init_cr0,            // i486 reset: 6000_0010 (caches off: CD, NW)
    input  logic [31:0] init_ip,
    input  logic [15:0] init_flags,
    // Wishbone B4 pipelined master
    output logic        wb_cyc,
    output logic        wb_stb,
    output logic        wb_we,
    output logic [31:$clog2(BUS_DW/8)] wb_adr,   // beat address
    output logic [BUS_DW/8-1:0]        wb_sel,
    output logic [BUS_DW-1:0]          wb_dato,
    output logic [1:0]  wb_tga,      // 0 mem, 1 io, 2 inta
    output logic        wb_lock,     // locked cycles (page-table updates, LOCK / XCHG read-modify-write)
    input  logic [BUS_DW-1:0]          wb_dati,
    input  logic        wb_ack,
    input  logic        wb_stall,
    // interrupts
    input  logic        intr,
    input  logic        nmi,
    input  logic        sstep,
    input  logic        stop_req,
    input  logic        a20m,        // A20 gate: force linear address bit 20 to 0
    // external snoop (DMA writes)
    input  logic        snoop_v,
    input  logic [31:4] snoop_line,
    // cache control: FLUSH (invalidate both caches) in; INVD / WBINVD executed out (one-cycle
    // pulses for external caches: the i486 flush / write-back special cycles)
    input  logic        flush,
    output logic        cflush,
    output logic        cwback,
    // status / debug
    output logic        halted,
    output logic        shutdown,    // triple fault
    output logic        retire,
    output logic        idle,        // pipeline + store buffer empty
    output logic [255:0] dbg_gpr,
    output logic [95:0] dbg_seg,
    output logic [31:0] dbg_ip,
    output logic [31:0] dbg_flags,
    output logic [191:0] dbg_sbase,          // descriptor caches ES CS SS DS FS GS
    output logic [191:0] dbg_slim,
    output logic [59:0]  dbg_sattr,          // {null, B/D, access byte} per segment
    output logic [31:0] dbg_cr0,
    output logic [1:0]  dbg_cpl,
    output logic [31:0] dbg_sys,             // {TR, LDTR} selectors
    output logic [31:0] dbg_perf,
    // testbench lockstep: instruction class of 'retire', stores leaving W in program order
    output logic        dbg_ret_inj,
    output logic        dbg_ret_dbt,         // the retired instruction is followed by a debug trap
    output logic        dbg_nmi_ack,         // an NMI is taken
    output logic [31:0] dbg_dr6,
    output logic [31:0] dbg_dr7,
    output logic        dbg_st_v,
    output logic [1:0]  dbg_st_sz,
    output logic [31:0] dbg_st_lin,
    output logic [31:2] dbg_st_lin4,   // word address of the store's second word (physical)
    output logic [31:0] dbg_st_data,
    output logic        dbg_pw_v,            // page walker write (accessed / dirty bits)
    output logic [31:2] dbg_pw_adr,
    output logic [31:0] dbg_pw_dat
);
  // ------------------------------------------------------------ wires
  // fetch <-> decode
  logic q_full, q_push, q_pt;
  logic [63:0] q_data;
  logic [223:0] q_pd;
  logic [2:0] q_s, q_e;
  logic [31:0] q_ptgt;
  logic [31:3] q_lin;
  logic [31:0] f_cs;                   // code segment base in fetch
  // redirects
  logic f_redir, f_nopred, f_stop, f_rpush, f_rpop;
  logic [31:0] f_rasip;
  logic [1:0] be_kind, ba_kind, t_kind;
  logic       be_ind, be_tcw;
  logic be_inval;
  // branch predictor snapshot ids
  logic [3:0] q_bid, c_bid, m_bid, ba_bid, be_bid, d_bid, d_tbid, t_bid;
  logic rd_br, rd_tk, f_br, f_tk;
  logic [1:0] f_src;                   // redirect source for the predictor snapshot: 0 E, 1 A, 2 D
  logic rd_rpush, rd_rpop, ra_rpush;
  logic [31:0] rd_rip, ra_rip;
  logic [31:0] f_rcs;
  logic [31:0] f_rip;
  logic d_flush, d_keep, d_kill, d_inject;
  // decode -> agu
  logic a_valid, a_vld_eff, a_last, a_repkill, hold_a, a2_valid;
  logic [AF_BITS-1:0] a_af;
  logic [UW_BITS-1:0] a_uw;
  logic [7:0] c_op, c_modrm;
  logic c_pg, c_os32, c_as32, c_lock, c_ud;
  logic [2:0] m_xc;
  logic [1:0] m_amis;
  logic       m_xs;
  logic [$clog2(`DC_KB * 1024 / `DC_WAYS) - $clog2(`LINE_B) - 2:0] m_tset0, m_tset1;   // D-cache tag sets per line-parity bank
  logic m_as32;
  logic [31:0] e_t0, e_idtb, e_gdtb, e_ldtb, e_trb, e_trl;
  logic        e_byp_t0, e_byp_ok, m_ldt0;
  logic [31:0] c_disp, c_imm;
  logic [31:0] c_ip_start, c_ptgt;
  logic [31:0] c_ip_nx;
  logic [31:0] q_ip;
  logic d_qempty;
  logic c_pt, c_inj;
  logic [5:0] c_srdm;
  logic [2:0] c_sreg;
  logic [1:0] c_rep;
  logic d_redir;
  logic [31:0] d_redir_ip;
  logic [31:0] d_btb_lin;
  // agu -> mem/exec
  logic [9:0] ac_row, ac_row1;
  logic [44:0] a_sel;
  logic m_valid, m_last, m_bnd, m_w, m_pt, m_inj, m_cxnz, m_ataken, m_aex, m_pg, m_os32, m_lock;
  logic [UW_BITS-1:0] m_uw;
  logic [7:0] m_op, m_modrm;
  logic [31:0] m_imm, m_disp, m_off;
  logic [31:0] m_ip_start, m_ip_next, m_ptgt, m_tgt;
  logic m_tbad;
  logic [2:0] m_sreg;
  logic [1:0] m_rep;
  logic [2:0] m_abr;
  logic [31:0] m_lin, m_slin, m_brlin;
  logic [31:2] m_lin4, m_slin4;
  logic m_spw, m_siw, m_diw, m_cxw;
  logic [31:0] m_spv, m_siv, m_div, m_cxv;
  logic [1:0]  m_sz, m_msz;
  logic [15:0] m_dmask, e_dmask;
  logic [7:0]  m_ldm, e_dm_e, e_byp_m;
  logic        m_ld32, e_byp_32;
  logic [31:0] e_byp_d;
  logic        ce_push, ce_pop;
  logic [31:0] ce_rip;
  logic ra_v, ba_we, ba_taken, ba_inval;
  logic [31:0] ra_cs;
  logic [31:0] ra_ip, ba_tgt;
  logic [31:0] ba_lin;
  // mem
  logic hold_m, m_adv;
  logic [31:0] m_data, x_data;
  logic [3:0] x_hb;
  logic m_ldwait, x_act, x_hit, x_cached, x_fill, x_fill_done, du_req;
  logic [31:0] x_lin;
  logic [31:2] x_lin4;
  logic [1:0]  x_sz;
  logic dfill_req;
  logic [31:4] dfill_line;
  // exec
  logic hold_e, hold_w, e_valid, e_st_v;
  logic [31:2] e_st_a0, e_st_a1;
  logic [3:0]  e_st_be0, e_st_be1;
  logic [255:0] e_gpr;
  logic [95:0] e_seg;
  logic e_df;
  logic [31:0] e_flags;
  logic e_pm, e_csd, e_iochk, e_pgq;
  logic [1:0] e_cpl;
  logic [31:0] e_cr0;
  logic [31:0] e_ip;
  logic esw_en, edf_en, edf_v;
  logic [2:0] esw_r;
  logic [23:0] ewh0, ewh1;
  logic [31:0] ewv0, ewv1;
  logic [1:0]  esw_k;
  logic [31:0] esw_base, esw_lim;
  logic [7:0]  esw_acc;
  logic        esw_db, esw_nul;
  logic        ss_snap, ss_rest;
  logic w_nowr;
  logic w_v, w_two, w_hlo, w_hhi, e_st_hlo, e_st_hhi;
  logic [1:0] w_wlo, w_whi, e_st_wlo, e_st_whi, w_sz;
  logic [31:0] e_st_lin;
  logic [31:2] e_st_lin4;
  logic [31:0] w_lin;
  logic [31:2] w_lin4;
  logic [31:0] w_data;
  logic flush_r, rd_fetch, rd_inject, rd_stop;
  logic [31:0] rd_cs;
  logic [31:0] rd_ip;
  logic [7:0] rd_op;
  logic [4:0] rd_injid;
  logic [31:0] rd_imm, rd_ips, rd_ipn;
  logic rd_os32, rd_int, rd_ecvx, c_ecv, e_tss32, e_ldtw;
  logic [4:0] rd_cnt;
  logic [31:0] a_ssbase;
  logic [47:0] a_sacc;
  logic be_we, be_taken;
  logic [31:0] be_lin;
  logic [31:0] be_tgt;
  logic io_req, io_we, io_inta, io_done;
  logic [1:0]  io_sz;
  logic [15:0] io_port;
  logic [31:0] io_wdata;
  // wb stage
  logic l_st_v;
  logic [31:2] w_a0, w_a1, l_a0, l_a1;
  logic [3:0]  w_be0, w_be1, l_be0, l_be1;
  logic [31:0] w_d0, w_d1, l_d0, l_d1;
  logic [15:0] m_fwd;
  logic sb_v, sb_pop, sb_empty, sb_qempty, wr_busy;
  logic [31:2] sb_adr;
  logic [3:0] sb_be;
  logic [31:0] sb_dat;
  assign sb_empty = sb_qempty && !wr_busy;
  // biu
  logic if_req, if_we, if_done, df_we, df_done, du_done;
  logic [31:4] if_line;
  logic [1:0] f_row, f_hm;
  logic [63:0] f_data;
  logic [31:0] rdata32;
  logic smc_hit, snp_hit, smc_hold;

  // ---------------------------------------------------------------- paging (tetrium_mmu)
  wire         pgon = e_cr0[31] && e_cr0[0];
  // fetch's copies (one cycle late: PG and the CPL change only with serializing
  // instructions, whose flush and refetch come after; keeps E's registers off the
  // fetch hit path)
  logic        pg_f, cpl3_f;
  logic        rm_f;                    // real mode / V86 (fetch: far predictions)
  logic [15:0] csr_sel;
  always_ff @(posedge clk) begin pg_f <= pgon; cpl3_f <= (e_cpl == 2'd3); rm_f <= !e_pm; end
  logic        mm_flush, mm_invlpg, mm_lpkill, tr_we, tr_sel7;
  logic [31:12] mm_inva, e_cr3;
  logic [31:0] tr_d, tr6, tr7;
  logic [31:12] dl_a, fl_a, e_pa, mlp_vpn;
  logic        dl_hit, fl_hit, fl_touch, m_rp, mlp_p_ld, mlp_s_ld, dl_user, dl_wr, dl_okp, dl_okw;
  logic [1:0]  dl_way, fl_way;
  logic [41:0] dl_e, fl_e;
  logic [2:0]  a_lt_v;
  logic [14:0] a_lt_sw;
  logic        f_lt_v;
  logic [4:0]  f_lt_sw;
  logic [(1<<`UT_SB)*`UT_WAYS-1:0]    ut_v;
  logic [(1<<`UT_SB)*`UT_WAYS*42-1:0] ut_e;
  logic [(1<<`UT_SB)*`UT_WAYS*3-1:0]  ut_lo;
  logic [(1<<`UT_SB)*`UT_WAYS*2-1:0]  ut_w;
  logic [1:0]  ut_tv;
  logic [7:0]  ut_tsw;
  logic        tw_v, lpf_kill;
  logic [4:0]  tw_sw;
  logic        e_preq, e_pwr, e_puser, e_pcpl3, e_pdone, f_preq, f_pacc, f_pdone, w_ok;
  logic [2:0]  w_err, ff_err;
  logic [41:0] w_e;
  logic [1:0]  w_way;
  logic        e_lpp_ld, e_lps_ld, x_pcd, ff_flt, ff_go;
  logic [31:0] ff_lin;
  logic [31:12] m_pppn, m_sppn;
  logic        m_pok, m_ppcd, m_sok, e_st_xp;
  logic [1:0]  m_ucpl;
  logic        pw_req, pw_we, pw_lock, pw_done, pw_snp;
  logic [31:2] pw_adr;
  logic [31:0] pw_wdat;
  logic [31:4] pw_snl;
  logic        d_starve, lk_hold, m_noacc;
  logic [15:0] e_gdtl, e_idtl;
  logic [31:0] e_ldtl;
  // fetch may walk / fault only when nothing older is in flight and decode waits for it
  logic        fe_drained;
  always_ff @(posedge clk)
    fe_drained <= !rst && started && d_starve && !a_valid && !a2_valid && !m_valid && !e_valid && !flush_r;
  assign ff_go = ff_flt && fe_drained;
  // cache line invalidations: external snoops, then the walker's page-table writes
  logic        psn_v;
  logic [31:4] psn_l;
  always_ff @(posedge clk) begin
    if (rst) psn_v <= 1'b0;
    else if (pw_snp) begin psn_v <= 1'b1; psn_l <= pw_snl; end
    else if (!snoop_v) psn_v <= 1'b0;
  end
  wire        isn_v = snoop_v || psn_v;
  // CR0.NW: the D-cache ignores external snoops (the walker's own writes still invalidate)
  wire        nw    = e_cr0[29];
  wire        dsn_v = (snoop_v && !nw) || psn_v;
  wire [31:4] dsn_l = (snoop_v && !nw) ? snoop_line : psn_l;
  // INVD / WBINVD / FLUSH: both caches sweep their tags
  logic       e_cinv, e_cwb, dc_ibusy, ic_ibusy;
  wire        inv_all = e_cinv || flush;
  assign cflush = e_cinv;
  assign cwback = e_cinv && e_cwb;
  wire [31:4] isn_l = snoop_v ? snoop_line : psn_l;
  tetrium_mmu u_mmu (
      .clk, .rst, .wp(e_cr0[16]), .a20m, .cr3(e_cr3),
      .flush_all(mm_flush), .invlpg_v(mm_invlpg), .invlpg_a(mm_inva), .lp_kill(mm_lpkill),
      .tr_we, .tr_sel7, .tr_d, .tr6, .tr7,
      .dl_a, .dl_touch(m_rp), .dl_hit, .dl_way, .dl_e, .dl_user, .dl_wr, .dl_okp, .dl_okw,
      .fl_a, .fl_touch, .fl_hit, .fl_way, .fl_e,
      .lt_v({f_lt_v, a_lt_v[1:0]}), .lt_sw({f_lt_sw, a_lt_sw[9:0]}),
      .ut_v, .ut_e, .ut_lo, .ut_w, .ut_tv, .ut_tsw,
      .lpp_ld(e_lpp_ld || mlp_p_ld), .lps_ld(e_lps_ld || mlp_s_ld),
      .lp_vpn((e_lpp_ld || e_lps_ld) ? e_pa : mlp_vpn),
      .lp_e((e_lpp_ld || e_lps_ld) ? w_e : dl_e),
      .lp_way((e_lpp_ld || e_lps_ld) ? w_way : dl_way),
      .tw_v, .tw_sw, .lpf_kill,
      .e_req(e_preq), .e_a(e_pa), .e_wr(e_pwr), .e_user(e_puser), .e_cpl3(e_pcpl3), .e_done(e_pdone),
      .f_req(f_preq), .f_a(fl_a), .f_user(e_cpl == 2'd3), .f_acc(f_pacc), .f_done(f_pdone),
      .w_ok, .w_err, .w_e, .w_way,
      .io_ok, .pw_req, .pw_we, .pw_lock, .pw_adr, .pw_wdat, .pw_done, .pw_rdata(rdata32),
      .snp_v(pw_snp), .snp_line(pw_snl));

  // ------------------------------------------------------------ redirect arbitration
  // priority: E flush > A redirect > D (bad prediction) redirect
  logic started;
  always_ff @(posedge clk) started <= rst ? 1'b0 : 1'b1;
  wire boot = !started;     // first cycle after reset: start fetching at CS:IP

  always_comb begin
    f_redir = 1'b0; f_nopred = 1'b0; f_stop = 1'b0; f_rcs = rd_cs; f_rip = rd_ip;
    f_rpush = 1'b0; f_rpop = 1'b0; f_rasip = rd_rip;
    f_br = 1'b0; f_tk = 1'b0; f_src = 2'd0;
    d_flush = 1'b0; d_keep = 1'b0; d_kill = 1'b0; d_inject = 1'b0;
    if (boot) begin
      f_redir = 1'b1; f_rcs = init_csbase; f_rip = init_ip;
      d_flush = 1'b1; d_kill = 1'b1;
    end else if (flush_r) begin
      f_redir = rd_fetch; f_stop = rd_stop;
      f_rpush = rd_fetch && rd_rpush; f_rpop = rd_fetch && rd_rpop;
      f_br = rd_br; f_tk = rd_tk;
      d_flush = 1'b1; d_kill = 1'b1; d_inject = rd_inject;
    end else if (ra_v) begin
      f_redir = 1'b1; f_rcs = ra_cs; f_rip = ra_ip;
      f_rpush = ra_rpush; f_rasip = ra_rip;
      f_br = !ba_inval; f_tk = ba_taken; f_src = 2'd1;
      d_flush = 1'b1; d_kill = 1'b1;
    end else if (d_redir) begin
      f_redir = 1'b1; f_rcs = rm_f ? {12'h0, csr_sel, 4'h0} : f_cs; f_rip = d_redir_ip; f_nopred = 1'b1;
      f_src = 2'd2;
      d_flush = 1'b1; d_keep = 1'b1;
    end
  end

  // BTB training arbitration: E first; an A training that loses the write port
  // waits in a one-entry buffer (else a CALL trained in A right behind a RET
  // trained in E would never enter the BTB)
  logic        pa_v, pa_taken, pa_inval;
  logic [31:0] pa_lin, pa_tgt;
  logic [1:0]  pa_kind;
  logic [3:0]  pa_bid;
  always_ff @(posedge clk) begin
    if (rst) pa_v <= 1'b0;
    else if (ba_we && (be_we || pa_v)) pa_v <= 1'b1;      // (a newer one replaces a waiting one)
    else if (!be_we) pa_v <= 1'b0;
    if (ba_we && (be_we || pa_v)) begin
      pa_taken <= ba_taken; pa_inval <= ba_inval; pa_lin <= ba_lin; pa_tgt <= ba_tgt;
      pa_kind <= ba_kind; pa_bid <= ba_bid;
    end
  end
  logic        t_we, t_taken, t_inval;
  logic [31:0] t_lin;
  logic [31:0] t_tgt;
  always_comb begin
    t_we = 1'b0; t_taken = be_taken; t_lin = be_lin; t_tgt = be_tgt; t_kind = be_kind;
    t_bid = be_bid; t_inval = be_inval;
    if (be_we) begin
      t_we = 1'b1;
    end else if (pa_v) begin
      t_we = 1'b1; t_taken = pa_taken; t_inval = pa_inval; t_lin = pa_lin; t_tgt = pa_tgt; t_kind = pa_kind;
      t_bid = pa_bid;
    end else if (ba_we) begin
      t_we = 1'b1; t_taken = ba_taken; t_inval = ba_inval; t_lin = ba_lin; t_tgt = ba_tgt; t_kind = ba_kind;
      t_bid = ba_bid;
    end else if (d_redir) begin
      t_we = 1'b1; t_inval = 1'b1; t_lin = d_btb_lin; t_kind = 2'd0; t_bid = d_tbid;
    end
  end

  wire io_ok      = !w_v && sb_empty;
  // 8-byte code blocks touched by a store: its first byte's and its last byte's
  wire [31:3] e_l1 = (e_st_be1 != 4'h0 && e_st_lin[2]) ? e_st_lin4[31:3] : e_st_lin[31:3];
  wire [31:3] w_l1 = (w_be1 != 4'h0 && w_lin[2]) ? w_lin4[31:3] : w_lin[31:3];
  assign idle     = !e_valid && io_ok && !m_valid && !a2_valid && !a_valid;

  // ------------------------------------------------------------ stages
  tetrium_fetch #(.FILL64(BUS_DW >= 64)) u_fetch (
      .clk, .rst,
      .redir_v(f_redir), .redir_csb(f_rcs), .rm(rm_f), .csr_bid(d_bid), .csr_sel, .redir_ip(f_rip), .redir_nopred(f_nopred), .stop(f_stop), .a20m,
      .redir_rpush(f_rpush), .redir_rpop(f_rpop), .redir_rip(f_rasip),
      .rid_e(be_bid), .rid_a(ba_bid), .rid_d(d_bid), .redir_src(f_src), .ce_push, .ce_pop, .ce_rip,
      .rlin_e(be_lin[2:0]), .rlin_a(ba_lin[2:0]), .redir_br(f_br), .redir_tk(f_tk),
      .q_full, .q_push, .q_data, .q_pd, .q_s, .q_e, .q_pt, .q_ptgt, .q_lin, .q_ip, .q_bid,
      .btb_bid(t_bid), .btb_we(t_we), .btb_lin(t_lin), .btb_taken(t_taken), .btb_inval(t_inval), .btb_tgt(t_tgt), .btb_kind(t_kind), .btb_ind(be_we && be_ind), .btb_tcw(be_we && be_tcw),
      .fill_req(if_req), .fill_line(if_line), .fill_we(if_we), .fill_row(f_row), .fill_hm(f_hm),
      .fill_data(f_data), .fill_done(if_done),
      .snp_v(isn_v), .snp_line(isn_l),
      .wsn_v(w_v && !hold_w), .wsn_l0(w_lin[31:3]), .wsn_l1(w_l1),
      .est_v(e_st_v), .est_l0(e_st_lin[31:3]), .est_l1(e_l1), .hold_w,
      .smc_hit, .snp_hit, .smc_hold,
      .pg(pg_f), .cpl3(cpl3_f), .fl_a, .fl_touch, .fl_hit, .fl_way, .fl_e, .lpf_kill, .tw_v, .tw_sw,
      .lt_v(f_lt_v), .lt_sw(f_lt_sw), .fe_drained, .f_req(f_preq), .f_acc(f_pacc), .f_done(f_pdone),
      .w_ok, .w_err, .w_e, .w_way, .ff_flt, .ff_err, .ff_lin,
      .inv_all, .inv_busy(ic_ibusy), .cs_o(f_cs));

  tetrium_decode u_dec (
      .clk, .rst, .cs_d(e_csd), .pm(e_pm), .iochk(e_iochk),
      .q_push, .q_data, .q_pd, .q_s, .q_e, .q_pt, .q_ptgt, .q_lin, .q_ip, .q_bid, .q_full,
      .flush_front(d_flush), .flush_keep_pfx(d_keep), .kill_a(d_kill),
      .inject(d_inject), .inject_id(rd_injid), .inject_imm(rd_imm), .inject_ips(rd_ips), .inject_ipn(rd_ipn),
      .inject_os32(rd_os32), .inject_op(rd_op), .inject_int(rd_int), .inject_ecv(rd_ecvx), .inject_cnt(rd_cnt), .c_ecv,
      .hold_a, .a_repkill, .a_valid, .a_vld_eff, .a_last, .a_af, .a_sel, .a_uw,
      .c_op, .c_pg, .c_modrm, .c_disp, .c_imm_o(c_imm), .c_ip_start, .c_ip_nx, .c_rep,
      .c_os32, .c_as32, .c_lock, .c_ud, .c_sreg, .c_pt, .c_ptgt, .c_bid, .c_inj, .c_srdm,
      .d_redir, .d_redir_ip, .d_btb_lin, .d_bid, .d_tbid, .q_empty(d_qempty), .d_starve);

  tetrium_agu u_agu (
      .clk, .rst,
      .a_vld_eff, .a_last, .a_af, .a_sel, .a_uw,
      .c_op, .c_pg, .c_modrm, .c_disp, .c_imm, .c_ip_start, .c_ip_nx, .c_rep,
      .c_os32, .c_as32, .c_lock, .c_ud, .c_sreg, .c_pt, .c_ptgt, .c_bid, .c_inj, .c_srdm,
      .a_repkill, .hold_m, .hold_a, .a20m, .init_seg, .init_csbase, .flush_e(flush_r || rst), .e_gpr, .e_df, .e_pm, .e_t0, .e_byp_t0, .e_idtb, .e_gdtb, .e_ldtb, .e_trb, .e_trl, .e_tss32, .c_ecv, .a_ssbase, .a_sacc, .e_ldtw,
      .ewh0, .ewh1, .ewv0, .ewv1,
      .esw_en, .esw_r, .esw_k, .esw_base, .esw_lim, .esw_acc, .esw_db, .esw_nul, .edf_en, .edf_v, .ss_snap, .ss_rest,
      .m_dmask_in(m_valid ? m_dmask : 16'd0), .e_dmask_in(e_dmask),
      .e_dm_e, .e_byp_m, .e_byp_ok, .e_byp_32, .e_byp_d, .m_ldm, .m_ld32, .m_ldt0, .a2_valid,
      .ac_row, .ac_row1,
      .m_valid, .m_uw, .m_last, .m_bnd, .m_w, .m_sz, .m_msz, .m_op, .m_pg, .m_modrm, .m_imm, .m_disp, .m_ip_start,
      .m_ip_next, .m_sreg, .m_rep, .m_os32, .m_as32, .m_lock, .m_pt, .m_ptgt, .m_bid, .m_inj, .m_abr, .m_lin, .m_lin4, .m_tset0, .m_tset1, .m_off,
      .m_slin, .m_slin4, .m_spw, .m_spv, .m_siw, .m_siv, .m_diw, .m_div, .m_cxw, .m_cxv,
      .m_tgt, .m_tbad, .m_brlin, .m_cxnz, .m_ataken, .m_aex, .m_dmask, .m_amis, .m_xc, .m_xs,
      .pg(e_pgq), .wp(e_cr0[16]), .e_cpl, .ut_v, .ut_e, .ut_lo, .ut_w, .ut_tv, .ut_tsw,
      .dl_a, .dl_hit, .dl_e, .dl_user, .dl_wr, .dl_okp, .dl_okw, .m_rp, .x_act, .mlp_p_ld, .mlp_s_ld, .mlp_vpn, .lt_v(a_lt_v), .lt_sw(a_lt_sw),
      .m_pppn, .m_pok, .m_ppcd, .m_sppn, .m_sok, .m_ucpl, .e_gdtl, .e_idtl, .e_ldtl, .m_noacc,
      .ra_v, .ra_csb(ra_cs), .ra_ip, .ba_we, .ba_lin, .ba_taken, .ba_inval, .ba_tgt, .ba_kind, .ba_bid, .ra_rpush, .ra_rip,
      .dbg_sbase, .dbg_slim, .dbg_sattr);

  tetrium_mem #(.CACHEABLE(CACHEABLE), .WCOMB(WCOMB), .MT_N(MT_N), .MT_BASE(MT_BASE), .MT_MASK(MT_MASK), .MT_TYPE(MT_TYPE)) u_mem (
      .clk, .rst,
      .ac_row, .ac_row1, .m_valid, .m_uw, .m_sz(m_msz), .m_lin, .m_lin4, .m_tset0, .m_tset1,
      .m_ppn(m_pppn), .m_pok, .m_pcd(m_ppcd), .m_rp, .pg(e_pgq), .e_st_xp, .m_noacc,
      .hold_e, .flush_e(flush_r), .hold_m, .m_adv,
      .e_st_v, .e_st_a0, .e_st_a1, .e_st_be0, .e_st_be1,
      .w_v, .w_a0, .w_a1, .w_be0, .w_be1, .w_d0, .w_d1, .w_hlo, .w_hhi, .w_wlo, .w_whi,
      .l_st_v, .l_a0, .l_a1, .l_be0, .l_be1, .l_d0, .l_d1,
      .e_st_lin, .e_st_lin4, .e_st_hlo, .e_st_hhi, .e_st_wlo, .e_st_whi,
      .x_act, .x_lin, .x_lin4, .x_sz, .x_pcd, .x_data, .x_hit, .x_hb, .x_cached, .x_fill, .x_fill_done,
      .fill_req(dfill_req), .fill_line(dfill_line), .fill_we(df_we), .fill_row(f_row), .fill_hm(f_hm),
      .fill_data(f_data), .fill_done(df_done),
      .inv_all, .inv_busy(dc_ibusy), .snp_v(dsn_v), .snp_line(dsn_l),
      .m_data, .m_ldwait, .m_fwd);

  tetrium_exec #(.HAS_CPUID(HAS_CPUID), .CPU_SIG(CPU_SIG)) u_exec (
      .clk, .rst,
      .init_gpr, .init_seg, .init_csbase, .init_cr0, .init_ip, .init_flags,
      .m_adv, .m_valid, .m_uw, .m_last, .m_bnd, .m_w, .m_sz, .m_msz, .m_op, .m_pg, .m_modrm, .m_imm, .m_disp, .m_ip_start,
      .m_ip_next, .m_sreg, .m_rep, .m_as32, .m_os32, .m_pt, .m_ptgt, .m_bid, .m_inj, .m_abr, .m_off,
      .m_spw, .m_spv, .m_siw, .m_siv, .m_diw, .m_div, .m_cxw, .m_cxv,
      .m_tgt, .m_tbad, .m_brlin, .m_cxnz, .m_ataken, .m_aex, .m_dmask, .m_ldm, .m_ld32, .m_ldt0, .m_amis, .m_xc, .m_xs, .m_data, .m_ldwait, .m_fwd,
      .m_lin, .m_lin4, .m_slin, .m_slin4,
      .m_pppn, .m_pok, .m_ppcd, .m_sppn, .m_sok, .m_ucpl, .e_st_xp,
      .mm_flush, .mm_invlpg, .mm_inva, .mm_lpkill, .e_cr3, .tr_we, .tr_sel7, .tr_d, .tr6, .tr7,
      .e_preq, .e_pa, .e_pwr, .e_puser, .e_pcpl3, .e_pdone, .w_ok, .w_err, .w_e, .e_lpp_ld, .e_lps_ld, .x_pcd,
      .ff_go, .ff_err, .ff_lin, .m_lock, .lk_hold, .e_gdtl, .e_idtl, .e_ldtl, .m_noacc,
      .x_act, .x_lin, .x_lin4, .x_sz, .x_data, .x_hit, .x_hb, .x_cached, .x_fill, .x_fill_done,
      .du_req, .du_done, .du_data(rdata32), .l_st_v,
      .hold_e, .hold_w, .io_ok, .e_cinv, .e_cwb, .c_busy(dc_ibusy || ic_ibusy), .smc_hit, .snp_hit, .e_busy_valid(e_valid), .e_dmask, .ce_push, .ce_pop, .ce_rip, .e_dm_e, .e_byp_m, .e_byp_ok, .e_byp_32, .e_byp_d, .e_st_v, .e_st_a0, .e_st_a1, .e_st_be0, .e_st_be1,
      .e_gpr, .e_seg, .e_df, .e_t0, .e_byp_t0, .e_idtb, .e_gdtb, .e_ldtb, .e_trb, .e_trl, .e_tss32, .e_ldtw, .a_ssbase, .a_sacc, .e_flags, .e_ip, .e_pm, .e_cpl, .e_csd, .e_iochk, .e_pgq, .e_cr0, .e_sysdbg(dbg_sys),
      .ewh0, .ewh1, .ewv0, .ewv1,
      .esw_en, .esw_r, .esw_k, .esw_base, .esw_lim, .esw_acc, .esw_db, .esw_nul, .edf_en, .edf_v, .ss_snap, .ss_rest,
      .e_st_lin, .e_st_lin4, .e_st_hlo, .e_st_hhi, .e_st_wlo, .e_st_whi, .w_hlo, .w_hhi, .w_wlo, .w_whi,
      .w_v, .w_lin, .w_lin4, .w_sz, .w_data, .w_two, .w_nowr, .w_d0, .w_d1,
      .flush_r, .rd_fetch, .rd_csb(rd_cs), .rd_ip, .rd_inject, .rd_injid, .rd_imm, .rd_ips, .rd_ipn, .rd_os32, .rd_op, .rd_int, .rd_ecvx, .rd_cnt,
      .rd_stop,
      .be_we, .be_lin, .be_taken, .be_tgt, .be_kind, .be_ind, .be_tcw, .be_inval, .be_bid, .rd_br, .rd_tk,
      .rd_rpush, .rd_rpop, .rd_rip,
      .io_req, .io_we, .io_inta, .io_port, .io_sz, .io_wdata, .io_done, .io_rdata(rdata32),
      .intr, .nmi, .sstep, .stop_req, .halted, .shutdown, .retire, .retire_inj(dbg_ret_inj), .retire_dbt(dbg_ret_dbt), .nmi_ack(dbg_nmi_ack), .dbg_dr6, .dbg_dr7);

  tetrium_wb #(.CACHEABLE(CACHEABLE), .WCOMB(WCOMB), .MT_N(MT_N), .MT_BASE(MT_BASE), .MT_MASK(MT_MASK), .MT_TYPE(MT_TYPE)) u_wb (
      .clk, .rst,
      .w_v, .w_lin, .w_lin4, .w_sz, .w_data, .w_two, .w_nowr, .hold_w, .ext_hold(smc_hold),
      .w_skip0(nw && w_hlo), .w_skip1(nw && w_hhi),
      .w_a0, .w_a1, .w_be0, .w_be1, .w_d0, .w_d1,
      .l_st_v, .l_a0, .l_a1, .l_be0, .l_be1, .l_d0, .l_d1,
      .sb_v, .sb_adr, .sb_be, .sb_dat, .sb_pop, .sb_qempty);

  tetrium_biu #(.BUS_DW(BUS_DW)) u_biu (
      .clk, .rst,
      .sb_v, .sb_adr, .sb_be, .sb_dat, .sb_pop, .wr_busy,
      .if_req, .if_ok(!w_v), .if_line, .if_we, .if_done,
      .df_req(dfill_req), .df_line(dfill_line), .df_we, .df_done, .f_row, .f_hm, .f_data,
      .du_req, .du_lin(x_lin), .du_lin4(x_lin4), .du_sz(x_sz), .du_done,
      .pw_req, .pw_we, .pw_lock, .pw_adr, .pw_wdat, .pw_done, .lk_hold, .wb_lock,
      .io_req, .io_we, .io_inta, .io_port, .io_sz, .io_wdata, .io_done, .rdata32,
      .wb_cyc, .wb_stb, .wb_we, .wb_adr, .wb_sel, .wb_dato, .wb_tga, .wb_dati, .wb_ack, .wb_stall);

  assign dbg_pw_v    = pw_done && pw_we;
  assign dbg_pw_adr  = pw_adr;
  assign dbg_pw_dat  = pw_wdat;
  assign dbg_st_v    = w_v && !hold_w && !w_nowr;
  assign dbg_st_sz   = w_sz;
  assign dbg_st_lin  = w_lin;
  assign dbg_st_lin4 = w_lin4;
  assign dbg_st_data = w_data;
  assign dbg_gpr   = e_gpr;
  assign dbg_seg   = e_seg;
  assign dbg_ip    = e_ip;
  assign dbg_flags = e_flags;
  assign dbg_cr0   = e_cr0;
  assign dbg_cpl   = e_cpl;
`ifdef SIM
  assign dbg_perf = {
      7'd0,
      ba_we && be_we && pa_v,                    // 24 A BTB training replaced while waiting
      ra_v && !flush_r && ba_inval,              // 23 effective A redirect: not a branch (stale BTB)
      ra_v && !flush_r,                          // 22 effective A redirect
      flush_r && !be_we,                         // 21 E redirect: not a branch (serializing, fault, ...)
      flush_r && be_we && be_kind != 2'd2,       // 20 E redirect: jump / Jcc / call
      flush_r && be_we && be_kind == 2'd2,       // 19 E redirect: return
      q_push && q_pt,                            // 18 predicted-taken fetch block
      u_exec.ldwait && u_exec.v,                 // 17 E waiting for a late load
      d_qempty,                                  // 16 decode queue empty
      retire,                                    // 15
      dfill_req,                                 // 14 D$ fill
      if_req,                                    // 13 I$ fill
      d_redir,                                   // 12
      ra_v,                                      // 11
      flush_r,                                   // 10
      q_push,                                    // 9
      u_dec.ir_issue,                               // 8 new instruction issued
      a_vld_eff,                                 // 7
      a_vld_eff && u_agu.sb_stall,               // 6 scoreboard stall
      u_exec.lst == 3'd4,                         // 5 E waiting for a line fill
      hold_w,                                    // 4
      u_exec.act && !u_exec.done,                // 3 E multi-cycle busy
      e_valid,                                   // 2
      m_valid,                                   // 1
      u_exec.complete                            // 0 uop completed
  };
`else
  assign dbg_perf = '0;
`endif
endmodule
