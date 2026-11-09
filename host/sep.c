/* vresearch101's SEP: a second core with an address space of its own (QEMU's hw/vmapple/vresearch101.c
   create_sep, and hw/vmapple/sep-storage.c, GPL-2.0-or-later). Here it is a machine of its own with one
   CPU, its own GIC and JIT space, sharing the AP's RAM and its config region:
     0x02000000  SEP ROM (OpenSEP or AVPSEPBooter), 512 KB      0x04000000  SRAM, 8 MB
     0x06000000  TZ0, 32 MB                                    0x08000000  VSTD, the storage request buffer
     0x10000000  its GIC                                        0x30020000  VSTR, the SEPStorage file
     0x30250000  its bank of the mailbox                        0x70000000  the AP's RAM */
#include "sep.h"

#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "dispatch.h"
#include "gicv3.h"
#include "timer.h"

#define ROM_BASE 0x02000000ull
#define ROM_SIZE 0x00080000ull
#define SRAM_BASE 0x04000000ull
#define SRAM_SIZE 0x00800000ull
#define TZ0_BASE 0x06000000ull
#define TZ0_SIZE 0x02000000ull
#define VSTD_BASE 0x08000000ull
#define VSTD_SIZE 0x4000ull
#define VSTR_BASE 0x30020000ull

static HvMachine sm;
static HvCpu *scpu;
static HvGic *sgic;
static int store_fd = -1;
static uint32_t st_enable, st_status, st_done;
static uint64_t st_notify;
static int slog;

/* ---- VSTR: virtio-blk-like requests to the SEPStorage file ---- */

static uint64_t sectors(void) {
    off_t n = store_fd >= 0 ? lseek(store_fd, 0, SEEK_END) : 0;
    return n > 0 ? (uint64_t)n / 512 : 0;
}

static void request(uint64_t table) {
    struct { uint64_t addr; uint32_t len; uint16_t flags; } d[16];
    int n = 0;
    do {
        uint8_t raw[16];
        if (n == 16 || hv_phys_read(&sm, table + (uint64_t)n * 16, raw, 16)) {
            fprintf(stderr, "sep-storage: bad descriptor chain at %llx\n", (unsigned long long)table);
            return;
        }
        memcpy(&d[n].addr, raw, 8), memcpy(&d[n].len, raw + 8, 4), memcpy(&d[n].flags, raw + 14, 2);
        n++;
    } while (d[n - 1].flags & 1);
    if (n < 2 || d[0].len < 16 || d[n - 1].len < 1) return;
    uint8_t hdr[16];
    hv_phys_read(&sm, d[0].addr, hdr, 16);
    uint32_t type;
    uint64_t sector;
    memcpy(&type, hdr, 4), memcpy(&sector, hdr + 8, 8);
    uint8_t status = 0;
    if (type == 0 || type == 1) {
        uint64_t off = sector * 512, end = sectors() * 512;
        for (int i = 1; i < n - 1 && !status; i++) {
            uint8_t *buf = malloc(d[i].len);
            if (off + d[i].len > end) status = 1;
            else if (type == 1) {
                if (hv_phys_read(&sm, d[i].addr, buf, d[i].len) || pwrite(store_fd, buf, d[i].len, (off_t)off) != (ssize_t)d[i].len) status = 1;
            } else if (pread(store_fd, buf, d[i].len, (off_t)off) != (ssize_t)d[i].len || hv_phys_write(&sm, d[i].addr, buf, d[i].len)) status = 1;
            free(buf);
            off += d[i].len;
        }
    } else if (type == 4) status = store_fd >= 0 && fsync(store_fd) ? 1 : 0;
    else status = 2;
    if (slog) fprintf(stderr, "sep-storage: type %u sector %llu -> %u\n", type, (unsigned long long)sector, status);
    hv_phys_write(&sm, d[n - 1].addr, &status, 1);
}

static uint64_t vstr_read(void *o, uint64_t off, unsigned size) {
    (void)o;
    switch (off) {
    case 0x000: return 1;
    case 0x004: return 2;
    case 0x008: return 0x100;
    case 0x010: return st_done;
    case 0x400: return st_enable;
    case 0x404: return st_status;
    }
    if (off >= 0x100 && off + size <= 0x140) {
        uint8_t cfg[0x40] = {0};
        uint64_t cap = sectors();
        uint32_t bs = 512;
        memcpy(cfg, &cap, 8), memcpy(cfg + 0x14, &bs, 4);
        uint64_t v = 0;
        memcpy(&v, cfg + (off - 0x100), size);
        return v;
    }
    if (slog) fprintf(stderr, "sep-storage: read +%llx\n", (unsigned long long)off);
    return 0;
}

static void vstr_write(void *o, uint64_t off, uint64_t v, unsigned size) {
    (void)o;
    if (off == 0x400) st_enable = (uint32_t)v;
    else if (off == 0x404) st_status = (uint32_t)v;
    else if (off == 0x408) {
        st_notify = size == 8 ? v : (st_notify & ~0xffffffffull) | (uint32_t)v;
        if (size == 8) st_done = 0, request(st_notify), st_done = 1;
    } else if (off == 0x40c) {
        st_notify = (st_notify & 0xffffffffull) | v << 32;
        st_done = 0, request(st_notify), st_done = 1;
    } else if (slog) fprintf(stderr, "sep-storage: write +%llx = %llx\n", (unsigned long long)off, (unsigned long long)v);
}

/* sepOS maps a SEP-only device at 0x30220000 that nobody has described yet: log it. */
static uint64_t unk_read(void *o, uint64_t off, unsigned size) {
    if (slog) fprintf(stderr, "sep: read of %s+%llx (size %u)\n", (const char *)o, (unsigned long long)off, size);
    return 0;
}

static void unk_write(void *o, uint64_t off, uint64_t v, unsigned size) {
    if (slog) fprintf(stderr, "sep: write of %s+%llx = %llx (size %u)\n", (const char *)o, (unsigned long long)off, (unsigned long long)v, size);
}

static uint64_t tick(HvMachine *m, HvCpu *cpu) {
    (void)m;
    return hv_timer_update(sgic, cpu);
}

static void *sep_thread(void *arg) {
    (void)arg;
    int r = hv_run(scpu);
    fprintf(stderr, "hengevm: SEP core stopped (reason %d) at pc %llx el%u\n", r, (unsigned long long)scpu->pc, scpu->el);
    return NULL;
}

static void *ram_or_die(uint64_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

int hv_sep_start(HvVmapple *b, const char *rom_path, const char *storage_path, void *jit_rx, void *jit_rw, size_t jit_bytes) {
    slog = getenv("HV_SEP_LOG") != NULL;
    int r = jit_rx ? hv_machine_init_jit(&sm, jit_rx, jit_rw, jit_bytes) : hv_machine_init(&sm, jit_bytes);
    if (r) return -1;
    sm.log = b->m->log;
    uint8_t *rom = ram_or_die(ROM_SIZE), *sram = ram_or_die(SRAM_SIZE), *tz0 = ram_or_die(TZ0_SIZE), *vstd = ram_or_die(VSTD_SIZE);
    if (!rom || !sram || !tz0 || !vstd) return -1;
    FILE *f = fopen(rom_path, "rb");
    if (!f) return -1;
    size_t n = fread(rom, 1, ROM_SIZE, f);
    fclose(f);
    if (!n) return -1;
    hv_machine_add_ram(&sm, ROM_BASE, ROM_SIZE, rom, 0);
    hv_machine_add_ram(&sm, SRAM_BASE, SRAM_SIZE, sram, 0);
    hv_machine_add_ram(&sm, TZ0_BASE, TZ0_SIZE, tz0, 0);
    hv_machine_add_ram(&sm, VSTD_BASE, VSTD_SIZE, vstd, 0);
    hv_machine_add_ram(&sm, 0x70000000ull, b->ram_size, b->ram, 0); /* the AP's RAM, shared */
    hv_cfg_attach(&sm, 0x400000ull, b->cfg);                      /* ACFG: sepOS's TRNG reads its random word */
    sgic = hv_gicv3_create(&sm, 0x10000000ull, 0x10010000ull);
    hv_machine_add_mmio(&sm, VSTR_BASE, 0x4000, NULL, vstr_read, vstr_write, "sep-storage");
    hv_machine_add_mmio(&sm, 0x30220000ull, 0x10000, "sep-dev-30220000", unk_read, unk_write, "sep-dev-30220000");
    hv_vpiop_attach_sep(b->vpiop, &sm, sgic, 0x30250000ull, 32 + 0x14);
    store_fd = storage_path ? open(storage_path, O_RDWR) : -1;
    if (store_fd < 0) fprintf(stderr, "hengevm: no SEPStorage: sepOS will panic in SEPD/VSTR\n");
    sm.tick = tick;
    scpu = calloc(1, sizeof *scpu);
    if (!scpu) return -1;
    hv_cpu_reset_index(scpu, &sm, 0);
    scpu->mpidr = 0x80000000u;
    scpu->pc = ROM_BASE;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8u << 20);
    pthread_t t;
    if (pthread_create(&t, &attr, sep_thread, NULL)) return -1;
    fprintf(stderr, "hengevm: SEP core started from %s\n", rom_path);
    return 0;
}

void hv_sep_stop(void) {
    if (!scpu) return;
    scpu->halted = 3;
    hv_machine_kick_all(&sm);
    hv_cpu_wake(scpu);
}
