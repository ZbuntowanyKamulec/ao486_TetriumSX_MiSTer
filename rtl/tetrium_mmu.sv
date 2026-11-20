// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium paging unit: TLB (i486 organisation), last-page registers, page walker,
// TLB test registers TR6 / TR7
//  * TLB: 8 sets x 4 ways (32 entries), set = linear[14:12], tag = linear[31:15],
//    pseudo-LRU replacement (3 bits per set, an invalid way first), as on the i486.
//    Entry {tag, ppn, U, W, D, PCD, PWT} in distributed RAM (one RAM per way and read
//    port), valid bits and LRU bits in flip-flops (CR3 write: flash clear).
//    U / W are the combined (most restrictive) PDE and PTE bits.
//  * read ports: D (M-stage replay), F (fetch page change), K (walker, TR6)
//  * data micro-TLB (checked in A2 for the primary and secondary address): 8 sets x
//    2 ways, set = linear[14:12] as the TLB's, each entry a copy of one TLB entry with
//    its way; a TLB write to that entry, INVLPG, a CR3 write, a TR6 write or a CR0 write
//    drops it.  (The fetch last-page register lives in tetrium_fetch.)  Hits through it
//    touch the entry's LRU bits like a TLB lookup.
//  * walker: one request at a time (E before F): TLB lookup; if it misses, lacks the
//    rights or a write needs D, the page tables are read and updated over the bus
//    (uncached, locked, after the store buffer has drained), the entry is written and
//    the checks are redone on the walked bits.  Accessed / dirty bits are written
//    only when they change; the written word's line is invalidated in both caches.
//  * L2 TLB (L2TLB_AB > 0): 2^L2TLB_AB entries, direct-mapped by linear[12 +: L2TLB_AB], in
//    block RAM: {valid, tag, ppn, U, W, D, PCD, PWT} as the TLB's.  Read with the walker's
//    TLB lookup; a hit with the rights (and D for a write) fills the TLB as a walk would
//    (no bus access).  Filled by every successful walk.  INVLPG and TR6 writes clear the
//    entry at that index; a CR3 write clears all of it (one entry per cycle, the L2 unused
//    meanwhile).  TR6 / TR7 see only the TLB.
//  * TR6 / TR7: write (C = 0) and lookup (C = 1) as in the i486 manual (10.6): a write
//    places the entry in the way TR7.REP (TR7.PL set) or the replacement way; a lookup
//    matches the tag, V and the attribute bit pairs and reports PA, PCD, PWT, the LRU
//    bits before the lookup (TR7[9:7] = B2 B1 B0), PL (hit) and REP (way).
`include "tetrium_cfg.svh"
module tetrium_mmu (
    input  logic        clk,
    input  logic        rst,
    input  logic        wp,              // CR0.WP
    input  logic        a20m,            // A20M#: physical address bit 20 forced to 0
    input  logic [31:12] cr3,
    // TLB management (from E, serializing instructions)
    input  logic        flush_all,       // CR3 write (MOV, task switch)
    input  logic        invlpg_v,
    input  logic [31:12] invlpg_a,
    input  logic        lp_kill,         // CR0 write: drop the last-page registers
    // test registers
    input  logic        tr_we,           // MOV TRn, r (n = 6, 7)
    input  logic        tr_sel7,         //   TR7 (else TR6)
    input  logic [31:0] tr_d,
    output logic [31:0] tr6,
    output logic [31:0] tr7,
    // D port (M-stage replay lookup)
    input  logic [31:12] dl_a,
    input  logic        dl_touch,        // the lookup is used: touch its LRU bits
    output logic        dl_hit,
    output logic [1:0]  dl_way,
    output logic [41:0] dl_e,
    input  logic        dl_user,         // rights of the replayed access (computed per way)
    input  logic        dl_wr,
    output logic        dl_okp,          //   hit with the rights (and D) of that access
    output logic        dl_okw,          //   hit with write rights and D (its secondary store)
    // F port (fetch page change)
    input  logic [31:12] fl_a,
    input  logic        fl_touch,
    output logic        fl_hit,
    output logic [1:0]  fl_way,
    output logic [41:0] fl_e,
    // LRU touches of last-page register hits: {valid, set, way} x 3 (F, primary, secondary)
    input  logic [2:0]  lt_v,
    input  logic [14:0] lt_sw,           // per touch {set[2:0], way[1:0]}
    // data micro-TLB (checked in A2): 2^UT_SB sets x UT_WAYS ways, flattened
    // [set * UT_WAYS + way]: {valid, entry, linear[14:12], TLB way}
    output logic [(1<<`UT_SB)*`UT_WAYS-1:0]    ut_v,
    output logic [(1<<`UT_SB)*`UT_WAYS*42-1:0] ut_e,
    output logic [(1<<`UT_SB)*`UT_WAYS*3-1:0]  ut_lo,
    output logic [(1<<`UT_SB)*`UT_WAYS*2-1:0]  ut_w,
    input  logic [1:0]    ut_tv,           // micro-TLB hits used (uop leaving M): {secondary, primary}
    input  logic [7:0]    ut_tsw,          //   entry index each
    input  logic        lpp_ld,          // load the micro-TLB from {lp_vpn, lp_e, lp_way}
    input  logic        lps_ld,
    input  logic [31:12] lp_vpn,
    input  logic [41:0] lp_e,
    input  logic [1:0]  lp_way,
    // TLB write event (the fetch last-page register drops its entry on a match)
    output logic        tw_v,
    output logic [4:0]  tw_sw,           // {set, way}
    output logic        lpf_kill,        // flush / INVLPG / TR6 write / CR0 write
    // walker requests: E (data) and F (code)
    input  logic        e_req,
    input  logic [31:12] e_a,
    input  logic        e_wr,
    input  logic        e_user,          // CPL 3 and not an implicit supervisor access
    input  logic        e_cpl3,          // error code U/S
    output logic        e_done,          // one cycle: e_ok / e_err / walk result
    input  logic        f_req,
    input  logic [31:12] f_a,
    input  logic        f_user,
    output logic        f_acc,           // the F request is taken this cycle
    output logic        f_done,
    output logic        w_ok,
    output logic [2:0]  w_err,           // #PF error code {U/S, W/R, P}
    output logic [41:0] w_e,
    output logic [1:0]  w_way,
    // bus (BIU single 32-bit access)
    input  logic        io_ok,           // W and the store buffer are empty
    output logic        pw_req,
    output logic        pw_we,
    output logic        pw_lock,
    output logic [31:2] pw_adr,
    output logic [31:0] pw_wdat,
    input  logic        pw_done,
    input  logic [31:0] pw_rdata,
    output logic        snp_v,           // invalidate the written line in both caches
    output logic [31:4] snp_line
);
  // entry fields
  localparam int E_TAG = 25, E_PPN = 5, E_U = 4, E_W = 3, E_D = 2, E_PCD = 1, E_PWT = 0;
  function automatic logic [16:0] etag(input logic [41:0] e); return e[41:25]; endfunction

  // ---------------------------------------------------------------- arrays
  logic [3:0]  tv [8];             // valid bits per set
  logic [2:0]  lru [8];            // pseudo-LRU {B2, B1, B0} per set
  logic        tlb_we;
  logic [2:0]  tlb_ws;
  logic [1:0]  tlb_ww;
  logic [41:0] tlb_wd;
  logic        tlb_wv;             // valid bit written
  logic [31:12] k_a;               // K port address
  logic [41:0] rd [3][4];          // [port D/F/K][way]
  genvar gw;
  generate
  for (gw = 0; gw < 4; gw = gw + 1) begin : g_way
    logic [3*42-1:0] r3;
    tetrium_lutram #(.AW(3), .DW(42), .NR(3)) u_t (
        .clk(clk), .clr(1'b0), .we(tlb_we && tlb_ww == 2'(gw)), .waddr(tlb_ws), .wdata(tlb_wd),
        .raddr({k_a[14:12], fl_a[14:12], dl_a[14:12]}), .rdata(r3));
    assign rd[0][gw] = r3[0 +: 42];
    assign rd[1][gw] = r3[42 +: 42];
    assign rd[2][gw] = r3[84 +: 42];
  end
  endgenerate
  // lookup on port p: {hit, way, entry}
  function automatic logic [44:0] look(input int p, input logic [31:12] a);
    logic h; logic [1:0] w; logic [41:0] e;
    h = 1'b0; w = 2'd0; e = rd[p][0];
    for (int i = 3; i >= 0; i--)
      if (tv[a[14:12]][i] && etag(rd[p][i]) == a[31:15]) begin h = 1'b1; w = 2'(i); e = rd[p][i]; end
    return {h, w, e};
  endfunction
  // physical page as used (A20M#: bit 20 masked; the TLB keeps the entry as written)
  function automatic logic [41:0] am(input logic [41:0] e);
    logic [41:0] r;
    r = e;
    r[E_PPN + 8] = e[E_PPN + 8] && !a20m;
    return r;
  endfunction
  wire [44:0] dl_r = look(0, dl_a);
  wire [44:0] fl_r = look(1, fl_a);
  assign {dl_hit, dl_way} = dl_r[44:42];
  assign {fl_hit, fl_way} = fl_r[44:42];
  assign dl_e = am(dl_r[41:0]);
  assign fl_e = am(fl_r[41:0]);
  // D port rights per way, in parallel with the way select
  always_comb begin
    dl_okp = 1'b0; dl_okw = 1'b0;
    for (int i = 0; i < 4; i++)
      if (tv[dl_a[14:12]][i] && etag(rd[0][i]) == dl_a[31:15]) begin
        dl_okp = dl_okp | (perm_ok(rd[0][i], dl_user, dl_wr) && (!dl_wr || rd[0][i][E_D]));
        dl_okw = dl_okw | (perm_ok(rd[0][i], dl_user, 1'b1) && rd[0][i][E_D]);
      end
  end
  wire [44:0] kl = look(2, k_a);
  wire        k_hit = kl[44];
  wire [1:0]  k_way = kl[43:42];
  wire [41:0] k_e   = kl[41:0];

  // pseudo-LRU: touching way w points away from it; victim: an invalid way first
  function automatic logic [2:0] touch(input logic [2:0] b, input logic [1:0] w);
    logic [2:0] r;
    r = b;
    r[0] = !w[1];
    if (!w[1]) r[1] = !w[0]; else r[2] = !w[0];
    return r;
  endfunction
  function automatic logic [1:0] victim(input logic [3:0] v, input logic [2:0] b);
    logic [1:0] r;
    r = b[0] ? {1'b1, b[2]} : {1'b0, b[1]};
    for (int i = 3; i >= 0; i--) if (!v[i]) r = 2'(i);
    return r;
  endfunction
  function automatic logic perm_ok(input logic [41:0] e, input logic user, input logic wr);
    return !(user && !e[E_U]) && !(wr && !e[E_W] && (user || wp));
  endfunction

  // ---------------------------------------------------------------- TR6 / TR7
  logic [31:0] tr6_q, tr7_q;
  assign tr6 = tr6_q;
  assign tr7 = tr7_q;
  wire tr6_wr = tr_we && !tr_sel7 && !tr_d[0];      // TLB write
  wire tr6_lk = tr_we && !tr_sel7 &&  tr_d[0];      // TLB lookup
  // attribute pair match (Table 10-4): 00 never, 01 bit clear, 10 bit set, 11 either
  function automatic logic pmatch(input logic [1:0] pr, input logic b);
    return pr[1] && b || pr[0] && !b;
  endfunction
  logic        tl_hit;
  logic [1:0]  tl_way;
  logic [41:0] tl_e;
  always_comb begin
    tl_hit = 1'b0; tl_way = 2'd0; tl_e = rd[2][0];
    for (int i = 3; i >= 0; i--)
      if (etag(rd[2][i]) == tr_d[31:15] && (tv[tr_d[14:12]][i] == tr_d[11]) &&
          pmatch(tr_d[10:9], rd[2][i][E_D]) && pmatch(tr_d[8:7], rd[2][i][E_U]) &&
          pmatch(tr_d[6:5], rd[2][i][E_W])) begin
        tl_hit = 1'b1; tl_way = 2'(i); tl_e = rd[2][i];
      end
  end

  // ---------------------------------------------------------------- walker
  typedef enum logic [3:0] {W_IDLE, W_LK, W_LK2, W_DR, W_PDE, W_PTE, W_WPDE, W_WPTE, W_FIN, W_DONE} ws_t;
  ws_t ws;
  logic        rq_f;               // request from F
  logic [31:12] rq_a;
  logic        rq_wr, rq_user, rq_cpl3;
  logic [31:0] pde, pte;
  logic        lk_hit;             // the TLB held the page (rewrite that way)
  logic [1:0]  lk_way;
  logic        r_ok;
  logic [2:0]  r_err;
  logic [41:0] r_e;
  logic [1:0]  r_way;
  assign k_a = tr_we ? tr_d[31:12] : invlpg_v ? invlpg_a : rq_a;
  wire [41:0] wk_e = {rq_a[31:15], pte[31:12], pde[2] & pte[2], pde[1] & pte[1], pte[6] | rq_wr, pte[4], pte[3]};
  wire [1:0]  fin_way = lk_hit ? lk_way : victim(tv[rq_a[14:12]], lru[rq_a[14:12]]);
  assign f_acc    = (ws == W_IDLE) && f_req && !e_req && !tr_we && !invlpg_v;
  assign e_done   = (ws == W_DONE) && !rq_f;
  assign f_done   = (ws == W_DONE) && rq_f;
  assign w_ok     = r_ok;
  assign w_err    = r_err;
  assign w_e      = am(r_e);
  assign w_way    = r_way;
  assign pw_req   = (ws == W_PDE) || (ws == W_PTE) || (ws == W_WPDE) || (ws == W_WPTE);
  assign pw_we    = (ws == W_WPDE) || (ws == W_WPTE);
  wire [31:2] pw_a = (ws == W_PDE || ws == W_WPDE) ? {cr3, rq_a[31:22]} : {pde[31:12], rq_a[21:12]};
  assign pw_adr   = {pw_a[31:21], pw_a[20] && !a20m, pw_a[19:2]};
  assign pw_wdat  = (ws == W_WPDE) ? (pde | 32'h20) : (pte | 32'h20 | (rq_wr ? 32'h40 : 32'h0));
  // locked from the PDE read to the last page-table write (the BIU runs nothing else)
  assign pw_lock  = pw_req;
  // walked checks on the arriving PTE
  wire [41:0] wk_en  = {rq_a[31:15], pw_rdata[31:12], pde[2] & pw_rdata[2], pde[1] & pw_rdata[1], pw_rdata[6] | rq_wr, pw_rdata[4], pw_rdata[3]};
  wire        pt_bad_n = !pw_rdata[0] || !perm_ok(wk_en, rq_user, rq_wr);
  assign snp_v    = pw_done && pw_we;
  assign snp_line = pw_adr[31:4];

  // ---------------------------------------------------------------- L2 TLB
  localparam int L2B = `L2TLB_AB;
  localparam int L2N = (L2B > 0) ? L2B : 1;
  localparam int L2T = 20 - L2N;                       // tag bits
  logic           l2_hit;                              // (W_LK2) the L2 holds rq_a
  logic [24:0]    l2_d;                                // {ppn, U, W, D, PCD, PWT}
  logic           l2_clr;                              // clearing (reset, CR3 write): unused
  logic           l2_nof;                              // no fill for the walk in progress
  logic [L2N-1:0] l2_cnt;
  generate if (L2B > 0) begin : g_l2
    logic [L2T+25:0] rd, wd;
    logic            we;
    logic [L2N-1:0]  wa;
    always_comb begin
      we = 1'b0; wa = rq_a[12 +: L2N]; wd = {1'b1, rq_a[31 -: L2T], wk_e[24:0]};
      if (l2_clr) begin we = 1'b1; wa = l2_cnt; wd = '0; end
      else if (invlpg_v || tr6_wr) begin we = 1'b1; wa = invlpg_v ? invlpg_a[12 +: L2N] : tr_d[12 +: L2N]; wd = '0; end
      else if (ws == W_FIN && !l2_nof) we = 1'b1;
    end
    tetrium_bram #(.AW(L2N), .DW(L2T + 26)) u_l2 (
        .clk(clk), .re(1'b1), .raddr(rq_a[12 +: L2N]), .rdata(rd), .we(we), .waddr(wa), .wdata(wd));
    assign l2_hit = rd[L2T + 25] && (rd[L2T + 24:25] == rq_a[31 -: L2T]) && !l2_clr;
    assign l2_d   = rd[24:0];
    always_ff @(posedge clk) begin
      if (rst || flush_all) begin l2_clr <= 1'b1; l2_cnt <= '0; end
      else if (l2_clr) begin l2_cnt <= l2_cnt + 1'b1; if (&l2_cnt) l2_clr <= 1'b0; end
      if (ws == W_IDLE) l2_nof <= 1'b0;
      else if (flush_all || invlpg_v || tr6_wr) l2_nof <= 1'b1;
    end
  end else begin : g_nol2
    assign l2_hit = 1'b0; assign l2_d = '0; assign l2_clr = 1'b0; assign l2_nof = 1'b0; assign l2_cnt = '0;
  end endgenerate
  // the L2 entry as a TLB entry (for the rights check)
  wire [41:0] l2_e = {rq_a[31:15], l2_d};

  // ---------------------------------------------------------------- TLB writes
  always_comb begin
    tlb_we = 1'b0; tlb_ws = rq_a[14:12]; tlb_ww = fin_way; tlb_wd = wk_e; tlb_wv = 1'b1;
    if (tr6_wr) begin
      tlb_we = 1'b1; tlb_ws = tr_d[14:12];
      tlb_ww = tr7_q[4] ? tr7_q[3:2] : victim(tv[tr_d[14:12]], lru[tr_d[14:12]]);
      tlb_wd = {tr_d[31:15], tr7_q[31:12], tr_d[8], tr_d[6], tr_d[10], tr7_q[11], tr7_q[10]};
      tlb_wv = tr_d[11];
    end else if (ws == W_FIN) tlb_we = 1'b1;
  end
  assign tw_v     = tlb_we;
  assign tw_sw    = {tlb_ws, tlb_ww};
  assign lpf_kill = flush_all || invlpg_v || tr6_wr || lp_kill;

  // ---------------------------------------------------------------- data micro-TLB
  // 2^UT_SB sets (linear[12 +: UT_SB]; 3: the TLB's set) x UT_WAYS ways, each entry a copy
  // of one TLB entry with its way.  Loaded by M replay hits and E walks (into the way
  // already holding the page, else an invalid way, else the set's replacement way); a TLB
  // write to that entry, INVLPG, a CR3 write, a TR6 write or a CR0 write drops it.
  // Replacement: pseudo-LRU over the ways (hits of uops leaving M, loads).
  localparam int USB = `UT_SB, UWY = `UT_WAYS, UNS = 1 << USB, UN = UNS * UWY;
  // (the entries are kept in the flat output vectors: unpacked arrays here crashed Quartus 17
  //  synthesis, SGN 'Cannot get member name')
  logic [2:0]  ulru [UNS];
  function automatic int uset(input logic [31:12] a); return (USB == 0) ? 0 : (int'(a[14:12]) & (UNS - 1)); endfunction
  function automatic logic [1:0] uvict(input logic [2:0] b);
    return (UWY == 1) ? 2'd0 : (UWY == 2) ? {1'b0, b[0]} : (b[0] ? {1'b1, b[2]} : {1'b0, b[1]});
  endfunction
  function automatic logic [2:0] utouch(input logic [2:0] b, input logic [1:0] w);
    return (UWY == 1) ? b : (UWY == 2) ? {2'b00, !w[0]} : touch(b, w);
  endfunction
  // (loads are registered: they come from the TLB lookup / walk result paths; dropped when
  // the TLB entry is rewritten meanwhile: the copy would be stale)
  logic        ld_q;
  logic [31:12] ld_vpn;
  logic [41:0] ld_e;
  logic [1:0]  ld_way;
  always_ff @(posedge clk) begin
    ld_q <= (lpp_ld || lps_ld) && !(rst || flush_all || invlpg_v || tr6_wr || lp_kill) &&
            !(tlb_we && tlb_ws == lp_vpn[14:12] && tlb_ww == lp_way);
    ld_vpn <= lp_vpn; ld_e <= lp_e; ld_way <= lp_way;
  end
  // the entry a load writes: one select bit per entry, from compares with constants (a
  // computed index times the entry width became a DSP multiplier in Quartus, 7 ns)
  int          ld_s;
  logic [1:0]  ld_w;
  logic [UN-1:0] ld_sel;
  always_comb begin
    ld_s = uset(ld_vpn);
    ld_w = uvict(ulru[ld_s]);
    // (descending: the lowest invalid way, then the lowest way already holding the page)
    for (int q = UN - 1; q >= 0; q--) if ((q / UWY) == ld_s && !ut_v[q]) ld_w = 2'(q % UWY);
    for (int q = UN - 1; q >= 0; q--)
      if ((q / UWY) == ld_s && ut_v[q] && etag(ut_e[q * 42 +: 42]) == ld_vpn[31:15] && ut_lo[q * 3 +: 3] == ld_vpn[14:12])
        ld_w = 2'(q % UWY);
    for (int q = 0; q < UN; q++) ld_sel[q] = ((q / UWY) == ld_s) && ((q % UWY) == int'(ld_w));
  end
  always_ff @(posedge clk) begin
    if (rst || flush_all || invlpg_v || tr6_wr || lp_kill) begin
      for (int i = 0; i < UN; i++) ut_v[i] <= 1'b0;
    end else begin
      for (int i = 0; i < UN; i++)
        if (tlb_we && tlb_ws == ut_lo[(i) * 3 +: 3] && tlb_ww == ut_w[(i) * 2 +: 2]) ut_v[i] <= 1'b0;
      for (int q = 0; q < UN; q++)
        if (ld_q && ld_sel[q] && !(tlb_we && tlb_ws == ld_vpn[14:12] && tlb_ww == ld_way)) ut_v[q] <= 1'b1;
    end
    for (int q = 0; q < UN; q++)
      if (ld_q && ld_sel[q]) begin ut_e[q * 42 +: 42] <= ld_e; ut_lo[q * 3 +: 3] <= ld_vpn[14:12]; ut_w[q * 2 +: 2] <= ld_way; end
    for (int t = 0; t < 2; t++)
      if (ut_tv[t]) ulru[int'(ut_tsw[t*4 +: 4]) / UWY] <= utouch(ulru[int'(ut_tsw[t*4 +: 4]) / UWY], 2'(int'(ut_tsw[t*4 +: 4]) % UWY));
    if (ld_q) ulru[ld_s] <= utouch(ulru[ld_s], ld_w);
  end

`ifdef SIM
  logic ptr;
  initial ptr = $test$plusargs("ptrace");
  always_ff @(posedge clk) if (ptr) begin
    if (ws == W_IDLE && (e_req || f_req)) $display("W req %s a=%05x wr=%0d user=%0d", e_req ? "E" : "F", e_req ? e_a : f_a, e_wr, e_req ? e_user : f_user);
    if (ws == W_DONE) $display("W done ok=%0d err=%0d e=%011x way=%0d pde=%08x pte=%08x", r_ok, r_err, r_e, r_way, pde, pte);
  end
`endif
  // ---------------------------------------------------------------- state
  // LRU touches of the last-page hits and the D / F lookups: applied one cycle later
  // (they come from the pipeline stall / hit paths)
  logic [4:0]  tq_v;
  logic [24:0] tq_sw;          // {F, D, lt2, lt1, lt0} x {set, way}
  always_ff @(posedge clk) begin
    tq_v  <= rst ? 5'h0 : {fl_touch && fl_hit, dl_touch && dl_hit, lt_v};
    tq_sw <= {fl_a[14:12], fl_way, dl_a[14:12], dl_way, lt_sw};
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int s = 0; s < 8; s++) begin tv[s] <= 4'h0; lru[s] <= 3'h0; end
      ws <= W_IDLE;
      tr6_q <= '0; tr7_q <= '0;
    end else begin
      // LRU: last-page hits, D / F lookups used, walker hits and fills, TR6 operations.
      // One touch per cycle, the highest of: TR6 > TLB write > walker hit > F > D > the
      // last-page hits (several in a cycle only with paging on, where the LRU order is an
      // approximation of the i486's per-access lookups anyway; TR6 / TR7 tests see one)
      begin
        logic [7:0] sv; logic [2:0] ss [8]; logic [1:0] sw [8];
        logic       uv; logic [2:0] us; logic [1:0] uw;
        for (int t = 0; t < 5; t++) begin sv[t] = tq_v[t]; ss[t] = tq_sw[t*5+2 +: 3]; sw[t] = tq_sw[t*5 +: 2]; end
        sv[5] = (ws == W_LK2) && lk_hit; ss[5] = rq_a[14:12];   sw[5] = lk_way;
        sv[6] = tlb_we;                  ss[6] = tlb_ws;        sw[6] = tlb_ww;
        sv[7] = tr6_lk && tl_hit;        ss[7] = tr_d[14:12];   sw[7] = tl_way;
        uv = 1'b0; us = 3'd0; uw = 2'd0;
        for (int t = 0; t < 8; t++) if (sv[t]) begin uv = 1'b1; us = ss[t]; uw = sw[t]; end
        for (int s = 0; s < 8; s++)
          if (uv && us == s) lru[s] <= touch(lru[s], uw);
      end
      // valid bits
      if (flush_all) for (int s = 0; s < 8; s++) tv[s] <= 4'h0;
      else begin
        if (invlpg_v)
          for (int i = 0; i < 4; i++)
            if (etag(rd[2][i]) == invlpg_a[31:15]) tv[invlpg_a[14:12]][i] <= 1'b0;
        if (tlb_we) tv[tlb_ws][tlb_ww] <= tlb_wv;
      end
      // test registers
      if (tr_we) begin
        if (tr_sel7) tr7_q <= tr_d;
        else begin
          tr6_q <= tr_d;
          if (tr6_lk) begin
            tr7_q[9:7] <= {lru[tr_d[14:12]][2], lru[tr_d[14:12]][1], lru[tr_d[14:12]][0]};
            tr7_q[4]   <= tl_hit;
            if (tl_hit) begin
              tr7_q[31:12] <= tl_e[E_PPN +: 20];
              tr7_q[11]    <= tl_e[E_PCD];
              tr7_q[10]    <= tl_e[E_PWT];
              tr7_q[3:2]   <= tl_way;
              tr6_q[11:5]  <= {1'b1, tl_e[E_D], !tl_e[E_D], tl_e[E_U], !tl_e[E_U], tl_e[E_W], !tl_e[E_W]};
            end
          end
        end
      end
      // walker
      case (ws)
        W_IDLE: if ((e_req || f_req) && !tr_we && !invlpg_v) begin
          rq_f <= !e_req;
          rq_a <= e_req ? e_a : f_a;
          rq_wr <= e_req && e_wr;
          rq_user <= e_req ? e_user : f_user;
          rq_cpl3 <= e_req ? e_cpl3 : f_user;
          ws <= W_LK;
        end
        // TLB lookup (registered), then the decision
        W_LK: begin
          lk_hit <= k_hit; lk_way <= k_way; r_e <= k_e;
          ws <= W_LK2;
        end
        W_LK2: begin
          r_way <= lk_way;
          if (lk_hit && perm_ok(r_e, rq_user, rq_wr) && (!rq_wr || r_e[E_D])) begin
            r_ok <= 1'b1; ws <= W_DONE;
          end else if (!lk_hit && l2_hit && perm_ok(l2_e, rq_user, rq_wr) && (!rq_wr || l2_e[E_D])) begin
            // L2 hit: the entry through the walk's PDE / PTE registers (wk_e), then W_FIN
            pde <= 32'h7;
            pte <= {l2_d[24:5], 5'b0, l2_d[2], 1'b0, l2_d[1], l2_d[0], l2_d[4], l2_d[3], 1'b1};
            ws <= W_FIN;
          end else ws <= W_DR;
        end
        W_DR: if (io_ok) ws <= W_PDE;
        W_PDE: if (pw_done) begin
          pde <= pw_rdata;
          if (!pw_rdata[0]) begin
            r_ok <= 1'b0; r_err <= {rq_cpl3, rq_wr, 1'b0}; ws <= W_DONE;
          end else ws <= W_PTE;
        end
        W_PTE: if (pw_done) begin
          pte <= pw_rdata;
          if (pt_bad_n) begin
            r_ok <= 1'b0; r_err <= {rq_cpl3, rq_wr, pw_rdata[0]}; ws <= W_DONE;
          end else ws <= !pde[5] ? W_WPDE : (!pw_rdata[5] || (rq_wr && !pw_rdata[6])) ? W_WPTE : W_FIN;
        end
        W_WPDE: if (pw_done) ws <= (!pte[5] || (rq_wr && !pte[6])) ? W_WPTE : W_FIN;
        W_WPTE: if (pw_done) ws <= W_FIN;
        W_FIN: begin
          r_ok <= 1'b1; r_e <= wk_e; r_way <= fin_way; ws <= W_DONE;
        end
        default: ws <= W_IDLE;          // W_DONE: result valid this cycle
      endcase
    end
  end
endmodule
