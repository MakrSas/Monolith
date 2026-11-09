/* vresearch101 SEP mailbox, ported from QEMU's hw/vmapple/vpiop.c (GPL-2.0-or-later).
 *   0x010 CTRL   0x014 STATUS (bit 31 ready, bits 3:0 cause W1C)   0x018 IRQ_EN (bit 4 inbox, bit 5 outbox)
 *   0x01c INBOX  0x020 OUTBOX (bit 17 empty, bit 16 full, 7:0 count; the AP's INBOX also has its level in 23:20)
 *   0x100 inbox message (16 bytes, popped by reading its last word)
 *   0x200 outbox message (16 bytes, pushed by writing its last word) */
#include "vpiop.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { AP, SEP, SIDES, DEPTH = 16, MSG = 16 };
#define READY (1u << 31)
#define EMPTY (1u << 17)
#define FULL (1u << 16)
#define IRQ_IN (1u << 4)
#define IRQ_OUT (1u << 5)

typedef struct {
    uint8_t msg[DEPTH][MSG];
    uint32_t head, count;
} Queue;

typedef struct {
    uint32_t ctrl, status, irq_en;
    uint8_t out[MSG];
    Queue inbox;
} Side;

typedef struct {
    HvVpiop *v;
    int side;
} Bank;

struct HvVpiop {
    pthread_mutex_t lock; /* the two sides run on different machines' threads */
    Side side[SIDES];
    Bank bank[SIDES];
    HvGic *gic[SIDES];
    int intid[SIDES];
    int ap_in_pending, ap_out_pending;
    uint32_t ap_in_seen;
    int log;
};

static void update(HvVpiop *v) {
    Side *ap = &v->side[AP];
    int in = (ap->irq_en & IRQ_IN) && ap->inbox.count, out = (ap->irq_en & IRQ_OUT) && !v->side[SEP].inbox.count;
    if (v->gic[AP]) {
        /* XNU takes both events on the first line, edge-triggered: give every new one its own edge. */
        if ((in && (!v->ap_in_pending || ap->inbox.count > v->ap_in_seen)) || (out && !v->ap_out_pending))
            hv_gicv3_set_irq(v->gic[AP], v->intid[AP], 0);
        hv_gicv3_set_irq(v->gic[AP], v->intid[AP], in || out);
        hv_gicv3_set_irq(v->gic[AP], v->intid[AP] + 1, out);
    }
    v->ap_in_pending = in, v->ap_out_pending = out, v->ap_in_seen = ap->inbox.count;
    Side *sep = &v->side[SEP];
    if (v->gic[SEP]) {
        hv_gicv3_set_irq(v->gic[SEP], v->intid[SEP], (sep->irq_en & IRQ_IN) && sep->inbox.count);
        hv_gicv3_set_irq(v->gic[SEP], v->intid[SEP] + 1, (sep->irq_en & IRQ_OUT) && !v->side[AP].inbox.count);
    }
}

static uint32_t level(Queue *q) { return (q->count < 15 ? q->count : 15) << 20; }

static uint32_t status(Queue *q) { return (q->count & 0xff) | (q->count ? 0 : EMPTY) | (q->count == DEPTH ? FULL : 0); }

static void push(HvVpiop *v, int from) {
    Side *s = &v->side[from];
    Queue *q = &v->side[!from].inbox;
    if (v->log) {
        uint64_t a, b;
        memcpy(&a, s->out, 8), memcpy(&b, s->out + 8, 8);
        fprintf(stderr, "vpiop: %s -> %s %016llx %016llx\n", from == AP ? "ap" : "sep", from == AP ? "sep" : "ap",
                (unsigned long long)a, (unsigned long long)b);
    }
    if (q->count == DEPTH) {
        fprintf(stderr, "vpiop: %s outbox overflow\n", from == AP ? "ap" : "sep");
        return;
    }
    memcpy(q->msg[(q->head + q->count) % DEPTH], s->out, MSG);
    q->count++;
    memset(s->out, 0, MSG);
}

static uint64_t rd(void *opaque, uint64_t off, unsigned size) {
    Bank *b = opaque;
    HvVpiop *v = b->v;
    pthread_mutex_lock(&v->lock);
    Side *me = &v->side[b->side];
    uint64_t val = 0;
    if (off == 0x10) val = me->ctrl;
    else if (off == 0x14) val = me->status;
    else if (off == 0x18) val = me->irq_en;
    else if (off == 0x1c) val = status(&me->inbox) | (b->side == AP ? level(&me->inbox) : 0);
    else if (off == 0x20) val = status(&v->side[!b->side].inbox);
    else if (off >= 0x100 && off < 0x100 + MSG && off + size <= 0x100 + MSG) {
        if (me->inbox.count) {
            uint8_t msg[MSG];
            memcpy(msg, me->inbox.msg[me->inbox.head], MSG);
            if (b->side == AP) {
                uint32_t w;
                memcpy(&w, msg + 12, 4);
                w |= level(&me->inbox);
                memcpy(msg + 12, &w, 4);
            }
            memcpy(&val, msg + (off - 0x100), size);
            if (off + size == 0x100 + MSG) { /* reading the last word pops it */
                me->inbox.head = (me->inbox.head + 1) % DEPTH;
                me->inbox.count--;
                update(v);
            }
        }
    } else if (off >= 0x200 && off + size <= 0x200 + MSG) memcpy(&val, me->out + (off - 0x200), size);
    else if (v->log) fprintf(stderr, "vpiop: %s read +%llx\n", b->side == AP ? "ap" : "sep", (unsigned long long)off);
    pthread_mutex_unlock(&v->lock);
    return val;
}

static void wr(void *opaque, uint64_t off, uint64_t val, unsigned size) {
    Bank *b = opaque;
    HvVpiop *v = b->v;
    pthread_mutex_lock(&v->lock);
    Side *me = &v->side[b->side];
    if (off == 0x10) me->ctrl = (uint32_t)val;
    else if (off == 0x14) me->status = (me->status | ((uint32_t)val & READY)) & ~((uint32_t)val & 0xf);
    else if (off == 0x18) me->irq_en = (uint32_t)val;
    else if (off >= 0x200 && off + size <= 0x200 + MSG) {
        memcpy(me->out + (off - 0x200), &val, size);
        if (off + size == 0x200 + MSG) push(v, b->side); /* writing the last word sends it */
    } else if (v->log) fprintf(stderr, "vpiop: %s write +%llx = %llx\n", b->side == AP ? "ap" : "sep", (unsigned long long)off, (unsigned long long)val);
    update(v);
    pthread_mutex_unlock(&v->lock);
}

HvVpiop *hv_vpiop_create(HvMachine *ap, HvGic *gic, uint64_t pa, int intid) {
    HvVpiop *v = calloc(1, sizeof *v);
    pthread_mutex_init(&v->lock, NULL);
    v->log = getenv("HV_VPIOP_LOG") != NULL;
    for (int i = 0; i < SIDES; i++) v->bank[i].v = v, v->bank[i].side = i;
    v->gic[AP] = gic, v->intid[AP] = intid;
    hv_machine_add_mmio(ap, pa, 0x1000, &v->bank[AP], rd, wr, "vpiop-ap");
    return v;
}

void hv_vpiop_attach_sep(HvVpiop *v, HvMachine *sep, HvGic *gic, uint64_t pa, int intid) {
    v->gic[SEP] = gic, v->intid[SEP] = intid;
    hv_machine_add_mmio(sep, pa, 0x1000, &v->bank[SEP], rd, wr, "vpiop-sep");
}
