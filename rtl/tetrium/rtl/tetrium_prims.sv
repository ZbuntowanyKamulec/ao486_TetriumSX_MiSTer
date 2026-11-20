// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Tetrium memory primitives. Written so that Vivado and Quartus both infer
// block RAM / distributed RAM from them without vendor primitives.

// Simple dual-port block RAM: one synchronous read port with enable and one
// write port. Read-during-write to the same address returns OLD data
// (the core relies on that and handles the hazard itself).
module tetrium_bram #(
    parameter int AW = 10,
    parameter int DW = 8,
    parameter logic [DW-1:0] INIT = '0      // initial content of every word
) (
    input  logic          clk,
    input  logic          re,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata
);
`ifdef ALTERA
  (* ramstyle = "M10K, no_rw_check" *) logic [DW-1:0] mem [0:(1<<AW)-1];
`else
  (* ram_style = "block" *) logic [DW-1:0] mem [0:(1<<AW)-1];
`endif
  initial for (int i = 0; i < (1 << AW); i++) mem[i] = INIT;
  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    if (re) rdata <= mem[raddr];
  end
endmodule

// Simple dual-port block RAM with byte write enables (NB bytes per word).
module tetrium_bram_be #(
    parameter int AW = 9,
    parameter int NB = 4
) (
    input  logic            clk,
    input  logic            re,
    input  logic [AW-1:0]   raddr,
    output logic [8*NB-1:0] rdata,
    input  logic [NB-1:0]   we,
    input  logic [AW-1:0]   waddr,
    input  logic [8*NB-1:0] wdata
);
`ifdef ALTERA
  (* ramstyle = "M10K, no_rw_check" *) logic [8*NB-1:0] mem [0:(1<<AW)-1];
`else
  (* ram_style = "block" *) logic [8*NB-1:0] mem [0:(1<<AW)-1];
`endif
  always_ff @(posedge clk) begin
    for (int b = 0; b < NB; b++) if (we[b]) mem[waddr][b*8 +: 8] <= wdata[b*8 +: 8];
    if (re) rdata <= mem[raddr];
  end
endmodule

// Synchronous ROM with read enable, initialised from a hex file.
module tetrium_rom #(
    parameter int AW = 10,
    parameter int DW = 64,
    parameter FILE = "ucode_rom.hex"
) (
    input  logic          clk,
    input  logic          re,
    input  logic [AW-1:0] addr,
    output logic [DW-1:0] q
);
`ifdef ALTERA
  (* ramstyle = "M10K" *) logic [DW-1:0] mem [0:(1<<AW)-1];
`else
  (* rom_style = "block" *) logic [DW-1:0] mem [0:(1<<AW)-1];
`endif
  initial $readmemh(FILE, mem);
  always_ff @(posedge clk) if (re) q <= mem[addr];
endmodule

// Distributed RAM: one synchronous write port, NR asynchronous read ports.
// In simulation (SIM defined) 'clr' flash-clears the whole array.
module tetrium_lutram #(
    parameter int AW = 9,
    parameter int DW = 8,
    parameter int NR = 1
) (
    input  logic             clk,
    input  logic             clr,
    input  logic             we,
    input  logic [AW-1:0]    waddr,
    input  logic [DW-1:0]    wdata,
    input  logic [NR*AW-1:0] raddr,
    output logic [NR*DW-1:0] rdata
);
  genvar r;
`ifdef ALTERA
  // Quartus (17) builds a multi-read-port array from registers, and loses the
  // MLAB style for an array read or declared inside a generate block: one
  // single-port MLAB module per read port (Vivado replicates internally)
  generate
  for (r = 0; r < NR; r = r + 1) begin : g_rd
    tetrium_mlab #(.AW(AW), .DW(DW)) u_m (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(raddr[r*AW +: AW]), .rdata(rdata[r*DW +: DW]));
  end
  endgenerate
`else
  (* ram_style = "distributed" *) logic [DW-1:0] mem [0:(1<<AW)-1];
`endif
`ifdef ALTERA
`elsif SIM
  // simulation only: flash clear through a packed valid vector
  logic [(1<<AW)-1:0] vld;
  always_ff @(posedge clk) begin
    if (clr) vld <= '0;
    else if (we) vld[waddr] <= 1'b1;
    if (we) mem[waddr] <= wdata;
  end
  generate
  for (r = 0; r < NR; r = r + 1) begin : g_rd
    assign rdata[r*DW +: DW] = vld[raddr[r*AW +: AW]] ? mem[raddr[r*AW +: AW]] : '0;
  end
  endgenerate
`else
  always_ff @(posedge clk) if (we) mem[waddr] <= wdata;
  generate
  for (r = 0; r < NR; r = r + 1) begin : g_rd
    assign rdata[r*DW +: DW] = mem[raddr[r*AW +: AW]];
  end
  endgenerate
`endif
endmodule

// Quartus: one MLAB, one synchronous write port, one asynchronous read port
// (used by tetrium_lutram under ALTERA)
module tetrium_mlab #(
    parameter int AW = 9,
    parameter int DW = 8
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata
);
  (* ramstyle = "MLAB, no_rw_check" *) logic [DW-1:0] mem [0:(1<<AW)-1];
  always_ff @(posedge clk) if (we) mem[waddr] <= wdata;
  assign rdata = mem[raddr];
endmodule
