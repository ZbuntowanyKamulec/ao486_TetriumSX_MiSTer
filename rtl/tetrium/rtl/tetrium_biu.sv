// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium bus interface unit: pipelined Wishbone (B4) master, data width BUS_DW
// (16, 32, 64 or 128 bit; wb_adr is the beat address, wb_sel one bit per byte lane)
//  * line fills are issued as LINE_B/(BUS_DW/8) back-to-back pipelined requests and
//    handed to the caches as 8-byte row writes (one per cycle, see f_*):
//      16 bit: two beats assembled per 32-bit word, a half-row write each
//      32 bit: one half-row write per beat
//      64 bit: one full-row write per beat
//     128 bit: two rows per beat; rows that cannot be written in the beat's cycle
//              wait in a line buffer (the fill ends one cycle after the last ack)
//  * store buffer writes are streamed: one request per cycle (two for a word with
//    bytes in both halves on a 16-bit bus), up to 8 outstanding acks; an entry
//    leaves the store buffer when it is loaded into the request register
//  * tga: 0 = memory, 1 = I/O, 2 = interrupt acknowledge
//  * a single access of 1, 2 or 4 bytes is issued per 32-bit word it touches
//    (per 16-bit half on a 16-bit bus): 1 to 3 requests
`include "tetrium_cfg.svh"
module tetrium_biu #(
    parameter int BUS_DW = 32
) (
    input  logic        clk,
    input  logic        rst,
    // store buffer
    input  logic        sb_v,
    input  logic [31:2] sb_adr,
    input  logic [3:0]  sb_be,
    input  logic [31:0] sb_dat,
    output logic        sb_pop,
    output logic        wr_busy,      // write stream active (queued or unacked writes)
    // I-cache fill
    input  logic        if_req,
    input  logic        if_ok,        // no store in W (fills wait for all stores to reach memory)
    input  logic [31:4] if_line,
    output logic        if_we,
    output logic        if_done,      // with the last row write
    // D-cache fill
    input  logic        df_req,
    input  logic [31:4] df_line,
    output logic        df_we,
    output logic        df_done,      // with the last row write
    // fill row write (both caches)
    output logic [1:0]  f_row,        // 8-byte row within the line
    output logic [1:0]  f_hm,         // words written: [0] low (even), [1] high (odd)
    output logic [63:0] f_data,
    // D uncached read
    input  logic        du_req,
    input  logic [31:0] du_lin,
    input  logic [31:2] du_lin4,
    input  logic [1:0]  du_sz,        // 0: 1 byte, 1: 2 bytes, 2: 4 bytes
    output logic        du_done,
    // page walker: one aligned 32-bit memory access; while pw_lock is set nothing
    // else is started (locked page-table read-modify-write)
    input  logic        pw_req,
    input  logic        pw_we,
    input  logic        pw_lock,
    input  logic [31:2] pw_adr,
    input  logic [31:0] pw_wdat,
    output logic        pw_done,
    input  logic        lk_hold,      // locked RMW: only its uncached read, its store, walks
    output logic        wb_lock,
    // E I/O / INTA
    input  logic        io_req,
    input  logic        io_we,
    input  logic        io_inta,
    input  logic [15:0] io_port,
    input  logic [1:0]  io_sz,
    input  logic [31:0] io_wdata,
    output logic        io_done,
    output logic [31:0] rdata32,      // read result, right-aligned (valid with *_done)
    // store snoop (I-cache invalidation)
    output logic        snp_v,
    output logic [31:4] snp_line,
    // Wishbone
    output logic        wb_cyc,
    output logic        wb_stb,
    output logic        wb_we,
    output logic [31:$clog2(BUS_DW/8)] wb_adr,
    output logic [BUS_DW/8-1:0]        wb_sel,
    output logic [BUS_DW-1:0]          wb_dato,
    output logic [1:0]  wb_tga,
    input  logic [BUS_DW-1:0]          wb_dati,
    input  logic        wb_ack,
    input  logic        wb_stall
);
  localparam int BB  = BUS_DW / 8;               // bytes per beat
  localparam int AB  = $clog2(BB);
  localparam int LB  = $clog2(`LINE_B);
  localparam int NBL = `LINE_B / BB;             // beats per line fill
  localparam int PW  = (BB == 2) ? 16 : 32;      // piece of a single access per beat
  localparam int NR  = `LINE_B / 8;              // rows per line
  initial assert (BB == 2 || BB == 4 || BB == 8 || BB == 16) else $error("BUS_DW must be 16, 32, 64 or 128");

  typedef enum logic [2:0] {J_NONE, J_WS, J_IF, J_DF, J_DU, J_IO, J_PW} jt_t;
  jt_t         jt;
  logic [4:0]  nb;          // number of beats
  logic [4:0]  ni, na;      // issued, acked
  logic        fm;          // line fill: address = {line, beat}
  logic [31:4] fln;
  // single access: the (up to) two 32-bit words it touches; beats are its
  // pieces (words, or 16-bit halves on a 16-bit bus) from piece bo on
  logic [31:2] ba [2];
  logic [3:0]  bs [2];
  logic [31:0] bd [2];
  logic [1:0]  bo;
  logic        bwe;
  logic [1:0]  btga;
  logic [1:0]  lo_lane;     // byte lane of the first byte in its word
  logic [63:0] win;         // read window: the two words, filled as beats are acked

  wire busy = (jt != J_NONE);
  wire ws   = (jt == J_WS);

  // write stream request register
  logic        rq_v;
  logic [31:2] rq_adr;
  logic [3:0]  rq_sel;
  logic [31:0] rq_dat;
  logic        rq_h;          // 16-bit bus: half being issued
  logic [3:0]  outs;          // write beats issued, not yet acked
  logic        yielded;       // last stream stopped for an I-cache fill
  logic        gact;          // 128-bit: fill rows still to be written

  // piece of the single access issued (s) / acked (a)
  wire [1:0] ps = bo + ni[1:0];
  wire [1:0] pa = bo + na[1:0];
  always_comb begin
    logic [31:0] fa;
    fa = {fln[31:LB], LB'(0)} | 32'(ni * BB);
    wb_cyc  = busy;
    wb_stb  = ws ? rq_v : (busy && (ni < nb));
    wb_we   = ws ? 1'b1 : bwe;
    wb_tga  = ws ? 2'd0 : btga;
    if (BB == 2) begin
      logic [31:2] a;
      logic [3:0]  s;
      logic [31:0] d;
      logic        h;
      a = ws ? rq_adr : ba[ps[1]];
      s = ws ? rq_sel : bs[ps[1]];
      d = ws ? rq_dat : bd[ps[1]];
      h = ws ? rq_h   : ps[0];
      wb_adr  = fm && !ws ? fa[31:AB] : (32-AB)'({a, h});
      wb_sel  = fm && !ws ? '1 : BB'(h ? s[3:2] : s[1:0]);
      wb_dato = BUS_DW'(h ? d[31:16] : d[15:0]);
    end else begin
      logic [31:2] a;
      logic [3:0]  s;
      logic [31:0] d;
      a = ws ? rq_adr : ba[ni[0]];
      s = ws ? rq_sel : bs[ni[0]];
      d = ws ? rq_dat : bd[ni[0]];
      wb_adr  = fm && !ws ? fa[31:AB] : a[31:AB];
      wb_sel  = fm && !ws ? '1 : BB'(BB'(s) << (BB > 4 ? {a[AB-1 > 2 ? AB-1 : 2:2], 2'b00} : 0));
      wb_dato = BUS_DW'({4{d}});
    end
  end
  wire issue = wb_stb && !wb_stall;
  wire ack   = busy && wb_ack;
  wire lastack = !ws && ack && (na + 5'd1 == nb);

  // stream: load the next entry when the request register is free (or being accepted)
  wire ws_beat  = ws && rq_v && !wb_stall;
  wire ws_acc   = ws_beat && (BB != 2 || rq_h || rq_sel[3:2] == 2'b00);
  // instruction fills do not overtake stores: the store buffer drains first
  // (a fill must see code just written; D-fills wait the same way)
  wire ws_stop  = 1'b0;
  wire [3:0] outs_n = outs + (ws_beat ? 4'd1 : 4'd0) - ((ws && wb_ack) ? 4'd1 : 4'd0);
  wire ws_load  = ws && (!rq_v || ws_acc) && sb_v && !ws_stop && (outs_n < 4'd8);
  wire ws_end   = ws && !rq_v && (outs == 4'd0) && (!sb_v || ws_stop);
  wire start_ws = !busy && !io_req && !pw_req && !pw_lock && !(if_req && yielded) && sb_v;
  // next job (taken when the bus is idle)
  jt_t nj;
  always_comb begin
    if (pw_lock)                         nj = pw_req ? J_PW : J_NONE;
    else if (lk_hold)                    nj = pw_req ? J_PW : sb_v ? J_WS : du_req ? J_DU : J_NONE;
    else if (io_req)                     nj = J_IO;
    else if (pw_req)                     nj = J_PW;
    else if (sb_v)                       nj = J_WS;
    else if (df_req && !gact)            nj = J_DF;
    else if (du_req)                     nj = J_DU;
    else if (if_req && if_ok && !gact)   nj = J_IF;
    else                                 nj = J_NONE;
  end
  wire fstart = !busy && (nj == J_DF || nj == J_IF);
  assign wr_busy = ws;

  // ------------------------------------------------------------ fill rows
  wire fack = fm && ack;
  wire [127:0] di = 128'(wb_dati);     // zero-padded (keeps unused width branches in range)
  logic        f_we, f_last;
  logic [15:0] acc16;       // 16-bit bus: first half of a word
  logic [63:0] lbuf [NR];   // 128-bit bus: rows not written yet
  logic [1:0]  rb;          // 128-bit bus: beats arrived (rows arrived = 2 * rb)
  logic [2:0]  wc;          // 128-bit bus: rows written
  wire  [2:0]  ra = {rb, 1'b0};
  logic        gi;          // 128-bit bus: the drained fill is for the I-cache
  always_comb begin
    f_we = 1'b0; f_last = 1'b0; f_row = '0; f_hm = 2'b11; f_data = '0;
    if (BB == 2) begin
      f_we   = fack && na[0];
      f_row  = 2'(na[4:2]);
      f_hm   = na[1] ? 2'b10 : 2'b01;
      f_data = {2{di[15:0], acc16}};
      f_last = fm && lastack;
    end else if (BB == 4) begin
      f_we   = fack;
      f_row  = 2'(na[2:1]);
      f_hm   = na[0] ? 2'b10 : 2'b01;
      f_data = {2{di[31:0]}};
      f_last = fm && lastack;
    end else if (BB == 8) begin
      f_we   = fack;
      f_row  = 2'(na[1:0]);
      f_data = di[63:0];
      f_last = fm && lastack;
    end else begin
      f_we   = gact && ((wc < ra) || (fack && wc == ra));
      f_row  = 2'(wc);
      f_data = (wc < ra) ? lbuf[2'(wc)] : di[63:0];
      f_last = f_we && (wc == 3'(NR - 1));
    end
  end
  wire f_isi = (BB == 16) ? gi : (jt == J_IF);
  assign if_we   = f_we && f_isi;
  assign df_we   = f_we && !f_isi;
  assign if_done = f_last && f_isi;
  assign df_done = f_last && !f_isi;
  always_ff @(posedge clk) begin
    if (BB == 2 && fack && !na[0]) acc16 <= di[15:0];
    if (BB == 16) begin
      if (fack) begin
        lbuf[{rb[0], 1'b0}] <= di[63:0];
        lbuf[{rb[0], 1'b1}] <= di[127:64];
      end
      if (rst || f_last) begin
        gact <= 1'b0; rb <= '0; wc <= '0;
      end else begin
        if (fack) rb <= rb + 2'd1;
        if (f_we) wc <= wc + 3'd1;
        if (fstart) begin
          gact <= 1'b1; gi <= (nj == J_IF);
        end
      end
    end else begin
      gact <= 1'b0;
    end
  end

  assign du_done = (jt == J_DU) && lastack;
  assign pw_done = (jt == J_PW) && lastack;
  assign wb_lock = pw_lock || lk_hold;
  assign io_done = (jt == J_IO) && lastack;
  assign sb_pop  = ws_load || start_ws;
  assign snp_v   = ws_acc;
  assign snp_line = rq_adr[31:4];

  // assembled read result (valid with *_done): the bytes from the first byte's
  // lane on; the last piece comes straight from the bus
  logic [PW-1:0] pc_a;      // piece of the beat being acked
  always_comb begin
    logic [63:0] wn;
    if (BB == 2)      pc_a = PW'(wb_dati);
    else if (BB == 4) pc_a = PW'(wb_dati);
    else              pc_a = PW'(wb_dati >> {ba[na[0]][(AB > 2 ? AB-1 : 2):2], 5'b00000});
    wn = win;
    wn[((BB == 2) ? pa : {1'b0, na[0]}) * PW +: PW] = pc_a;
    rdata32 = 32'(wn >> {lo_lane, 3'b000});
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      jt <= J_NONE; ni <= '0; na <= '0; nb <= '0; bwe <= 1'b0; btga <= 2'd0; fm <= 1'b0;
      rq_v <= 1'b0; outs <= '0; yielded <= 1'b0; rq_h <= 1'b0;
    end else if (ws) begin
      outs <= outs_n;
      if (ws_load) begin
        rq_v <= 1'b1; rq_adr <= sb_adr; rq_sel <= sb_be; rq_dat <= sb_dat;
        rq_h <= (sb_be[1:0] == 2'b00);
      end else if (ws_acc) rq_v <= 1'b0;
      else if (ws_beat) rq_h <= 1'b1;
      if (ws_end) begin
        jt <= J_NONE;
        yielded <= ws_stop && sb_v;
      end
    end else begin
      if (busy) begin
        if (issue) ni <= ni + 5'd1;
        if (ack) begin
          na <= na + 5'd1;
          win[((BB == 2) ? pa : {1'b0, na[0]}) * PW +: PW] <= pc_a;
        end
        if (lastack) begin
          jt <= J_NONE; ni <= '0; na <= '0;
        end
      end else begin
        // arbitration
        logic [31:0] l0;
        logic [31:2] l4;
        logic [1:0]  sz;
        logic        two, rd;
        logic [31:0] d;
        logic [3:0]  bm;
        logic [7:0]  be8;
        logic [63:0] d64;
        logic [3:0]  pv;      // 16-bit bus: halves with bytes
        l0 = du_lin; l4 = du_lin4; sz = du_sz; d = io_wdata; rd = 1'b1;
        btga <= 2'd0;
        if (nj == J_PW) begin
          l0 = {pw_adr, 2'b00}; l4 = pw_adr + 30'd1; sz = 2'd2; d = pw_wdat; rd = !pw_we;
        end else if (io_req) begin
          l0 = {16'h0, io_port}; l4 = {16'h0, io_port[15:2]} + 30'd1; sz = io_sz;
          rd = !io_we;
          btga <= io_inta ? 2'd2 : 2'd1;
          // one acknowledge cycle, vector in the low byte
          if (io_inta) begin l0 = '0; sz = (BB == 2) ? 2'd1 : 2'd2; end
        end
        bm  = (sz == 2'd0) ? 4'b0001 : (sz == 2'd1) ? 4'b0011 : 4'b1111;
        be8 = 8'({4'b0000, bm} << l0[1:0]);
        d64 = 64'({32'h0, d} << {l0[1:0], 3'b000});
        two = |be8[7:4];
        for (int k = 0; k < 4; k++) pv[k] = |be8[2*k +: 2];
        lo_lane <= l0[1:0];
        jt <= nj;
        ni <= '0; na <= '0;
        if (nj == J_IF) yielded <= 1'b0;
        if (nj == J_WS) begin
          rq_v <= 1'b1; rq_adr <= sb_adr; rq_sel <= sb_be; rq_dat <= sb_dat; outs <= '0;
          rq_h <= (sb_be[1:0] == 2'b00);
        end
        fm <= (nj == J_DF || nj == J_IF);
        if (nj == J_DF || nj == J_IF) begin
          fln <= (nj == J_DF) ? df_line : if_line;
          nb  <= 5'(NBL);
          bwe <= 1'b0;
        end else begin
          ba[0] <= l0[31:2];
          ba[1] <= l4;
          bs[0] <= be8[3:0];
          bs[1] <= be8[7:4];
          bd[0] <= d64[31:0];
          bd[1] <= d64[63:32];
          bwe <= !rd;
          if (BB == 2) begin
            bo <= pv[0] ? 2'd0 : 2'd1;
            nb <= 5'(pv[0]) + 5'(pv[1]) + 5'(pv[2]) + 5'(pv[3]);
          end else begin
            bo <= 2'd0;
            nb <= two ? 5'd2 : 5'd1;
          end
        end
      end
    end
  end
endmodule
