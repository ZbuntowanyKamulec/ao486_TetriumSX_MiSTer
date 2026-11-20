// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
//
// Simulation models (Verilator) of the Altera RAM primitives the ao486 SoC uses, only in the
// modes it uses them in: altdpram (L2 tags / dirty / LRU: registered write, unregistered read),
// altsyncram DUAL_PORT (L2 rows: write port A with byte enables, read port B with a registered
// address), and the VHDL wrappers of rtl/common/bram.vhd (dpram / dpram_dif / dpram_difclk:
// BIDIR_DUAL_PORT, registered addresses, new data on read-during-write, q = all ones when
// cs is low).  Verilator has no port defaults: cs and enable_a (never connected in the
// SoC) are left out, enable_b is connected on every dpram_difclk, dpram passes 1.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off MULTIDRIVEN */
module altdpram #(
    parameter width = 1, parameter widthad = 1, parameter width_byteena = 1,
    parameter indata_aclr = "OFF", parameter indata_reg = "INCLOCK", parameter intended_device_family = "",
    parameter lpm_type = "", parameter outdata_aclr = "OFF", parameter outdata_reg = "UNREGISTERED",
    parameter ram_block_type = "", parameter rdaddress_aclr = "OFF", parameter rdaddress_reg = "UNREGISTERED",
    parameter rdcontrol_aclr = "OFF", parameter rdcontrol_reg = "UNREGISTERED",
    parameter read_during_write_mode_mixed_ports = "", parameter wraddress_aclr = "OFF",
    parameter wraddress_reg = "INCLOCK", parameter wrcontrol_aclr = "OFF", parameter wrcontrol_reg = "INCLOCK"
) (
    input logic                inclock,
    input logic                outclock,
    input logic  [width-1:0]   data,
    input logic  [widthad-1:0] rdaddress,
    input logic  [widthad-1:0] wraddress,
    input logic                wren,
    output [width-1:0]   q
);
  reg [width-1:0] mem [0:(1<<widthad)-1];
  always @(posedge inclock) if (wren) mem[wraddress] <= data;
  assign q = mem[rdaddress];
endmodule

module altsyncram #(
    parameter address_aclr_b = "NONE", parameter address_reg_b = "CLOCK0", parameter byte_size = 8,
    parameter clock_enable_input_a = "BYPASS", parameter clock_enable_input_b = "BYPASS",
    parameter clock_enable_output_b = "BYPASS", parameter intended_device_family = "",
    parameter lpm_type = "", parameter numwords_a = 1, parameter numwords_b = 1,
    parameter operation_mode = "DUAL_PORT", parameter outdata_aclr_b = "NONE",
    parameter outdata_reg_b = "UNREGISTERED", parameter power_up_uninitialized = "FALSE",
    parameter read_during_write_mode_mixed_ports = "DONT_CARE",
    parameter widthad_a = 1, parameter widthad_b = 1, parameter width_a = 8, parameter width_b = 8,
    parameter width_byteena_a = 1
) (
    input logic                    clock0,
    input logic  [widthad_a-1:0]   address_a,
    input logic  [width_byteena_a-1:0] byteena_a,
    input logic  [width_a-1:0]     data_a,
    input logic                    wren_a,
    input logic  [widthad_b-1:0]   address_b,
    output [width_b-1:0]     q_b,
    output [width_a-1:0]     q_a,
    input logic aclr0, input logic aclr1, input logic addressstall_a, input logic addressstall_b, input logic byteena_b,
    input logic clock1, input logic clocken0, input logic clocken1, input logic clocken2, input logic clocken3,
    input logic [width_b-1:0] data_b, output eccstatus, input logic rden_a, input logic rden_b, input logic wren_b
);
  initial if (width_a != width_b || widthad_a != widthad_b) $fatal(1, "altsyncram model: mixed widths");
  reg [width_a-1:0] mem [0:numwords_a-1];
  reg [widthad_b-1:0] ab;
  integer k;
  always @(posedge clock0) begin
    if (wren_a)
      for (k = 0; k < width_byteena_a; k = k + 1)
        if (byteena_a[k]) mem[address_a][k*byte_size +: byte_size] <= data_a[k*byte_size +: byte_size];
    ab <= address_b;
  end
  assign q_b = mem[ab];
  assign q_a = {width_a{1'b0}};
  assign eccstatus = 1'b0;
endmodule

module dpram_difclk #(
    parameter addr_width_a = 8, parameter data_width_a = 8,
    parameter addr_width_b = 8, parameter data_width_b = 8, parameter mem_init_file = " "
) (
    input  logic                    clk_a,
    input  logic                    clk_b,
    input  logic [addr_width_a-1:0] address_a,
    input  logic [data_width_a-1:0] data_a,
    input  logic                    wren_a,
    output logic [data_width_a-1:0] q_a,
    input  logic [addr_width_b-1:0] address_b,
    input  logic [data_width_b-1:0] data_b,
    input  logic                    enable_b,
    input  logic                    wren_b,
    output logic [data_width_b-1:0] q_b
);
  initial if (data_width_a != data_width_b || addr_width_a != addr_width_b) $fatal(1, "dpram model: mixed widths");
  logic [data_width_a-1:0] mem [0:(1<<addr_width_a)-1];
  logic [addr_width_a-1:0] aa, ab;
  always @(posedge clk_a) begin
    if (wren_a) mem[address_a] <= data_a;
    aa <= address_a;
  end
  always @(posedge clk_b) if (enable_b) begin
    if (wren_b) mem[address_b] <= data_b;
    ab <= address_b;
  end
  assign q_a = mem[aa];
  assign q_b = mem[ab];
endmodule

module dpram #(parameter addr_width = 8, parameter data_width = 8, parameter mem_init_file = " ") (
    input  logic                  clock,
    input  logic [addr_width-1:0] address_a,
    input  logic [data_width-1:0] data_a,
    input  logic                  wren_a,
    output logic [data_width-1:0] q_a,
    input  logic [addr_width-1:0] address_b,
    input  logic [data_width-1:0] data_b,
    input  logic                  wren_b,
    output logic [data_width-1:0] q_b
);
  dpram_difclk #(addr_width, data_width, addr_width, data_width) r (
      .clk_a(clock), .clk_b(clock), .address_a, .data_a, .wren_a, .q_a,
      .address_b, .data_b, .enable_b(1'b1), .wren_b, .q_b);
endmodule
