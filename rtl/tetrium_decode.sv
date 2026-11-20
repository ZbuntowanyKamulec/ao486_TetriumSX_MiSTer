// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium decode stage (D)
//  * 4-entry shift-register queue of 8-byte fetch blocks: the head blocks are
//    always registers q[0], q[1], ... (no read-pointer mux)
//  * instruction length from the per-byte predecode stored in the I-cache
//    (tetrium_pdec.svh: mode independent; the operand / address size selects),
//    everything else in the BRAM microcode ROM indexed by page / opcode
//    (+mod3, +reg for group opcodes)
//  * the instruction pointer is not tracked here: every block carries its IP,
//    so the IP of the current byte is {block_ip[15:3], offset}
//  * prefixes (segment, 66, 67, LOCK, REP) and the 0F escape are consumed one
//    per cycle; a prefix / escape right after an instruction is consumed together
//    with it (skip: caught with the instruction in front, its state kept in sk_*);
//    the instruction proper is opcode, modrm, SIB, displacement, immediate: 1 to
//    11 bytes, over up to three blocks
//  * microsequencer: multi-uop instructions loop on the ROM 'next' field
//  * two stages: D1 finds instruction boundaries (queue, prefixes, length,
//    prediction checks) and catches the instruction in the instruction register
//    (IR: byte window, length fields, prefix state, IPs); D2 decodes the fields,
//    the A-stage selects and the dispatch address from IR and issues to A1.
//    D1 keeps going while A1 sequences a multi-uop instruction.
`ifndef UCODE_FILE
`define UCODE_FILE "ucode_rom.hex"
`endif
import tetrium_pkg::*;
module tetrium_decode (
    input  logic        clk,
    input  logic        rst,
    input  logic        cs_d,          // default operand / address size of the code segment (1 = 32 bit)
    input  logic        pm,            // protected mode (CR0.PE, not V86): protected-mode dispatch (pm_ent)
    input  logic        iochk,         // I/O instructions check the permission bitmap (CPL > IOPL, V86)
    // block queue from fetch
    input  logic        q_push,
    input  logic [63:0] q_data,
    input  logic [223:0] q_pd,      // per-byte predecode from the I-cache (pdec), 28 bits / byte
    input  logic [2:0]  q_s,
    input  logic [2:0]  q_e,
    input  logic        q_pt,
    input  logic [31:0] q_ptgt,
    input  logic [31:3] q_lin,
    input  logic [31:3] q_ip,
    input  logic [3:0]  q_bid,
    output logic        q_full,
    // front-end flush (registered by the core)
    input  logic        flush_front,   // clear queue
    input  logic        flush_keep_pfx,
    input  logic        kill_a,        // uop in A (and sequence) is killed
    // inject a microcode sequence (interrupt / exception entry, E micro-jump): entry id,
    // instruction context (immediate: the vector; restart IP, next IP, operand size)
    input  logic        inject,
    input  logic [4:0]  inject_id,
    input  logic [31:0] inject_imm,
    input  logic [31:0] inject_ips,
    input  logic [31:0] inject_ipn,
    input  logic        inject_os32,
    input  logic [7:0]  inject_op,
    input  logic        inject_int,    // interrupt / exception delivery (not an instruction)
    input  logic        inject_ecv,    // the delivery pushes an error code
    input  logic [4:0]  inject_cnt,    // micro-loop count
    output logic        c_ecv,
    // A stage handshake
    input  logic        hold_a,
    input  logic        a_repkill,     // A kills a REP iteration (CX==0)
    output logic        a_valid,
    output logic        a_vld_eff,
    output logic        a_last,        // uop in A ends the instruction
    output logic [AF_BITS-1:0] a_af,
    output logic [44:0] a_sel,         // predecoded A-stage operand selects (tetrium_asel.svh)
    output logic [UW_BITS-1:0] a_uw,
    // instruction context for A
    output logic [7:0]  c_op,
    output logic        c_pg,          // 0F page opcode
    output logic [7:0]  c_modrm,
    output logic [31:0] c_disp,
    output logic [31:0] c_imm_o,
    output logic [31:0] c_ip_start,    // first prefix
    output logic [31:0] c_ip_op,       // opcode byte (the 0F escape for a two-byte opcode)
    output logic [3:0]  c_len,         // opcode..end (ip_next = c_ip_op + c_len)
    output logic [31:0] c_ip_nx,       // IP of the next instruction
    output logic        c_sovr_v,
    output logic [2:0]  c_sovr,
    output logic [1:0]  c_rep,         // [1]=present [0]=F3
    output logic        c_os32,        // operand size 32
    output logic        c_as32,        // address size 32
    output logic        c_lock,
    output logic        c_ud,          // invalid form (bad LOCK, reserved modrm.reg): raises #UD
    output logic [7:0]  c_eab,         // effective address: base register (one-hot)
    output logic [8:0]  c_eai,         //                    index register (one-hot, [8] = AL)
    output logic [1:0]  c_eas,         //                    index scale
    output logic        c_dss,         // default segment SS (else DS)
    output logic [2:0]  c_sreg,
    output logic        c_pt,
    output logic [31:0] c_ptgt,
    output logic [3:0]  c_bid,         // predictor snapshot id of the block holding the last byte
    output logic        c_inj,
    output logic [5:0]  c_srdm,        // segment registers read as E operands (interlocked in A)
    // bad-prediction redirect request
    output logic        d_redir,
    output logic [31:0] d_redir_ip,
    output logic [31:0] d_btb_lin,
    output logic [3:0]  d_bid,         // block to refetch (history repair)
    output logic [3:0]  d_tbid,        // block whose BTB entry made the bad prediction
    output logic        q_empty,
    output logic        d_starve       // nothing to issue: no instruction caught or complete in the queue
);
`include "ucode_class.svh"
`include "tetrium_asel.svh"
`include "tetrium_pdec.svh"

  // ------------------------------------------------------------ block queue (shift register)
  logic [63:0] qd   [4];
  logic [2:0]  qs   [4];
  logic [2:0]  qe   [4];
  logic        qpt  [4];
  logic [31:0] qptg [4];
  logic [31:3] qlin [4];
  logic [31:3] qip  [4];
  logic [3:0]  qbid [4];     // branch predictor snapshot id of the block
  logic [8*PDW-1:0] qpd [4]; // per-byte predecode
  logic [2:0]  cnt;
  assign q_full  = (cnt == 3'd4);
  assign q_empty = (cnt == 3'd0);

  // eoff (0..18): offset of the next byte to decode, relative to q[0].
  // eoff >= 8 means q[0] is consumed: it is shifted out this cycle (pop comes
  // straight from the register) while decoding continues in q[1].  eoff >= 16
  // (after an instruction that ended in the third block): pop only.
  (* max_fanout = 24 *) logic [4:0]  eoff;
  logic        wait_s;   // next instruction starts at the start offset of block cb (not yet known)
  logic        skip;     // block cb ends in a predicted-taken branch already consumed
  wire         big   = eoff[4];
  wire         cb    = eoff[3];                 // current block 0/1
  wire  [2:0]  off   = eoff[2:0];
  wire         pop   = (cb || big) && (cnt != 3'd0);
  wire         blkv  = cb ? (cnt >= 3'd2) : (cnt != 3'd0);   // block cb present
  wire         hv    = blkv && !wait_s && !skip && !big;
  wire         nbv   = cb ? (cnt >= 3'd3) : (cnt >= 3'd2);    // next block present
  wire  [2:0]  cb_e  = cb ? qe[1]  : qe[0];
  wire         cb_pt = cb ? qpt[1] : qpt[0];
  wire  [2:0]  nb_e  = cb ? qe[2]  : qe[1];
  wire  [2:0]  nb_s  = cb ? qs[2]  : qs[1];
  wire  [31:0] cur_ip = cb ? {qip[1], off} : {qip[0], off};

  // length select form (see lsel): the shift tree on Cyclone V, or with DEC_LTREE (sim)
`ifdef ALTERA
`define DEC_LTREE
`endif
  // D1: 12-byte window starting at eoff (11 caught in IR; byte 11: a skipped prefix)
  logic [7:0] fw [12];
  always_comb begin
    logic [255:0] four;
    four = {qd[3], qd[2], qd[1], qd[0]};
    for (int k = 0; k < 12; k++) fw[k] = four[(5'(eoff[3:0]) + 5'(k)) * 8 +: 8];
  end
  wire [7:0] f0 = fw[0];

  // ------------------------------------------------------------ prefix state
  // pr_*: registers; the prefixes of an instruction issued in the previous
  // cycle (iss_q) are dropped one cycle late, so the issue decision does not
  // reach the prefix registers.  pfx_*: the effective prefix state.
  // skq / sk_b: a prefix byte consumed in the previous cycle together with the
  // instruction (or prefix) in front of it (younger than the pr_* state)
  logic        pr_any, pr_sv, pr_os, pr_as, pr_lock, pr_0f, iss_q, skq;
  logic [1:0]  pr_rep;
  logic [2:0]  pr_s;
  logic [7:0]  sk_b;
  logic [31:0] pfx_ip;
  wire         sk_sg    = skq && (sk_b == 8'h26 || sk_b == 8'h2E || sk_b == 8'h36 || sk_b == 8'h3E ||
                                  sk_b == 8'h64 || sk_b == 8'h65);
  wire         pfx_any  = (pr_any  && !iss_q) || skq;
  wire         pfx_sv   = (pr_sv   && !iss_q) || sk_sg;
  wire         pfx_os   = (pr_os   && !iss_q) || (skq && sk_b == 8'h66);
  wire         pfx_as   = (pr_as   && !iss_q) || (skq && sk_b == 8'h67);
  wire         pfx_lock = (pr_lock && !iss_q) || (skq && sk_b == 8'hF0);
  wire         pfx_0f   = pr_0f;          // (already void after an issue: !cap is in its next state)
  wire [1:0]   pfx_rep  = (skq && sk_b == 8'hF2) ? 2'b10 : (skq && sk_b == 8'hF3) ? 2'b11 : pr_rep & {2{!iss_q}};
  wire [2:0]   pfx_s    = !sk_sg ? pr_s : (sk_b == 8'h64) ? 3'd4 : (sk_b == 8'h65) ? 3'd5 : {1'b0, sk_b[4:3]};
  wire         pg1  = pfx_0f;                   // the byte at eoff is the second byte of a 0F opcode
  // effective sizes: eo_* = CS.D ^ pfx_* kept in registers (CS.D changes only with a flush;
  // the idle cycles after it reload them): after an issue (iss_q) the prefixes are void
  // and eo_* = CS.D, so os1 / as1 come straight from a register
  (* max_fanout = 24 *) logic eo_os, eo_as;
  wire         os1  = eo_os;
  wire         as1  = eo_as;

  // ------------------------------------------------------------ length
  // The length fields of an instruction starting at each of the 16 positions of
  // q[0..1] are computed in parallel from the stored predecode of its bytes p,
  // p + 1, p + 2 (registers and the prefix state only); eoff just selects one.
  // (keeps the length logic out of the eoff -> eoff loop)
  typedef struct packed {
    logic       praw;     // prefix / escape byte (any page)
    logic       pfx;      // prefix or escape in the primary page: consumed alone
    logic       modrm, sib;
    logic [2:0] immc, disp;
    logic [2:0] imm;      // immediate bytes
    logic [3:0] len, ipos;
  } lf_t;
  lf_t lfp [16];
  always_comb begin
    logic [24*PDW-1:0] three;
    three = {qpd[2], qpd[1], qpd[0]};
    for (int p = 0; p < 16; p++) begin
      logic [PDW-1:0] a0, a1, a2;
      logic       m, sb;
      logic [2:0] ic, dp, im;
      a0 = three[p*PDW +: PDW];
      a1 = three[(p+1)*PDW +: PDW];
      a2 = three[(p+2)*PDW +: PDW];
      m  = pg1 ? a0[7] : a0[2];
      ic = pg1 ? ((a0[9:8] == 2'd1) ? 3'd1 : (a0[9:8] == 2'd2) ? 3'd3 : 3'd0) : a0[5:3];
      sb = as1 && m && a1[14];
      if (!m)                    dp = 3'd0;
      else if (!as1)            dp = {1'b0, a1[11:10]};
      else if (a1[15] && a2[17]) dp = 3'd4;
      else                       dp = (a1[13:12] == 2'd1) ? 3'd1 : (a1[13:12] == 2'd2) ? 3'd4 : 3'd0;
      case (ic)
        3'd1: im = 3'd1;
        3'd2: im = 3'd2;
        3'd3: im = os1 ? 3'd4 : 3'd2;
        3'd4: im = os1 ? 3'd6 : 3'd4;
        3'd5: im = as1 ? 3'd4 : 3'd2;
        3'd6: im = 3'd3;
        3'd7: im = !a1[16] ? 3'd0 : !a0[6] ? 3'd1 : os1 ? 3'd4 : 3'd2;
        default: im = 3'd0;
      endcase
      lfp[p].praw  = a0[0] || a0[1];
      lfp[p].pfx   = !pg1 && (a0[0] || a0[1]);
      lfp[p].modrm = m;
      lfp[p].sib   = sb;
      lfp[p].immc  = ic;
      lfp[p].disp  = dp;
      lfp[p].imm   = im;
      lfp[p].ipos  = 4'd1 + {3'd0, m} + {3'd0, sb} + {1'b0, dp};
      lfp[p].len   = 4'd1 + {3'd0, m} + {3'd0, sb} + {1'b0, dp} + {1'b0, im};
    end
  end
  lf_t       lf;
  assign     lf      = lfp[eoff[3:0]];
  wire       l_pfx   = lf.pfx;
  wire       l_modrm = lf.modrm;
  wire [2:0] l_immc  = lf.immc;
  wire       l_sib   = lf.sib;
  wire [2:0] l_disp  = lf.disp;
  wire [3:0] len     = lf.len;
  // Selecting a per-length table entry by the length.  Cyclone V: the length is never
  // formed as a binary sum on the capture path (a 5-term add, ~4 LUT levels there); the
  // table is shifted by each term instead, len = 1 + modrm + sib + disp + imm
  // (disp takes the values 0 1 2 4, imm 0 1 2 3 4 6).  Artix-7: the carry chain makes
  // the sum fast and the 16:1 select by it is shorter than the shift tree.
`ifndef DEC_LTREE
  function automatic logic lsel(input logic [15:0] v, input lf_t lsf);
    lsel = v[lsf.len];
  endfunction
`else
  function automatic logic lsel(input logic [15:0] v, input lf_t lsf);
    logic [15:0] lst;
    lst = v >> 1;
    if (lsf.modrm) lst = lst >> 1;
    if (lsf.sib)   lst = lst >> 1;
    case (lsf.disp)
      3'd1:    lst = lst >> 1;
      3'd2:    lst = lst >> 2;
      3'd4:    lst = lst >> 4;
      default: ;
    endcase
    case (lsf.imm)
      3'd1:    lsel = lst[1];
      3'd2:    lsel = lst[2];
      3'd3:    lsel = lst[3];
      3'd4:    lsel = lst[4];
      3'd6:    lsel = lst[6];
      default: lsel = lst[0];
    endcase
  endfunction
`endif

  // ------------------------------------------------------------ instruction register (D1 -> D2)
  logic        ir_v;
  logic [7:0]  wb [11];
  lf_t         ir_lf;
  logic [PDW-1:0] pc0;           // predecode of the opcode byte
  logic        pg, os32, as32, i_sv, i_lock, i_any;
  logic [2:0]  i_s;
  logic [1:0]  i_rep;
  logic [31:0] ir_ipstart, ir_curip, ir_ptgt;
  logic [31:3] ir_cbip3;
  logic [4:0]  ir_iend;
  logic        ir_pt;
  logic [3:0]  ir_bid;
  wire [7:0] w0 = wb[0], w1 = wb[1], w2 = wb[2];

  // ------------------------------------------------------------ D2: fields of the instruction in IR
  wire [1:0] mod  = w1[7:6];
  wire [2:0] rm   = w1[2:0];
  wire       mod3 = (mod == 2'd3);
  // (computed from the bytes; only the registered copies are used downstream)
  // (modrm / immediate class / SIB / displacement size from the stored predecode)
  wire        has_modrm = ir_lf.modrm;
  wire [2:0]  immc      = ir_lf.immc;
  logic       imm_sext, imm_rel;
  always_comb begin
    imm_sext  = 1'b0; imm_rel = 1'b0;
    if (!pg)
      casez (w0)
        8'h6A, 8'h6B, 8'h83, 8'hEB, 8'b0111_????, 8'b1110_00??: imm_sext = 1'b1;
        8'hE8, 8'hE9: imm_rel = 1'b1;
        default: ;
      endcase
    else imm_rel = (w0[7:4] == 4'h8);
  end
  wire        sibp   = ir_lf.sib;
  wire [2:0]  dbytes = ir_lf.disp;  // displacement bytes: 0, 1, 2, 4
  wire [3:0] dpos = sibp ? 4'd3 : 4'd2;
  wire [3:0] ipos = ir_lf.ipos;
  logic [31:0] dw, iw;       // 4 bytes at the displacement / immediate position
  always_comb begin
    for (int k = 0; k < 4; k++) begin
      dw[k*8 +: 8] = wb[4'(dpos + 4'(k))];
      iw[k*8 +: 8] = (ipos + 4'(k) <= 4'd10) ? wb[4'(ipos + 4'(k))] : 8'h00;
    end
  end
  wire [31:0] w14 = {wb[4], wb[3], wb[2], wb[1]};       // 4 bytes after the opcode
  logic [31:0] disp, imm;
  // the immediate register: data input only (a sign-extension set / zero reset
  // inferred on the late immediate-select path costs the S/R pin setup)
  (* extract_reset = "no" *) logic [31:0] c_imm;
  assign c_imm_o = c_imm;
  always_comb begin
    // displacement field: modrm displacement, far pointer offset, moffs, ENTER level
    if (immc == 3'd4)      disp = os32 ? w14 : {16'h0, w14[15:0]};
    else if (immc == 3'd5) disp = as32 ? w14 : {16'h0, w14[15:0]};
    else if (immc == 3'd6) disp = {24'h0, wb[3]};
    else case (dbytes)
      3'd1:    disp = as32 ? {{24{dw[7]}}, dw[7:0]} : {16'h0, {8{dw[7]}}, dw[7:0]};
      3'd2:    disp = {16'h0, dw[15:0]};
      3'd4:    disp = dw;
      default: disp = 32'h0;
    endcase
    // immediate field: immediate, far pointer selector, ENTER frame size
    case (immc)
      3'd1:    imm = imm_sext ? {{24{iw[7]}}, iw[7:0]} : {24'h0, iw[7:0]};
      3'd2:    imm = {16'h0, iw[15:0]};
      3'd3:    imm = os32 ? iw : (imm_rel ? {{16{iw[15]}}, iw[15:0]} : {16'h0, iw[15:0]});
      3'd4:    imm = os32 ? {16'h0, wb[6], wb[5]} : {16'h0, wb[4], wb[3]};
      3'd6:    imm = {16'h0, w14[15:0]};
      3'd7:    imm = !w0[0] ? {24'h0, iw[7:0]} : os32 ? iw : {16'h0, iw[15:0]};
      default: imm = 32'h0;
    endcase
  end
  // EA base / index / scale / default segment
  logic [7:0] eab;
  logic [8:0] eai;
  logic [1:0] eas;
  logic       dss;
  always_comb begin
    eab = '0; eai = '0; eas = 2'd0; dss = 1'b0;
    if (!pg && w0 == 8'hD7) begin                       // XLAT: (E)BX + AL
      eab[3] = 1'b1; eai[8] = 1'b1;
    end else if (has_modrm && !mod3) begin
      if (!as32) begin
        case (rm)
          3'd0: begin eab[3] = 1'b1; eai[6] = 1'b1; end
          3'd1: begin eab[3] = 1'b1; eai[7] = 1'b1; end
          3'd2: begin eab[5] = 1'b1; eai[6] = 1'b1; dss = 1'b1; end
          3'd3: begin eab[5] = 1'b1; eai[7] = 1'b1; dss = 1'b1; end
          3'd4: eai[6] = 1'b1;
          3'd5: eai[7] = 1'b1;
          3'd6: if (mod != 2'd0) begin eab[5] = 1'b1; dss = 1'b1; end
          default: eab[3] = 1'b1;
        endcase
      end else if (sibp) begin
        if (!(w2[2:0] == 3'd5 && mod == 2'd0)) eab[w2[2:0]] = 1'b1;
        if (w2[5:3] != 3'd4) eai[w2[5:3]] = 1'b1;
        eas = w2[7:6];
        dss = (w2[2:0] == 3'd4) || (w2[2:0] == 3'd5 && mod != 2'd0);
      end else begin
        if (!(rm == 3'd5 && mod == 2'd0)) eab[rm] = 1'b1;
        dss = (rm == 3'd5) && (mod != 2'd0);
      end
    end else if (has_modrm)
      eab[rm] = 1'b1;               // register form: the r/m register (selector of a DSCR uop)
  end
  // invalid forms that the microcode dispatch does not see
  logic lock_ok, ud;
  always_comb begin
    logic [2:0] rg;
    rg = w1[5:3];
    // LOCK: only on the memory-destination forms of these
    lock_ok = 1'b0;
    if (has_modrm && !mod3) begin
      if (!pg)
        casez (w0)
          8'b00??_?00?: lock_ok = (w0[5:3] != 3'd7);                     // ADD OR ADC SBB AND SUB XOR r/m,r
          8'h80, 8'h81, 8'h82, 8'h83: lock_ok = (rg != 3'd7);
          8'h86, 8'h87: lock_ok = 1'b1;                                  // XCHG
          8'hF6, 8'hF7: lock_ok = (rg == 3'd2) || (rg == 3'd3);          // NOT NEG
          8'hFE, 8'hFF: lock_ok = (rg == 3'd0) || (rg == 3'd1);          // INC DEC
          default: ;
        endcase
      else
        case (w0)
          8'hAB, 8'hB3, 8'hBB, 8'hB0, 8'hB1, 8'hC0, 8'hC1: lock_ok = 1'b1;   // BTS BTR BTC CMPXCHG XADD
          8'hBA: lock_ok = (rg >= 3'd5);
          default: ;
        endcase
    end
    ud = i_lock && !lock_ok;
    // MOV to / from CR1, CR4-CR7
    if (pg && (w0 == 8'h20 || w0 == 8'h22) && !(rg == 3'd0 || rg == 3'd2 || rg == 3'd3)) ud = 1'b1;
    if (!pg)
      case (w0)
        8'h8C: ud = ud || (rg > 3'd5);
        8'h8E: ud = ud || (rg > 3'd5) || (rg == 3'd1);                   // no MOV CS
        8'h8F, 8'hC6, 8'hC7: ud = ud || (rg != 3'd0);
        default: ;
      endcase
  end
  logic [2:0] sreg;
  always_comb begin
    if (!pg)
      case (w0)
        8'h8C, 8'h8E: sreg = w1[5:3];
        8'hC4:        sreg = 3'd0;
        8'hC5:        sreg = 3'd3;
        default:      sreg = {1'b0, w0[4:3]};
      endcase
    else
      case (w0)
        8'hB2:        sreg = 3'd2;
        8'hA8, 8'hA9, 8'hB5: sreg = 3'd5;
        default:      sreg = 3'd4;                       // A0 A1 B4
      endcase
  end
  // group opcodes
  wire        grp  = pg ? (pc0[27:24] == 4'd15) : pc0[23];
  wire [2:0]  gsel = pg ? ((w0 == 8'h00) ? 3'd4 : (w0 == 8'h01) ? 3'd5 : 3'd6) : {1'b0, w0[3], w0[0]};
  // dispatch index
  // (cs_d and pm change only through serializing instructions: a refetch follows)
  wire [10:0] didx0 = grp ? 11'(GROUP_BASE) | 11'({gsel, w1[5:3], mod3}) : {1'b0, pg, w0, mod3};
  // (I/O instructions at CPL > IOPL / in V86: the sequence with the bitmap check)
  wire [ROM_AW+AF_BITS:0] ioe = io_ent(w0);
  wire              iov   = iochk && !pg && ioe[ROM_AW+AF_BITS];
  // protected mode: the instructions with their own sequence (static dispatch condition)
  wire [ROM_AW+AF_BITS:0] pme = grp ? pm_ent_g({gsel, w1[5:3], mod3}) : pm_ent_n({pg, w0, mod3});
  wire              pmv   = pm && pme[ROM_AW+AF_BITS];
  wire [ROM_AW-1:0] didx  = iov ? ioe[ROM_AW+AF_BITS-1:AF_BITS] : pmv ? pme[ROM_AW+AF_BITS-1:AF_BITS] : ROM_AW'(didx0);
  // first-uop A-fields from the stored opcode class (pc0)
  wire [AF_BITS-1:0] af1r = grp ? grp_af({gsel, w1[5:3], mod3}) :
                            pg  ? class0f_af(pc0[27:24], mod3) : class_af(pc0[22:18], mod3);
  wire [AF_BITS-1:0] af1  = iov ? ioe[AF_BITS-1:0] : pmv ? pme[AF_BITS-1:0] : af1r;


  // ------------------------------------------------------------ issue logic
  // all length-dependent conditions are precomputed for len = 1..11 from
  // registers; the decoded length only selects among them (one-hot).
  // Both possible current blocks (cb = 0: q0.., cb = 1: q1..) are evaluated
  // in parallel from registers; cb selects at the end.
  // (length 12: whether the byte after an 11-byte instruction can be skipped)
  logic [12:1] k_en, k_eae, k_bad, k_xpt;
  logic [1:0]  k_bb  [13];      // block (relative to cb) whose BTB entry made a bad prediction
  logic [1:0]  k_lb  [13];      // block holding the last byte
  logic [4:0]  k_end [13];
  always_comb begin
    for (int k = 1; k <= 12; k++) begin
      logic [4:0] e, last;
      logic [1:0] en, eae, bd, xp;
      logic [1:0] bb [2];
      e        = {2'b0, off} + 5'(k);          // one past the last byte, relative to block cb
      last     = e - 5'd1;
      k_end[k] = e;
      k_lb[k]  = last[4:3];
      for (int c = 0; c < 2; c++) begin
        logic [2:0] ce, ne, n2e;
        logic       cp, np, n2p, nv, n2v, b0, xb1, b1, xb2, b2;
        ce = qe[c]; ne = qe[c+1]; n2e = qe[c+2];
        cp = qpt[c]; np = qpt[c+1]; n2p = qpt[c+2];
        nv  = (c == 0) ? (cnt >= 3'd2) : (cnt >= 3'd3);
        n2v = (c == 0) ? (cnt >= 3'd3) : (cnt >= 3'd4);
        en[c]  = (last <= {2'b0, ce}) ||
                 ((ce == 3'd7) && nv && (last[4:3] == 2'd1) && (last[2:0] <= ne)) ||
                 ((ce == 3'd7) && nv && (ne == 3'd7) && n2v && (last[4:3] == 2'd2) && (last[2:0] <= n2e));
        eae[c] = (last == {2'b0, ce});
        // the predicted branch end lies inside the instruction (or, in the
        // third block, anywhere up to its last byte: no branch is that long)
        b0  = cp && (last > {2'b0, ce});
        xb1 = !cp && nv && np && (last[4:3] != 2'd0);
        b1  = xb1 && ((last[4:3] == 2'd2) || (last[2:0] > ne));
        xb2 = !cp && nv && !np && n2v && n2p && (last[4:3] == 2'd2);
        b2  = xb2 && (last[2:0] >= n2e);
        bd[c] = b0 || b1 || b2;
        bb[c] = b2 ? 2'd2 : b1 ? 2'd1 : 2'd0;
        xp[c] = xb1 && (last[4:3] == 2'd1) && (last[2:0] == ne);
      end
      k_en[k]  = cb ? en[1]  : en[0];
      k_eae[k] = cb ? eae[1] : eae[0];
      k_bad[k] = cb ? bd[1] : bd[0];
      k_bb[k]  = cb ? bb[1] : bb[0];
      k_xpt[k] = cb ? xp[1]  : xp[0];
    end
    k_end[0] = '0; k_bb[0] = '0; k_lb[0] = '0;
  end
  // selected by the length directly (16:1 multiplexers)
  wire [15:0] v_bad = {4'd0, k_bad[11:1], 1'b0};
  wire [15:0] v_xpt = {4'd0, k_xpt[11:1], 1'b0};
  // per length: issue allowed (enough bytes, no bad prediction inside) and the
  // decoder's next position, all from registers; the length only selects
  // skip: the byte after the instruction (fw[len]) is a prefix / escape in sequence
  // (present, no predicted-taken end on either byte): consumed in the same cycle;
  // not after an 0F escape consumed alone (the byte after it is the opcode)
  logic [15:0] v_ok, v_pte, v_wt, v_sk, v_k66, v_k67, v_k0f;
  logic [4:0]  v_na [16], v_nb [16];   // next position without / with the skipped prefix
  wire         esc0 = !pg1 && (f0 == 8'h0F);
  always_comb begin
    logic [12:1] pte;
    v_ok = '0; v_pte = '0; v_wt = '0; v_sk = '0; v_k66 = '0; v_k67 = '0; v_k0f = '0;
    for (int k = 0; k < 16; k++) begin v_na[k] = '0; v_nb[k] = '0; end
    for (int k = 1; k <= 12; k++) pte[k] = (cb_pt && k_eae[k]) || k_xpt[k];
    for (int k = 1; k <= 11; k++) begin
      logic px, sk;
      px = (fw[k] == 8'h26) || (fw[k] == 8'h2E) || (fw[k] == 8'h36) || (fw[k] == 8'h3E) ||
           (fw[k] == 8'h64) || (fw[k] == 8'h65) || (fw[k] == 8'h66) || (fw[k] == 8'h67) ||
           (fw[k] == 8'hF0) || (fw[k] == 8'hF2) || (fw[k] == 8'hF3) || (fw[k] == 8'h0F);
      // (!pte[k] is implied by !k_bad[k + 1] but synthesizes faster here; pte[k + 1]: a
      // stale prediction ending on the prefix byte itself)
      sk = px && !pte[k] && k_en[k+1] && !k_bad[k+1] && !pte[k+1] && !(k == 1 && esc0);
      v_ok[k]  = k_en[k] && !k_bad[k];
      v_pte[k] = pte[k];
      v_wt[k]  = !k_xpt[k] && pte[k] && !nbv;
      // (the skip choice is made after the length select, not per length: the skip term
      //  is the deepest on the decoder's position loop; sk implies !pte[k], !k_xpt[k])
      v_na[k]  = k_xpt[k] ? 5'd8 : pte[k] ? (nbv ? {2'b01, nb_s} : 5'd8) : k_end[k];
      v_nb[k]  = k_end[k+1];
      v_sk[k]  = sk;
      v_k66[k] = sk && (fw[k] == 8'h66);
      v_k67[k] = sk && (fw[k] == 8'h67);
      v_k0f[k] = sk && (fw[k] == 8'h0F);
    end
  end
  // a prediction is bad if the predicted branch end lies inside the instruction,
  // or on a prefix byte (prefixes are consumed on their own and can't be a branch)
  // (also bad: the predicted end is on a prefix / escape byte at the current position)
  wire       bpfx      = cb_pt && (off == cb_e) && lf.praw;
  wire       bad       = hv && (lsel(v_bad, lf) || bpfx);
  wire       cross_pt  = lsel(v_xpt, lf);
  wire [4:0] iend      = {2'b0, off} + {1'b0, len};               // one past last byte (relative to block cb)
  logic [1:0] badblk, lastblk;
`ifndef DEC_LTREE
  always_comb begin
    badblk = '0; lastblk = '0;
    for (int k = 1; k <= 11; k++)
      if (len == 4'(k)) begin badblk = k_bb[k]; lastblk = k_lb[k]; end
  end
`else
  always_comb begin
    logic [15:0] bbv0, bbv1, lbv0, lbv1;
    bbv0 = '0; bbv1 = '0; lbv0 = '0; lbv1 = '0;
    for (int k = 1; k <= 11; k++) begin
      bbv0[k] = k_bb[k][0]; bbv1[k] = k_bb[k][1]; lbv0[k] = k_lb[k][0]; lbv1[k] = k_lb[k][1];
    end
    badblk  = {lsel(bbv1, lf), lsel(bbv0, lf)};
    lastblk = {lsel(lbv1, lf), lsel(lbv0, lf)};
  end
`endif
  // next IP = block IP + iend (D2, from IR)
  wire [31:3] cb_ip3 = cb ? qip[1] : qip[0];
  wire [31:3] nx_ip3 = ir_cbip3 + {27'd0, ir_iend[4:3]};
  // a prefix / escape byte is always 1 byte long
  wire       pfx_ok    = hv && k_en[1] && !k_bad[1] && !bpfx;

  // sequencer state from the uop currently in A
  // micro-loop (ENTER level): a uop with 'lp' continues at next + 1 (a uop without
  // A-stage fields) when the count register is zero, else the count is decremented
  logic [4:0] ucnt;
  wire        lpx  = a_uw[UW_LP_L] && (ucnt == 5'd0);
  wire [ROM_AW-1:0] uw_next = {a_uw[UW_NEXT_L+1 +: UW_NEXT_W-1], a_uw[UW_NEXT_L] | lpx};
  wire [AF_BITS-1:0] uw_na = lpx ? '0 : a_uw[AF_BITS-1:0];   // na_* fields are the low bits
  assign a_vld_eff = a_valid && !kill_a;
  wire   seq_more  = a_vld_eff && !a_af[AF_ISLAST_L] && !(a_af[AF_ENDNR_L] && !c_rep[1]) && !a_repkill;
  assign a_last    = !seq_more;

  wire take    = !kill_a && !flush_front && !inject;
  // D2 issues IR to A1 when A does not hold; D1 catches the next instruction in
  // IR when IR is free or issuing (both outcomes of hold_a formed, hold_a selects)
  wire ir_go_nh = ir_v && take && !seq_more;
  wire ir_issue = ir_go_nh && !hold_a;
  wire capok    = take && hv && !bpfx && !l_pfx && lsel(v_ok, lf);
  wire cap_nh   = capok && (!ir_v || ir_go_nh);
  wire cap_h    = capok && !ir_v;
  wire cap      = hold_a ? cap_h : cap_nh;
  wire ir_den   = hold_a ? !ir_v : (!ir_v || ir_go_nh);   // IR may take a new instruction
  wire use_pfx = take && l_pfx && pfx_ok;
  // (registered: nothing could be consumed last cycle and nothing could change since:
  // no push, no queue / position movement of its own; the core's drain detection only)
  logic d_stq;
  always_ff @(posedge clk)
    d_stq <= !rst && take && !use_pfx && !q_push && !big && !skip && !(wait_s && blkv);
  // (!capok of last cycle = !iss_q (= cap registered) whenever IR is empty now: with IR
  //  empty or issuing last cycle cap was capok; capok, the deepest D1 term, stays out)
  assign d_starve = d_stq && !iss_q && !ir_v && !a_valid;
`ifdef SIM
  logic d_stq_ref;
  always_ff @(posedge clk) d_stq_ref <= !rst && take && !capok && !use_pfx && !q_push && !big && !skip && !(wait_s && blkv);
  always_ff @(posedge clk) if (!rst && d_starve != (d_stq_ref && !ir_v && !a_valid)) $fatal(1, "decode: d_starve differs");
`endif
  wire pt_end  = lsel(v_pte, lf);                        // instruction ends at a predicted-taken branch

  // ROM
  logic [ROM_AW-1:0] rom_addr;
  logic       rom_en;
  wire [ROM_AW+AF_BITS-1:0] ient = inj_ent(inject_id);
  wire [AF_BITS-1:0] inj_af = ient[AF_BITS-1:0];
  always_comb begin
    if (inject)        rom_addr = ient[ROM_AW+AF_BITS-1:AF_BITS];
    else if (seq_more) rom_addr = uw_next;
    else               rom_addr = didx;
  end
  assign rom_en = inject || !hold_a || kill_a;
  tetrium_rom #(.AW(ROM_AW), .DW(UW_BITS), .FILE(`UCODE_FILE)) u_rom (
      .clk(clk), .re(rom_en), .addr(rom_addr), .q(a_uw));

  // bad prediction -> refetch at the current byte with prediction suppressed
  // (blocks relative to q[0]: cb + badblk)
  wire [1:0] bbi = {1'b0, cb} + badblk;
  always_ff @(posedge clk) begin
    if (rst) d_redir <= 1'b0;
    else     d_redir <= take && bad && !d_redir;
    d_redir_ip <= cur_ip;
    // invalidate the BTB entry that made the bad prediction
    d_btb_lin  <= {qlin[bbi], qe[bbi]};
    d_bid      <= cb ? qbid[1] : qbid[0];
    d_tbid     <= qbid[bbi];
  end

  // ------------------------------------------------------------ queue
  wire [2:0] wpos = cnt - {2'd0, pop};
  always_ff @(posedge clk) begin
    if (rst || flush_front || inject) begin
      cnt <= '0;
    end else begin
      cnt <= cnt + {2'd0, q_push} - {2'd0, pop};
    end
    for (int i = 0; i < 4; i++) begin
      if (wpos == 3'(i)) begin      // first free slot: written every cycle, counted only on push
        qd[i] <= q_data; qs[i] <= q_s; qe[i] <= q_e; qpt[i] <= q_pt;
        qptg[i] <= q_ptgt; qlin[i] <= q_lin; qip[i] <= q_ip; qpd[i] <= q_pd;
        qbid[i] <= q_bid;
      end else if (pop && i < 3) begin
        qd[i] <= qd[i+1]; qs[i] <= qs[i+1]; qe[i] <= qe[i+1]; qpt[i] <= qpt[i+1];
        qptg[i] <= qptg[i+1]; qlin[i] <= qlin[i+1]; qip[i] <= qip[i+1]; qpd[i] <= qpd[i+1];
        qbid[i] <= qbid[i+1];
      end
    end
  end

  // ------------------------------------------------------------ A-stage selects
  always_ff @(posedge clk) begin
    if (inject)
      a_sel <= asel(inj_af, 8'd0, 9'd0, 2'd0, 1'b0, 3'd0, 1'b0);
    else if (!kill_a && !hold_a)
      a_sel <= seq_more ? asel(uw_na, c_eab, c_eai, c_eas, c_sovr_v, c_sovr, c_dss)
                        : aexsel(pg, w0, w1, w2, asel(af1, eab, eai, eas, i_sv, i_s, dss));
  end

  // ------------------------------------------------------------ registers
  wire [1:0] ptblk = cross_pt ? 2'd1 : 2'd0;
`ifndef DEC_LTREE
  wire [4:0] n_eoff_c = v_sk[len] ? v_nb[len] : v_na[len];
`else
  logic [4:0] n_eoff_c;
  always_comb begin
    logic [4:0] na, nb;
    for (int j = 0; j < 5; j++) begin
      logic [15:0] nav, nbv2;
      for (int k = 0; k < 16; k++) begin nav[k] = v_na[k][j]; nbv2[k] = v_nb[k][j]; end
      na[j] = lsel(nav, lf);
      nb[j] = lsel(nbv2, lf);
    end
    n_eoff_c = lsel(v_sk, lf) ? nb : na;
  end
`endif
  wire [4:0] n_eoff_p = pop ? {2'b0, off} : eoff;
  wire       cons_n   = use_pfx || cap_nh;
  wire       cons_h   = use_pfx || cap_h;
  wire [4:0] n_eoff_h = cons_h ? n_eoff_c : n_eoff_p;
  wire [4:0] n_eoff_n = cons_n ? n_eoff_c : n_eoff_p;
  wire       n_skip_h = cons_h && cross_pt, n_skip_n = cons_n && cross_pt;
  wire       n_wait_h = cons_h && lsel(v_wt, lf), n_wait_n = cons_n && lsel(v_wt, lf);
  // skipped prefix: the byte fw[len]
  logic [7:0] n_skb;
  always_comb
    for (int j = 0; j < 8; j++) begin
      logic [15:0] bv;
      bv = '0;
      for (int k = 1; k <= 11; k++) bv[k] = fw[k][j];
      n_skb[j] = lsel(bv, lf);
    end
  // IP of the prefixes: a prefix skipped behind the instruction caught last cycle
  // starts where that instruction (still in IR) ends
  wire [31:0] pfx_ip_e = (skq && !(pr_any && !iss_q)) ? {nx_ip3, ir_iend[2:0]} : pfx_ip;
  always_ff @(posedge clk) begin
    if (rst) begin
      eoff <= '0; wait_s <= 1'b0; skip <= 1'b0;
      pr_any <= 1'b0; pr_sv <= 1'b0; pr_s <= '0; pr_rep <= '0; pfx_ip <= '0;
      pr_os <= 1'b0; pr_as <= 1'b0; pr_lock <= 1'b0; pr_0f <= 1'b0; iss_q <= 1'b0; skq <= 1'b0;
      eo_os <= cs_d; eo_as <= cs_d;
      a_valid <= 1'b0;
      a_af <= '0;
      c_inj <= 1'b0;
    end else begin
      if (flush_front || inject) begin
        wait_s <= 1'b0; skip <= 1'b0; eoff <= 5'd0; iss_q <= 1'b0; skq <= 1'b0;
        if (!flush_keep_pfx || inject) begin
          pr_any <= 1'b0; pr_sv <= 1'b0; pr_rep <= '0;
          pr_os <= 1'b0; pr_as <= 1'b0; pr_lock <= 1'b0; pr_0f <= 1'b0;
          eo_os <= cs_d; eo_as <= cs_d;
        end else begin
          pr_any <= pfx_any; pr_sv <= pfx_sv; pr_rep <= pfx_rep;
          pr_os <= pfx_os; pr_as <= pfx_as; pr_lock <= pfx_lock; pr_0f <= pfx_0f;
          pr_s <= pfx_s; pfx_ip <= pfx_ip_e;
          eo_os <= cs_d ^ pfx_os; eo_as <= cs_d ^ pfx_as;
        end
      end else begin
        // positions relative to q[0]; after a pop the current block becomes q[0]
        if (wait_s) begin
          // waiting for the start offset of block cb (becomes q[0] after a pop)
          if (blkv)                         begin eoff <= {2'b0, cb ? qs[1] : qs[0]}; wait_s <= 1'b0; end
          else if (q_push && wpos == 3'd0)  begin eoff <= {2'b0, q_s}; wait_s <= 1'b0; end
          else                                    eoff <= 5'd0;
        end else if (big) begin
          eoff <= eoff - 5'd8;                                 // pop only
        end else if (skip) begin
          // block cb's predicted branch was consumed: continue at the next block
          skip <= 1'b0;
          if (nbv) eoff <= {2'b01, nb_s};
          else begin eoff <= 5'd8; wait_s <= 1'b1; end
        end else if (cnt == 3'd0) begin
          eoff <= {2'b0, q_s};                                // first block arrives
        end else begin
          // consumed (prefix or issued instruction): after a predicted-taken branch the
          // target block (or wait for it); a branch that ended in block cb+1 skips the
          // rest of that block; else the next byte (may be >= 8: pop next cycle).
          // Both outcomes of hold_a are formed first; hold_a (late) selects.
          eoff   <= hold_a ? n_eoff_h : n_eoff_n;
          skip   <= hold_a ? n_skip_h : n_skip_n;
          wait_s <= hold_a ? n_wait_h : n_wait_n;
        end
        // prefixes
        pfx_ip  <= pfx_any ? pfx_ip_e : cur_ip;
        iss_q   <= cap;
        skq     <= cap ? lsel(v_sk, lf) : (use_pfx && v_sk[1]);
        sk_b    <= n_skb;
        pr_any  <= pfx_any  || use_pfx;
        pr_sv   <= pfx_sv   || (use_pfx && (f0 == 8'h26 || f0 == 8'h2E || f0 == 8'h36 || f0 == 8'h3E ||
                                            f0 == 8'h64 || f0 == 8'h65));
        pr_os   <= pfx_os   || (use_pfx && f0 == 8'h66);
        pr_as   <= pfx_as   || (use_pfx && f0 == 8'h67);
        // (cap selects last: it is the latest signal here)
        eo_os   <= cs_d ^ (cap ? lsel(v_k66, lf) : (pfx_os || (use_pfx && (f0 == 8'h66 || v_k66[1]))));
        eo_as   <= cs_d ^ (cap ? lsel(v_k67, lf) : (pfx_as || (use_pfx && (f0 == 8'h67 || v_k67[1]))));
        pr_lock <= pfx_lock || (use_pfx && f0 == 8'hF0);
        // (the 0F state feeds the 16 length computations: kept a plain register, like eo_*)
        pr_0f   <= cap ? lsel(v_k0f, lf) : (pfx_0f || (use_pfx && (f0 == 8'h0F || v_k0f[1])));
        pr_rep  <= (use_pfx && f0 == 8'hF2) ? 2'b10 : (use_pfx && f0 == 8'hF3) ? 2'b11 : pfx_rep;
        pr_s    <= pfx_s;
        if (use_pfx)
          case (f0)
            8'h26, 8'h2E, 8'h36, 8'h3E: pr_s <= {1'b0, f0[4:3]};
            8'h64: pr_s <= 3'd4;
            8'h65: pr_s <= 3'd5;
            default: ;
          endcase
      end
      // A-stage uop register
      if (inject) begin
        a_valid    <= 1'b1;
        a_af       <= inj_af;
        c_op       <= inject_op;
        c_pg       <= 1'b0;
        c_modrm    <= 8'h00;
        // (no constants here, so c_imm / c_disp need no synchronous reset: the stall
        // reaches their enables late)
        c_imm      <= inject_imm;
        c_ip_start <= inject_ips;
        c_ip_op    <= inject_ips;
        c_ip_nx    <= inject_ipn;
        c_len      <= 4'd0;
        c_sovr_v   <= 1'b0;
        c_rep      <= 2'b00;
        c_os32     <= inject_os32;
        c_as32     <= 1'b0;
        c_lock     <= 1'b0;
        c_ud       <= 1'b0;
        c_eab      <= 8'd0;
        c_eai      <= 9'd0;
        c_eas      <= 2'd0;
        c_pt       <= 1'b0;
        c_inj      <= inject_int;
        c_ecv      <= inject_ecv;
        ucnt       <= inject_cnt;
        c_srdm     <= 6'b000010;
      end else if (kill_a) begin
        a_valid <= 1'b0;
      end else if (!hold_a) begin
        if (seq_more) begin
          a_valid <= 1'b1;
          a_af    <= uw_na;
          if (a_uw[UW_LP_L] && !lpx) ucnt <= ucnt - 5'd1;
        end else begin
          a_valid <= ir_issue;
          a_af    <= af1;
          if (take) begin   // captured whenever decode may advance; a_valid qualifies
            c_op       <= w0;
            c_pg       <= pg;
            c_modrm    <= w1;
            c_disp     <= disp;
            c_imm      <= imm;
            ucnt       <= wb[3][4:0];              // ENTER nesting level
            c_ip_start <= ir_ipstart;
            c_ip_op    <= pg ? ir_curip - 32'd1 : ir_curip;
            c_ip_nx    <= {nx_ip3, ir_iend[2:0]};
            c_len      <= pg ? ir_lf.len + 4'd1 : ir_lf.len;
            c_sovr_v   <= i_sv;
            c_sovr     <= i_s;
            c_rep      <= i_rep;
            c_os32     <= os32;
            c_as32     <= as32;
            c_lock     <= i_lock;
            c_ud       <= ud;
            c_eab      <= eab;
            c_eai      <= eai;
            c_eas      <= eas;
            c_dss      <= dss;
            c_sreg     <= sreg;
            c_pt       <= ir_pt;
            c_ptgt     <= ir_ptgt;
            c_bid      <= ir_bid;
            c_inj      <= 1'b0;
            c_srdm     <= 6'b000000;
            if (!pg)
              casez (w0)
                8'b000?_?110: c_srdm <= 6'(1) << w0[4:3];                 // PUSH seg
                8'h8C:        c_srdm <= 6'(1) << w1[5:3];                 // MOV r/m, sreg
                8'h9A:        c_srdm <= 6'b000010;                        // CALL far: push CS
                8'hFF:        c_srdm <= (w1[5:3] == 3'd3) ? 6'b000010 : 6'b000000;
                default: ;
              endcase
            else
              case (w0)
                8'hA0: c_srdm <= 6'b010000;                               // PUSH FS
                8'hA8: c_srdm <= 6'b100000;                               // PUSH GS
                default: ;
              endcase
          end
        end
      end
    end
  end
  // ------------------------------------------------------------ IR (D1 -> D2)
  always_ff @(posedge clk) begin
    if (rst || kill_a || inject) ir_v <= 1'b0;
    else if (cap)                ir_v <= 1'b1;
    else if (ir_issue)           ir_v <= 1'b0;
    // (the data registers load whenever IR is free or issuing; ir_v alone waits for cap,
    //  the deepest decision in D1: its fan-out to every IR enable was the slow part.  IR
    //  contents without ir_v are never used: A captures them qualified by ir_issue,
    //  pfx_ip_e only in the cycle after a capture)
    if (ir_den) begin
      logic [16*PDW-1:0] two;
      two = {qpd[1], qpd[0]};
      for (int k = 0; k < 11; k++) wb[k] <= fw[k];
      ir_lf      <= lf;
      pc0        <= two[eoff[3:0] * PDW +: PDW];
      pg         <= pg1;
      os32       <= os1;
      as32       <= as1;
      i_sv       <= pfx_sv;
      i_s        <= pfx_s;
      i_rep      <= pfx_rep;
      i_lock     <= pfx_lock;
      i_any      <= pfx_any;
      ir_ipstart <= pfx_any ? pfx_ip_e : cur_ip;
      ir_curip   <= cur_ip;
      ir_cbip3   <= cb_ip3;
      ir_iend    <= iend;
      ir_pt      <= pt_end;
      ir_ptgt    <= qptg[{1'b0, cb} + ptblk];
      ir_bid     <= qbid[{1'b0, cb} + lastblk];
    end
  end
endmodule
