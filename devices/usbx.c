/* vresearch101's USB (see usbx.h): devices/xhci.c's controller grown to three devices and a hub.
   The touch screen is Virtualization.framework's (Apple 0x8108, "Virtual USB Touch Screen") with
   vphone-linux's report descriptor: four Finger collections of a 6-bit transducer index, In Range,
   Touch, and X, Y over 0..0x7fff. */
#include "usbx.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "machine.h"

#define CAPLENGTH 0x40
#define OP 0x40
#define PORTREGS 0x440
#define RT 0x1000
#define DB 0x2000
#define XECP 0x800
#define BAR_SIZE 0x4000
#define SLOTS 8
#define PORTS 10 /* keyboard, touch screen, buttons on root ports 1-3; or (HV_USBX_HUB) the hub on port 2 with both behind it */
#define INTRS 4
#define EPS 32
#define QLEN 256
#define DCI_IN 3 /* endpoint 1 IN */

enum {
    TRB_NORMAL = 1, TRB_SETUP = 2, TRB_DATA = 3, TRB_STATUS = 4, TRB_LINK = 6,
    TRB_ENABLE_SLOT = 9, TRB_DISABLE_SLOT = 10, TRB_ADDRESS_DEVICE = 11, TRB_CONFIGURE_EP = 12, TRB_EVALUATE_CTX = 13,
    TRB_RESET_EP = 14, TRB_STOP_EP = 15, TRB_SET_TR_DEQUEUE = 16, TRB_RESET_DEVICE = 17, TRB_NOOP_CMD = 23,
    TRB_TRANSFER_EVENT = 32, TRB_CMD_COMPLETION = 33, TRB_PORT_STATUS = 34,
};
enum { CC_SUCCESS = 1, CC_TRB_ERROR = 5, CC_STALL = 6, CC_SLOTS_FULL = 9, CC_SHORT_PACKET = 13 };

#define PORT_CCS (1u << 0)
#define PORT_PED (1u << 1)
#define PORT_PR (1u << 4)
#define PORT_PLS_SHIFT 5
#define PORT_PP (1u << 9)
#define PORT_SPEED_SHIFT 10
#define PORT_LWS (1u << 16)
#define PORT_CSC (1u << 17)
#define PORT_PRC (1u << 21)
#define PORT_PLC (1u << 22)
#define PORT_CHANGES (0x7fu << 17)
#define SPEED_FULL 1

enum { KBD, HUB, TOUCH, CONS, NDEV };

typedef struct {
    uint64_t dequeue;
    int ccs;
} Ring;

typedef struct {
    int slot, configured;
    Ring ep[EPS];
    int running[EPS];
    uint8_t q[QLEN][20];
    uint32_t qh, qt;
    int rlen;
} Dev;

struct HvUsbx {
    HvPciDev pci;
    HvMachine *m;
    uint32_t usbcmd, usbsts, dnctrl, config;
    uint64_t dcbaap;
    Ring cmd;
    int cmd_running;
    uint32_t portsc[PORTS];
    struct Intr {
        uint32_t iman, imod, erstsz;
        uint64_t erstba, erdp, seg_base;
        uint32_t seg_size, seg_index, index;
        int pcs;
    } intr[INTRS];
    int slot_used[SLOTS + 1], slot_dev[SLOTS + 1];
    Dev dev[NDEV];
    pthread_mutex_t mu;
    uint8_t kbd[8];
    struct { int down; uint16_t x, y; } finger[4];
    uint16_t hub_status[2], hub_change[2]; /* the hub's two ports: the touch screen, the buttons */
    uint16_t cons;                         /* the consumer usage held down, or 0 */
    int hub_reported;
    int hub_mode; /* HV_USBX_HUB: the touch screen and buttons behind a hub, as vphone-linux has them (a watch has no hub driver) */
    uint64_t delivered;
};

/* ---- descriptors ---- */

static const uint8_t kbd_report[] = {
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01,
    0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06,
    0x75, 0x08, 0x15, 0x00, 0x26, 0xff, 0x00, 0x05, 0x07, 0x19, 0x00, 0x29, 0xff, 0x81, 0x00, 0xc0,
};

#define FINGER 0x05, 0x0d, 0x09, 0x22, 0xa1, 0x02, 0x09, 0x38, 0x75, 0x06, 0x95, 0x01, 0x81, 0x02, \
    0x09, 0x32, 0x09, 0x33, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x02, 0x81, 0x02, \
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x26, 0xff, 0x7f, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02, 0xc0
static const uint8_t touch_report[] = {0x05, 0x0d, 0x09, 0x04, 0xa1, 0x01, FINGER, FINGER, FINGER, FINGER, 0xc0};
#define TOUCH_LEN 20

static const uint8_t kbd_dev[18] = {18, 1, 0x00, 0x02, 0, 0, 0, 64, 0xac, 0x05, 0x05, 0x81, /* VZ's 0x8105 */ 0x00, 0x01, 1, 2, 3, 1};
static const uint8_t kbd_cfg[34] = {
    9, 2, 34, 0, 1, 1, 0, 0xa0, 50, 9, 4, 0, 0, 1, 3, 1, 1, 0,
    9, 0x21, 0x11, 0x01, 0, 1, 0x22, sizeof kbd_report, 0, 7, 5, 0x81, 3, 8, 0, 10,
};
static const uint8_t hub_dev[18] = {18, 1, 0x10, 0x01, 9, 0, 0, 8, /* as QEMU's usb-hub: USB 1.1, EP0 of 8 bytes */ 0x09, 0x04, 0xaa, 0x55, 0x01, 0x01, 1, 2, 3, 1};
static const uint8_t hub_cfg[25] = {9, 2, 25, 0, 1, 1, 0, 0xe0, 0, 9, 4, 0, 0, 1, 9, 0, 0, 0, 7, 5, 0x81, 3, 1, 0, 0xff};
static const uint8_t hub_desc[9] = {9, 0x29, 2, 0x0a, 0x00, 1, 0, 0x06, 0xff}; /* two ports, neither device removable */
static const uint8_t touch_dev[18] = {18, 1, 0x00, 0x02, 0, 0, 0, 64, 0xac, 0x05, 0x08, 0x81, 0x00, 0x00, 1, 2, 3, 1};
static const uint8_t touch_cfg[34] = {
    9, 2, 34, 0, 1, 1, 0, 0xa0, 50, 9, 4, 0, 0, 1, 3, 0, 0, 0,
    9, 0x21, 0x11, 0x01, 0, 1, 0x22, sizeof touch_report, 0, 7, 5, 0x81, 3, TOUCH_LEN, 0, 4,
};
/* The buttons: one consumer-page usage at a time (Menu 0x40 is Home and the Digital Crown, Help 0x95 a watch's side
   button, Power 0x30, Volume 0xe9/0xea), what vphone sends through its guest daemon, here from a USB device. */
/* Then the Digital Crown's turn: a relative Wheel (Generic Desktop 0x38), one signed byte of detents. */
static const uint8_t cons_report[] = {0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01, 0x15, 0x00, 0x26, 0xff, 0x03, 0x19, 0x00,
                                      0x2a, 0xff, 0x03, 0x75, 0x10, 0x95, 0x01, 0x81, 0x00,
                                      0x05, 0x01, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0xc0};
static const uint8_t cons_dev[18] = {18, 1, 0x00, 0x02, 0, 0, 0, 64, 0xac, 0x05, 0x09, 0x81, 0x00, 0x00, 1, 2, 3, 1};
static const uint8_t cons_cfg[34] = {
    9, 2, 34, 0, 1, 1, 0, 0xa0, 50, 9, 4, 0, 0, 1, 3, 0, 0, 0,
    9, 0x21, 0x11, 0x01, 0, 1, 0x22, sizeof cons_report, 0, 7, 5, 0x81, 3, 3, 0, 4,
};
static const char *const strs[NDEV][4] = {
    {NULL, "Apple Inc.", "Virtual USB Keyboard", "1"},
    {NULL, "QEMU", "QEMU USB Hub", "2"},
    {NULL, "Apple Inc.", "Virtual USB Touch Screen", "3"},
    {NULL, "Apple Inc.", "Virtual USB Buttons", "4"},
};

static int xlog(void) {
    static int on = -1;
    if (on < 0) on = getenv("HV_USBX_LOG") != NULL;
    return on;
}

/* ---- guest memory, events ---- */

static void rd(HvUsbx *x, uint64_t pa, void *b, unsigned n) { if (hv_phys_read(x->m, pa, b, n)) memset(b, 0, n); }
static void wr(HvUsbx *x, uint64_t pa, const void *b, unsigned n) { hv_phys_write(x->m, pa, b, n); }
static uint32_t rd32(HvUsbx *x, uint64_t pa) { uint32_t v; rd(x, pa, &v, 4); return v; }

static void update_irq(HvUsbx *x) {
    int level = 0;
    for (int i = 0; i < INTRS; i++) level |= (x->intr[i].iman & 3) == 3;
    hv_pci_set_intx(&x->pci, level && (x->usbcmd & 4));
}

static void load_segment(HvUsbx *x, struct Intr *it) {
    uint64_t e[2];
    rd(x, it->erstba + 16ull * it->seg_index, e, 16);
    it->seg_base = e[0] & ~0x3full, it->seg_size = (uint32_t)e[1] & 0xffff, it->index = 0;
}

static void event_to(HvUsbx *x, int target, uint64_t param, uint32_t status, uint32_t control) {
    struct Intr *it = &x->intr[target < INTRS ? target : 0];
    if (!it->erstsz || !it->seg_size) return;
    uint32_t trb[4] = {(uint32_t)param, (uint32_t)(param >> 32), status, (control & ~1u) | (uint32_t)it->pcs};
    wr(x, it->seg_base + 16ull * it->index, trb, 16);
    if (++it->index == it->seg_size) {
        if (++it->seg_index >= it->erstsz) it->seg_index = 0, it->pcs ^= 1;
        load_segment(x, it);
    }
    it->iman |= 1;
    x->usbsts |= 1u << 3;
    update_irq(x);
}

static void port_event(HvUsbx *x, int p) { event_to(x, 0, (uint64_t)(p + 1) << 24, (uint32_t)CC_SUCCESS << 24, TRB_PORT_STATUS << 10); }
static void cmd_done(HvUsbx *x, uint64_t at, int cc, int slot) { event_to(x, 0, at, (uint32_t)cc << 24, TRB_CMD_COMPLETION << 10 | (uint32_t)slot << 24); }
static void xfer_event(HvUsbx *x, uint64_t at, int cc, uint32_t residual, int slot, int dci) {
    event_to(x, (int)(rd32(x, at + 8) >> 22), at, (uint32_t)cc << 24 | (residual & 0xffffff),
             TRB_TRANSFER_EVENT << 10 | (uint32_t)dci << 16 | (uint32_t)slot << 24);
}

static int ring_peek(HvUsbx *x, Ring *r, uint32_t trb[4], uint64_t *at) {
    for (int guard = 0; guard < 64; guard++) {
        uint32_t *ctl = hv_phys_ptr(x->m, r->dequeue + 12, 4);
        uint32_t c = ctl ? __atomic_load_n(ctl, __ATOMIC_ACQUIRE) : 0;
        if ((c & 1) != (uint32_t)r->ccs) return 0;
        rd(x, r->dequeue, trb, 12);
        trb[3] = c;
        if (((trb[3] >> 10) & 0x3f) == TRB_LINK) {
            if (trb[3] & 2) r->ccs ^= 1;
            r->dequeue = ((uint64_t)trb[1] << 32 | trb[0]) & ~0xfull;
            continue;
        }
        *at = r->dequeue;
        return 1;
    }
    return 0;
}

static uint64_t out_ctx(HvUsbx *x, int slot) {
    uint64_t p;
    rd(x, x->dcbaap + 8ull * slot, &p, 8);
    return p & ~0x3full;
}

static void set_ep_state(HvUsbx *x, int slot, int dci, uint32_t st) {
    uint64_t c = out_ctx(x, slot) + 32ull * dci;
    uint32_t d = (rd32(x, c) & ~7u) | st;
    wr(x, c, &d, 4);
}

static Dev *dev_of(HvUsbx *x, int slot) {
    return slot >= 1 && slot <= SLOTS && x->slot_used[slot] && x->slot_dev[slot] >= 0 ? &x->dev[x->slot_dev[slot]] : NULL;
}

/* ---- control requests ---- */

static int str_desc(const char *s, uint8_t *t) {
    int n = (int)strlen(s);
    if (n > 30) n = 30;
    t[0] = (uint8_t)(2 + 2 * n), t[1] = 3;
    for (int i = 0; i < n; i++) t[2 + 2 * i] = (uint8_t)s[i], t[3 + 2 * i] = 0;
    return 2 + 2 * n;
}

static void touch_report_now(HvUsbx *x, uint8_t *b) {
    memset(b, 0, TOUCH_LEN);
    for (int i = 0; i < 4; i++) {
        b[i * 5] = (uint8_t)(i | (x->finger[i].down ? 0xc0 : 0));
        memcpy(b + i * 5 + 1, &x->finger[i].x, 2);
        memcpy(b + i * 5 + 3, &x->finger[i].y, 2);
    }
}

static int control(HvUsbx *x, int d, const uint8_t setup[8], uint8_t *out, int max) {
    uint8_t type = setup[0], req = setup[1];
    uint16_t value = (uint16_t)(setup[2] | setup[3] << 8), index = (uint16_t)(setup[4] | setup[5] << 8);
    if (xlog()) fprintf(stderr, "usbx: dev %d request %02x %02x value %04x index %u\n", d, type, req, value, index);
    const uint8_t *src = NULL;
    int len = 0;
    uint8_t t[64];
    Dev *dv = &x->dev[d];
    const uint8_t *ddesc = d == KBD ? kbd_dev : d == HUB ? hub_dev : d == TOUCH ? touch_dev : cons_dev;
    const uint8_t *cdesc = d == KBD ? kbd_cfg : d == HUB ? hub_cfg : d == TOUCH ? touch_cfg : cons_cfg;
    int clen = d == HUB ? (int)sizeof hub_cfg : 34;
    if (type == 0x80 && req == 6) {
        uint8_t dt = value >> 8, idx = value & 0xff;
        if (dt == 1) src = ddesc, len = 18;
        else if (dt == 2) src = cdesc, len = clen;
        else if (dt == 3) {
            if (!idx) t[0] = 4, t[1] = 3, t[2] = 0x09, t[3] = 0x04, src = t, len = 4;
            else if (idx < 4) len = str_desc(strs[d][idx], t), src = t;
            else return -1;
        } else return -1;
    } else if (type == 0x81 && req == 6 && d != HUB) {
        if ((value >> 8) == 0x22) {
            if (d == KBD) src = kbd_report, len = sizeof kbd_report;
            else if (d == TOUCH) src = touch_report, len = sizeof touch_report;
            else src = cons_report, len = sizeof cons_report;
        }
        else if ((value >> 8) == 0x21) src = cdesc + 18, len = 9;
        else return -1;
    } else if (type == 0xa0 && req == 6 && d == HUB) {
        src = hub_desc, len = sizeof hub_desc;
    } else if (type == 0xa0 && req == 0 && d == HUB) {
        memset(t, 0, 4), src = t, len = 4;
    } else if (type == 0xa3 && req == 0 && d == HUB && index >= 1 && index <= 2) { /* port status */
        pthread_mutex_lock(&x->mu);
        memcpy(t, &x->hub_status[index - 1], 2), memcpy(t + 2, &x->hub_change[index - 1], 2);
        pthread_mutex_unlock(&x->mu);
        src = t, len = 4;
    } else if (type == 0x23 && (req == 1 || req == 3) && d == HUB && index >= 1 && index <= 2) { /* port CLEAR/SET_FEATURE */
        pthread_mutex_lock(&x->mu);
        uint16_t *st = &x->hub_status[index - 1], *ch = &x->hub_change[index - 1];
        if (req == 3) {
            if (value == 4) *st |= 0x2, *ch |= 0x10;                            /* PORT_RESET: enabled, reset done */
            else if (value == 8) *st |= 0x100;                                 /* PORT_POWER */
            else if (value == 2) *st |= 0x4;                                   /* PORT_SUSPEND */
        } else {
            if (value == 1) *st &= ~0x2;                                       /* PORT_ENABLE */
            else if (value == 2) *st &= ~0x4;
            else if (value == 8) *st &= ~0x100;
            else if (value >= 16 && value <= 20) *ch &= (uint16_t)~(1u << (value - 16));
        }
        x->hub_reported = 0;
        pthread_mutex_unlock(&x->mu);
        return 0;
    } else if ((type & 0x9f) == 0x80 && req == 0) {
        t[0] = t[1] = 0, src = t, len = 2;
    } else if (type == 0x80 && req == 8) {
        t[0] = (uint8_t)dv->configured, src = t, len = 1;
    } else if (type == 0x00 && req == 9) {
        dv->configured = value & 0xff;
        return 0;
    } else if (type == 0x81 && req == 10) {
        t[0] = 0, src = t, len = 1;
    } else if (type == 0xa1 && req == 1) {
        if (d == KBD) src = x->kbd, len = 8;
        else if (d == TOUCH) touch_report_now(x, t), src = t, len = TOUCH_LEN;
        else memcpy(t, &x->cons, 2), t[2] = 0, src = t, len = 3;
    } else if (type == 0xa1 && (req == 2 || req == 3)) {
        t[0] = req == 3 ? 1 : 0, src = t, len = 1;
    } else if ((type & 0x60) == 0x20 || (type & 0x9c) == 0) {
        return 0; /* class requests left, SET_FEATURE/CLEAR_FEATURE, SET_INTERFACE: accepted */
    } else {
        if (x->m->log) fprintf(stderr, "hengevm: usbx: dev %d unhandled request %02x %02x value %04x\n", d, type, req, value);
        return -1;
    }
    if (len > max) len = max;
    memcpy(out, src, (size_t)len);
    return len;
}

static void run_ep0(HvUsbx *x, int slot) {
    Dev *dv = dev_of(x, slot);
    if (!dv) return;
    int d = (int)(dv - x->dev);
    Ring *r = &dv->ep[1];
    uint32_t trb[4];
    uint64_t at;
    uint8_t setup[8], reply[256];
    int reply_len = 0;
    while (ring_peek(x, r, trb, &at)) {
        int type = (trb[3] >> 10) & 0x3f, ioc = (trb[3] >> 5) & 1;
        r->dequeue += 16;
        if (type == TRB_SETUP) {
            memcpy(setup, trb, 8);
            uint16_t wlen = (uint16_t)(setup[6] | setup[7] << 8);
            reply_len = control(x, d, setup, reply, wlen < sizeof reply ? wlen : (int)sizeof reply);
            if (reply_len < 0) {
                xfer_event(x, at, CC_STALL, 0, slot, 1);
                set_ep_state(x, slot, 1, 2);
                dv->running[1] = 0;
                return;
            }
            if (ioc) xfer_event(x, at, CC_SUCCESS, 0, slot, 1);
        } else if (type == TRB_DATA) {
            uint64_t buf = (uint64_t)trb[1] << 32 | trb[0];
            uint32_t want = trb[2] & 0x1ffff, n;
            if ((trb[3] >> 16) & 1) {
                n = reply_len < 0 ? 0 : (uint32_t)reply_len < want ? (uint32_t)reply_len : want;
                if (n) wr(x, buf, reply, n);
            } else n = want;
            int isp = (trb[3] >> 2) & 1;
            if (ioc || (isp && n < want)) xfer_event(x, at, n < want ? CC_SHORT_PACKET : CC_SUCCESS, want - n, slot, 1);
        } else if (ioc) xfer_event(x, at, CC_SUCCESS, 0, slot, 1);
    }
}

/* Reports waiting for a device's interrupt IN endpoint; the hub's is its port change bitmap. */
static void run_in(HvUsbx *x, int d) {
    Dev *dv = &x->dev[d];
    if (!dv->slot || !dv->running[DCI_IN]) return;
    Ring *r = &dv->ep[DCI_IN];
    uint32_t trb[4];
    uint64_t at;
    pthread_mutex_lock(&x->mu);
    if (d == HUB && (x->hub_change[0] || x->hub_change[1]) && !x->hub_reported && dv->qt - dv->qh < QLEN) {
        dv->q[dv->qt++ % QLEN][0] = (uint8_t)((x->hub_change[0] ? 2 : 0) | (x->hub_change[1] ? 4 : 0));
        x->hub_reported = 1;
    }
    while (dv->qh != dv->qt && ring_peek(x, r, trb, &at)) {
        r->dequeue += 16;
        if (((trb[3] >> 10) & 0x3f) != TRB_NORMAL) continue;
        uint64_t buf = (uint64_t)trb[1] << 32 | trb[0];
        uint32_t want = trb[2] & 0x1ffff, n = want < (uint32_t)dv->rlen ? want : (uint32_t)dv->rlen;
        if (xlog()) fprintf(stderr, "usbx: dev %d report %u bytes delivered\n", d, n);
        wr(x, buf, dv->q[dv->qh++ % QLEN], n);
        x->delivered++;
        xfer_event(x, at, n < want ? CC_SHORT_PACKET : CC_SUCCESS, want - n, dv->slot, DCI_IN);
    }
    pthread_mutex_unlock(&x->mu);
}

/* ---- commands ---- */

static void init_ring(HvUsbx *x, Dev *dv, int slot, int dci) {
    uint64_t deq;
    rd(x, out_ctx(x, slot) + 32ull * dci + 8, &deq, 8);
    dv->ep[dci].dequeue = deq & ~0xfull, dv->ep[dci].ccs = (int)(deq & 1), dv->running[dci] = 1;
}

static int address_device(HvUsbx *x, int slot, uint64_t input, int bsr) {
    uint64_t out = out_ctx(x, slot);
    uint8_t sc[32], ep0[32];
    rd(x, input + 32, sc, 32);
    rd(x, input + 64, ep0, 32);
    uint32_t dw0;
    memcpy(&dw0, sc, 4);
    int port = sc[6], route = (int)(dw0 & 0xfffff);
    int d = -1;
    if (x->hub_mode) d = port == 1 && !route ? KBD : port == 2 && !route ? HUB : port == 2 && route == 1 ? TOUCH : port == 2 && route == 2 ? CONS : -1;
    else d = route ? -1 : port == 10 ? TOUCH : port == 9 ? KBD : port == 8 ? CONS : -1; /* Virtualization.framework's ports: touch screen @0ca00000, keyboard @0c900000 */
    if (xlog()) fprintf(stderr, "usbx: address slot %d port %d route %x -> dev %d\n", slot, port, route, d);
    if (d < 0) return CC_TRB_ERROR;
    uint32_t dw3 = (uint32_t)(bsr ? 1 : 2) << 27 | (uint32_t)(bsr ? 0 : slot);
    memcpy(sc + 12, &dw3, 4);
    uint32_t e0;
    memcpy(&e0, ep0, 4);
    e0 = (e0 & ~7u) | 1;
    memcpy(ep0, &e0, 4);
    wr(x, out, sc, 32);
    wr(x, out + 32, ep0, 32);
    x->slot_dev[slot] = d;
    Dev *dv = &x->dev[d];
    dv->slot = slot;
    init_ring(x, dv, slot, 1);
    return CC_SUCCESS;
}

static int configure_eps(HvUsbx *x, int slot, uint64_t input, int deconfigure) {
    Dev *dv = dev_of(x, slot);
    if (!dv) return CC_TRB_ERROR;
    uint64_t out = out_ctx(x, slot);
    if (deconfigure) {
        for (int i = 2; i < EPS; i++) dv->running[i] = 0;
        return CC_SUCCESS;
    }
    uint32_t drop = rd32(x, input), add = rd32(x, input + 4);
    for (int dci = 2; dci < EPS; dci++) {
        if (drop & (1u << dci)) {
            uint8_t z[32] = {0};
            dv->running[dci] = 0;
            wr(x, out + 32ull * dci, z, 32);
        }
        if (add & (1u << dci)) {
            uint8_t ep[32];
            rd(x, input + 32ull * (dci + 1), ep, 32);
            uint32_t e0;
            memcpy(&e0, ep, 4);
            e0 = (e0 & ~7u) | 1;
            memcpy(ep, &e0, 4);
            wr(x, out + 32ull * dci, ep, 32);
            init_ring(x, dv, slot, dci);
        }
    }
    uint32_t dw3 = (uint32_t)3 << 27 | (uint32_t)slot;
    if (add & 1) {
        uint8_t sc[32];
        rd(x, input + 32, sc, 32);
        memcpy(sc + 12, &dw3, 4);
        wr(x, out, sc, 32);
    } else wr(x, out + 12, &dw3, 4);
    return CC_SUCCESS;
}

static void run_commands(HvUsbx *x) {
    uint32_t trb[4];
    uint64_t at;
    while (ring_peek(x, &x->cmd, trb, &at)) {
        x->cmd.dequeue += 16;
        int type = (trb[3] >> 10) & 0x3f, slot = (int)(trb[3] >> 24), cc = CC_SUCCESS;
        uint64_t ptr = ((uint64_t)trb[1] << 32 | trb[0]) & ~0xfull;
        Dev *dv = dev_of(x, slot);
        if (xlog()) fprintf(stderr, "usbx: command %d slot %d\n", type, slot);
        switch (type) {
        case TRB_ENABLE_SLOT: {
            int s = 1;
            while (s <= SLOTS && x->slot_used[s]) s++;
            if (s > SLOTS) { cmd_done(x, at, CC_SLOTS_FULL, 0); continue; }
            x->slot_used[s] = 1, x->slot_dev[s] = -1;
            cmd_done(x, at, CC_SUCCESS, s);
            continue;
        }
        case TRB_DISABLE_SLOT:
            if (dv) memset(dv->running, 0, sizeof dv->running), dv->slot = 0, dv->configured = 0;
            if (slot >= 1 && slot <= SLOTS) x->slot_used[slot] = 0, x->slot_dev[slot] = -1;
            break;
        case TRB_ADDRESS_DEVICE: cc = address_device(x, slot, ptr, (trb[3] >> 9) & 1); break;
        case TRB_CONFIGURE_EP: cc = configure_eps(x, slot, ptr, (trb[3] >> 9) & 1); break;
        case TRB_EVALUATE_CTX: {
            uint32_t add = rd32(x, ptr + 4);
            uint64_t out = out_ctx(x, slot);
            if (add & 1) { /* slot context: the hub's port count and the like */
                uint8_t sc[16];
                rd(x, ptr + 32, sc, 16);
                wr(x, out, sc, 12);
            }
            if (add & 2) { uint32_t dw1 = rd32(x, ptr + 64 + 4); wr(x, out + 32 + 4, &dw1, 4); }
            break;
        }
        case TRB_RESET_EP: set_ep_state(x, slot, (trb[3] >> 16) & 0x1f, 3); break;
        case TRB_STOP_EP: {
            int dci = (trb[3] >> 16) & 0x1f;
            if (dv) {
                dv->running[dci] = 0;
                uint64_t deq = dv->ep[dci].dequeue | (uint64_t)dv->ep[dci].ccs;
                wr(x, out_ctx(x, slot) + 32ull * dci + 8, &deq, 8);
            }
            set_ep_state(x, slot, dci, 3);
            break;
        }
        case TRB_SET_TR_DEQUEUE: {
            int dci = (trb[3] >> 16) & 0x1f;
            uint64_t p = (uint64_t)trb[1] << 32 | trb[0];
            if (dv) dv->ep[dci].dequeue = p & ~0xfull, dv->ep[dci].ccs = (int)(p & 1);
            wr(x, out_ctx(x, slot) + 32ull * dci + 8, &p, 8);
            break;
        }
        case TRB_RESET_DEVICE: {
            if (dv) { for (int i = 2; i < EPS; i++) dv->running[i] = 0; dv->configured = 0; }
            uint32_t dw3 = (uint32_t)1 << 27;
            wr(x, out_ctx(x, slot) + 12, &dw3, 4);
            break;
        }
        case TRB_NOOP_CMD: break;
        default: cc = CC_TRB_ERROR; break;
        }
        cmd_done(x, at, cc, slot);
    }
}

/* ---- ports and registers ---- */

static uint32_t connected(void) { return PORT_PP | PORT_CCS | PORT_CSC | (uint32_t)SPEED_FULL << PORT_SPEED_SHIFT | 7u << PORT_PLS_SHIFT; }

static void port_write(HvUsbx *x, int p, uint32_t v) {
    uint32_t s = x->portsc[p];
    s &= ~(v & PORT_CHANGES);
    if (v & PORT_PED) s &= ~PORT_PED;
    if (v & PORT_PR) {
        x->portsc[p] = (s & ~(0xfu << PORT_PLS_SHIFT)) | PORT_PED | PORT_PRC;
        port_event(x, p);
        return;
    }
    if ((v & PORT_LWS) && (s & PORT_CCS)) {
        uint32_t pls = (v >> PORT_PLS_SHIFT) & 0xf;
        s = (s & ~(0xfu << PORT_PLS_SHIFT)) | pls << PORT_PLS_SHIFT;
        if (pls == 0 || pls == 15) {
            x->portsc[p] = (s & ~(0xfu << PORT_PLS_SHIFT)) | PORT_PLC;
            port_event(x, p);
            return;
        }
    }
    x->portsc[p] = (s & ~PORT_PP) | (v & PORT_PP);
}

static void reset(HvUsbx *x) {
    x->usbcmd = 0, x->usbsts = 1, x->dnctrl = x->config = 0, x->dcbaap = 0;
    memset(&x->cmd, 0, sizeof x->cmd);
    memset(x->intr, 0, sizeof x->intr);
    for (int i = 0; i < INTRS; i++) x->intr[i].pcs = 1;
    memset(x->slot_used, 0, sizeof x->slot_used);
    for (int d = 0; d < NDEV; d++) {
        memset(x->dev[d].running, 0, sizeof x->dev[d].running);
        x->dev[d].slot = x->dev[d].configured = 0;
    }
    for (int i = 0; i < 2; i++) x->hub_status[i] = 0x101, x->hub_change[i] = 0x1;
    x->hub_reported = 0;
    for (int p = 0; p < PORTS; p++) x->portsc[p] = (x->hub_mode ? p < 2 : p >= 7) ? connected() : PORT_PP;
    update_irq(x);
}

static uint64_t bar_read(HvPciDev *pd, int bar, uint64_t off, unsigned size) {
    HvUsbx *x = pd->opaque;
    uint64_t v = 0;
    if (bar) return 0;
    if (off < CAPLENGTH) {
        static const uint32_t cap[8] = {CAPLENGTH | 0x0100u << 16, SLOTS | (uint32_t)INTRS << 8 | (uint32_t)PORTS << 24, 1u << 4, 0,
                                        1u | (uint32_t)(XECP / 4) << 16, DB, RT, 0};
        uint32_t i = (uint32_t)off / 4;
        v = cap[i];
        if (size == 8 && i + 1 < 8) v |= (uint64_t)cap[i + 1] << 32;
        v >>= 8 * (off & 3);
    } else if (off >= XECP && off < XECP + 16) {
        static const uint32_t ext[4] = {2u | 0x0200u << 16, 0x20425355, 1u | (uint32_t)PORTS << 8, 0};
        uint32_t i = (uint32_t)(off - XECP) / 4;
        v = ext[i];
        if (size == 8 && i + 1 < 4) v |= (uint64_t)ext[i + 1] << 32;
    } else if (off >= OP && off < PORTREGS) {
        switch (off - OP) {
        case 0x00: v = x->usbcmd; break;
        case 0x04: v = x->usbsts; break;
        case 0x08: v = 1; break;
        case 0x14: v = x->dnctrl; break;
        case 0x18: v = x->cmd_running ? 8 : 0; break;
        case 0x30: v = size == 8 ? x->dcbaap : (uint32_t)x->dcbaap; break;
        case 0x34: v = x->dcbaap >> 32; break;
        case 0x38: v = x->config; break;
        }
    } else if (off >= PORTREGS && off < PORTREGS + 16u * PORTS) {
        v = (off - PORTREGS) % 16 == 0 ? x->portsc[(off - PORTREGS) / 16] : 0;
    } else if (off >= RT + 0x20 && off < RT + 0x20 + 32u * INTRS) {
        struct Intr *it = &x->intr[(off - RT - 0x20) / 32];
        switch ((off - RT - 0x20) % 32) {
        case 0x00: v = it->iman; break;
        case 0x04: v = it->imod; break;
        case 0x08: v = it->erstsz; break;
        case 0x10: v = size == 8 ? it->erstba : (uint32_t)it->erstba; break;
        case 0x14: v = it->erstba >> 32; break;
        case 0x18: v = size == 8 ? it->erdp : (uint32_t)it->erdp; break;
        case 0x1c: v = it->erdp >> 32; break;
        }
    }
    return v;
}

static void set64(uint64_t *f, uint64_t hi, uint64_t v, unsigned size) {
    if (size == 8) *f = v;
    else if (hi) *f = (*f & 0xffffffffull) | v << 32;
    else *f = (*f & ~0xffffffffull) | (uint32_t)v;
}

static void bar_write(HvPciDev *pd, int bar, uint64_t off, uint64_t v, unsigned size) {
    HvUsbx *x = pd->opaque;
    if (bar) return;
    if (off >= OP && off < PORTREGS) {
        uint64_t r = off - OP;
        switch (r) {
        case 0x00:
            if (v & 2) {
                reset(x);
                for (int p = 0; p < PORTS; p++) port_event(x, p);
                return;
            }
            if ((v & 1) && !(x->usbcmd & 1)) {
                x->usbcmd = (uint32_t)v, x->usbsts &= ~1u;
                for (int p = 0; p < PORTS; p++) if (x->portsc[p] & PORT_CSC) port_event(x, p);
            } else {
                x->usbcmd = (uint32_t)v;
                if (!(v & 1)) x->usbsts |= 1;
            }
            update_irq(x);
            break;
        case 0x04: x->usbsts &= ~((uint32_t)v & (1u << 2 | 1u << 3 | 1u << 4 | 1u << 10)); break;
        case 0x14: x->dnctrl = (uint32_t)v; break;
        case 0x18:
            if (size == 4) x->cmd.dequeue = (x->cmd.dequeue & ~0xffffffffull) | ((uint32_t)v & ~0x3fu), x->cmd.ccs = (int)(v & 1);
            else x->cmd.dequeue = v & ~0x3full, x->cmd.ccs = (int)(v & 1);
            break;
        case 0x1c: x->cmd.dequeue = (x->cmd.dequeue & 0xffffffffull) | v << 32; break;
        case 0x30: case 0x34: set64(&x->dcbaap, r - 0x30, v, size); x->dcbaap &= ~0x3full; break;
        case 0x38: x->config = (uint32_t)v; break;
        }
    } else if (off >= PORTREGS && off < PORTREGS + 16u * PORTS) {
        if ((off - PORTREGS) % 16 == 0) port_write(x, (int)(off - PORTREGS) / 16, (uint32_t)v);
    } else if (off >= RT + 0x20 && off < RT + 0x20 + 32u * INTRS) {
        struct Intr *it = &x->intr[(off - RT - 0x20) / 32];
        uint64_t r = (off - RT - 0x20) % 32;
        switch (r) {
        case 0x00:
            if (v & 1) it->iman &= ~1u;
            it->iman = (it->iman & 1) | ((uint32_t)v & 2);
            update_irq(x);
            break;
        case 0x04: it->imod = (uint32_t)v; break;
        case 0x08: it->erstsz = (uint32_t)v & 0xffff; break;
        case 0x10: case 0x14:
            set64(&it->erstba, r - 0x10, v, size);
            if (r == 0x14 || size == 8) it->erstba &= ~0x3full, it->seg_index = 0, it->pcs = 1, load_segment(x, it);
            break;
        case 0x18: case 0x1c:
            set64(&it->erdp, r - 0x18, v, size);
            if (r == 0x18 && (v & 8)) it->erdp &= ~8ull;
            break;
        }
    } else if (off >= DB && off < DB + 4u * (SLOTS + 1)) {
        int slot = (int)(off - DB) / 4;
        if (!slot) {
            x->cmd_running = 1;
            run_commands(x);
            return;
        }
        Dev *dv = dev_of(x, slot);
        int dci = (int)(v & 0xff);
        if (!dv || dci < 1 || dci >= EPS) return;
        uint32_t st = rd32(x, out_ctx(x, slot) + 32ull * dci) & 7;
        if (st == 2) return;
        if (st != 1) set_ep_state(x, slot, dci, 1);
        dv->running[dci] = 1;
        if (xlog() && dci != 1) fprintf(stderr, "usbx: doorbell slot %d dci %d (dev %d)\n", slot, dci, (int)(dv - x->dev));
        if (dci == 1) run_ep0(x, slot);
        else if (dci == DCI_IN) run_in(x, (int)(dv - x->dev));
    }
}

/* ---- input ---- */

static void push(HvUsbx *x, int d, const uint8_t *rep) {
    Dev *dv = &x->dev[d];
    if (dv->qt - dv->qh < QLEN) memcpy(dv->q[dv->qt++ % QLEN], rep, (size_t)dv->rlen);
}

void hv_usbx_key(HvUsbx *x, uint8_t usage, int down) {
    if (!x || !usage) return;
    pthread_mutex_lock(&x->mu);
    uint8_t *s = x->kbd;
    if (usage >= 0xe0 && usage <= 0xe7) {
        uint8_t bit = (uint8_t)(1u << (usage - 0xe0));
        s[0] = down ? s[0] | bit : s[0] & ~bit;
    } else {
        int i;
        for (i = 2; i < 8 && s[i] != usage; i++) {}
        if (down && i == 8) {
            for (i = 2; i < 8 && s[i]; i++) {}
            if (i < 8) s[i] = usage;
        } else if (!down && i < 8) {
            memmove(s + i, s + i + 1, (size_t)(7 - i));
            s[7] = 0;
        }
    }
    push(x, KBD, s);
    pthread_mutex_unlock(&x->mu);
    hv_machine_wake(x->m);
}

void hv_usbx_touch(HvUsbx *x, int finger, int down, double fx, double fy) {
    if (!x || finger < 0 || finger > 3) return;
    if (fx < 0) fx = 0;
    if (fx > 1) fx = 1;
    if (fy < 0) fy = 0;
    if (fy > 1) fy = 1;
    pthread_mutex_lock(&x->mu);
    x->finger[finger].down = down;
    x->finger[finger].x = (uint16_t)(fx * 0x7fff + 0.5);
    x->finger[finger].y = (uint16_t)(fy * 0x7fff + 0.5);
    uint8_t rep[TOUCH_LEN];
    touch_report_now(x, rep);
    push(x, TOUCH, rep);
    pthread_mutex_unlock(&x->mu);
    hv_machine_wake(x->m);
}

void hv_usbx_consumer(HvUsbx *x, uint16_t usage, int down) {
    if (!x) return;
    pthread_mutex_lock(&x->mu);
    x->cons = down ? usage : 0;
    uint8_t rep[3] = {0};
    memcpy(rep, &x->cons, 2);
    push(x, CONS, rep);
    pthread_mutex_unlock(&x->mu);
    hv_machine_wake(x->m);
}

void hv_usbx_wheel(HvUsbx *x, int detents) {
    if (!x || !detents) return;
    pthread_mutex_lock(&x->mu);
    while (detents) {
        int step = detents > 127 ? 127 : detents < -127 ? -127 : detents;
        uint8_t rep[3];
        memcpy(rep, &x->cons, 2);
        rep[2] = (uint8_t)(int8_t)step;
        push(x, CONS, rep);
        detents -= step;
    }
    pthread_mutex_unlock(&x->mu);
    hv_machine_wake(x->m);
}

uint64_t hv_usbx_delivered(HvUsbx *x) { return x ? x->delivered : 0; }

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000;
}

void hv_usbx_poll(HvUsbx *x) {
    if (!x) return;
    /* A digitizer reports at its polling rate while a finger is down, not only when it moves. */
    static uint64_t last;
    uint64_t t = now_us();
    if (t - last >= 8000) {
        last = t;
        pthread_mutex_lock(&x->mu);
        int any = 0;
        for (int i = 0; i < 4; i++) any |= x->finger[i].down;
        if (any && x->dev[TOUCH].qh == x->dev[TOUCH].qt) {
            uint8_t rep[TOUCH_LEN];
            touch_report_now(x, rep);
            push(x, TOUCH, rep);
        }
        pthread_mutex_unlock(&x->mu);
    }
    for (int d = 0; d < NDEV; d++)
        if (x->dev[d].qh != x->dev[d].qt || (d == HUB && (x->hub_change[0] || x->hub_change[1]) && !x->hub_reported)) run_in(x, d);
}

HvUsbx *hv_usbx_create(HvMachine *m, HvPcie *bus) {
    HvUsbx *x = calloc(1, sizeof *x);
    if (!x) return NULL;
    x->m = m;
    x->hub_mode = getenv("HV_USBX_HUB") != NULL;
    pthread_mutex_init(&x->mu, NULL);
    x->dev[KBD].rlen = 8, x->dev[HUB].rlen = 1, x->dev[TOUCH].rlen = TOUCH_LEN, x->dev[CONS].rlen = 3;
    for (int i = 0; i <= SLOTS; i++) x->slot_dev[i] = -1;
    hv_pci_init(&x->pci, 0x1b36, 0x000d, 0x0c033000, 0x1af4, 0x1100);
    x->pci.opaque = x;
    x->pci.bar_read = bar_read;
    x->pci.bar_write = bar_write;
    hv_pci_add_bar(&x->pci, 0, BAR_SIZE, 1);
    x->pci.config[0x60] = 0x30;
    x->pci.config[0x61] = 0x20;
    /* Virtualization.framework's slot for it (AppleUSBXHCIPCI@0c000000): the guest's device tree may know it there. */
    if (12 < HV_PCI_SLOTS && !bus->dev[12]) bus->dev[12] = &x->pci, x->pci.bus = bus, x->pci.slot = 12;
    else if (hv_pcie_attach(bus, &x->pci) < 0) {
        free(x);
        return NULL;
    }
    reset(x);
    return x;
}
