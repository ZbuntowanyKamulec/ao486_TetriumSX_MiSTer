// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 ZbuntowanyKamulec; based on Main_MiSTer (GPL-3.0)
//
// HPS side of the ao486 IDE controller (rtl/soc/ide.v) for the simulation: a port of the
// hard-disk parts of Main_MiSTer ide.cpp (no CD-ROM, no placeholders).
#pragma once
#include <cstdint>
#include <string>
#include <vector>

void ide_hps_reset();
bool ide_hps_mount(int drvnum, const std::string &file);   // drvnum 0 = primary master
void ide_hps_poll(uint8_t ide0_request);
std::vector<uint8_t> ide_hps_state();              // simulator save / restore
bool ide_hps_set_state(const std::vector<uint8_t> &v);
bool ide_hps_idle();

// provided by tb_soc.cpp: one mgmt bus write / read (the read returns the data at the address
// before the read strobe, as hps_ext.v hands it to the HPS)
void mgmt_write(uint16_t a, uint16_t d);
uint16_t mgmt_read(uint16_t a);
