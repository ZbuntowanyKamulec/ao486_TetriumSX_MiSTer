// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
//
// Tetrium in place of the ao486 CPU in the MiSTer ao486 SoC (rtl/system.v).
//
// Same system-side ports as ao486 (interrupt_do/vector/done, io_read/write_do/done, dma_*,
// a20_enable), memory through the 64-bit L2 port (l2_cache): avm_address is the 64-bit
// word address, avm_byteenable one bit per byte, avm_idle = the L2 takes a request this cycle
// unless avm_waitrequest.  The core runs with BUS_DW = 64 (pipelined Wishbone):
//  * line fill = the only read with all 8 byte selects set: one L2 burst of LINE_B / 8 beats;
//    the core's remaining requests of the fill are taken without stall while the data comes
//  * other reads (uncached, one 32-bit word per beat): L2 burst of 1
//  * writes (store buffer stream, one beat per word): one L2 write each, acked when taken
//  * I/O (tga 1): one iobus transfer per beat (address = first selected byte, length = number
//    of selected bytes, data right-aligned on the iobus side)
//  * INTA (tga 2): returns interrupt_vector in byte 0, pulses interrupt_done
//  * DMA (ISA, 8 / 16 bit): served between core beats (never inside a fill or a locked
//    sequence), with the same dma_waitrequest / dma_readdatavalid shape as ao486's memory
//    unit; DMA writes snoop the core's caches
//  * the i486 reset fetch (FFFFFFF0): FFFE0000-FFFFFFFF aliases E0000-FFFFF (AT chipset)
//  * shutdown (triple fault) resets the core, as AT boards do
//  * CPU clock = clk / 2^clk_div: the core runs on a gated copy of clk (a clock control block,
//    no clock enable inside the core); see "CPU clock" below
`include "tetrium_cfg.svh"
module tetrium_ao486 #(
    // below 1 MB: A0000-BFFFF (VGA) uncached and write-combined, the rest cached
    parameter logic [63:0] CACHEABLE = 64'hFFF7_00FF_FFFF_FFFF,  // CC000-CFFFF (shared-folder window) uncached too
    parameter logic [63:0] WCOMB     = 64'h0000_FF00_0000_0000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [1:0]  clk_div,        // CPU clock = clk / 1, 2, 4, 8

    input  logic        a20_enable,
    input  logic        cache_disable,

    input  logic        interrupt_do,
    input  logic [7:0]  interrupt_vector,
    output logic        interrupt_done,

    output logic [28:0] avm_address,
    output logic [63:0] avm_writedata,
    output logic [7:0]  avm_byteenable,
    output logic [3:0]  avm_burstcount,
    output logic        avm_write,
    output logic        avm_read,
    input  logic        avm_waitrequest,
    input  logic        avm_idle,
    input  logic        avm_readdatavalid,
    input  logic [63:0] avm_readdata,

    input  logic [23:0] dma_address,
    input  logic        dma_16bit,
    input  logic        dma_write,
    input  logic [15:0] dma_writedata,
    input  logic        dma_read,
    output logic [15:0] dma_readdata,
    output logic        dma_readdatavalid,
    output logic        dma_waitrequest,

    output logic        io_read_do,
    output logic [15:0] io_read_address,
    output logic [2:0]  io_read_length,
    input  logic [31:0] io_read_data,
    input  logic        io_read_done,

    output logic        io_write_do,
    output logic [15:0] io_write_address,
    output logic [2:0]  io_write_length,
    output logic [31:0] io_write_data,
    input  logic        io_write_done
);
  localparam int FB = `LINE_B / 8;      // beats per line fill

  // ------------------------------------------------------------------ core
  logic        wb_cyc, wb_stb, wb_we, wb_lock, wb_ack, wb_stall;
  logic [31:3] wb_adr;
  logic [7:0]  wb_sel;
  logic [63:0] wb_dato, wb_dati;
  logic [1:0]  wb_tga;
  logic        halted, shutdown, cflush, cwback;
  logic        snoop_v;
  logic [31:4] snoop_line;
  logic        rst_q, core_rst;

  always_ff @(posedge clk) rst_q <= !rst_n;
  always_ff @(posedge clk) core_rst <= rst_q || shutdown;

  // ------------------------------------------------------------------ CPU clock
  // cpu_ce is high in the clk cycles that end with a core clock edge (every 2^clk_div-th); the
  // clock gate passes those edges only. Everything else here stays on clk and deals with the
  // core only in cpu_ce cycles: core requests are taken and acks / snoops handed over in them,
  // and read data that arrives faster than the core takes it waits in the ack FIFO. The core's
  // bus outputs come from its registers, so they are stable between its edges. With clk_div = 0
  // cpu_ce stays high and the timing is the same as without the gate.
  logic [2:0] dv_cnt;
  logic       cpu_ce, clk_cpu;
  wire  [2:0] dv_nx = (dv_cnt == 3'd0) ? 3'((4'd1 << clk_div) - 4'd1) : dv_cnt - 3'd1;
  always_ff @(posedge clk) begin
    dv_cnt <= dv_nx;
    cpu_ce <= (dv_nx == 3'd0);
  end
  tetrium_clkgate u_cg (.clk, .en(cpu_ce), .gclk(clk_cpu));

  // RESET_CR0: caches on from reset. The ao486 BIOS (Bochs BIOS) never clears CR0.CD / NW
  // (ao486's own CPU ignores them); with the i486 reset value every miss would stay unfilled
  // (about 3.5x slower even with a fast bus). Software that sets CD later is still obeyed.
  tetrium_top #(.CACHEABLE(CACHEABLE), .WCOMB(WCOMB), .BUS_DW(64), .RESET_CR0(32'h0000_0010)) u_cpu (
      .clk(clk_cpu), .rst(core_rst),
      .wb_cyc, .wb_stb, .wb_we, .wb_adr, .wb_sel, .wb_dato, .wb_tga, .wb_lock,
      .wb_dati, .wb_ack, .wb_stall,
      .intr(interrupt_do), .nmi(1'b0), .a20m(!a20_enable),
      .snoop_v, .snoop_line, .flush(1'b0), .cflush, .cwback,
      .halted, .shutdown);

  // ------------------------------------------------------------------ bridge
  typedef enum logic [2:0] {S_IDLE, S_RD, S_IO, S_INTA, S_DMAR, S_DMAW} st_t;
  st_t         st;
  logic [3:0]  r_n;          // beats of the current read burst
  logic [3:0]  r_acc;        // core requests taken for it
  logic [3:0]  r_got;        // data beats returned
  logic        io_go, io_we_q;
  logic [2:0]  io_lane;
  logic [1:0]  dma_cool;     // the DMA controller's request drops two cycles after the grant

  wire req    = wb_cyc && wb_stb && cpu_ce;   // a core request that can be taken this cycle
  wire take   = req && !wb_stall;
  wire l2_ok  = avm_idle && !avm_waitrequest;
  wire fill   = !wb_we && (wb_sel == 8'hFF);
  wire dma_rq = (dma_read || dma_write) && (dma_cool == 2'd0) && !wb_lock;
  wire dma_go = dma_rq && (cpu_ce || !dma_write);  // a DMA write's snoop goes to the core with it
  wire take_dma = (st == S_IDLE) && dma_go && l2_ok;
  wire mem_rq = req && (wb_tga == 2'd0);

  // physical 64-bit word address (BIOS alias at the top of the 4 GB)
  wire [28:0] cpu_wa = (wb_adr[31:17] == 15'h7FFF) ? {12'h000, 3'b111, wb_adr[16:3]} : wb_adr[31:3];

  // I/O: first selected byte and number of bytes (the selects are contiguous)
  logic [2:0] sel_lo;
  logic [3:0] sel_n;
  always_comb begin
    sel_lo = 3'd0;
    for (int k = 7; k >= 0; k--) if (wb_sel[k]) sel_lo = 3'(k);
    sel_n = 4'd0;
    for (int k = 0; k < 8; k++) sel_n = sel_n + {3'b000, wb_sel[k]};
  end

  // DMA lanes (byte or 16-bit word in the 64-bit row)
  wire [7:0] dma_be = dma_16bit ? (8'b0000_0011 << {dma_address[2:1], 1'b0}) : (8'b0000_0001 << dma_address[2:0]);

  always_comb begin
    avm_address    = cpu_wa;
    avm_writedata  = wb_dato;
    avm_byteenable = wb_sel;
    avm_burstcount = fill ? 4'(FB) : 4'd1;
    avm_write      = 1'b0;
    avm_read       = 1'b0;
    wb_stall       = 1'b1;
    if (st == S_IDLE) begin
      if (dma_rq) begin
        avm_address    = {5'd0, dma_address[23:3]};
        avm_writedata  = dma_16bit ? {4{dma_writedata}} : {8{dma_writedata[7:0]}};
        avm_byteenable = dma_be;
        avm_burstcount = 4'd1;
        avm_write      = dma_go && dma_write;
        avm_read       = dma_go && !dma_write;
      end else if (mem_rq) begin
        avm_write = wb_we;
        avm_read  = !wb_we;
        wb_stall  = !l2_ok;
      end else if (req) begin
        wb_stall  = 1'b0;          // I/O, INTA: taken at once, acked when done
      end
    end else if (st == S_RD) begin
      wb_stall = (r_acc == r_n);   // the fill's remaining requests
    end
  end

  // acks to the core, in order: at most one line fill (FB beats) is outstanding, as the core
  // starts its next transfer only after the last ack of the current one. An ack goes out only
  // for a request taken at an earlier core edge (a fill's data can come before its requests).
  localparam int QA = $clog2(FB);
  logic [QA-1:0] aq_wp, aq_rp;
  logic [QA:0]   aq_n;         // entries
  logic [QA:0]   pend;         // core requests taken, not yet acked
  logic          aq_push;
  logic [63:0]   aq_in;
  always_comb begin
    aq_push = 1'b0;
    aq_in   = avm_readdata;
    case (st)
      S_IDLE: aq_push = take && (wb_tga == 2'd0) && wb_we;   // writes: acked when taken
      S_RD:   aq_push = avm_readdatavalid;
      S_IO: begin
        aq_push = io_we_q ? io_write_done : io_read_done;
        aq_in   = 64'({32'h0, io_read_data} << {io_lane, 3'b000});
      end
      S_INTA: begin
        aq_push = 1'b1;
        aq_in   = {56'h0, interrupt_vector};
      end
      default: ;
    endcase
  end
  tetrium_lutram #(.AW(QA), .DW(64)) u_aq (.clk, .clr(1'b0), .we(aq_push), .waddr(aq_wp),
      .wdata(aq_in), .raddr(aq_rp), .rdata(wb_dati));
  assign wb_ack = (aq_n != '0) && (pend != '0);
  wire aq_pop = cpu_ce && wb_ack;

  always_ff @(posedge clk) begin
    if (core_rst) begin
      aq_wp <= '0; aq_rp <= '0; aq_n <= '0; pend <= '0;
    end else begin
      if (aq_push) aq_wp <= aq_wp + 1'b1;
      if (aq_pop)  aq_rp <= aq_rp + 1'b1;
      aq_n <= aq_n + (QA+1)'(aq_push) - (QA+1)'(aq_pop);
      pend <= pend + (QA+1)'(take) - (QA+1)'(aq_pop);
    end
  end

  assign snoop_v    = take_dma && dma_write;
  assign snoop_line = {8'h00, dma_address[23:4]};

  assign dma_waitrequest   = !(st == S_DMAR || st == S_DMAW);
  assign dma_readdatavalid = (st == S_DMAR) && avm_readdatavalid;
  assign dma_readdata      = dma_16bit ? avm_readdata[{dma_address[2:1], 4'b0000} +: 16]
                                       : {8'h00, avm_readdata[{dma_address[2:0], 3'b000} +: 8]};

  assign io_read_do  = io_go && !io_we_q;
  assign io_write_do = io_go && io_we_q;

  always_ff @(posedge clk) begin
    io_go          <= 1'b0;
    interrupt_done <= 1'b0;
    if (dma_cool != 2'd0) dma_cool <= dma_cool - 2'd1;
    if (rst_q) begin
      st <= S_IDLE;
      dma_cool <= 2'd0;
    end else begin
      case (st)
        S_IDLE:
          if (take_dma) begin
            st <= dma_write ? S_DMAW : S_DMAR;
          end else if (take) begin
            case (wb_tga)
              2'd0: if (!wb_we) begin st <= S_RD; r_n <= fill ? 4'(FB) : 4'd1; r_acc <= 4'd1; r_got <= 4'd0; end
              2'd1: begin
                st <= S_IO; io_go <= 1'b1; io_we_q <= wb_we; io_lane <= sel_lo;
                io_read_address  <= {wb_adr[15:3], sel_lo};
                io_write_address <= {wb_adr[15:3], sel_lo};
                io_read_length   <= sel_n[2:0];
                io_write_length  <= sel_n[2:0];
                io_write_data    <= 32'(wb_dato >> {sel_lo, 3'b000});
              end
              default: begin
                st <= S_INTA;
              end
            endcase
          end
        S_RD: begin
          // done when all beats are in and the core has issued all its requests for them
          // (a slowed core can still be issuing the fill's requests after the last beat)
          r_acc <= r_acc + 4'(take);
          r_got <= r_got + 4'(avm_readdatavalid);
          if (r_got + 4'(avm_readdatavalid) == r_n && r_acc + 4'(take) == r_n) st <= S_IDLE;
        end
        S_IO:
          if (io_we_q ? io_write_done : io_read_done) st <= S_IDLE;
        S_INTA: begin
          interrupt_done <= 1'b1;
          st <= S_IDLE;
        end
        S_DMAW: begin
          st <= S_IDLE;
          dma_cool <= 2'd2;
        end
        S_DMAR:
          if (avm_readdatavalid) begin
            st <= S_IDLE;
            dma_cool <= 2'd2;
          end
        default: st <= S_IDLE;
      endcase
    end
  end

`ifdef SIM
  always_ff @(posedge clk)
    if (!core_rst && aq_push && !aq_pop && aq_n == (QA+1)'(FB))
      $fatal(1, "tetrium_ao486: ack FIFO overflow (st %0d pend %0d tga %0d we %0d sel %h r_n %0d r_acc %0d r_got %0d)",
             st, pend, wb_tga, wb_we, wb_sel, r_n, r_acc, r_got);
`endif
endmodule

// Gated clock for the core: gclk passes the clk cycles for which en was high at the preceding
// rising edge (en is sampled on the falling edge, so gclk is glitch-free). Quartus: a Cyclone V
// clock control block on a global network; timing is analysed as clk, nothing to constrain.
module tetrium_clkgate (
    input  logic clk,
    input  logic en,
    output logic gclk
);
`ifdef ALTERA
  cyclonev_clkena #(.clock_type("Global Clock"), .ena_register_mode("falling edge"),
      .disable_mode("low")) u_ena (.inclk(clk), .ena(en), .enaout(), .outclk(gclk));
`else
  logic en_l;
  always_ff @(negedge clk) en_l <= en;
  assign gclk = clk & en_l;
`endif
endmodule
