// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium memory stage (M) + L1 data cache
//  * DC_KB, DC_WAYS-way set associative (tree PLRU), LINE_B lines (tetrium_cfg.svh),
//    write-through / no-write-allocate; all ways are read in parallel and the
//    hit way is selected after the byte select
//  * data array = 2 banks (even / odd 32-bit word) x 4 byte lanes; any
//    access of 1, 2 or 4 contiguous bytes (unaligned, across lines) is one read
//  * separate write port (W stage) => loads in M and stores in W proceed
//    in the same cycle (1-cycle RMW)
//  * M never stalls the pipeline by itself: a load that misses, conflicts
//    with an older in-flight store or is uncacheable is passed to E with
//    'ldwait' set; E then re-reads through the late port (x_*) and requests
//    line fills / uncached reads itself.  This keeps the stall network short.
//  * W-stage store hit check is done here, at W time, on its own tag ports.
import tetrium_pkg::*;
`include "tetrium_cfg.svh"
module tetrium_mem #(
    parameter logic [63:0] CACHEABLE = 64'hFFFF_00FF_FFFF_FFFF,   // per 16 KB region below 1 MB
    parameter logic [63:0] WCOMB     = 64'h0000_FF00_0000_0000,
    // memory types above 1 MB: up to 4 ranges {base, mask} of address bits [31:12]
    // (20 bits each, range 0 in the low bits), type {wcomb, cacheable} per range
    parameter int          MT_N    = 0,
    parameter logic [79:0] MT_BASE = '0,
    parameter logic [79:0] MT_MASK = '0,
    parameter logic [7:0]  MT_TYPE = '0
) (
    input  logic        clk,
    input  logic        rst,
    // from A
    input  logic [9:0]  ac_row,       // odd-word bank row  (row of lin)
    input  logic [9:0]  ac_row1,      // even-word bank row (row of lin + 4)
    input  logic        m_valid,
    input  logic [UW_BITS-1:0] m_uw,
    input  logic [1:0]  m_sz,         // 0: 1 byte, 1: 2 bytes, 2: 4 bytes
    input  logic [31:0] m_lin,        // linear address of the first byte
    input  logic [31:2] m_lin4,       // word address of the next word
    input  logic [$clog2(`DC_KB * 1024 / `DC_WAYS) - $clog2(`LINE_B) - 2:0] m_tset0, m_tset1,   // tag sets per line-parity bank (lin / lin + 4)
    // paging: physical page of the access (A2 last-page check / M replay), usable for the
    // uop's access (rights, D), PCD; M replays a last-page miss (holds, re-reads its rows)
    input  logic [31:12] m_ppn,
    input  logic        m_pok,
    input  logic        m_pcd,
    input  logic        m_rp,
    input  logic        pg,           // paging on (else the next word's page is its own)
    input  logic        e_st_xp,      // the store in E is not translated yet: loads wait
    input  logic        m_noacc,      // the load is beyond its table: not done
    // pipeline control
    input  logic        hold_e,
    input  logic        flush_e,
    output logic        hold_m,
    output logic        m_adv,
    // store completing in E (forwarded by E one cycle later, from W)
    input  logic        e_st_v,
    input  logic [31:2] e_st_a0,
    input  logic [31:2] e_st_a1,
    input  logic [3:0]  e_st_be0,
    input  logic [3:0]  e_st_be1,
    // W stage store (cache write port, forwarding), aligned word entries
    input  logic        w_v,
    input  logic [31:2] w_a0,
    input  logic [31:2] w_a1,
    input  logic [3:0]  w_be0,
    input  logic [3:0]  w_be1,
    input  logic [31:0] w_d0,
    input  logic [31:0] w_d1,
    input  logic        w_hlo,        // store hit (checked in E): first word's line
    input  logic        w_hhi,        //                           second word's line
    input  logic [1:0]  w_wlo,        // ... and its way
    input  logic [1:0]  w_whi,
    // store accepted last cycle (forwarding: its cache write is not readable yet)
    input  logic        l_st_v,
    input  logic [31:2] l_a0,
    input  logic [31:2] l_a1,
    input  logic [3:0]  l_be0,
    input  logic [3:0]  l_be1,
    input  logic [31:0] l_d0,
    input  logic [31:0] l_d1,
    // E-stage store address (hit check)
    input  logic [31:0] e_st_lin,
    input  logic [31:2] e_st_lin4,
    output logic        e_st_hlo,
    output logic        e_st_hhi,
    output logic [1:0]  e_st_wlo,     // D-cache way of the store's words
    output logic [1:0]  e_st_whi,
    // E late port: re-read for a waiting load, line fill
    input  logic        x_act,        // E owns the read port this cycle (registered in E)
    input  logic [31:0] x_lin,
    input  logic [31:2] x_lin4,
    input  logic [1:0]  x_sz,
    input  logic        x_pcd,
    output logic [31:0] x_data,       // data for x address (read issued last cycle)
    output logic        x_hit,        // all needed bytes present
    output logic [3:0]  x_hb,         // per byte of x_data: its line hit
    output logic        x_cached,
    input  logic        x_fill,       // request a line fill of x address' missing line
    output logic        x_fill_done,
    // BIU: line fill
    output logic        fill_req,
    output logic [31:4] fill_line,
    input  logic        fill_we,      // row write: fill_hm words of row fill_row
    input  logic [1:0]  fill_row,
    input  logic [1:0]  fill_hm,
    input  logic [63:0] fill_data,
    input  logic        fill_done,
    // snoop invalidate (DMA)
    input  logic        inv_all,      // invalidate every line (INVD / WBINVD / FLUSH): the tag sweep
    output logic        inv_busy,     // ... requested or running
    input  logic        snp_v,
    input  logic [31:4] snp_line,
    // results to E
    output logic [31:0] m_data,
    output logic        m_ldwait,
    output logic [15:0] m_fwd         // per load byte {valid, entry, lane[1:0]} of the store in E
);
  genvar w, b, k;
`include "tetrium_mtype.svh"
  wire mrd = m_uw[UW_MRD_L] && !m_noacc;

  // geometry
  localparam int NW    = `DC_WAYS;
  localparam int LB    = $clog2(`LINE_B);            // line offset bits
  localparam int WAYB  = $clog2(`DC_KB * 1024 / NW);  // bytes per way (log2)
  localparam int ROWB  = WAYB - 3;                    // 8-byte rows per way
  localparam int SETB  = WAYB - LB;
  localparam int TAGB  = 32 - WAYB;
  localparam int BEATB = LB - 2;                      // 32-bit beats per line (log2)
  localparam int TE    = TAGB + 1;                    // tag entry {valid, tag}
  // virtually indexed, physically tagged: the index must lie within the 4 KB page
  initial assert (WAYB <= 12) else $error("D-cache way larger than 4 KB (DC_KB / DC_WAYS)");
  // physical word addresses of the access (page from the last-page registers)
  wire [31:2] p_a0 = {m_ppn, m_lin[11:2]};
  wire [31:2] p_a4 = {pg ? m_ppn : m_lin4[31:12], m_lin4[11:2]};

  typedef enum logic [1:0] {S_INIT, S_RUN, S_FILL, S_FILLTAG} st_t;
  st_t st;
  logic [SETB-2:0] init_cnt;
  logic [1:0]      fw;              // way being filled

  function automatic logic [3:0] szm(input logic [1:0] sz);     // byte mask of an access size
    return (sz == 2'd0) ? 4'b0001 : (sz == 2'd1) ? 4'b0011 : 4'b1111;
  endfunction
  // number of bytes - 1
  function automatic logic [2:0] szl(input logic [1:0] sz);
    return (sz == 2'd0) ? 3'd0 : (sz == 2'd1) ? 3'd1 : 3'd3;
  endfunction

  // ---------------------------------------------------------------- data array
  // per way: even / odd 32-bit word bank, byte write enables.  An access of up
  // to 4 bytes touches the word holding its first byte and at most the next
  // word: one of them is in each bank.
  // (a replaying uop re-reads its own rows for the cycle after the replay)
  wire [ROWB-1:0] rrow_o = x_act ? x_lin[WAYB-1:3]  : m_rp ? m_lin[WAYB-1:3]  : ac_row[ROWB-1:0];
  wire [ROWB-1:0] rrow_e = x_act ? x_lin4[WAYB-1:3] : m_rp ? m_lin4[WAYB-1:3] : ac_row1[ROWB-1:0];
  logic [31:0] rd_e [NW], rd_o [NW];
  wire         filling = (st == S_FILL);
  logic [3:0]  wbe_e [NW], wbe_o [NW];
  always_comb begin
    for (int w = 0; w < NW; w++) begin wbe_e[w] = '0; wbe_o[w] = '0; end
    if (w_v && w_hlo) begin
      if (w_a0[2]) wbe_o[w_wlo] = w_be0;
      else         wbe_e[w_wlo] = w_be0;
    end
    if (w_v && w_hhi) begin
      if (w_a1[2]) wbe_o[w_whi] = wbe_o[w_whi] | w_be1;
      else         wbe_e[w_whi] = wbe_e[w_whi] | w_be1;
    end
    if (filling) begin
      for (int w = 0; w < NW; w++) begin
        wbe_e[w] = {4{fill_we && fill_hm[0] && fw == 2'(w)}};
        wbe_o[w] = {4{fill_we && fill_hm[1] && fw == 2'(w)}};
      end
    end
  end
  logic [31:4] fl;
  wire [ROWB-1:0] frow   = {fl[WAYB-1:LB], fill_row[LB-4:0]};
  // the two words of a store are in different banks
  wire [ROWB-1:0] wrow_e = filling ? frow : (w_a0[2] ? w_a1[WAYB-1:3] : w_a0[WAYB-1:3]);
  wire [ROWB-1:0] wrow_o = filling ? frow : (w_a0[2] ? w_a0[WAYB-1:3] : w_a1[WAYB-1:3]);
  wire [31:0]     wdat_e = filling ? fill_data[31:0]  : (w_a0[2] ? w_d1 : w_d0);
  wire [31:0]     wdat_o = filling ? fill_data[63:32] : (w_a0[2] ? w_d0 : w_d1);
  generate
  for (w = 0; w < NW; w = w + 1) begin : g_way
    tetrium_bram_be #(.AW(ROWB), .NB(4)) u_e (
        .clk(clk), .re(1'b1), .raddr(rrow_e), .rdata(rd_e[w]),
        .we(wbe_e[w]), .waddr(wrow_e), .wdata(wdat_e));
    tetrium_bram_be #(.AW(ROWB), .NB(4)) u_o (
        .clk(clk), .re(1'b1), .raddr(rrow_o), .rdata(rd_o[w]),
        .we(wbe_o[w]), .waddr(wrow_o), .wdata(wdat_o));
  end
  endgenerate
  // the address the BRAM output belongs to (M's or E's)
  logic        rx;                 // last read was for E
  always_ff @(posedge clk) rx <= x_act;

  // ---------------------------------------------------------------- tags
  // Per way, split into even / odd line banks.  The bytes of an access are in
  // the line of its first byte and at most the next line (the line of the
  // next word), which have opposite parity, so per access each bank needs one
  // read port: 3 accesses (M load, E store hit, E late load); M reads both of
  // its lines' sets straight from the M registers.
  function automatic logic [SETB-2:0] bra(input logic [31:0] a, input logic [31:2] a4, input logic par);
    return (a[LB] == par) ? a[WAYB-1:LB+1] : a4[WAYB-1:LB+1];
  endfunction
  // [bank][way]: ports [0] M (each bank: the set of whichever of lin / lin + 4 has its line
  // parity: both lines of a line-crossing access in one read), [1] E store, [2] late load.
  // Tags alone (20-bit entries fill an MLAB / LUT RAM width); the valid bits of a set's
  // ways are one RAM per bank with the same read ports, written read-modify-write
  // through a fourth port at the write address.
  logic [3*TAGB-1:0] tg [2][NW];
  logic [3*NW-1:0]   vb [2];       // [p*NW + w]
  logic [NW-1:0]     vb_cur [2];
  logic [1:0]      tag_we [2];     // per bank: write one way / all ways
  logic [NW-1:0]   tag_wv;         // ways written
  logic [SETB-2:0] tag_wa;
  logic [TE-1:0]   tag_wd;         // {valid, tag}
  generate
  for (b = 0; b < 2; b = b + 1) begin : g_tbank
    for (w = 0; w < NW; w = w + 1) begin : g_tway
      tetrium_lutram #(.AW(SETB-1), .DW(TAGB), .NR(3)) u_tag (
          .clk(clk), .clr(rst), .we(tag_we[b][0] && tag_wv[w]), .waddr(tag_wa), .wdata(tag_wd[TAGB-1:0]),
          .raddr({bra(x_lin, x_lin4, 1'(b)), bra(e_st_lin, e_st_lin4, 1'(b)), b ? m_tset1 : m_tset0}),
          .rdata(tg[b][w]));
    end
    logic [NW-1:0] vwd;
    always_comb
      for (int i = 0; i < NW; i++) vwd[i] = tag_wv[i] ? tag_wd[TAGB] : vb_cur[b][i];
    tetrium_lutram #(.AW(SETB-1), .DW(NW), .NR(4)) u_vb (
        .clk(clk), .clr(rst), .we(tag_we[b][0]), .waddr(tag_wa), .wdata(vwd),
        .raddr({tag_wa, bra(x_lin, x_lin4, 1'(b)), bra(e_st_lin, e_st_lin4, 1'(b)), b ? m_tset1 : m_tset0}),
        .rdata({vb_cur[b], vb[b]}));
  end
  endgenerate
  // hit vector of the line of word address a on port p (its line's bank)
  function automatic logic [NW-1:0] hv(input logic [31:2] a, input int p);
    logic [NW-1:0] r;
    for (int w = 0; w < NW; w++) begin
      logic [TAGB-1:0] t;
      logic            v;
      t = a[LB] ? tg[1][w][p*TAGB +: TAGB] : tg[0][w][p*TAGB +: TAGB];
      v = a[LB] ? vb[1][p*NW + w] : vb[0][p*NW + w];
      r[w] = v && (t == a[31:WAYB]);
    end
    return r;
  endfunction
  function automatic logic [1:0] wenc(input logic [NW-1:0] v);
    logic [1:0] r;
    r = '0;
    for (int w = 0; w < NW; w++) if (v[w]) r = r | 2'(w);
    return r;
  endfunction
  // valid bits of the ways of word address a's set (port p)
  function automatic logic [NW-1:0] vv(input logic [31:2] a, input int p);
    return a[LB] ? vb[1][p*NW +: NW] : vb[0][p*NW +: NW];
  endfunction
  // M: compare both banks' entries, then pick by the line's parity (the bank
  // select sits after the compare)
  function automatic logic [NW-1:0] hvm(input logic [31:2] a, input int p);
    logic [NW-1:0] r;
    for (int w = 0; w < NW; w++) begin
      logic c0, c1;
      c0 = vb[0][p*NW + w] && (tg[0][w][p*TAGB +: TAGB] == a[31:WAYB]);
      c1 = vb[1][p*NW + w] && (tg[1][w][p*TAGB +: TAGB] == a[31:WAYB]);
      r[w] = a[LB] ? c1 : c0;
    end
    return r;
  endfunction
  wire [NW-1:0] hv_lo  = hvm(p_a0, 0);
  wire [NW-1:0] hv_hi  = hvm(p_a4, 0);
  wire [NW-1:0] xhv_lo = hv(x_lin[31:2], 2);
  wire [NW-1:0] xhv_hi = hv(x_lin4, 2);
  wire [NW-1:0] ehv_lo = hv(e_st_lin[31:2], 1);
  wire [NW-1:0] ehv_hi = hv(e_st_lin4, 1);
  wire h_lo   = |hv_lo;
  wire h_hi   = |hv_hi;
  wire xh_lo0 = |xhv_lo;
  wire xh_hi0 = |xhv_hi;
  assign e_st_hlo = |ehv_lo;
  assign e_st_hhi = |ehv_hi;
  assign e_st_wlo = wenc(ehv_lo);
  assign e_st_whi = wenc(ehv_hi);

  // the access needs its second word / its bytes cross into the next line
  wire       m_two  = ({1'b0, m_lin[1:0]} + szl(m_sz)) > 3'd3;
  wire       x_two  = ({1'b0, x_lin[1:0]} + szl(x_sz)) > 3'd3;
  // per load byte k: it lies in the next line (line offset + k overflows)
  function automatic logic [3:0] xline(input logic [LB-1:0] o);
    logic [3:0] r;
    for (int k = 0; k < 4; k++) r[k] = (({1'b0, o} + (LB+1)'(k)) >> LB) != 0;
    return r;
  endfunction
  wire [3:0] m_xl = xline(m_lin[LB-1:0]);
  wire [3:0] x_xl = xline(x_lin[LB-1:0]);
  wire       m_xline = |(m_xl & szm(m_sz));
  wire       x_xline = |(x_xl & szm(x_sz));

  // Byte select per way, shared by M and the late port: in a late-port cycle
  // (rx) M cannot use the cache data (ok_now needs !rx), so the byte offset
  // follows the registered rx (a mux on registers, parallel to the BRAM read).
  // The hit-way selects stay separate (each port's own hit vectors).
  wire [2:0] so = rx ? x_lin[2:0] : m_lin[2:0];
  logic [31:0] wd [NW];             // the 4 bytes at the access address, per way
  always_comb
    for (int w = 0; w < NW; w++)
      wd[w] = 32'((so[2] ? {rd_e[w], rd_o[w]} : {rd_o[w], rd_e[w]}) >> {so[1:0], 3'b000});
  function automatic logic [31:0] wsel(input logic [NW-1:0] hlo, input logic [NW-1:0] hhi, input logic [3:0] xl);
    logic [31:0] r;
    r = '0;
    for (int k = 0; k < 4; k++)
      for (int w = 0; w < NW; w++)
        if (xl[k] ? hhi[w] : hlo[w]) r[k*8 +: 8] = r[k*8 +: 8] | wd[w][k*8 +: 8];
    return r;
  endfunction
  wire [31:0] cdat = wsel(hv_lo, hv_hi, m_xl);        // M path
  assign x_data    = wsel(xhv_lo, xhv_hi, x_xl);      // E late port

  // ---------------------------------------------------------------- store-to-load forwarding
  // Byte lanes of aligned words: the load's two words {m_lin[31:2], m_lin4}
  // against the word entries of the store in W and of the store accepted last
  // cycle (their data is in registers); the store in E is forwarded in E (it
  // is in W by then).  Youngest store first.
  // forwarded lane bytes of load word a: {hit[3:0], data[31:0]}
  function automatic logic [35:0] fwdw(input logic [31:2] a);
    logic [3:0]  h;
    logic [31:0] d;
    logic m0, m1, m2, m3;
    m0 = w_v && (a == w_a0);
    m1 = w_v && (a == w_a1);
    m2 = l_st_v && (a == l_a0);
    m3 = l_st_v && (a == l_a1);
    h = '0; d = '0;
    for (int b = 0; b < 4; b++) begin
      if (m0 && w_be0[b])      begin h[b] = 1'b1; d[b*8 +: 8] = w_d0[b*8 +: 8]; end
      else if (m1 && w_be1[b]) begin h[b] = 1'b1; d[b*8 +: 8] = w_d1[b*8 +: 8]; end
      else if (m2 && l_be0[b]) begin h[b] = 1'b1; d[b*8 +: 8] = l_d0[b*8 +: 8]; end
      else if (m3 && l_be1[b]) begin h[b] = 1'b1; d[b*8 +: 8] = l_d1[b*8 +: 8]; end
    end
    return {h, d};
  endfunction
  wire [35:0] fw0 = fwdw(p_a0);
  wire [35:0] fw1 = fwdw(p_a4);
  // lanes -> load bytes (byte k of the load is lane m_lin[1:0] + k of the word pair)
  wire [7:0]  fh8 = {fw1[35:32], fw0[35:32]};
  wire [63:0] fd8 = {fw1[31:0], fw0[31:0]};
  wire [3:0]  fhit = 4'(fh8 >> m_lin[1:0]);
  wire [31:0] fdat = 32'(fd8 >> {m_lin[1:0], 3'b000});
  logic [31:0] mb;
  always_comb
    for (int k = 0; k < 4; k++) mb[k*8 +: 8] = fhit[k] ? fdat[k*8 +: 8] : cdat[k*8 +: 8];
  // store in E: which of its (future W) entry lanes each load byte takes
  function automatic logic [15:0] fwde();
    logic [15:0] r;
    logic e0a, e1a, e0b, e1b;
    logic [2:0] p;
    logic [3:0] bm;
    r = '0;
    bm = szm(m_sz);
    e0a = e_st_v && (p_a0 == e_st_a0);          // load word 0 = store entry 0
    e1a = e_st_v && (p_a0 == e_st_a1);          // load word 0 = store entry 1
    e0b = e_st_v && (p_a4 == e_st_a0);          // load word 1 = store entry 0
    e1b = e_st_v && (p_a4 == e_st_a1);
    for (int k = 0; k < 4; k++) begin
      p = {1'b0, m_lin[1:0]} + 3'(k);
      if (bm[k]) begin
        if (!p[2]) begin
          if (e0a && e_st_be0[p[1:0]])      r[k*4 +: 4] = {1'b1, 1'b0, p[1:0]};
          else if (e1a && e_st_be1[p[1:0]]) r[k*4 +: 4] = {1'b1, 1'b1, p[1:0]};
        end else begin
          if (e0b && e_st_be0[p[1:0]])      r[k*4 +: 4] = {1'b1, 1'b0, p[1:0]};
          else if (e1b && e_st_be1[p[1:0]]) r[k*4 +: 4] = {1'b1, 1'b1, p[1:0]};
        end
      end
    end
    return r;
  endfunction
  wire [1:0] mt_m0 = mtype(p_a0);
  wire [1:0] mt_m1 = mtype(p_a4);
  wire [1:0] mt_x0 = mtype(x_lin[31:2]);
  wire [1:0] mt_x1 = mtype(x_lin4);
  wire cached   = mt_m0[0] && (mt_m1[0] || !m_two) && !m_pcd;
  // (paging: the page usable, the access within it, no untranslated store in E)
  wire m_xpage  = (m_sz == 2'd1) ? (m_lin[11:0] == 12'hFFF) : (m_sz == 2'd2) ? (m_lin[11:0] > 12'hFFC) : 1'b0;
  wire ok_now   = cached && h_lo && (h_hi || !m_xline) && !rx && m_pok && !(pg && m_xpage) && !e_st_xp;

  logic        dsaved, dsok;
  logic [31:0] dsave;
  logic        sinv_v;               // snoop invalidation pending (applied to the tags next)
  logic [31:4] sinv_l;
  // an empty M takes the next uop from A even while E is busy (absorbs decode bubbles),
  // except when E's late load uses the D-cache read port this cycle
  assign hold_m = (hold_e && (m_valid || x_act)) || m_rp;
  assign m_adv  = m_valid && !hold_e && !m_rp;
  // (a line invalidation while the data is held, or still on its way to the tags, makes
  // it stale: the page walker's A / D writes are older than the load (in E, holding M);
  // DMA snoops: conservative.  E then reads it through the late port.)
  always_ff @(posedge clk) begin
    if (rst || flush_e || m_adv) dsaved <= 1'b0;
    else if (m_valid && mrd && hold_e && !dsaved && !rx && !m_rp) begin
      dsaved <= 1'b1;
      dsok   <= ok_now && !snp_v && !sinv_v;
      dsave  <= mb;
    end else if (snp_v) dsok <= 1'b0;
  end
  assign m_data   = dsaved ? dsave : mb;
  assign m_ldwait = mrd && (dsaved ? !dsok : !ok_now);
  // (not gated by the hit check: a load that misses is re-read later anyway)
  assign m_fwd    = mrd ? fwde() : 16'h0;

  // ---------------------------------------------------------------- E late port results
  assign x_hit    = xh_lo0 && (xh_hi0 || !x_xline);
  always_comb for (int k = 0; k < 4; k++) x_hb[k] = x_xl[k] ? xh_hi0 : xh_lo0;
  assign x_cached = mt_x0[0] && (mt_x1[0] || !x_two) && !x_pcd;

  // ---------------------------------------------------------------- replacement (tree PLRU)
  // The tree bits of a set in one RAM, written read-modify-write through a port at
  // the write address (only the bits on the access's path change); read when
  // choosing a victim.
  // Updated (one cycle late) on M load hits and on fills.
  localparam int PB = (NW > 1) ? NW - 1 : 1;
  logic          pu_v;
  logic [SETB-1:0] pu_set;
  logic [1:0]    pu_way;
  logic [PB-1:0] pl_rd;
  logic [SETB-1:0] pl_ra;
  logic [PB-1:0] pl_cur, pl_wd;
  always_comb begin
    pl_wd = pl_cur;
    for (int k = 0; k < PB; k++)
      if ((k == 0) || (NW == 4 && ((k == 1) == (pu_way[1] == 1'b0))))
        // bit value: point away from the accessed way
        pl_wd[k] = (k == 0) ? ((NW == 4) ? !pu_way[1] : !pu_way[0]) : !pu_way[0];
  end
  tetrium_lutram #(.AW(SETB), .DW(PB), .NR(2)) u_pl (
      .clk(clk), .clr(rst), .we(pu_v), .waddr(pu_set), .wdata(pl_wd),
      .raddr({pu_set, pl_ra}), .rdata({pl_cur, pl_rd}));
  function automatic logic [1:0] plru_victim(input logic [PB-1:0] b);
    if (NW == 4) return b[0] ? {1'b1, b[2]} : {1'b0, b[1]};
    else if (NW == 2) return {1'b0, b[0]};
    else return 2'd0;
  endfunction

  // ---------------------------------------------------------------- fills
  assign fill_line   = fl;
  assign fill_req    = (st == S_FILL);
  // a snoop of the line being filled (its data may predate the DMA write): the fill's
  // tag is written invalid and the waiting load re-reads (misses, fills again)
  logic        fsn;
  wire         fsn_now = snp_v && (snp_line == fl);
  // the pending invalidation goes first; the fill's tag write waits for it
  wire         ftag = (st == S_FILLTAG) && !sinv_v;
  logic        ia_pend;
  assign inv_busy = ia_pend || (st == S_INIT);
  // the missing line of the waiting load and its set's valid ways
  logic xh_lo;      // first line hit of the last E re-read (registered)
  always_ff @(posedge clk) if (rx) xh_lo <= xh_lo0;
  wire [31:2]   mline = xh_lo ? x_lin4 : x_lin[31:2];
  wire [NW-1:0] mval  = vv(mline, 2);
  assign pl_ra = mline[WAYB-1:LB];
  logic [1:0] vict;
  always_comb begin
    vict = plru_victim(pl_rd);
    for (int w = NW - 1; w >= 0; w--) if (!mval[w]) vict = 2'(w);    // an empty way first
  end
  always_comb begin
    tag_we[0] = 2'b00; tag_we[1] = 2'b00;
    tag_wv = '0; tag_wa = fl[WAYB-1:LB+1]; tag_wd = {1'b1, fl[31:WAYB]};
    if (st == S_INIT) begin
      tag_we[0] = 2'b01; tag_we[1] = 2'b01; tag_wv = '1; tag_wa = init_cnt; tag_wd = '0;
    end else if (sinv_v) begin
      tag_we[sinv_l[LB]] = 2'b01; tag_wv = '1; tag_wa = sinv_l[WAYB-1:LB+1]; tag_wd = '0;
    end else if (st == S_FILLTAG) begin
      tag_we[fl[LB]] = 2'b01; tag_wv[fw] = 1'b1; tag_wd = {!(fsn || fsn_now), fl[31:WAYB]};
    end
  end
  assign x_fill_done = ftag;

  always_ff @(posedge clk) begin
    // PLRU update: the filled way, else the way a load hit in M
    pu_v   <= !rst && (ftag || (m_valid && mrd && h_lo && !rx && !m_rp));
    pu_set <= (st == S_FILLTAG) ? fl[WAYB-1:LB] : m_lin[WAYB-1:LB];
    pu_way <= (st == S_FILLTAG) ? fw : wenc(hv_lo);
    if (rst) begin
`ifdef SIM
      st <= S_RUN;
`else
      st <= S_INIT;
`endif
      init_cnt <= '0;
      sinv_v   <= 1'b0;
      ia_pend  <= 1'b0;
    end else begin
      if (inv_all) ia_pend <= 1'b1;
      // DMA snoop: invalidate all ways of the set (conservative), the cycle after it
      // (it has the tag port first: a new snoop never replaces one not yet applied)
      if (snp_v) begin sinv_v <= 1'b1; sinv_l <= snp_line; end
      else if (st != S_INIT) sinv_v <= 1'b0;
      if (st == S_RUN) fsn <= 1'b0;
      else if (fsn_now) fsn <= 1'b1;
      case (st)
        S_INIT: begin
          init_cnt <= init_cnt + 1'b1;
          if (&init_cnt) st <= S_RUN;
        end
        S_RUN: if (x_fill) begin
          st <= S_FILL;
          fl <= mline[31:4];
          fw <= vict;
        end else if (ia_pend) begin               // (a requested fill first: E waits for it)
          st       <= S_INIT;
          init_cnt <= '0;
          ia_pend  <= inv_all;
        end
        S_FILL: if (fill_done) st <= S_FILLTAG;
        default: if (!sinv_v) st <= S_RUN;      // S_FILLTAG: tag written this cycle
      endcase
    end
  end
endmodule
