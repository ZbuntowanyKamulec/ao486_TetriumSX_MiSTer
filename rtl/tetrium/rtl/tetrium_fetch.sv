// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium fetch stage (F)
//  * IC_KB, IC_WAYS-way set associative I-cache (tree PLRU), LINE_B lines
//    (tetrium_cfg.svh), 8 bytes read per cycle from every way, hit way selected
//  * BRAM BTB (one branch per 8-byte block) read with the I-cache; a predicted
//    taken block costs one bubble (the target is read in the next cycle)
//  * direction: gselect counters in BRAM indexed by {folded global history,
//    block address}, read with the BTB (see "direction predictor")
//  * 8-entry return address stack
//  * pushes 8-byte fetch blocks into the decoder's block queue
`include "tetrium_cfg.svh"
module tetrium_fetch #(
    parameter bit FILL64 = 1'b0     // fills deliver full 8-byte rows (bus >= 64 bit)
) (
    input  logic        clk,
    input  logic        rst,
    // redirect (registered by the core)
    input  logic        redir_v,
    input  logic [31:0] redir_csb,     // code segment base of the redirect target
    input  logic        rm,            // real mode or V86 (registered copy): far predictions
    input  logic [3:0]  csr_bid,       // block of a decode redirect: its code segment selector
    output logic [15:0] csr_sel,
    input  logic [31:0] redir_ip,
    input  logic        redir_nopred,
    input  logic        redir_rpush,   // return stack: push redir_rip (unpredicted CALL)
    input  logic        redir_rpop,    //               pop (unpredicted RET)
    input  logic [31:0] redir_rip,
    // predictor snapshot of the redirecting uop's block, per redirect source
    // (read in parallel, selected by redir_src: 0 E / other, 1 A, 2 D)
    input  logic [3:0]  rid_e, rid_a, rid_d,
    input  logic [1:0]  redir_src,
    input  logic        ce_push,       // near CALL / RET completed in E (committed return stack)
    input  logic        ce_pop,
    input  logic [31:0] ce_rip,
    input  logic [2:0]  rlin_e, rlin_a,  // end offset of the redirecting branch (E / A)
    input  logic        redir_br,      // redirect from a resolved branch (direction redir_tk)
    input  logic        redir_tk,
    input  logic        stop,          // stop fetching until next redirect
    input  logic        a20m,          // force linear address bit 20 to 0
    // block queue
    input  logic        q_full,
    output logic        q_push,
    output logic [63:0] q_data,
    output logic [223:0] q_pd,         // per-byte predecode (tetrium_pdec.svh, 28 bits / byte)
    output logic [2:0]  q_s,
    output logic [2:0]  q_e,
    output logic        q_pt,
    output logic [31:0] q_ptgt,
    output logic [31:3] q_lin,
    output logic [31:3] q_ip,
    output logic [3:0]  q_bid,         // predictor snapshot id of the block
    // BTB training
    input  logic [3:0]  btb_bid,
    input  logic        btb_we,
    input  logic [31:0] btb_lin,       // linear address of last byte of branch
    input  logic        btb_taken,
    input  logic        btb_inval,     // drop the entry (not a branch)
    input  logic [31:0] btb_tgt,
    input  logic [1:0]  btb_kind,      // 0 jump / jcc, 1 call, 2 ret
    input  logic        btb_pt,        // the branch was predicted taken by the BTB
    input  logic        btb_ind,       // an indirect near JMP / CALL (target cache)
    input  logic        btb_tcw,       //   ... that was mispredicted: write the target cache
    // line fill (to BIU)
    output logic        fill_req,
    output logic [31:4] fill_line,
    input  logic        fill_we,       // row write: fill_hm words of row fill_row
    input  logic [1:0]  fill_row,
    input  logic [1:0]  fill_hm,
    input  logic [63:0] fill_data,
    input  logic        fill_done,
    // snoop invalidate: external writes (DMA) and this CPU's stores in W
    input  logic        snp_v,
    input  logic [31:4] snp_line,
    input  logic        wsn_v,         // a store is accepted from W this cycle
    input  logic [31:3] wsn_l0,        // 8-byte blocks of its bytes
    input  logic [31:3] wsn_l1,
    input  logic        est_v,         // the uop in E stores to blocks est_l0 / est_l1
    input  logic [31:3] est_l0,        // (looked up one cycle ahead of W)
    input  logic [31:3] est_l1,
    input  logic        hold_w,
    output logic        smc_hit,       // the store hit a valid I-cache line (self-modifying code)
    output logic        snp_hit,       // an external snoop hit a valid I-cache line
    output logic        smc_busy,      // its invalidations are not all written yet
    output logic        smc_hold,      // hold W (invalidation queue filling up)
    // paging: the fetch last-page register, TLB F port, walker (non-speculative: only
    // once the pipeline has drained and decode waits for these bytes), page fault
    input  logic        pg,
    input  logic        cpl3,
    output logic [31:12] fl_a,
    output logic        fl_touch,
    input  logic        fl_hit,
    input  logic [1:0]  fl_way,
    input  logic [41:0] fl_e,
    input  logic        lpf_kill,
    input  logic        tw_v,
    input  logic [4:0]  tw_sw,
    output logic        lt_v,          // LRU touch of the last-page entry (pushed block)
    output logic [4:0]  lt_sw,
    input  logic        fe_drained,
    output logic        f_req,
    input  logic        f_acc,         // the walker took the request
    input  logic        f_done,
    input  logic        w_ok,
    input  logic [2:0]  w_err,
    input  logic [41:0] w_e,
    input  logic [1:0]  w_way,
    output logic        ff_flt,        // fetch stopped at a page fault (error code, address)
    output logic [2:0]  ff_err,
    output logic [31:0] ff_lin,
    // status
    output logic        busy_init,
    input  logic        inv_all,      // invalidate every line (INVD / WBINVD / FLUSH): the tag sweep
    output logic        inv_busy,     // ... requested or running
    output logic [31:0] cs_o
);
  genvar w, h, k;
`include "ucode_class.svh"
`include "tetrium_pdec.svh"
  // ---------------------------------------------------------------- state
  typedef enum logic [2:0] {S_INIT, S_RUN, S_FILL, S_FILLTAG, S_RETRY, S_XL, S_FW, S_FAULT} st_t;
  st_t st;
  logic        f_valid;     // fetching
  logic [31:0] f_lin;       // current fetch address (byte granular start)
  logic [31:0] f_ip;
  logic [31:0] f_cs;               // code segment base
  logic        f_nopred;
  logic        dv;          // BRAM output corresponds to f_lin
  logic        poisoned;
  // I-cache geometry
  localparam int INW    = `IC_WAYS;
  localparam int LB     = $clog2(`LINE_B);
  localparam int IWB    = $clog2(`IC_KB * 1024 / INW);   // bytes per way (log2)
  localparam int IROWB  = IWB - 3;
  localparam int ISETB  = IWB - LB;
  localparam int ITAGB  = 32 - IWB;
  localparam int IBEATB = LB - 2;
  localparam int ITE    = ITAGB + 1;
  initial assert (IWB <= 12) else $error("I-cache way larger than 4 KB (IC_KB / IC_WAYS)");
  localparam int NSB    = `LINE_B / 8;                   // 8-byte sub-blocks per line
  localparam int SBB    = (NSB > 1) ? $clog2(NSB) : 1;
  logic [ISETB-1:0] init_cnt;

  // ---------------------------------------------------------------- fetch micro-TLB (paging)
  // the translation of the page being fetched (tags are physical) from a micro-TLB of
  // 2^FUT_SB entries, direct-mapped by linear[12 +: FUT_SB], LUT RAM {vpn, ppn, U, PCD}
  // read in parallel with the I-tags; valid bits and the TLB way each entry copies (for
  // the invalidation by a TLB write) in registers.  A fetch from a page it does not hold
  // looks the TLB up (S_XL, two bubbles) or waits for a walk (S_FW), then fills it.
  localparam int FSB = `FUT_SB;
  localparam int FUN = 1 << FSB;
  logic [FUN-1:0] fu_v;
  logic [1:0]     fu_way [FUN];
  wire  [FSB-1:0] fu_i = f_lin[12 +: FSB];
  logic           fu_we;
  logic [FSB-1:0] fu_wa;
  logic [41:0]    fu_wd, fu_r;
  logic [1:0]     fu_ww;
  tetrium_lutram #(.AW(FSB), .DW(42), .NR(1)) u_fut (
      .clk, .clr(1'b0), .we(fu_we), .waddr(fu_wa), .wdata(fu_wd), .raddr(fu_i), .rdata(fu_r));
  wire          lpf_v   = fu_v[fu_i];
  wire [31:12]  lpf_vpn = fu_r[41:22];
  wire [31:12]  lpf_ppn = fu_r[21:2];
  wire          lpf_u   = fu_r[1];
  wire          lpf_pcd = fu_r[0];
  wire [1:0]    lpf_way = fu_way[fu_i];
  wire         lp_ok = !pg || (lpf_v && (f_lin[31:12] == lpf_vpn) && (lpf_u || !cpl3));
  wire [31:12] fppn  = pg ? lpf_ppn : f_lin[31:12];
  wire [31:0]  f_phy = {fppn, f_lin[11:0]};

  // ---------------------------------------------------------------- tags
  // per way: the tag; read ports: external snoop, store lines (E).  The fetch port is
  // the pair of half RAMs below, which also hold the line's valid bit; the other ports
  // take validity from the sub-block valid bits (a valid sub-block implies a valid
  // line).  Invalidated tags are written all ones (a snoop of FFFFF000-FFFFFFFF may
  // match one: an invalidation of an invalid line, harmless).  (No valid bit: 20-bit
  // entries fill an MLAB / LUT RAM width exactly.)
  logic [INW-1:0]   tag_we;
  logic [ISETB-1:0] tag_waddr;
  logic [ITE-1:0]   tag_wdata;             // {valid, tag}
  logic [3*ITAGB-1:0] tag_rd [INW];
  logic [2*ITE-1:0] tag_fh [INW];          // fetch port: both set-parity halves
  generate
  for (w = 0; w < INW; w = w + 1) begin : g_itag
    tetrium_lutram #(.AW(ISETB), .DW(ITAGB), .NR(3)) u_tag (
        .clk(clk), .clr(rst), .we(tag_we[w]), .waddr(tag_waddr), .wdata(tag_wdata[ITAGB-1:0]),
        .raddr({est_l1[IWB-1:LB], est_l0[IWB-1:LB], snp_line[IWB-1:LB]}),
        .rdata(tag_rd[w]));
    // fetch hit path: the two halves (by the set's low bit) are read and
    // compared separately and the result is selected (no RAM output mux
    // before the compare)
    for (h = 0; h < 2; h = h + 1) begin : g_h
      tetrium_lutram #(.AW(ISETB - 1), .DW(ITE), .NR(1)) u_tf (
          .clk(clk), .clr(rst), .we(tag_we[w] && tag_waddr[0] == 1'(h)), .waddr(tag_waddr[ISETB-1:1]),
          .wdata(tag_wdata), .raddr(f_lin[IWB-1:LB+1]), .rdata(tag_fh[w][h*ITE +: ITE]));
    end
  end
  endgenerate
  // per way tag match of port p for line address a
  function automatic logic [INW-1:0] ihv(input int p, input logic [31:4] a);
    logic [INW-1:0] r;
    for (int w = 0; w < INW; w++)
      r[w] = (tag_rd[w][p*ITAGB +: ITAGB] == a[31:IWB]);
    return r;
  endfunction
  // per way and 8-byte sub-block valid bits [w*NSB + k], so a store clears only its
  // sub-block: data next to code in the same line costs one invalidation, not one per
  // store.  A sub-block is valid only in a valid line (fills set, invalidations clear
  // all of a way's bits).  One RAM for all ways, written read-modify-write through a
  // port at the write address.  Ports: fetch, store blocks (E), write address.
  localparam int SBW = INW * NSB;
  logic [SBW-1:0]   sbv_f, sbv_e0, sbv_e1, sbv_cur, sbv_wd;
  logic             sbv_we;
  logic [ISETB-1:0] sbv_wa;
  tetrium_lutram #(.AW(ISETB), .DW(SBW), .NR(4)) u_sbv (
      .clk(clk), .clr(rst), .we(sbv_we), .waddr(sbv_wa), .wdata(sbv_wd),
      .raddr({sbv_wa, est_l1[IWB-1:LB], est_l0[IWB-1:LB], f_lin[IWB-1:LB]}),
      .rdata({sbv_cur, sbv_e1, sbv_e0, sbv_f}));
  function automatic logic [SBB-1:0] sbi(input logic [31:3] a);
    return (NSB > 1) ? SBB'(a[LB-1:3]) : '0;
  endfunction
  logic [INW-1:0] hvf, hw0, hw1;
  logic [INW-1:0] tmf;                            // fetch tag match (any sub-block)
  wire  [INW-1:0] hvs = ihv(0, snp_line);         // external snoop (whole line)
  always_comb begin
    logic [INW-1:0] t0, t1, t2;
    for (int w = 0; w < INW; w++) begin
      logic c0, c1;
      c0 = tag_fh[w][ITAGB] && (tag_fh[w][0 +: ITAGB] == f_phy[31:IWB]);
      c1 = tag_fh[w][ITE + ITAGB] && (tag_fh[w][ITE +: ITAGB] == f_phy[31:IWB]);
      t0[w] = f_lin[LB] ? c1 : c0;
    end
    tmf = t0;
    t1 = ihv(1, est_l0[31:4]); t2 = ihv(2, est_l1[31:4]);
    for (int w = 0; w < INW; w++) begin
      hvf[w] = t0[w] && sbv_f[w*NSB + sbi(f_lin[31:3])];
      hw0[w] = t1[w] && sbv_e0[w*NSB + sbi(est_l0)];
      hw1[w] = t2[w] && sbv_e1[w*NSB + sbi(est_l1)];
    end
  end
  logic [INW-1:0] vf;                             // valid ways of f_lin's set
  always_comb for (int w = 0; w < INW; w++) vf[w] = f_lin[LB] ? tag_fh[w][ITE + ITAGB] : tag_fh[w][ITAGB];

  // ---------------------------------------------------------------- data
  logic [31:0] f_lin_next;
  logic [31:0] rd_addr;      // speculative BRAM read address
  // A20 gate on every fetch address formed here
  // (paging: A20M# masks the physical address, after translation: tetrium_mmu)
  function automatic logic [31:0] a20(input logic [31:0] x);
    return {x[31:21], x[20] && !(a20m && !pg), x[19:0]};
  endfunction
  logic [31:0] bram_lo, bram_hi;
  logic [4*PDW-1:0] bpd_lo, bpd_hi;
  // Fill beats are predecoded (PDW bits per byte, see tetrium_pdec.svh) in a register
  // stage and written one cycle later; the line is re-read only in S_RETRY.
  logic        pd_we_lo, pd_we_hi;
  logic [IROWB-1:0] pd_wa;
  logic [1:0]  fill_way, pd_way;
  logic        fill_way0;                 // first fill cycle: choose the victim
  logic [31:0] pd_dl, pd_dh;
  logic [4*PDW-1:0] pd_pl, pd_ph;
  always_ff @(posedge clk) begin
    pd_we_lo <= !rst && (st == S_FILL) && fill_we && fill_hm[0];
    pd_we_hi <= !rst && (st == S_FILL) && fill_we && fill_hm[1];
    pd_wa    <= {fill_line[IWB-1:LB], fill_row[LB-4:0]};
    pd_way   <= fill_way;
    pd_dl    <= fill_data[31:0];
    for (int k = 0; k < 4; k++) pd_pl[k*PDW +: PDW] <= pdec(fill_data[k*8 +: 8]);
  end
  // full-row fills (64-bit or wider bus): a second set of predecoders for the
  // high word; otherwise both halves come from the same 32-bit word
  generate
  if (FILL64) begin : g_pd64
    always_ff @(posedge clk) begin
      pd_dh <= fill_data[63:32];
      for (int k = 0; k < 4; k++) pd_ph[k*PDW +: PDW] <= pdec(fill_data[32 + k*8 +: 8]);
    end
  end else begin : g_pd32
    assign pd_dh = pd_dl;
    assign pd_ph = pd_pl;
  end
  endgenerate
  localparam int IDW = 4*PDW + 32;
  logic [IDW-1:0] dlo [INW], dhi [INW];
  generate
  for (w = 0; w < INW; w = w + 1) begin : g_idata
    tetrium_bram #(.AW(IROWB), .DW(IDW)) u_dlo (
        .clk(clk), .re(1'b1), .raddr(rd_addr[IWB-1:3]), .rdata(dlo[w]),
        .we(pd_we_lo && pd_way == 2'(w)), .waddr(pd_wa), .wdata({pd_pl, pd_dl}));
    tetrium_bram #(.AW(IROWB), .DW(IDW)) u_dhi (
        .clk(clk), .re(1'b1), .raddr(rd_addr[IWB-1:3]), .rdata(dhi[w]),
        .we(pd_we_hi && pd_way == 2'(w)), .waddr(pd_wa), .wdata({pd_ph, pd_dh}));
  end
  endgenerate
  // hit way select: binary-encoded way, plain mux (1 LUT per bit for 4 ways),
  // from the tag match alone (a line is never held in two ways; the sub-block
  // valid bits only gate the hit), so the data select and the hit diverge early
  logic [1:0] fway;
  always_comb begin
    fway = '0;
    for (int w = 0; w < INW; w++) if (tmf[w]) fway = fway | 2'(w);
  end
  assign {bpd_lo, bram_lo} = dlo[fway];
  assign {bpd_hi, bram_hi} = dhi[fway];

  // ---------------------------------------------------------------- BTB
  // Branch target buffer in block RAM, read with the same address as the
  // I-cache: the prediction for block f_lin arrives together with its data.
  // Two ways (two branches per 8-byte block), one BRAM each so either can be
  // written without reading the other.  The first way predicted taken (lowest
  // end offset) is followed; a predicted-taken block is pushed normally and
  // its target is read in the next cycle (one bubble).
  //   way entry: {kind[1:0], valid, ind, tag = lin[19:BA+3], end[2:0], tgt[31:0]}
  //   (ind: indirect near JMP / CALL, whose target the target cache may predict)
  //   (partial tag: an alias above 1 MB is a wrong prediction like a stale entry,
  //   caught in decode / A / E)
  logic        t_we, t_taken, t_inval, t_pt;
  logic [31:0] t_lin;
  logic [31:0] t_tgt;
  logic [1:0]  t_kind;
  logic        t_ind, t_tcw;
`ifndef BTB_AW
`define BTB_AW 10
`endif
  localparam int BA = `BTB_AW;            // blocks = 2**BA (x2 ways), index lin[BA+2:3]
  localparam int TW = 17 - BA;            // tag bits lin[19:BA+3]
  localparam int BW = 2 + 1 + 1 + TW + 3 + 32;
  logic [1:0]    btb_wr;
  logic [BW-1:0] btb_wdata;
  logic [BW-1:0] bw [2];
  generate
  for (w = 0; w < 2; w = w + 1) begin : g_btb
    tetrium_bram #(.AW(BA), .DW(BW)) u_btb (
        .clk(clk), .re(1'b1), .raddr(rd_addr[BA+2:3]), .rdata(bw[w]),
        .we(btb_wr[w]), .waddr(t_lin[BA+2:3]), .wdata(btb_wdata));
  end
  endgenerate
  logic [1:0] w_vt, w_hit;                // way valid for this block / hit at or after f_lin
  logic [2:0] w_end [2];
  always_comb
    for (int w = 0; w < 2; w++) begin
      w_end[w] = bw[w][34:32];
      w_vt[w]  = bw[w][BW-3] && (bw[w][BW-5 -: TW] == f_lin[19:BA+3]);
`ifdef NOPRED
      w_hit[w] = 1'b0;
`else
      w_hit[w] = dv && w_vt[w] && (w_end[w] >= f_lin[2:0]) && !f_nopred;
`endif
    end

  // return address stack state (used below, snapshot in the ring)
`ifndef BP_RAS
`define BP_RAS 8
`endif
  localparam int RSD = `BP_RAS;           // return stack depth (power of 2)
  localparam int RSB = $clog2(RSD);
  logic [31:0] ras [RSD];
  logic [RSB-1:0] rsp;
  logic [31:0] ras_top;

  // ---------------------------------------------------------------- direction predictor
  // 2-bit counters in BRAM (one per way), index {fold(history), block address},
  // read with the BTB.  The address part comes straight from rd_addr; the
  // history part only from registers, so nothing is added to the fetch address
  // path.
  // History: one bit per pushed block that hits in the BTB: the predicted
  // direction of its first (lowest end offset) branch, newest at [0].  The block being pushed while its successor is
  // read is not in the history yet, so the index always leaves out the
  // predecessor's bit (history up to the block before it).
  // Each pushed block stores a snapshot {counters read, ways (valid, end),
  // index history, history before its own bit} in a 16-entry ring; its id
  // travels with the uops for training (way, index, counters) and redirect
  // repair (history).
  localparam int GA = 7;                  // block address bits in the index
  localparam int GK = 7;                  // folded history bits in the index
  // history bits folded into the index; GH must not be a multiple of GK, so
  // that some index bit takes an odd number of history bits (otherwise
  // periodic histories such as all-taken / all-not-taken fold to one index)
`ifndef BP_GH
`define BP_GH 15
`endif
  localparam int GH = `BP_GH;
  localparam int GHW = GH + 1;            // global history register (GH + lag)
  localparam int RB = 4 + 8 + GK + GHW;      // predictor part of the snapshot
  localparam int RW = RB + RSB + 32 + 8;      // + return stack {rsp, top}, target-cache history
  logic [GHW-1:0] ghist;
  logic          lsh;                     // the last pushed block added a history bit
  logic [GK-1:0] ih_rd, ih_q;
  logic [3:0]    gctr;                    // {way 1, way 0}
  logic [3:0]    bwp;
  logic [4*RW-1:0] ring_rd;
  logic [3:0]    t_bid;
  function automatic logic [GK-1:0] fold(input logic [GH-1:0] h);
    logic [GK-1:0] r;
    r = '0;
    for (int i = 0; i < GH; i++) r[i % GK] = r[i % GK] ^ h[i];
    return r;
  endfunction
  wire [RW-1:0] rt    = ring_rd[RW-1:0];          // training: snapshot of t_bid
  wire [GK-1:0] rt_ih = rt[GHW +: GK];
  wire [3:0]    rt_wv = rt[GHW+GK +: 4];          // {valid, end} of way 1 at fetch
  wire [3:0]    rt_w0 = rt[GHW+GK+4 +: 4];        // way 0
  wire [3:0]    rt_ct = rt[RB-1 -: 4];
  // redirect: the three possible sources' snapshots are decoded in parallel
  logic [GHW-1:0] rs_gh [3];
  logic          rs_bit [3];
  logic [RSB-1:0] rs_rsp [3];
  logic [31:0]   rs_top [3];
  always_comb
    for (int k = 0; k < 3; k++) begin
      logic [RW-1:0] r;
      logic [3:0] w0, w1;
      logic [2:0] fe, e;
      r  = ring_rd[(k+1)*RW +: RW];
      w1 = r[GHW+GK +: 4];
      w0 = r[GHW+GK+4 +: 4];
      fe = (w0[3] && (!w1[3] || w0[2:0] <= w1[2:0])) ? w0[2:0] : w1[2:0];
      e  = (k == 1) ? rlin_a : rlin_e;
      rs_gh[k]  = r[GHW-1:0];
      // the block's history bit: the branch's direction if it is the block's
      // first known branch, else 0 (the first branch was not taken)
      rs_bit[k] = (!(w0[3] || w1[3]) || (e <= fe)) ? redir_tk : 1'b0;
      rs_rsp[k] = r[RW-9 -: RSB];
      rs_top[k] = r[RW-9-RSB -: 32];
    end
  wire [1:0]    rsx    = (redir_src == 2'd3) ? 2'd0 : redir_src;
  wire [GHW-1:0] rr_gh = rs_gh[rsx];
  wire          rbit   = rs_bit[rsx];
  // Committed return stack (CALL / RET as they complete in E).  An E redirect
  // restores the whole speculative stack from it: everything older has
  // completed, nothing younger is valid.  (The ring snapshot holds only {rsp,
  // top}; wrong-path pops followed by pushes overwrite entries below the top,
  // and the E mispredict shadow is long.)  A / D redirects use the snapshot.
  logic [31:0] cras [RSD];
  logic [RSB-1:0] crsp;
  always_ff @(posedge clk) begin
    if (rst)          crsp <= '0;
    else if (ce_push) crsp <= crsp + 1'b1;
    else if (ce_pop)  crsp <= crsp - 1'b1;
    if (ce_push) cras[crsp + 1'b1] <= ce_rip;
  end
  wire          rs_e   = (rsx == 2'd0);
  // (an E redirect restores from the committed stack: snapshots of A / D only)
  wire [RSB-1:0] rr_rsp = rs_e ? crsp : rsx[1] ? rs_rsp[2] : rs_rsp[1];
  wire [31:0]   rr_top = rs_e ? cras[crsp] : rsx[1] ? rs_top[2] : rs_top[1];
  // history seen by the lookup issued this cycle (leaving out the predecessor's bit)
  logic [GHW-2:0] hview;
  always_comb begin
    if (redir_v)                       hview = rr_gh[GHW-2:0];    // predecessor = redirecting block
    else if (tk || (!dv && lsh))       hview = ghist[GHW-1:1];    // predecessor already shifted in
    else                               hview = ghist[GHW-2:0];
  end
  assign ih_rd = fold(hview[GH-1:0]);
  always_ff @(posedge clk) ih_q <= ih_rd;
  logic [1:0]    gp_we;                   // per way: a way's counter is written alone
  logic [3:0]    gp_wd;
  generate
  for (w = 0; w < 2; w = w + 1) begin : g_gp
    tetrium_bram #(.AW(GK + GA), .DW(2), .INIT(2'd2)) u_gp (
        .clk(clk), .re(1'b1), .raddr({ih_rd, rd_addr[GA+2:3]}), .rdata(gctr[2*w +: 2]),
        .we(gp_we[w]), .waddr({rt_ih, t_lin[GA+2:3]}), .wdata(gp_wd[2*w +: 2]));
  end
  endgenerate
  // the snapshot is written one cycle after the push (keeps the many ring
  // write enables off q_push); it is read at the earliest two cycles later
  logic          rg_we;
  logic [3:0]    rg_wa;
  logic [RW-1:0] rg_wd;
  always_ff @(posedge clk) begin
    rg_we <= q_push && !rst;
    rg_wa <= bwp;
    rg_wd <= {tch_q, rsp, ras_top, gctr, w_vt[0], w_end[0], w_vt[1], w_end[1], ih_q, ghist};
  end
  tetrium_lutram #(.AW(4), .DW(RW), .NR(4)) u_ring (
      .clk(clk), .clr(rst), .we(rg_we), .waddr(rg_wa), .wdata(rg_wd),
      .raddr({rid_d, rid_a, rid_e, t_bid}), .rdata(ring_rd));
  assign q_bid = bwp;
  // code segment selector of each pushed block (real mode / V86 base >> 4): a decode
  // redirect refetches in its instruction's own code segment (a far prediction may have
  // changed f_cs since)
  logic [15:0] csr_rd;
  tetrium_lutram #(.AW(4), .DW(16), .NR(1)) u_csring (
      .clk(clk), .clr(1'b0), .we(q_push), .waddr(bwp), .wdata(f_cs[19:4]),
      .raddr(csr_bid), .rdata(csr_rd));
  assign csr_sel = csr_rd;

  // ---------------------------------------------------------------- indirect target cache
  // 256 entries {tag = lin[14:11], target}, direct-mapped, index = block address ^ folded
  // direction history ^ hash of the last two indirect targets (updated as E trains them, in
  // program order: the jumps still in flight are not in it).  Read with the BTB; a hit for
  // a BTB way marked indirect predicts its target (else the BTB's last target).  The hash
  // used by a block's lookup is kept in the ring for its training.  Written only when such
  // a jump was mispredicted: jumps with a stable target stay out of it (no extra bubble).
  logic [7:0]  tp1, tp2;                  // folded last / previous indirect target
  wire  [7:0]  tch   = tp1 ^ {tp2[3:0], tp2[7:4]};
  logic [7:0]  tch_q;
  wire  [7:0]  tc_ra = rd_addr[10:3] ^ {1'b0, ih_rd} ^ tch;
  always_ff @(posedge clk) tch_q <= tch;
  wire  [7:0]  rt_tch = rt[RW-1 -: 8];
  wire         tc_we  = t_we && t_tcw && t_taken && !t_inval;
  logic [35:0] tcr;
  tetrium_bram #(.AW(8), .DW(36)) u_tc (
      .clk(clk), .re(1'b1), .raddr(tc_ra), .rdata(tcr),
      .we(tc_we), .waddr(t_lin[10:3] ^ {1'b0, rt_ih} ^ rt_tch), .wdata({t_lin[14:11], t_tgt}));
  always_ff @(posedge clk)
    if (rst) begin tp1 <= '0; tp2 <= '0; end
    else if (t_we && t_ind && t_taken && !t_inval) begin tp2 <= tp1; tp1 <= t_tgt[8:1] ^ t_tgt[16:9]; end

  // prediction: first way predicted taken
  wire [1:0] w_tk = w_hit & {gctr[3], gctr[1]};     // base (fast) prediction
  wire       sel1 = w_tk[1] && (!w_tk[0] || (w_end[1] < w_end[0]));
  wire       bhit       = |w_hit;
  wire       first1     = w_hit[1] && (!w_hit[0] || (w_end[1] < w_end[0]));
  wire       hbit       = first1 ? w_tk[1] : w_tk[0];      // first branch's direction
  wire       pred_taken = |w_tk;
  wire [BW-1:0] be      = sel1 ? bw[1] : bw[0];
  wire [1:0]    be_kind = be[BW-1 -: 2];
  wire [2:0]    be_end  = be[34:32];
  wire [31:0]   be_tgt  = be[31:0];
  // the target cache overrides the BTB's last target (one more bubble: the target is added
  // to f_cs in the first, off the per-way target adders)
  wire          wind0   = bw[0][BW-4] && (bw[0][BW-1 -: 2] != 2'd2);
  wire          wind1   = bw[1][BW-4] && (bw[1][BW-1 -: 2] != 2'd2);
  wire          tc_use  = (sel1 ? wind1 : wind0) && (tcr[35:32] == f_lin[14:11]);
`ifdef BPDBG
  always_ff @(posedge clk) begin
    if (q_push) $display("F push lin=%05x ip=%04x hit=%b pt=%0d end=%0d kind=%0d tgt=%04x bid=%0d ctr=%h",
                         f_lin, f_ip, w_hit, pred_taken, be_end, be_kind, tgt_ip, bwp, gctr);
    if (redir_v) $display("F redir csb:ip=%08x:%08x src=%0d br=%0d tk=%0d nopred=%0d", redir_csb, redir_ip, redir_src, redir_br, redir_tk, redir_nopred);
    if (t_we) $display("F train lin=%05x tk=%0d inval=%0d pt=%0d kind=%0d tgt=%04x way=%b", t_lin, t_taken, t_inval, t_pt, t_kind, t_tgt, t_way);
  end
`endif

  // training: registered, write-only.  The snapshot of the branch's fetch block
  // gives the way that holds it (by end offset) or the way to replace, and the
  // counters read at prediction time (2-bit saturating update).
  always_ff @(posedge clk) begin
    t_we <= !rst && btb_we;
    t_taken <= btb_taken; t_inval <= btb_inval; t_lin <= btb_lin; t_tgt <= btb_tgt;
    t_kind <= btb_kind; t_pt <= btb_pt; t_bid <= btb_bid; t_ind <= btb_ind; t_tcw <= btb_tcw;
  end
  logic       rr_bit;                     // alternating victim when both ways are in use
  always_ff @(posedge clk)
    if (rst) rr_bit <= 1'b0;
    else if (t_we && t_taken) rr_bit <= !rr_bit;
  wire  m0 = rt_w0[3] && (rt_w0[2:0] == t_lin[2:0]);
  wire  m1 = rt_wv[3] && (rt_wv[2:0] == t_lin[2:0]) && !m0;
  wire  vict1 = rt_w0[3] && (!rt_wv[3] || rr_bit);
  logic [1:0] t_way;                      // one-hot way trained
  always_comb begin
    logic [1:0] c;
    c = 2'd0;
    t_way = m0 ? 2'b01 : m1 ? 2'b10 : (vict1 ? 2'b10 : 2'b01);
    btb_wr = 2'b00; btb_wdata = {t_kind, 1'b1, t_ind, t_lin[19:BA+3], t_lin[2:0], t_tgt};
    gp_wd  = rt_ct;
    gp_we  = 2'b00;
    if (t_we) begin
      if (t_inval) begin
        btb_wr = {m1, m0}; btb_wdata[BW-3] = 1'b0;          // drop the entry (valid = 0)
      end else if (m0 || m1 || t_taken) begin
        if (t_taken) btb_wr = t_way;                        // (re)write the entry
        gp_we = t_way;
        for (int w = 0; w < 2; w++)
          if (t_way[w]) begin
            c = rt_ct[2*w +: 2];
            if (!(m0 || m1)) gp_wd[2*w +: 2] = 2'd2;        // new entry: weakly taken
            else gp_wd[2*w +: 2] = t_taken ? ((c == 2'd3) ? 2'd3 : c + 2'd1)
                                           : ((c == 2'd0) ? 2'd0 : c - 2'd1);
          end
      end
    end
  end

  logic [2:0] wq_n;                        // queued store invalidations (snoop section)
  logic       sh0_v, sh1_v;
  // ---------------------------------------------------------------- next PC
  wire        hit   = dv && |hvf && lp_ok;
  // (no pushes while store invalidations are queued: those lines may be stale)
  wire        run   = (st == S_RUN) && f_valid && !redir_v && !stop && (wq_n == 3'd0) && !sh0_v && !sh1_v;
  logic        tk;          // bubble cycle: read the predicted target
  logic [31:0] tk_lin;
  logic [31:0] tk_ip;
  assign      q_push = run && hit && !q_full && !tk;
  // (no wrap at 64 KB: bytes beyond the code segment limit fault in A)
  wire [31:0] blk_ip = {f_ip[31:3], 3'b000};
  wire [31:0] seq_lin = a20({f_lin[31:3], 3'b000} + 32'd8);
  wire [31:0] seq_ip  = blk_ip + 32'd8;
  // target / return address of each way computed before the way select
  // (keep: otherwise synthesis shares one adder after the select)
  (* keep = "true" *) wire [31:0] wtgt_lin0 = a20(f_cs + bw[0][31:0]);
  (* keep = "true" *) wire [31:0] wtgt_lin1 = a20(f_cs + bw[1][31:0]);

  // ---------------------------------------------------------------- return address stack
  wire  [31:0] ras_lin  = a20(f_cs + ras_top);
  wire         p_ret    = pred_taken && (be_kind == 2'd2);
  wire         p_call   = pred_taken && (be_kind == 2'd1);
  (* keep = "true" *) wire [31:0] cret0 = {f_ip[31:3], w_end[0]} + 32'd1;  // IP after the predicted CALL
  (* keep = "true" *) wire [31:0] cret1 = {f_ip[31:3], w_end[1]} + 32'd1;
  wire  [31:0] call_ret = sel1 ? cret1 : cret0;
  // per-way final target (RAS for a return), then the way select
  wire  [31:0] wtl0 = (bw[0][BW-1 -: 2] == 2'd2) ? ras_lin : wtgt_lin0;
  wire  [31:0] wtl1 = (bw[1][BW-1 -: 2] == 2'd2) ? ras_lin : wtgt_lin1;
  wire  [31:0] wti0 = (bw[0][BW-1 -: 2] == 2'd2) ? ras_top : bw[0][31:0];
  wire  [31:0] wti1 = (bw[1][BW-1 -: 2] == 2'd2) ? ras_top : bw[1][31:0];
  wire  [31:0] tgt_lin  = sel1 ? wtl1 : wtl0;
  wire  [31:0] tgt_ip   = sel1 ? wti1 : wti0;
  // Far predictions (real mode / V86, where an offset fits 16 bits): a target or return
  // address with nonzero upper half is {selector, offset} of a far transfer that changes
  // CS.  Such a prediction takes a second bubble: the first computes the linear target
  // and the new CS base (off the f_cs + target adders above).
  wire         far_sel  = rm && (tgt_ip[31:16] != 16'h0) && !tc_use;
  logic        tk_far;                 // this bubble is the first of two (far / target cache)
  logic        tk_fcs;                 //   a far prediction: tk_ip = {selector, offset}
  wire  [31:0] far_lin  = a20((tk_fcs ? {12'h0, tk_ip[31:16], 4'h0} : f_cs) + (tk_fcs ? {16'h0, tk_ip[15:0]} : tk_ip));
  // The array write is registered (one cycle late, off the hit -> q_push path).
  // A pop never reads the slot still pending: that slot is the new top, whose
  // value is in ras_top, and a pop reads the one below it.
  logic        rw_v;
  logic [RSB-1:0] rw_a;
  logic [31:0] rw_d;
  // On a redirect the stack is restored to its state before the redirecting
  // uop's block (snapshot), then that uop's own CALL / RET is applied.  Only an E
  // redirect pops (A redirects push, D redirects neither: tetrium_core), so the entry
  // below the restored top comes from the committed stack alone.
  wire  [31:0] rb_dnv = cras[crsp - 1'b1];
`ifdef SIM
  always_ff @(posedge clk)
    if (!rst && redir_v && redir_rpop && !redir_rpush && !rs_e) $error("return stack pop on an A / D redirect");
`endif
  // The pending array write's address / data are loaded every cycle (selected
  // by the registered redirect / override state only); just rw_v, rsp and
  // ras_top depend on the late push decision (BTB hit -> way -> call / ret).
  wire  [RSB-1:0] base_sp = redir_v ? rr_rsp : rsp;           // stack before this cycle's op
  wire  [31:0] push_d  = redir_v ? redir_rip : pq_d;
  wire  [31:0] pop_v   = redir_v ? rb_dnv : ras[rsp - 1'b1];
  wire  [31:0] keep_t  = redir_v ? rr_top : ras_top;
  // A predicted CALL / RET (always a taken block, so the next cycle is the
  // bubble) is applied one cycle later: the next block that can read the stack
  // is pushed two cycles after it.  A redirect / override in the bubble cycle
  // replaces it.
  logic        pq_push, pq_pop;
  logic [31:0] pq_d;
  always_ff @(posedge clk) begin
    pq_push <= !rst && !redir_v && q_push && p_call;
    pq_pop  <= !rst && !redir_v && q_push && p_ret;
    // (a far CALL that changes CS pushes {its selector, return offset})
    pq_d    <= (rm && (tgt_ip[31:16] != 16'h0)) ? {f_cs[19:4], call_ret[15:0]} : call_ret;
  end
  logic        do_push, do_pop;
  always_comb begin
    if (redir_v)    begin do_push = redir_rpush; do_pop = !redir_rpush && redir_rpop; end
    else            begin do_push = pq_push; do_pop = pq_pop; end
  end
  always_ff @(posedge clk) begin
    rw_v <= !rst && do_push;
    rw_a <= base_sp + 1'b1;
    rw_d <= push_d;
    if (rst) begin
      rsp <= '0; ras_top <= '0;
    end else begin
      rsp     <= do_push ? base_sp + 1'b1 : do_pop ? base_sp - 1'b1 : base_sp;
      ras_top <= do_push ? push_d : do_pop ? pop_v : keep_t;
    end
    if (redir_v && rs_e) begin
      for (int i = 0; i < RSD; i++) ras[i] <= cras[i];
    end else if (rw_v) ras[rw_a] <= rw_d;
  end
  wire [31:0] redir_lin = a20(redir_csb + redir_ip);

  // The BRAM always reads the next sequential block when the current data is
  // valid; if that block is not consumed (miss / queue full) dv drops and the
  // current address is re-read.  After a predicted-taken push the target is
  // read in the bubble cycle.  The read address comes only from registers.
  assign rd_addr = redir_v ? redir_lin : tk ? tk_lin : dv ? seq_lin : f_lin;
  always_comb begin
    if (redir_v)     f_lin_next = redir_lin;
    else if (tk)     f_lin_next = tk_lin;
    else if (q_push) f_lin_next = seq_lin;
    else             f_lin_next = f_lin;
  end

  assign q_data = {bram_hi, bram_lo};
  assign q_pd   = {bpd_hi, bpd_lo};
  assign q_s    = f_lin[2:0];
  assign q_e    = pred_taken ? be_end : 3'd7;
  assign q_pt   = pred_taken;
  assign q_ptgt = tc_use ? tcr[31:0] : tgt_ip;
  assign q_lin  = f_lin[31:3];
  assign q_ip   = f_ip[31:3];

  // ---------------------------------------------------------------- uncacheable code (PCD)
  // A line filled from a page with PCD set is used once: it becomes valid as any fill,
  // and is invalidated as soon as fetch pushes a block of another line, is redirected or
  // starts another fill (the next entry into it reads memory again).
  logic             fill_nc;               // the fill in progress is from a PCD page
  logic             nc_v;                  // such a line is valid: {set, way, line}
  logic [ISETB-1:0] nc_set;
  logic [1:0]       nc_way;
  logic [31:LB]     nc_ln;
  logic             nc_inv;                // its invalidation is pending (tag port)
  logic [ISETB-1:0] nc_iset;
  logic [1:0]       nc_iway;
  wire              nc_wr = nc_inv && (st != S_INIT) && !inv_pend && (wq_n == 3'd0);
  always_ff @(posedge clk) begin
    if (rst) begin nc_v <= 1'b0; nc_inv <= 1'b0; end
    else begin
      if (nc_wr) nc_inv <= 1'b0;
      if (st == S_FILLTAG && fill_nc && !nc_inv && !inv_pend && wq_n == 3'd0 && !sh0_v && !sh1_v) begin
        nc_v <= 1'b1; nc_set <= fill_line[IWB-1:LB]; nc_way <= fill_way; nc_ln <= fill_line[31:LB];
      end else if (nc_v && ((q_push && f_phy[31:LB] != nc_ln) || redir_v || st == S_FILL)) begin
        nc_v <= 1'b0; nc_inv <= 1'b1; nc_iset <= nc_set; nc_iway <= nc_way;
      end
    end
  end

  // ---------------------------------------------------------------- snoop
  // External writes and this CPU's stores invalidate matching I-cache lines.
  // A store that hits a valid line is self-modifying code: smc_hit makes E
  // refetch after its instruction boundary, so instructions fetched before the
  // store are not executed; fills wait for the store buffer.
  logic           inv_pend;
  logic [INW-1:0] inv_wv;
  logic [ISETB-1:0] inv_idx;
  logic [ITAGB-1:0] fill_tag;
  // the store's lines are looked up while it is in E (registered with the W
  // address registers, same enable), and used when W hands it to the buffer
  logic [INW-1:0] eh0_q, eh1_q;
  always_ff @(posedge clk)
    if (!hold_w) begin eh0_q <= hw0; eh1_q <= hw1; end
  wire  ws_h0 = wsn_v && |eh0_q;
  wire  ws_h1 = wsn_v && (wsn_l1 != wsn_l0) && |eh1_q;
  // a fill must not become valid if a store to its line is in E or W (the
  // store may not have reached memory before the fill read it)
  function automatic logic sl(input logic [31:3] a, input logic [31:4] b);
    return a[31:LB] == b[31:LB];
  endfunction
  wire  fill_hit_st = (est_v && (sl(est_l0, fill_line) || sl(est_l1, fill_line))) ||
                      (wsn_v && (sl(wsn_l0, fill_line) || sl(wsn_l1, fill_line)));
  wire  fill_hit_sn = snp_v && (snp_line[31:LB] == fill_line[31:LB]);
  // pending store invalidations {set, ways, sub-block}: W is held while any is
  // pending, so at most the two of one store are queued
  logic [ISETB-1:0] wq [2];
  logic [INW-1:0]   wqv [2];
  logic [SBB-1:0]   wqs [2];
  wire        wq_pop = (wq_n != 3'd0) && !(st == S_INIT) && !inv_pend;
  // hits are registered first (sh_*) and queued in the next cycle
  logic [ISETB-1:0] sh0_i, sh1_i;
  logic [INW-1:0]   sh0_w, sh1_w;
  logic [SBB-1:0]   sh0_s, sh1_s;
  assign smc_hit  = ws_h0 || ws_h1;
  // (blocks of that line fetched along a predicted path before the snoop may already
  // be in the pipeline: E refetches at the next instruction boundary, as for a store.
  // A real 486 fetches past a jump only once it executes, so DMA'd code is always seen)
  assign snp_hit  = inv_pend;
  assign smc_busy = (wq_n != 3'd0) || sh0_v || sh1_v || ws_h0 || ws_h1;
  // smc_hold = (wq_n != 0) || sh0_v || sh1_v, registered from their next values (W hold path)
  logic smc_hold_q;
  assign smc_hold = smc_hold_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      inv_pend <= 1'b0;
      inv_idx  <= '0;
      wq_n     <= '0;
      sh0_v    <= 1'b0;
      sh1_v    <= 1'b0;
      smc_hold_q <= 1'b0;
    end else begin
      logic [ISETB-1:0] q [2];
      logic [INW-1:0]   qv [2];
      logic [SBB-1:0]   qs [2];
      logic [2:0] n;
      inv_pend <= snp_v && |hvs;
      inv_wv   <= hvs;
      inv_idx  <= snp_line[IWB-1:LB];
      for (int i = 0; i < 2; i++) begin q[i] = wq[i]; qv[i] = wqv[i]; qs[i] = wqs[i]; end
      n = wq_n;
      if (wq_pop) begin   // (written this cycle)
        q[0] = q[1]; qv[0] = qv[1]; qs[0] = qs[1];
        n = n - 3'd1;
      end
      if (sh0_v) begin q[n[0]] = sh0_i; qv[n[0]] = sh0_w; qs[n[0]] = sh0_s; n = n + 3'd1; end
      if (sh1_v) begin q[n[0]] = sh1_i; qv[n[0]] = sh1_w; qs[n[0]] = sh1_s; n = n + 3'd1; end
      sh0_v <= ws_h0; sh0_i <= wsn_l0[IWB-1:LB]; sh0_w <= eh0_q; sh0_s <= sbi(wsn_l0);
      sh1_v <= ws_h1; sh1_i <= wsn_l1[IWB-1:LB]; sh1_w <= eh1_q; sh1_s <= sbi(wsn_l1);
      for (int i = 0; i < 2; i++) begin wq[i] <= q[i]; wqv[i] <= qv[i]; wqs[i] <= qs[i]; end
      wq_n <= n;
      smc_hold_q <= (n != 3'd0) || ws_h0 || ws_h1;
    end
  end

  always_comb begin
    logic [SBW-1:0] m;
    tag_we    = '0;
    tag_waddr = inv_idx;
    tag_wdata = {1'b0, {ITAGB{1'b1}}};             // invalid
    sbv_we    = 1'b0;
    sbv_wa    = wq[0];
    sbv_wd    = sbv_cur;
    m         = '0;
    if (st == S_INIT) begin
      tag_we    = '1;
      tag_waddr = init_cnt;
      sbv_we    = 1'b1;
      sbv_wa    = init_cnt;
      sbv_wd    = '0;
    end else if (inv_pend) begin
      tag_we    = inv_wv;
      sbv_we    = 1'b1;
      sbv_wa    = inv_idx;
      for (int w = 0; w < INW; w++) if (inv_wv[w]) m[w*NSB +: NSB] = '1;
      sbv_wd    = sbv_cur & ~m;
    end else if (wq_n != 3'd0) begin
      sbv_we    = 1'b1;                            // store: drop just its 8-byte block
      for (int w = 0; w < INW; w++) if (wqv[0][w]) m[w*NSB + wqs[0]] = 1'b1;
      sbv_wd    = sbv_cur & ~m;
    end else if (nc_inv) begin
      tag_we[nc_iway] = 1'b1;                      // a PCD line left by fetch: invalid
      tag_waddr = nc_iset;
      sbv_we    = 1'b1;
      sbv_wa    = nc_iset;
      m[nc_iway*NSB +: NSB] = '1;
      sbv_wd    = sbv_cur & ~m;
    end else if (st == S_FILLTAG) begin
      tag_we[fill_way]  = 1'b1;
      tag_waddr = fill_line[IWB-1:LB];
      tag_wdata = {!(poisoned || fill_hit_st || fill_hit_sn), fill_tag};
      sbv_we    = 1'b1;
      sbv_wa    = fill_line[IWB-1:LB];
      sbv_wd    = sbv_cur;
      sbv_wd[fill_way*NSB +: NSB] = {NSB{tag_wdata[ITAGB]}};
    end
  end

  // ---------------------------------------------------------------- replacement (tree PLRU)
  // written (one cycle late) on fetch hits (pushed blocks) and fills
  localparam int IPB = (INW > 1) ? INW - 1 : 1;
  logic             ipu_v;
  logic [ISETB-1:0] ipu_set;
  logic [1:0]       ipu_way;
  logic [IPB-1:0]   ipl;
  // (the tree bits of a set in one RAM, written read-modify-write through a port at
  // the write address: only the bits on the accessed way's path change)
  logic [IPB-1:0]   ipl_cur, ipl_wd;
  always_comb begin
    ipl_wd = ipl_cur;
    for (int k = 0; k < IPB; k++)
      if ((k == 0) || (INW == 4 && ((k == 1) == (ipu_way[1] == 1'b0))))
        ipl_wd[k] = (k == 0) ? ((INW == 4) ? !ipu_way[1] : !ipu_way[0]) : !ipu_way[0];
  end
  tetrium_lutram #(.AW(ISETB), .DW(IPB), .NR(2)) u_pl (
      .clk(clk), .clr(rst), .we(ipu_v), .waddr(ipu_set), .wdata(ipl_wd),
      .raddr({ipu_set, f_lin[IWB-1:LB]}), .rdata({ipl_cur, ipl}));
  // victim: chosen in the first fill cycle from the vectors registered at the
  // miss (the first beat is written two cycles later at the earliest)
  logic [INW-1:0] mv_tm, mv_v;
  logic [IPB-1:0] mv_pl;
  always_ff @(posedge clk) begin mv_tm <= tmf; mv_v <= vf; mv_pl <= ipl; end
  logic [1:0] ivict;
  always_comb begin
    if (INW == 4)      ivict = mv_pl[0] ? {1'b1, mv_pl[IPB-1]} : {1'b0, mv_pl[INW > 2 ? 1 : 0]};
    else if (INW == 2) ivict = {1'b0, mv_pl[0]};
    else               ivict = 2'd0;
    for (int w = INW - 1; w >= 0; w--) if (!mv_v[w]) ivict = 2'(w);   // an empty way first
    // the line is present with an invalidated sub-block: refill that way, so a
    // line is never held twice (tag matches stay one-hot for the way select)
    for (int w = 0; w < INW; w++) if (mv_tm[w]) ivict = 2'(w);
  end
  function automatic logic [1:0] ienc(input logic [INW-1:0] v);
    logic [1:0] r;
    r = '0;
    for (int w = 0; w < INW; w++) if (v[w]) r = r | 2'(w);
    return r;
  endfunction
  always_ff @(posedge clk) begin
    ipu_v   <= !rst && (q_push || st == S_FILLTAG);
    ipu_set <= (st == S_FILLTAG) ? fill_line[IWB-1:LB] : f_lin[IWB-1:LB];
    ipu_way <= (st == S_FILLTAG) ? fill_way : fway;
  end

  assign fill_req  = (st == S_FILL);
  assign cs_o      = f_cs;
  assign busy_init = (st == S_INIT);
  logic  ia_pend;
  assign inv_busy  = ia_pend || (st == S_INIT);

  // ---------------------------------------------------------------- paging state
  logic fw_out, fw_stale;          // walk requested / redirected meanwhile (result unused)
  logic [31:12] fw_a;              // its page
  assign fl_a     = f_lin[31:12];
  assign fl_touch = (st == S_XL);
  assign f_req    = (st == S_FW) && !fw_out && !fw_stale && fe_drained;
  assign lt_v     = q_push && pg;
  assign lt_sw    = {f_lin[14:12], lpf_way};
  assign ff_flt   = (st == S_FAULT);
  // fills: a TLB hit in S_XL, a fetch walk; a TLB write drops the entries copying it
  always_comb begin
    fu_we = 1'b0; fu_wa = fu_i; fu_ww = fl_way;
    fu_wd = {f_lin[31:12], fl_e[24:5], fl_e[4], fl_e[1]};
    if (st == S_XL && fl_hit) fu_we = 1'b1;
    else if (st == S_FW && f_done && w_ok) begin
      fu_we = 1'b1; fu_wa = fw_a[12 +: FSB]; fu_ww = w_way;
      fu_wd = {fw_a, w_e[24:5], w_e[4], w_e[1]};
    end
  end
  always_ff @(posedge clk) begin
    if (rst || lpf_kill) fu_v <= '0;
    else begin
      for (int i = 0; i < FUN; i++)
        if (tw_v && tw_sw == {3'(i), fu_way[i]}) fu_v[i] <= 1'b0;
      if (fu_we) fu_v[fu_wa] <= 1'b1;
    end
    if (fu_we) fu_way[fu_wa] <= fu_ww;
    if (rst) begin fw_out <= 1'b0; fw_stale <= 1'b0; end
    else begin
      if (f_req && f_acc) begin fw_out <= 1'b1; fw_a <= f_lin[31:12]; end
      else if (f_done) fw_out <= 1'b0;
      if (st != S_FW || f_done) fw_stale <= 1'b0;
      else if (redir_v || stop) fw_stale <= 1'b1;
    end
    if (st == S_FW && f_done) begin ff_err <= w_err; ff_lin <= f_lin; end
  end

`ifdef SIM
  logic ptr;
  initial ptr = $test$plusargs("ptrace");
  st_t st_q;
  always_ff @(posedge clk) begin
    st_q <= st;
    if (ptr && (f_req && f_acc || f_done)) $display("F walk acc=%0d done=%0d fw_out=%0d st=%0d", f_req && f_acc, f_done, fw_out, st);
    if (ptr && st != st_q)
      $display("F st %0d -> %0d f_lin=%08x lp_ok=%0d lpf=%0d:%05x dr=%0d req=%0d", st_q, st, f_lin, lp_ok, lpf_v, lpf_vpn, fe_drained, f_req);
  end
`endif
  // ---------------------------------------------------------------- FSM
  always_ff @(posedge clk) begin
    if (rst) begin
`ifdef SIM
      st       <= S_RUN;
`else
      st       <= S_INIT;
`endif
      init_cnt <= '0;
      f_valid  <= 1'b0;
      f_lin    <= '0;
      f_ip     <= '0;
      f_cs     <= '0;
      f_nopred <= 1'b0;
      dv       <= 1'b0;
      tk       <= 1'b0;
      tk_far   <= 1'b0;
      poisoned <= 1'b0;
      ghist    <= '0;
      lsh      <= 1'b0;
      bwp      <= '0;
      fill_line <= '0;
      fill_tag <= '0;
      ia_pend  <= 1'b0;
    end else begin
      if (inv_all) ia_pend <= 1'b1;
      f_lin <= f_lin_next;
      dv    <= redir_v || tk || (dv && q_push) || !dv;
      tk    <= !redir_v && !stop && ((q_push && pred_taken) || (tk && tk_far));
      tk_far <= !redir_v && !stop && q_push && pred_taken && (far_sel || tc_use);
      tk_fcs <= far_sel;
      if (tk && tk_far) begin
        tk_lin <= far_lin;
        tk_ip  <= tk_fcs ? {16'h0, tk_ip[15:0]} : tk_ip;
      end else begin
        tk_lin <= tgt_lin;
        tk_ip  <= tc_use ? tcr[31:0] : tgt_ip;
      end
      // global history: repaired from the redirecting block's snapshot
      if (redir_v) begin
        // the block's bit: the branch's direction if it is the block's first
        // known branch, else 0 (the first branch was not taken)
        ghist <= redir_br ? {rr_gh[GHW-2:0], rbit} : rr_gh;
        lsh   <= redir_br;
      end else if (q_push) begin
        bwp <= bwp + 1'b1;
        lsh <= bhit;
        if (bhit) ghist <= {ghist[GHW-2:0], hbit};
      end
      if (redir_v) begin
        f_valid  <= 1'b1;
        f_ip     <= redir_ip;
        f_cs     <= redir_csb;
        f_nopred <= redir_nopred;
      end else if (stop) begin
        f_valid  <= 1'b0;
      end else if (tk) begin
        f_ip     <= tk_ip;
        if (tk_far && tk_fcs) f_cs <= {12'h0, tk_ip[31:16], 4'h0};
      end else if (q_push) begin
        f_nopred <= 1'b0;
        f_ip     <= seq_ip;
      end
      case (st)
        S_INIT: begin
          init_cnt <= init_cnt + 1'b1;
          if (&init_cnt) st <= S_RUN;
        end
        S_RUN: begin
          if (ia_pend) begin
            st       <= S_INIT;
            init_cnt <= '0;
            ia_pend  <= inv_all;
          end else if (run && dv && !tk && !lp_ok) st <= S_XL;
          else if (run && dv && !hit && !tk) begin
            st        <= S_FILL;
            fill_line <= f_phy[31:4];
            fill_tag  <= f_phy[31:IWB];
            fill_way0 <= 1'b1;
            poisoned  <= 1'b0;
            fill_nc   <= pg && lpf_pcd;
          end
        end
        S_FILL: begin
          if (fill_way0) begin fill_way <= ivict; fill_way0 <= 1'b0; end
          if (fill_hit_sn || fill_hit_st) poisoned <= 1'b1;
          if (fill_done) st <= S_FILLTAG;
        end
        S_FILLTAG: begin
          if (fill_hit_sn || fill_hit_st) poisoned <= 1'b1;
          if (!inv_pend && wq_n == 3'd0 && !sh0_v && !sh1_v && !nc_inv) st <= S_RETRY;
        end
        S_RETRY: begin
          st <= S_RUN;       // BRAM re-read of f_lin happened this cycle
        end
        // TLB lookup of the new page (the BRAM re-reads f_lin meanwhile)
        S_XL: st <= (fl_hit && (fl_e[4] || !cpl3)) ? S_RUN : S_FW;
        // walk, once nothing older is left; a redirect meanwhile only waits for it
        S_FW: if (f_done) st <= (w_ok || fw_stale) ? S_RUN : S_FAULT;
        S_FAULT: ;
        default: st <= S_RUN;
      endcase
      // data of the BRAM is not valid for f_lin while filling / right after
      if (st == S_FILL || st == S_FILLTAG) dv <= 1'b0;
      if ((redir_v || stop) && (st == S_XL || st == S_FAULT || (st == S_FW && !fw_out && !(f_req && f_acc))))
        st <= S_RUN;
      // a cache sweep (INVD / WBINVD in E) does not wait for a fetch translation: the walk is
      // only requested once E has drained, and E waits for the sweep (deadlock).  The
      // translation is dropped and redone after the sweep (the flush redirects fetch anyway).
      if (ia_pend && (st == S_XL || st == S_FAULT || (st == S_FW && !fw_out && !(f_req && f_acc)))) begin
        st       <= S_INIT;
        init_cnt <= '0;
        ia_pend  <= inv_all;
      end
    end
  end
endmodule
