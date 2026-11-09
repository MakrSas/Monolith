/* Apple GXF and SPRR for vresearch101 guests (see gxf.h). The guarded levels share the EL1 and EL0
   translation tables with everything else; what changes is the SPRR permission table that applies,
   so every change of the guarded state flushes the TLB (correct, and rare enough next to the work
   done at GL1). In the M1 layout GL code names its own banked registers S3_6_C15_C10_n, and the
   ordinary *_EL1 encodings reach the EL1 registers even while guarded.

   Behaviour follows QEMUAppleSilicon's a13_gxf.c and vphone-linux (AGPL-3.0-or-later). */
#include "gxf.h"

#include <stdio.h>
#include <stdlib.h>

#include "exception.h"
#include "machine.h"
#include "mmu.h"

#define REG(op1, crn, crm, op2) (3u << 14 | (uint32_t)(op1) << 11 | (uint32_t)(crn) << 7 | (uint32_t)(crm) << 3 | (uint32_t)(op2))

static int log_on(HvCpu *cpu) {
    static int v = -1;
    if (v < 0) v = getenv("HV_GXF_LOG") ? atoi(getenv("HV_GXF_LOG")) : 0;
    return v || (cpu->m && cpu->m->log >= 3);
}

void hv_gxf_reset(HvCpu *cpu, int on) {
    __builtin_memset(&cpu->gxf, 0, sizeof cpu->gxf);
    cpu->gxf.on = on;
    /* SPTM turns SPRR on before it writes the EL1 table, so the table must allow its own code from reset:
       the value SPTM programs (and later checks). */
    if (on) cpu->gxf.sprr_perm[1][0] = cpu->gxf.sprr_perm[1][1] = 0x2020a52a302abaf5ull;
}

static void flush(HvCpu *cpu) { hv_tlb_flush(cpu); }

void hv_gxf_set_gl1(HvCpu *cpu, int on) {
    on = !!on;
    if ((int)(cpu->gxf.status[1] & 1) == on) return;
    int before = hv_gxf_guarded(cpu);
    /* The EL1 stack slot holds the stack of whichever EL1 mode (guarded or not) is current. */
    uint64_t *live = cpu->el == 1 && cpu->spsel ? &cpu->sp : &cpu->sp_el1;
    uint64_t t = *live;
    *live = cpu->gxf.sp_gl;
    cpu->gxf.sp_gl = t;
    cpu->gxf.status[1] = (cpu->gxf.status[1] & ~1ull) | (uint64_t)on;
    if (before != hv_gxf_guarded(cpu) && hv_gxf_sprr_on(cpu)) flush(cpu);
}

static void set_gl0(HvCpu *cpu, int on) {
    on = !!on;
    if ((int)(cpu->gxf.status[0] & 1) == on) return;
    cpu->gxf.status[0] = (cpu->gxf.status[0] & ~1ull) | (uint64_t)on;
    if (cpu->el == 0 && hv_gxf_sprr_on(cpu)) flush(cpu);
}

int hv_gxf_el0_allowed(HvCpu *cpu, uint32_t reg) {
    if (!cpu->gxf.on) return 0;
    if (reg == REG(6, 15, 1, 5)) return 1; /* SPRR_EL0BR0_EL1: user code changes its own table (TPRO) */
    return hv_gxf_guarded_at(cpu, 0) && ((reg >> 11) & 7) == 6 && ((reg >> 7) & 15) == 15;
}

int hv_gxf_read(HvCpu *cpu, uint32_t reg, uint64_t *v) {
    if (!cpu->gxf.on || (reg >> 14) != 3 || ((reg >> 11) & 7) != 6 || ((reg >> 7) & 15) != 15) return -1;
    uint32_t crm = (reg >> 3) & 15, op2 = reg & 7;
    switch (crm << 3 | op2) {
    case 1 << 3 | 0: *v = cpu->gxf.sprr_config[1]; return 0;
    case 1 << 3 | 1: *v = cpu->gxf.sprr_config[0]; return 0;
    case 1 << 3 | 2: *v = cpu->gxf.config; return 0;
    case 1 << 3 | 5: *v = cpu->gxf.sprr_perm[0][0]; return 0;
    case 1 << 3 | 6: *v = cpu->gxf.sprr_perm[1][0]; return 0; /* unified: the EL1 table */
    case 1 << 3 | 7: *v = cpu->gxf.sprr_perm[1][0]; return 0;
    case 3 << 3 | 0: *v = cpu->gxf.c3_0; return 0;
    case 3 << 3 | 1: case 3 << 3 | 2: case 3 << 3 | 3: case 3 << 3 | 4: case 3 << 3 | 5:
        *v = cpu->gxf.mprr[op2 - 1]; return 0;
    case 8 << 3 | 0: *v = cpu->gxf.status[1]; return 0;
    case 8 << 3 | 1: *v = cpu->gxf.enter; return 0;
    case 8 << 3 | 2: *v = cpu->gxf.abort; return 0;
    case 8 << 3 | 3: case 10 << 3 | 4: *v = cpu->gxf.aspsr; return 0;
    /* A13 encodings (C9): the EL1 copies on a CPU without EL3. */
    case 9 << 3 | 0: *v = cpu->el == 1 && cpu->spsel && !hv_gxf_guarded(cpu) ? cpu->sp : cpu->sp_el1; return 0;
    case 9 << 3 | 1: *v = cpu->tpidr_el1; return 0;
    case 9 << 3 | 2: *v = cpu->vbar_el1; return 0;
    case 9 << 3 | 3: *v = cpu->spsr_el1; return 0;
    case 9 << 3 | 5: *v = cpu->esr_el1; return 0;
    case 9 << 3 | 6: *v = cpu->elr_el1; return 0;
    case 9 << 3 | 7: *v = cpu->far_el1; return 0;
    /* M1 encodings (C10): the GL1 registers. */
    case 10 << 3 | 0: *v = hv_gxf_guarded(cpu) && cpu->el == 1 && cpu->spsel ? cpu->sp : (cpu->gxf.status[1] & 1) ? cpu->sp_el1 : cpu->gxf.sp_gl; return 0;
    case 10 << 3 | 1: *v = cpu->gxf.tpidr_gl; return 0;
    case 10 << 3 | 2: *v = cpu->gxf.vbar_gl; return 0;
    case 10 << 3 | 3: *v = cpu->gxf.spsr_gl; return 0;
    case 10 << 3 | 5: *v = cpu->gxf.esr_gl; return 0;
    case 10 << 3 | 6: *v = cpu->gxf.elr_gl; return 0;
    case 10 << 3 | 7: *v = cpu->gxf.far_gl; return 0;
    }
    return -1;
}

int hv_gxf_write(HvCpu *cpu, uint32_t reg, uint64_t v) {
    if (!cpu->gxf.on || (reg >> 14) != 3 || ((reg >> 11) & 7) != 6 || ((reg >> 7) & 15) != 15) return -1;
    uint32_t crm = (reg >> 3) & 15, op2 = reg & 7;
    if (log_on(cpu) && crm != 9 && crm != 10)
        fprintf(stderr, "gxf: write S3_6_C15_C%u_%u = %llx pc %llx el%u%s\n", crm, op2, (unsigned long long)v,
                (unsigned long long)cpu->pc, cpu->el, hv_gxf_guarded(cpu) ? " guarded" : "");
    switch (crm << 3 | op2) {
    case 1 << 3 | 0:
        if (cpu->gxf.sprr_config[1] != v) cpu->gxf.sprr_config[1] = v, flush(cpu);
        return 0;
    case 1 << 3 | 1: cpu->gxf.sprr_config[0] = v; return 0;
    case 1 << 3 | 2: cpu->gxf.config = v; return 0;
    case 1 << 3 | 5: { /* SPRR_EL0BR0_EL1; from EL0 only the bits MPRR_EL0BR0 lets it change */
        uint64_t perm = cpu->gxf.sprr_perm[0][0];
        if (cpu->el == 0) {
            uint32_t mask = (uint32_t)cpu->gxf.mprr[0];
            for (int i = 0; i < 16; i++) {
                uint64_t um = (mask >> (i * 2)) & 3, req = (v >> (i * 4)) & 15, orig = (perm >> (i * 4)) & 15;
                uint64_t changed = (req ^ orig) & um, res = (orig & ~changed) | (req & changed);
                perm = (perm & ~(15ull << (i * 4))) | res << (i * 4);
            }
        } else perm = v;
        if (perm == cpu->gxf.sprr_perm[0][0] && perm == cpu->gxf.sprr_perm[0][1]) return 0;
        cpu->gxf.sprr_perm[0][0] = cpu->gxf.sprr_perm[0][1] = perm;
        flush(cpu);
        return 0;
    }
    case 1 << 3 | 6:
    case 1 << 3 | 7:
        if (cpu->gxf.sprr_perm[1][0] == v && cpu->gxf.sprr_perm[1][1] == v) return 0;
        cpu->gxf.sprr_perm[1][0] = cpu->gxf.sprr_perm[1][1] = v;
        flush(cpu);
        return 0;
    case 3 << 3 | 0: cpu->gxf.c3_0 = v; return 0;
    case 3 << 3 | 1: case 3 << 3 | 2: case 3 << 3 | 3: case 3 << 3 | 4: case 3 << 3 | 5:
        cpu->gxf.mprr[op2 - 1] = v; return 0;
    case 8 << 3 | 0: hv_gxf_set_gl1(cpu, v & 1); cpu->gxf.status[1] = (v & ~1ull) | (cpu->gxf.status[1] & 1); return 0;
    case 8 << 3 | 1: cpu->gxf.enter = v; return 0;
    case 8 << 3 | 2: cpu->gxf.abort = v; return 0;
    case 8 << 3 | 3: case 10 << 3 | 4: cpu->gxf.aspsr = v; return 0;
    case 9 << 3 | 0: if (cpu->el == 1 && cpu->spsel && !hv_gxf_guarded(cpu)) cpu->sp = v; else cpu->sp_el1 = v; return 0;
    case 9 << 3 | 1: cpu->tpidr_el1 = v; return 0;
    case 9 << 3 | 2: cpu->vbar_el1 = v & ~0x7ffull; return 0;
    case 9 << 3 | 3: cpu->spsr_el1 = v; return 0;
    case 9 << 3 | 5: cpu->esr_el1 = v; return 0;
    case 9 << 3 | 6: cpu->elr_el1 = v; return 0;
    case 9 << 3 | 7: cpu->far_el1 = v; return 0;
    case 10 << 3 | 0:
        if (hv_gxf_guarded(cpu) && cpu->el == 1 && cpu->spsel) cpu->sp = v;
        else if (cpu->gxf.status[1] & 1) cpu->sp_el1 = v;
        else cpu->gxf.sp_gl = v;
        return 0;
    case 10 << 3 | 1: cpu->gxf.tpidr_gl = v; return 0;
    case 10 << 3 | 2: cpu->gxf.vbar_gl = v; return 0;
    case 10 << 3 | 3: cpu->gxf.spsr_gl = v; return 0;
    case 10 << 3 | 5: cpu->gxf.esr_gl = v; return 0;
    case 10 << 3 | 6: cpu->gxf.elr_gl = v; return 0;
    case 10 << 3 | 7: cpu->gxf.far_gl = v; return 0;
    }
    return -1;
}

int hv_gxf_insn(HvCpu *cpu, uint32_t insn, uint64_t pc) {
    if (!cpu->gxf.on || (insn & 0xffff0000u) != 0x00200000u || ((insn >> 10) & 0x3f) != 5 || cpu->el == 0) return 0;
    uint32_t rn = (insn >> 5) & 31, rd = insn & 31;
    if (rn == 1) { /* GENTER: a synchronous exception into GL1 at GXF_ENTER_EL1 */
        if (hv_gxf_guarded(cpu)) return 0;
        if (log_on(cpu) >= 2) fprintf(stderr, "gxf: genter #%u pc %llx x0 %llx\n", rd, (unsigned long long)pc, (unsigned long long)cpu->x[0]);
        cpu->gxf.kind = 1;
        hv_take_exception(cpu, HV_EXC_SYNC, 0x3fu << 26 | 1u << 25 | 1u << 16 | rd, 0, 0, pc + 4);
        return 1;
    }
    if (rn == 0) { /* GEXIT: back to SPSR_GL1/ELR_GL1, guarded or not as ASPSR_GL1 bit 0 says */
        if (!hv_gxf_guarded(cpu)) return 0;
        uint64_t spsr = cpu->gxf.spsr_gl, elr = cpu->gxf.elr_gl;
        if (log_on(cpu) >= 2) fprintf(stderr, "gxf: gexit pc %llx -> %llx spsr %llx aspsr %llx\n", (unsigned long long)pc,
                                      (unsigned long long)elr, (unsigned long long)spsr, (unsigned long long)cpu->gxf.aspsr);
        hv_pstate_set(cpu, spsr);
        hv_gxf_set_gl1(cpu, cpu->gxf.aspsr & 1);
        cpu->pc = elr;
        cpu->excl_addr = ~0ull;
        cpu->exit_reason = HV_EXIT_EXCEPTION;
        return 1;
    }
    return 0;
}

void hv_gxf_after_eret(HvCpu *cpu, int from_guarded) {
    if (cpu->el == 0) set_gl0(cpu, from_guarded); /* M1 layout: an eret from a guarded level to EL0 enters GL0 (TXM) */
}

void hv_gxf_sprr_perm(HvCpu *cpu, int el, int ap, int uxn, int pxn, uint8_t *r, uint8_t *w, uint8_t *x) {
    int idx = ((ap << 2) | (uxn << 1) | pxn) & 15;
    int t = el ? 1 : 0;
    int attr = (int)((cpu->gxf.sprr_perm[t][t] >> (idx * 4)) & 15);
    int rr = 0, ww = 0, xx = 0;
    if (hv_gxf_guarded_at(cpu, (uint32_t)el)) {
        switch (attr >> 2) {
        case 1: rr = xx = 1; break;
        case 2: rr = 1; break;
        case 3: rr = ww = 1; break;
        }
    } else {
        switch (attr & 3) {
        case 1: rr = xx = 1; if ((attr >> 2) == 2) rr = 0; break;
        case 2: rr = 1; break;
        case 3: rr = ww = 1; if ((attr >> 2) == 1) rr = ww = 0; break; /* no R/W at EL if RX at GL */
        }
    }
    *r = (uint8_t)rr, *w = (uint8_t)ww, *x = (uint8_t)xx;
}
