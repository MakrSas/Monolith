#ifndef MONOLITH_GXF_H
#define MONOLITH_GXF_H

#include <stdint.h>

#include "cpu.h"

/* Apple's guarded execution (GXF) and shadow permission remapping (SPRR), M1 style, as vresearch101
   guests use them: SPTM runs at GL1 and TXM at GL0. Modelled on QEMUAppleSilicon / vphone-linux. */

static inline int hv_gxf_guarded_at(const HvCpu *cpu, uint32_t el) { return cpu->gxf.on && (cpu->gxf.status[el ? 1 : 0] & 1); }
static inline int hv_gxf_guarded(const HvCpu *cpu) { return hv_gxf_guarded_at(cpu, cpu->el); }
static inline int hv_gxf_sprr_on(const HvCpu *cpu) { return cpu->gxf.on && (cpu->gxf.sprr_config[1] & 1); }

void hv_gxf_reset(HvCpu *cpu, int on);
/* System registers in S3_6_C15: 0 handled (read: *v set), -1 not a GXF register. */
int hv_gxf_read(HvCpu *cpu, uint32_t reg, uint64_t *v);
int hv_gxf_write(HvCpu *cpu, uint32_t reg, uint64_t v);
/* May EL0 (TXM at GL0, or user code changing its SPRR table) touch reg? */
/* Any other S3_*_C15 register on a GXF CPU: kept as written. 0 handled, -1 not a GXF CPU. */
int hv_gxf_impdef_read(HvCpu *cpu, uint32_t reg, uint64_t *v);
int hv_gxf_impdef_write(HvCpu *cpu, uint32_t reg, uint64_t v);
int hv_gxf_el0_allowed(HvCpu *cpu, uint32_t reg);
/* GENTER, GEXIT: 1 if insn was one (the CPU state is changed and pc set), 0 if not. */
int hv_gxf_insn(HvCpu *cpu, uint32_t insn, uint64_t pc);
/* Called by an exception return: from_guarded is what hv_gxf_guarded said before it, new_el where it went. */
void hv_gxf_after_eret(HvCpu *cpu, int from_guarded);
/* SPRR: permissions of a leaf descriptor's (AP, UXN, PXN) index at el. */
void hv_gxf_sprr_perm(HvCpu *cpu, int el, int ap, int uxn, int pxn, uint8_t *r, uint8_t *w, uint8_t *x);
/* Set EL1's guarded bit, moving the stack pointers between the GL1 and EL1 banks. */
void hv_gxf_set_gl1(HvCpu *cpu, int on);

#endif
