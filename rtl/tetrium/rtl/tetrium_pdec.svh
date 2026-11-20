// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Per-byte predecode shared by fetch (computed at I-cache fill, stored with the
// line) and decode.  Needs ucode_class.svh.
//
// The stored bits do not depend on the processor mode: every byte is described
// in each role it can play, and decode selects with the operand / address size.
//   as a one-byte opcode
//     [0]     pfx     prefix (26 2E 36 3E 64 65 66 67 F0 F2 F3)
//     [1]     esc     0F escape
//     [2]     modrm   a modrm byte follows
//     [5:3]   immc    0 none, 1 ib, 2 iw, 3 iz (2/4 by operand size), 4 far pointer (iz + 2),
//                     5 moffs (2/4 by address size), 6 ENTER (iw + ib),
//                     7 group 3 (immediate iff modrm.reg < 2: ib or iz by [6])
//     [6]     opw     opcode bit 0
//   as the second byte of a 0F opcode
//     [7]     modrm
//     [9:8]   immc    0 none, 1 ib, 2 iz
//   as a modrm byte
//     [11:10] md16    displacement bytes with 16-bit addressing (0, 1, 2)
//     [14:12] md32    32-bit addressing: {SIB follows, displacement 0: none, 1: 1 byte, 2: 4 bytes}
//     [15]    sibx    mod = 0 and rm = 4: 4 more displacement bytes if the SIB base is 5
//     [16]    reg01   reg field < 2
//   as a SIB byte
//     [17]    base5   base field = 5
//   first-uop A-stage field class
//     [22:18] one-byte opcode class,  [23] group opcode (F6 F7 FE FF)
//     [27:24] 0F-page class (15: group opcode 0F00 0F01 0FBA)
localparam int PDW = 28;

  function automatic logic [PDW-1:0] pdec(input logic [7:0] b);
    logic       pfx, esc, m1, m0f, sib, sibx;
    logic [2:0] ic;
    logic [1:0] i0f, md16, d32;
    logic [3:0] c0f;
    pfx = 1'b0; esc = (b == 8'h0F); m1 = 1'b0; ic = 3'd0; m0f = 1'b0; i0f = 2'd0;
    // ---- one-byte opcodes
    casez (b)
      8'b00??_?0??: m1 = 1'b1;                              // ALU r/m forms
      8'b00??_?100: ic = 3'd1;                              // ALU AL,imm8
      8'b00??_?101: ic = 3'd3;                              // ALU eAX,imm
      default: ;
    endcase
    casez (b)
      8'h26, 8'h2E, 8'h36, 8'h3E, 8'h64, 8'h65, 8'h66, 8'h67, 8'hF0, 8'hF2, 8'hF3: begin
        pfx = 1'b1; ic = 3'd0; m1 = 1'b0;
      end
      8'h0F: begin m1 = 1'b0; ic = 3'd0; end
      8'h62, 8'h63: m1 = 1'b1;                              // BOUND, ARPL
      8'h68: ic = 3'd3;
      8'h69: begin m1 = 1'b1; ic = 3'd3; end
      8'h6A: ic = 3'd1;
      8'h6B: begin m1 = 1'b1; ic = 3'd1; end
      8'b0111_????: ic = 3'd1;                              // Jcc rel8
      8'h80, 8'h82, 8'h83: begin m1 = 1'b1; ic = 3'd1; end
      8'h81:        begin m1 = 1'b1; ic = 3'd3; end
      8'b1000_01??, 8'b1000_1???: m1 = 1'b1;                // 84-8F
      8'h9A, 8'hEA: ic = 3'd4;
      8'b1010_00??: ic = 3'd5;                              // A0-A3
      8'hA8: ic = 3'd1;
      8'hA9: ic = 3'd3;
      8'b1011_0???: ic = 3'd1;
      8'b1011_1???: ic = 3'd3;
      8'hC0, 8'hC1: begin m1 = 1'b1; ic = 3'd1; end
      8'hC2, 8'hCA: ic = 3'd2;
      8'hC4, 8'hC5: m1 = 1'b1;
      8'hC6: begin m1 = 1'b1; ic = 3'd1; end
      8'hC7: begin m1 = 1'b1; ic = 3'd3; end
      8'hC8: ic = 3'd6;
      8'hCD, 8'hD4, 8'hD5: ic = 3'd1;
      8'b1101_00??, 8'b1101_1???: m1 = 1'b1;                // D0-D3, D8-DF
      8'b1110_00??: ic = 3'd1;                              // E0-E3
      8'b1110_01??: ic = 3'd1;                              // E4-E7
      8'hE8, 8'hE9: ic = 3'd3;
      8'hEB: ic = 3'd1;
      8'hF6, 8'hF7: begin m1 = 1'b1; ic = 3'd7; end
      8'hFE, 8'hFF: m1 = 1'b1;
      default: ;
    endcase
    // ---- 0F page
    casez (b)
      8'h00, 8'h01, 8'h02, 8'h03: m0f = 1'b1;
      8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h26: m0f = 1'b1;
      8'b1000_????: i0f = 2'd2;                             // Jcc rel16/32
      8'b1001_????: m0f = 1'b1;                             // SETcc
      8'hA3, 8'hA5, 8'hAB, 8'hAD, 8'hAF: m0f = 1'b1;
      8'hA4, 8'hAC: begin m0f = 1'b1; i0f = 2'd1; end
      8'hB0, 8'hB1, 8'hB2, 8'hB3, 8'hB4, 8'hB5, 8'hB6, 8'hB7: m0f = 1'b1;
      8'hBA: begin m0f = 1'b1; i0f = 2'd1; end
      8'hBB, 8'hBC, 8'hBD, 8'hBE, 8'hBF: m0f = 1'b1;
      8'hC0, 8'hC1: m0f = 1'b1;
      default: ;
    endcase
    // ---- as a modrm byte
    case (b[7:6])
      2'd0: md16 = (b[2:0] == 3'd6) ? 2'd2 : 2'd0;
      2'd1: md16 = 2'd1;
      2'd2: md16 = 2'd2;
      default: md16 = 2'd0;
    endcase
    sib  = (b[7:6] != 2'd3) && (b[2:0] == 3'd4);
    sibx = (b[7:6] == 2'd0) && (b[2:0] == 3'd4);
    case (b[7:6])
      2'd0: d32 = (b[2:0] == 3'd5) ? 2'd2 : 2'd0;
      2'd1: d32 = 2'd1;
      2'd2: d32 = 2'd2;
      default: d32 = 2'd0;
    endcase
    c0f = ((b == 8'h00) || (b == 8'h01) || (b == 8'hBA)) ? 4'd15 : opclass0f(b);
    return {c0f, (b[7:4] == 4'hF) && (b[2:1] == 2'b11), opclass(b),
            b[2:0] == 3'd5, b[5:4] == 2'b00, sibx, sib, d32, md16, i0f, m0f, b[0], ic, m1, esc, pfx};
  endfunction
