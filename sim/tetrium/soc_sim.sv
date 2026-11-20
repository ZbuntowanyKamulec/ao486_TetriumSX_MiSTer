// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
//
// Simulation top: the ao486 SoC (rtl/system.v with Tetrium + the 64-bit L2), clk_sys for
// everything (UART / MPU / audio clocks too) except clk_vga = 2 x clk_sys, MiSTer's PS/2 keyboard device
// (sys/hps_io.sv ps2_device) driven by the testbench, sound / GUS / UART / MPU stubbed.
// The testbench (tb_soc.cpp) plays the HPS: DDR3 model, BIOS images, mgmt writes (CMOS,
// floppy, IDE), the keyboard host protocol, and shows the VGA output in a window.
module soc_sim (
    input  logic        clk,
    input  logic        clk_vga,      // 2x clk: the VGA pipeline needs gaps between pixel enables
    input  logic        reset,
    input  logic [27:0] clock_rate,
    input  logic [1:0]  cpu_clk_div,  // CPU clock = clk / 2^n

    input  logic [15:0] mgmt_address,
    input  logic        mgmt_read,
    output logic [15:0] mgmt_readdata,
    input  logic        mgmt_write,
    input  logic [15:0] mgmt_writedata,
    output logic [1:0]  fdd_request,
    output logic [2:0]  ide0_request,
    output logic [2:0]  ide1_request,

    input  logic        DDRAM_BUSY,
    output logic [7:0]  DDRAM_BURSTCNT,
    output logic [24:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic        DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic [7:0]  DDRAM_BE,
    output logic        DDRAM_WE,

    output logic        video_ce,
    output logic        video_blank_n,
    output logic        video_hsync,
    output logic        video_vsync,
    output logic [7:0]  video_r,
    output logic [7:0]  video_g,
    output logic [7:0]  video_b,

    // keyboard (HPS side of ps2_device)
    input  logic [7:0]  kbd_wdata,
    input  logic        kbd_we,
    output logic [8:0]  kbd_rdata,
    input  logic        kbd_rd,
    output logic        ps2_reset_n,
    // mouse (HPS side of a second ps2_device, as hps_io's)
    input  logic [7:0]  ms_wdata,
    input  logic        ms_we,
    output logic [8:0]  ms_rdata,
    input  logic        ms_rd,

    // debug: I/O writes (one cycle each), shutdown / halt
    output logic        dbg_io_wr,
    output logic [15:0] dbg_io_addr,
    output logic [31:0] dbg_io_data,
    output logic [2:0]  dbg_io_len,
    output logic        dbg_ior_done,     // I/O read completes: address / length / data
    output logic [15:0] dbg_ior_addr,
    output logic [2:0]  dbg_ior_len,
    output logic [31:0] dbg_ior_data,
    output logic        dbg_halted,
    output logic        dbg_inj,          // exception / INT n delivery starts (E, complete)
    output logic        dbg_inj_flt,      //  ... it is a fault
    output logic [7:0]  dbg_inj_vec,
    output logic [15:0] dbg_inj_err,
    output logic [31:0] dbg_inj_ip,
    output logic        dbg_shutdown,
    output logic [255:0] dbg_gpr,         // EAX ECX EDX EBX ESP EBP ESI EDI (E stage, architectural)
    output logic [95:0] dbg_seg,          // selectors ES CS SS DS FS GS
    output logic [31:0] dbg_flags,
    output logic [31:0] dbg_cr0,
    output logic [31:0] dbg_cr2,
    output logic [31:0] dbg_cr3,
    output logic [31:0] dbg_idtb,
    output logic [31:0] dbg_gdtb,
    output logic [31:0] dbg_trb,
    output logic [31:0] dbg_sys,          // {TR, LDTR}
    // CPU <-> L2 (Avalon, 64-bit words): memory checker in the testbench
    output logic [28:0] dbg_m_addr,
    output logic [63:0] dbg_m_wdata,
    output logic [63:0] dbg_m_rdata,
    output logic [7:0]  dbg_m_be,
    output logic [3:0]  dbg_m_bc,
    output logic        dbg_m_rd,
    output logic        dbg_m_wr,
    output logic        dbg_m_wait,
    output logic        dbg_m_rvalid,
    output logic        dbg_retire,
    output logic [31:0] dbg_ip,
    output logic [15:0] dbg_cs,
    output logic        dbg_vga_we,
    output logic [16:0] dbg_vga_addr,
    output logic [7:0]  dbg_vga_data,
    output logic [2:0]  dbg_vga_mode
);
  // PS/2 bit clock: clk / 2048 (about 16 kHz at 33 MHz)
  logic [10:0] ps2div;
  always_ff @(posedge clk) ps2div <= ps2div + 11'd1;
  wire clk_ps2 = ps2div[10];

  logic kb_clk_dev, kb_dat_dev, kb_clk_host, kb_dat_host;
  ps2_device keyboard (
      .clk_sys(clk), .wdata(kbd_wdata), .we(kbd_we), .ps2_clk(clk_ps2),
      .ps2_clk_out(kb_clk_dev), .ps2_dat_out(kb_dat_dev), .tx_empty(),
      .ps2_clk_in(kb_clk_host), .ps2_dat_in(kb_dat_host),
      .rdata(kbd_rdata), .rd(kbd_rd));

  logic ms_clk_dev, ms_dat_dev, ms_clk_host, ms_dat_host;
  ps2_device mouse (
      .clk_sys(clk), .wdata(ms_wdata), .we(ms_we), .ps2_clk(clk_ps2),
      .ps2_clk_out(ms_clk_dev), .ps2_dat_out(ms_dat_dev), .tx_empty(),
      .ps2_clk_in(ms_clk_host), .ps2_dat_in(ms_dat_host),
      .rdata(ms_rdata), .rd(ms_rd));

  wire [15:0] SDRAM_DQ;
  system system (
      .reset, .clk_sys(clk), .clock_rate, .cpu_clk_div,
      .l1_disable(1'b0), .l2_disable(1'b0),
      .fdd_request, .ide0_request, .ide1_request, .floppy_wp(2'b00),
      .joystick_dis(2'b11), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
      .joystick_ana_1(16'd0), .joystick_ana_2(16'd0), .joystick_mode(3'd0), .joystick_timed(2'd0),
      .mgmt_address, .mgmt_read, .mgmt_readdata, .mgmt_write, .mgmt_writedata,
      .ps2_kbclk_in(kb_clk_dev), .ps2_kbdat_in(kb_dat_dev),
      .ps2_kbclk_out(kb_clk_host), .ps2_kbdat_out(kb_dat_host),
      .ps2_mouseclk_in(ms_clk_dev), .ps2_mousedat_in(ms_dat_dev),
      .ps2_mouseclk_out(ms_clk_host), .ps2_mousedat_out(ms_dat_host),
      .ps2_reset_n,
      .bootcfg(6'd0), .uma_ram(1'b0), .syscfg(),
      .clk_uart1(clk), .uart1_rx(1'b1), .uart1_tx(), .uart1_cts_n(1'b0), .uart1_dcd_n(1'b0),
      .uart1_dsr_n(1'b0), .uart1_rts_n(), .uart1_dtr_n(),
      .clk_uart2(clk), .uart2_rx(1'b1), .uart2_tx(), .uart2_cts_n(1'b0), .uart2_dcd_n(1'b0),
      .uart2_dsr_n(1'b0), .uart2_rts_n(), .uart2_dtr_n(),
      .clk_mpu(clk), .mpu_rx(1'b1), .mpu_tx(),
      .clk_audio(clk), .sample_cms_l(), .sample_cms_r(), .sample_sb_l(), .sample_sb_r(),
      .sample_opl_l(), .sample_opl_r(), .sound_fm_mode(1'b0), .sound_cms_en(1'b0),
      .sample_gus_l(), .sample_gus_r(), .speaker_out(), .sbp(),
      .vol_master_l(), .vol_master_r(), .vol_voice_l(), .vol_voice_r(), .vol_midi_l(), .vol_midi_r(),
      .vol_cd_l(), .vol_cd_r(), .vol_line_l(), .vol_line_r(), .vol_spk(), .vol_en(),
      .clk_vga, .clock_rate_vga({clock_rate[26:0], 1'b0}),
      .video_ce, .video_blank_n, .video_hsync, .video_vsync, .video_r, .video_g, .video_b,
      .video_f60(1'b1), .video_pal_a(), .video_pal_d(), .video_pal_we(), .video_start_addr(),
      .video_width(), .video_height(), .video_flags(), .video_stride(), .video_off(),
      .video_fb_en(1'b0), .video_lores(1'b0), .video_border(1'b0),
      .DDRAM_CLK(), .DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY,
      .DDRAM_RD, .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE,
      .pll_locked(1'b1), .SDRAM_CLK(), .SDRAM_CKE(), .SDRAM_A(), .SDRAM_BA(), .SDRAM_DQ,
      .SDRAM_DQML(), .SDRAM_DQMH(), .SDRAM_nCS(), .SDRAM_nCAS(), .SDRAM_nRAS(), .SDRAM_nWE()
  );

  assign dbg_io_wr   = system.cpu_io_write_do;
  assign dbg_io_addr = system.cpu_io_write_address;
  assign dbg_io_data = system.cpu_io_write_data;
  assign dbg_io_len  = system.cpu_io_write_length;
  assign dbg_ior_done = system.cpu_io_read_done;
  assign dbg_ior_addr = system.cpu_io_read_address;
  assign dbg_ior_len  = system.cpu_io_read_length;
  assign dbg_ior_data = system.cpu_io_read_data;
  assign dbg_halted  = system.ao486.halted;
  assign dbg_inj      = system.ao486.u_cpu.u_core.u_exec.complete && system.ao486.u_cpu.u_core.u_exec.do_inj
                        && system.ao486.cpu_ce;   // core signals: count them at core clock edges only
  assign dbg_inj_flt  = system.ao486.u_cpu.u_core.u_exec.fault;
  assign dbg_inj_vec  = system.ao486.u_cpu.u_core.u_exec.inj_vec;
  assign dbg_inj_err  = system.ao486.u_cpu.u_core.u_exec.inj_err;
  assign dbg_inj_ip   = system.ao486.u_cpu.u_core.u_exec.ip_start;
  assign dbg_shutdown = system.ao486.shutdown;
  assign dbg_gpr   = system.ao486.u_cpu.u_core.e_gpr;
  assign dbg_seg   = system.ao486.u_cpu.u_core.e_seg;
  assign dbg_flags = system.ao486.u_cpu.u_core.e_flags;
  assign dbg_cr0   = system.ao486.u_cpu.u_core.e_cr0;
  assign dbg_cr2   = system.ao486.u_cpu.u_core.u_exec.cr2;
  assign dbg_cr3   = {system.ao486.u_cpu.u_core.e_cr3, 12'h0};
  assign dbg_idtb  = system.ao486.u_cpu.u_core.e_idtb;
  assign dbg_gdtb  = system.ao486.u_cpu.u_core.e_gdtb;
  assign dbg_trb   = system.ao486.u_cpu.u_core.e_trb;
  assign dbg_sys   = system.ao486.u_cpu.u_core.dbg_sys;
  assign dbg_m_addr   = system.mem_address;
  assign dbg_m_wdata  = system.mem_writedata;
  assign dbg_m_rdata  = system.mem_readdata;
  assign dbg_m_be     = system.mem_byteenable;
  assign dbg_m_bc     = system.mem_burstcount;
  assign dbg_m_rd     = system.mem_read;
  assign dbg_m_wr     = system.mem_write;
  assign dbg_m_wait   = system.mem_waitrequest;
  assign dbg_m_rvalid = system.mem_readdatavalid;
  assign dbg_retire  = system.ao486.u_cpu.retire && system.ao486.cpu_ce;
  assign dbg_vga_we   = system.vga_write;
  assign dbg_vga_addr = system.vga_address;
  assign dbg_vga_data = system.vga_writedata;
  assign dbg_vga_mode = system.vga_memmode;
  assign dbg_ip      = system.ao486.u_cpu.dbg_ip;
  assign dbg_cs      = system.ao486.u_cpu.dbg_seg[31:16];
endmodule
