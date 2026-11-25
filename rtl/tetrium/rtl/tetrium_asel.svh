// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// A-stage operand selects, decoded one cycle early (in D) and registered.
//   bsel  base register, one-hot by GPR index (AX CX DX BX SP BP SI DI)
//   isel  index: GPR one-hot [7:0], AL [8] (XLAT)
//   dsel  displacement (one-hot OR): disp, disp + operand size (EA2; 0F 01: + 2; registered,
//         so not valid in an instruction's first uop), vec, vec2, imm, ~imm, +1, -1, aoff,
//         {imm[15:3], aoff[2:0]} (descriptor of an immediate selector),
//         {imm[7:0], aoff[2:0]} (IDT gate)
//   ssel  segment ES CS SS DS FS GS, descriptor table (GDT / LDT by the selector's TI),
//         IDT, TSS (none = 0: linear, A-executed ops)
//   aex   the A stage computes this uop's register result (see below)
//   asub  result = base + index + disp + 1 (SUB r, imm)
//   areg  destination GPR of an A-executed uop
//   scl   index scale (32-bit addressing)
//   dscm  the base is a selector: masked to its index (& FFF8)
localparam int AS_B = 0, AS_I = 8, AS_D = 17, AS_DW = 11, AS_S = 28, AS_SW = 9,
               AS_AEX = 37, AS_ASUB = 38, AS_AREG = 39, AS_SCL = 42, AS_DSCM = 44;
localparam int ASEL_W = 45;
// bsel / isel / scl / dss of the instruction's modrm (+ SIB) come from decode
// (ea_b, ea_i, ea_s, dss; for a register modrm ea_b names the r/m register); the
// uop's address mode picks what is used.
function automatic logic [ASEL_W-1:0] asel(input logic [AF_BITS-1:0] af, input logic [7:0] ea_b,
                                           input logic [8:0] ea_i, input logic [1:0] ea_s,
                                           input logic sovr_v, input logic [2:0] sovr, input logic dss);
  logic [4:0] am;
  logic [7:0] b;
  logic [8:0] i;
  logic [AS_DW-1:0] d;
  logic [AS_SW-1:0] sg;
  logic [1:0] sc;
  logic [2:0] si;
  logic       dm;
  am = af[AF_AMODE_L +: AF_AMODE_W];
  b = '0; i = '0; d = '0; sg = '0; sc = '0; dm = 1'b0;
  si = sovr_v ? sovr : (dss ? 3'd2 : 3'd3);
  case (am)
    AM_EA, AM_EA2, AM_EAC: begin
      b = ea_b; i = ea_i; sc = ea_s;
      d[0] = (am != AM_EA2); d[1] = (am == AM_EA2);
      sg[si] = 1'b1;
    end
    AM_TA: sg[si] = 1'b1;
    AM_TAS: sg[2] = 1'b1;
    AM_POP, AM_POPN: begin b[4] = 1'b1; sg[2] = 1'b1; end
    AM_SI: begin b[6] = 1'b1; sg[sovr_v ? sovr : 3'd3] = 1'b1; end
    AM_DI: begin b[7] = 1'b1; sg[0] = 1'b1; end
    AM_VEC:  begin d[2] = 1'b1; sg[7] = 1'b1; end
    AM_VEC2: begin d[3] = 1'b1; sg[7] = 1'b1; end
    AM_DSCR: begin b = ea_b; d[8] = 1'b1; sg[6] = 1'b1; dm = 1'b1; end
    AM_DSCT: begin d[8] = 1'b1; sg[6] = 1'b1; dm = 1'b1; end
    AM_DSCI: begin d[9] = 1'b1; sg[6] = 1'b1; end
    AM_IDT:  begin d[10] = 1'b1; sg[7] = 1'b1; end
    AM_TSS:  begin d[8] = 1'b1; sg[8] = 1'b1; end
    AM_LIN:  d[8] = 1'b1;
    AM_TSSA: begin d[8] = 1'b1; sg[8] = 1'b1; end
    default: ;
  endcase
  return {dm, sc, 3'd0, 1'b0, 1'b0, sg, d, i, b};
endfunction

// A-executed register ops (operand size 16 / 32): the A stage computes the
// result on its own adder and writes the A-copy immediately, so dependent
// address computations do not interlock.  E executes the instruction normally
// (flags, architectural registers) but does not write the A-copy again.
//   MOV r,r (89/8B mod3)  MOV r,imm (B8+r)  INC/DEC r (40-4F)  ADD r,r (01/03 mod3)
//   ADD/SUB r,imm (81/83 /0 /5 mod3)  LEA (8D, uses the normal EA selects)
//   SHL r,1 (D1 /4 mod3: r + r)  SHL r,imm (C1 /4 mod3, count 1-3: index scaled by the count)
function automatic logic [ASEL_W-1:0] aexsel(input logic pg, input logic [7:0] op, input logic [7:0] mrm,
                                             input logic [7:0] ib, input logic [ASEL_W-1:0] dflt);
  logic [ASEL_W-1:0] r;
  logic m3;
  logic [2:0] rg, rmv;
  m3 = (mrm[7:6] == 2'd3); rg = mrm[5:3]; rmv = mrm[2:0];
  r = '0;
  casez (op)
    8'h8B: if (m3) begin r[AS_B + rmv] = 1'b1; r[AS_AREG +: 3] = rg; r[AS_AEX] = 1'b1; end
    8'h89: if (m3) begin r[AS_B + rg] = 1'b1;  r[AS_AREG +: 3] = rmv; r[AS_AEX] = 1'b1; end
    8'b1011_1???: begin r[AS_D + 4] = 1'b1; r[AS_AREG +: 3] = op[2:0]; r[AS_AEX] = 1'b1; end
    8'b0100_0???: begin r[AS_B + op[2:0]] = 1'b1; r[AS_D + 6] = 1'b1; r[AS_AREG +: 3] = op[2:0]; r[AS_AEX] = 1'b1; end
    8'b0100_1???: begin r[AS_B + op[2:0]] = 1'b1; r[AS_D + 7] = 1'b1; r[AS_AREG +: 3] = op[2:0]; r[AS_AEX] = 1'b1; end
    8'h01: if (m3) begin r[AS_B + rmv] = 1'b1; r[AS_I + rg] = 1'b1;  r[AS_AREG +: 3] = rmv; r[AS_AEX] = 1'b1; end
    8'h03: if (m3) begin r[AS_B + rg] = 1'b1;  r[AS_I + rmv] = 1'b1; r[AS_AREG +: 3] = rg;  r[AS_AEX] = 1'b1; end
    8'h81, 8'h83:
      if (m3 && rg == 3'd0) begin r[AS_B + rmv] = 1'b1; r[AS_D + 4] = 1'b1; r[AS_AREG +: 3] = rmv; r[AS_AEX] = 1'b1; end
      else if (m3 && rg == 3'd5) begin
        r[AS_B + rmv] = 1'b1; r[AS_D + 5] = 1'b1; r[AS_ASUB] = 1'b1; r[AS_AREG +: 3] = rmv; r[AS_AEX] = 1'b1;
      end
    8'hD1: if (m3 && rg == 3'd4) begin r[AS_B + rmv] = 1'b1; r[AS_I + rmv] = 1'b1; r[AS_AREG +: 3] = rmv; r[AS_AEX] = 1'b1; end
    8'hC1: if (m3 && rg == 3'd4 && ib[4:2] == 3'd0 && ib[1:0] != 2'd0) begin
             r[AS_I + rmv] = 1'b1; r[AS_SCL +: 2] = ib[1:0]; r[AS_AREG +: 3] = rmv; r[AS_AEX] = 1'b1;
           end
    8'h8D: if (!m3) begin r = dflt; r[AS_S +: AS_SW] = '0; r[AS_AREG +: 3] = rg; r[AS_AEX] = 1'b1; end
    default: ;
  endcase
  return (r[AS_AEX] && !pg) ? r : dflt;
endfunction
