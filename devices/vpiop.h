#ifndef MONOLITH_VPIOP_H
#define MONOLITH_VPIOP_H

#include "../core/machine.h"
#include "gicv3.h"

/* vresearch101's SEP mailbox ("iop-sep,vpiop") at 0x30250000: the AP and the SEP core each see
   their own register bank there, and one side's outbox is the other's inbox (from QEMU's
   hw/vmapple/vpiop.c, GPL-2.0-or-later). */
typedef struct HvVpiop HvVpiop;

/* The AP bank goes on ap at pa; SPIs intid and intid + 1 on gic. */
HvVpiop *hv_vpiop_create(HvMachine *ap, HvGic *gic, uint64_t pa, int intid);
/* The SEP bank, on the SEP core's own machine and GIC (gic may be NULL). */
void hv_vpiop_attach_sep(HvVpiop *v, HvMachine *sep, HvGic *gic, uint64_t pa, int intid);

#endif
