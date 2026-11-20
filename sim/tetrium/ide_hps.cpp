// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 ZbuntowanyKamulec; based on Main_MiSTer (GPL-3.0)
//
// Port of the hard-disk parts of Main_MiSTer ide.cpp (ide_img_set, ide_io, handle_hdd and the
// read / write block transfers) for the simulation; register layout and identify data as there.
#include "ide_hps.h"
#include <cstdio>
#include <cstring>
#include <vector>

#define ATA_STATUS_BSY  0x80
#define ATA_STATUS_RDY  0x40
#define ATA_STATUS_RDP  0x20
#define ATA_STATUS_DSC  0x10
#define ATA_STATUS_DRQ  0x08
#define ATA_STATUS_IRQ  0x04
#define ATA_STATUS_END  0x02
#define ATA_STATUS_ERR  0x01
#define ATA_ERR_ABRT    0x04

enum { ST_IDLE, ST_RESET, ST_WAIT_RD, ST_WAIT_WR };

struct Regs {
    uint8_t io_done, io_fast, features, sector_count, sector;
    uint16_t cylinder;
    uint8_t head, drv, lba, cmd, io_size, error, status;
};
struct Drive {
    FILE *f = nullptr;
    uint64_t size = 0;
    bool present = false;
    uint16_t cylinders = 0, heads = 0, spt = 0;
    uint32_t total_sectors = 0, spb = 16;
    uint16_t id[256];
};
struct Ide {
    uint16_t base = 0xF000;
    int state = ST_IDLE;
    bool null = false;
    Regs regs = {};
    uint32_t xfer_lba = 0;
    uint16_t xfer_cnt = 0;
    uint8_t xfer_multi = 0, xfer_irq = 0;
    Drive drive[2];
};
static Ide ide;
extern bool trace_ide;
static const uint32_t IO_MAX = 32;
static uint8_t buf[IO_MAX * 512], wbuf[IO_MAX * 512];

static void reg_set(uint16_t reg, uint16_t v) { mgmt_write(ide.base + reg, v); }
static void sendbuf(uint16_t reg, uint32_t words, const uint16_t *d) {
    for (uint32_t i = 0; i < words; i++) mgmt_write(ide.base + (reg == 255 ? 255 : reg + i), d[i]);
}
static void recvbuf(uint16_t reg, uint32_t words, uint16_t *d) {
    for (uint32_t i = 0; i < words; i++) d[i] = mgmt_read(ide.base + (reg == 255 ? 255 : reg + i));
}

static void get_regs() {
    uint32_t data[3];
    recvbuf(0, 6, (uint16_t *)data);
    Regs &r = ide.regs;
    r.io_done = data[0] & 1;
    r.io_fast = data[0] & 2;
    r.features = data[0] >> 8;
    r.sector_count = data[0] >> 16;
    r.sector = data[0] >> 24;
    r.cylinder = data[1] & 0xFFFF;
    r.head = (data[2] >> 16) & 0xF;
    r.drv = (data[2] >> 20) & 1;
    r.lba = (data[2] >> 22) & 1;
    r.cmd = data[2] >> 24;
    r.error = 0;
    r.status = 0;
    if (trace_ide) printf("  HPS get_regs: cmd %02x drv %d lba %d head %d cyl %04x sec %02x cnt %02x\n",
                          r.cmd, r.drv, r.lba, r.head, r.cylinder, r.sector, r.sector_count);
}
static void set_regs() {
    Regs &r = ide.regs;
    if (!(r.status & (ATA_STATUS_BSY | ATA_STATUS_ERR))) r.status |= ATA_STATUS_DSC;
    uint8_t d[12] = { r.io_size, r.error, r.sector_count, r.sector,
                      (uint8_t)r.cylinder, (uint8_t)(r.cylinder >> 8), 0, 0, 0, 0,
                      (uint8_t)((r.lba ? 0xE0 : 0xA0) | (r.drv ? 0x10 : 0x00) | r.head), r.status };
    sendbuf(0, 6, (uint16_t *)d);
    if (trace_ide) printf("  HPS set_regs: status %02x error %02x cnt %02x sec %02x cyl %04x dh %02x size %d\n",
                          r.status, r.error, r.sector_count, r.sector, r.cylinder, d[10], r.io_size);
}

static void set_geometry(Drive &d, uint16_t sectors, uint16_t heads) {
    d.heads = heads ? heads : 16;
    d.spt = sectors ? sectors : 256;
    uint64_t cyl = d.size / ((uint64_t)d.heads * d.spt * 512);
    d.cylinders = cyl > 65535 ? 65535 : (uint16_t)cyl;
}

static void img_set(int drv, FILE *f, uint64_t size, const std::string &name) {
    Drive &d = ide.drive[drv];
    if (d.f && d.f != f) fclose(d.f);
    d.f = f; d.size = size;
    d.cylinders = d.heads = d.spt = 0; d.spb = 16;
    d.present = f != nullptr;
    ide.state = ST_RESET;
    reg_set(6, (d.present ? 9 : 8) << (drv * 4));
    reg_set(6, 0x200);
    d.total_sectors = d.present ? (uint32_t)(size / 512) : 0;
    if (d.present) set_geometry(d, 0, 0);             // no .vhd cfg: 16 heads, 256 spt
    uint16_t id[256] = {0};
    id[0] = 0x0040; id[1] = d.cylinders; id[3] = d.heads; id[4] = 512 * d.spt; id[5] = 512; id[6] = d.spt;
    const char *sn = "AOHD00000           ";
    for (int i = 0; i < 10; i++) id[10 + i] = (sn[2 * i] << 8) | sn[2 * i + 1];
    id[20] = 3; id[21] = 512; id[22] = 4;
    for (int i = 27; i <= 46; i++) id[i] = 0x2020;
    id[47] = 0x8020; id[48] = 1; id[49] = 1 << 9; id[50] = 0x4001; id[51] = 0x0200; id[52] = 0x0200;
    id[53] = 0x0007; id[54] = d.cylinders; id[55] = d.heads; id[56] = d.spt;
    id[57] = d.total_sectors & 0xFFFF; id[58] = d.total_sectors >> 16; id[59] = 0x110;
    id[60] = d.total_sectors & 0xFFFF; id[61] = d.total_sectors >> 16;
    for (int i = 65; i <= 68; i++) id[i] = 120;
    id[80] = 0x007E; id[82] = (1 << 14) | (1 << 9); id[83] = (1 << 14) | (1 << 13) | (1 << 12); id[84] = 1 << 14;
    id[85] = (1 << 14) | (1 << 9); id[86] = (1 << 14) | (1 << 13) | (1 << 12); id[87] = 1 << 14;
    id[93] = (1 << 14) | (1 << 13) | (1 << 9) | (1 << 8) | (1 << 3) | (1 << 1) | (1 << 0);
    id[100] = d.total_sectors & 0xFFFF; id[101] = d.total_sectors >> 16;
    if (d.present) {
        const char *nm = name.c_str();
        const char *s = strrchr(nm, '/'); nm = s ? s + 1 : nm;
        for (int i = 0; i < 20; i++) {
            if (*nm) id[27 + i] = ((*nm++) << 8) | 0x20;
            if (*nm) id[27 + i] = (id[27 + i] & 0xFF00) | (*nm++);
        }
    }
    memcpy(d.id, id, sizeof id);
    printf("HDD%d: present %d, cylinders %d, heads %d, spt %d, total sectors %u\n",
           drv, d.present, d.cylinders, d.heads, d.spt, d.total_sectors);
}

void ide_hps_reset() {
    ide = Ide();
    img_set(0, nullptr, 0, "");
    img_set(1, nullptr, 0, "");
}

bool ide_hps_mount(int drvnum, const std::string &file) {
    if (file.empty()) return false;
    FILE *f = fopen(file.c_str(), "r+b");
    if (!f) f = fopen(file.c_str(), "rb");
    if (!f) { printf("cannot open %s\n", file.c_str()); return false; }
    fseeko(f, 0, SEEK_END);
    uint64_t size = ftello(f);
    img_set(drvnum & 1, f, size, file);
    return true;
}

static uint32_t get_lba() {
    Regs &r = ide.regs;
    if (r.lba) return r.sector | (r.cylinder << 8) | (r.head << 24);
    Drive &d = ide.drive[r.drv];
    uint32_t lba = r.cylinder;
    lba = (lba * d.heads + r.head) * d.spt + r.sector - 1;
    return lba;
}
static void put_lba(uint32_t lba) {
    Regs &r = ide.regs;
    lba--;
    if (r.lba) { r.sector = lba; lba >>= 8; r.cylinder = lba; lba >>= 16; r.head = lba & 0xF; }
    else {
        Drive &d = ide.drive[r.drv];
        uint32_t hspt = d.heads * d.spt;
        r.cylinder = lba / hspt; lba %= hspt;
        r.head = lba / d.spt; r.sector = lba % d.spt + 1;
    }
}
static uint16_t get_cnt() {
    uint16_t c = ide.regs.sector_count;
    if (!c || c > ide.drive[ide.regs.drv].spb) c = ide.drive[ide.regs.drv].spb;
    return c;
}
static bool readhdd(uint32_t lba, int cnt, uint8_t *b) {
    Drive &d = ide.drive[ide.regs.drv];
    if (fseeko(d.f, (off_t)lba * 512, SEEK_SET)) return false;
    return fread(b, 512, cnt, d.f) == (size_t)cnt;
}

static bool read_send_block() {
    uint32_t cnt = ide.xfer_cnt;
    ide.xfer_lba += cnt;
    ide.regs.sector_count -= cnt;
    put_lba(ide.xfer_lba);
    ide.regs.io_size = cnt;
    ide.regs.status = ATA_STATUS_RDP | ATA_STATUS_RDY | ATA_STATUS_DRQ | ATA_STATUS_IRQ;
    if (!ide.regs.sector_count) ide.regs.status |= ATA_STATUS_END;
    if (ide.regs.io_fast) { set_regs(); sendbuf(255, cnt * 256, (uint16_t *)buf); }
    else { sendbuf(255, cnt * 256, (uint16_t *)buf); ide.regs.status &= ~ATA_STATUS_RDP; set_regs(); }
    if (!ide.regs.sector_count) { ide.state = ST_IDLE; return false; }
    cnt = ide.xfer_multi ? get_cnt() : 1;
    ide.xfer_cnt = cnt;
    if (!ide.null) ide.null = !readhdd(ide.xfer_lba, cnt, buf);
    if (ide.null) memset(buf, 0, cnt * 512);
    ide.state = ST_WAIT_RD;
    return true;
}
static void process_read(int multi) {
    uint32_t lba = get_lba();
    uint32_t cnt = multi ? get_cnt() : 1;
    ide.null = !readhdd(lba, cnt, buf);
    if (ide.null) memset(buf, 0, cnt * 512);
    ide.xfer_lba = lba; ide.xfer_cnt = cnt; ide.xfer_multi = multi;
    read_send_block();
}
static void write_request_block() {
    uint32_t cnt = ide.xfer_multi ? get_cnt() : 1;
    ide.xfer_cnt = cnt;
    ide.regs.status = ATA_STATUS_RDY | ATA_STATUS_DRQ | ide.xfer_irq;
    ide.xfer_irq = ATA_STATUS_IRQ;
    ide.regs.io_size = cnt;
    set_regs();
    ide.state = ST_WAIT_WR;
}
static bool write_recv_block() {
    uint32_t cnt = ide.xfer_cnt;
    recvbuf(255, cnt * 256, (uint16_t *)wbuf);
    Drive &d = ide.drive[ide.regs.drv];
    if (!ide.null) {
        ide.null = fseeko(d.f, (off_t)ide.xfer_lba * 512, SEEK_SET) || fwrite(wbuf, 512, cnt, d.f) != cnt;
        fflush(d.f);
    }
    ide.xfer_lba += cnt;
    ide.regs.sector_count -= cnt;
    put_lba(ide.xfer_lba);
    if (!ide.regs.sector_count) {
        ide.state = ST_IDLE;
        ide.regs.status = ATA_STATUS_RDY | ATA_STATUS_IRQ;
        set_regs();
        return false;
    }
    write_request_block();
    return true;
}
static void process_write(int multi) {
    ide.null = false;
    ide.xfer_lba = get_lba(); ide.xfer_multi = multi; ide.xfer_irq = 0;
    write_request_block();
}

static int handle_hdd() {
    Regs &r = ide.regs;
    switch (r.cmd) {
    case 0xEC: { uint8_t drv = r.drv; r = Regs(); r.drv = drv; }
        r.io_size = 1;
        r.status = ATA_STATUS_RDY | ATA_STATUS_DRQ | ATA_STATUS_IRQ | ATA_STATUS_END;
        sendbuf(255, 256, ide.drive[r.drv].id);
        set_regs();
        break;
    case 0xC4: process_read(1); break;
    case 0x20: case 0x21: process_read(0); break;
    case 0xC5: process_write(1); break;
    case 0x30: case 0x31: process_write(0); break;
    case 0xC6:
        if (r.sector_count > IO_MAX) return 1;
        ide.drive[r.drv].spb = r.sector_count;
        r.status = ATA_STATUS_RDY | ATA_STATUS_IRQ; set_regs();
        break;
    case 0x08: return 1;
    case 0x10: case 0x11: case 0x12: case 0x13: case 0x14: case 0x15: case 0x16: case 0x17:
    case 0x18: case 0x19: case 0x1A: case 0x1B: case 0x1C: case 0x1D: case 0x1E: case 0x1F:
        r.status = ATA_STATUS_RDY | ATA_STATUS_IRQ; r.cylinder = 0; set_regs();
        break;
    case 0x40: case 0x70: case 0xE3:
        r.error = 0; r.status = ATA_STATUS_RDY | ATA_STATUS_DSC | ATA_STATUS_IRQ; set_regs();
        break;
    case 0x90:
        r.error = 0x01; r.status = ATA_STATUS_RDY | ATA_STATUS_DSC | ATA_STATUS_IRQ; set_regs();
        break;
    case 0x91:
        set_geometry(ide.drive[r.drv], r.sector_count, r.head + 1);
        r.status = ATA_STATUS_RDY | ATA_STATUS_IRQ; set_regs();
        break;
    default:
        printf("IDE: unsupported command %02X\n", r.cmd);
        return 1;
    }
    return 0;
}

void ide_hps_poll(uint8_t req) {
    req &= 7;
    if (trace_ide && req) printf("  HPS poll: req %d state %d\n", req, ide.state);
    if (req == 0) {
        if (ide.state == ST_RESET) { ide.state = ST_IDLE; ide.regs.status = ATA_STATUS_RDY; set_regs(); }
    } else if (req == 4) {
        ide.state = ST_IDLE;
        get_regs();
        int err = !ide.drive[ide.regs.drv].present ? 1 : handle_hdd();
        if (err) { ide.regs.status = ATA_STATUS_RDY | ATA_STATUS_ERR | ATA_STATUS_IRQ; ide.regs.error = ATA_ERR_ABRT; set_regs(); }
    } else if (req == 5) {
        if (ide.state == ST_WAIT_RD) read_send_block();
        else if (ide.state == ST_WAIT_WR) write_recv_block();
        else { ide.state = ST_IDLE; ide.regs.status = ATA_STATUS_RDY | ATA_STATUS_ERR | ATA_STATUS_IRQ; ide.regs.error = ATA_ERR_ABRT; set_regs(); }
    } else if (req == 6) {
        get_regs();
        ide.regs.head = 0; ide.regs.error = 0; ide.regs.sector = 1; ide.regs.sector_count = 1;
        ide.regs.cylinder = ide.drive[ide.regs.drv].present ? 0x0000 : 0xFFFF;
        ide.regs.status = ATA_STATUS_BSY;
        set_regs();
        ide.state = ST_RESET;
    }
}

// simulator save / restore: the HPS state (the image files stay as mounted)
std::vector<uint8_t> ide_hps_state() {
    std::vector<uint8_t> v(sizeof ide + sizeof buf + sizeof wbuf);
    memcpy(v.data(), &ide, sizeof ide);
    memcpy(v.data() + sizeof ide, buf, sizeof buf);
    memcpy(v.data() + sizeof ide + sizeof buf, wbuf, sizeof wbuf);
    return v;
}
bool ide_hps_set_state(const std::vector<uint8_t> &v) {
    if (v.size() != sizeof ide + sizeof buf + sizeof wbuf) return false;
    FILE *f0 = ide.drive[0].f, *f1 = ide.drive[1].f;
    memcpy(&ide, v.data(), sizeof ide);
    memcpy(buf, v.data() + sizeof ide, sizeof buf);
    memcpy(wbuf, v.data() + sizeof ide + sizeof buf, sizeof wbuf);
    ide.drive[0].f = f0; ide.drive[1].f = f1;
    return true;
}
bool ide_hps_idle() { return ide.state == ST_IDLE; }
