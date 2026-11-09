#ifndef MONOLITH_SEP_H
#define MONOLITH_SEP_H

#include <stddef.h>

#include "vmapple.h"

/* Starts vresearch101's SEP core on a thread of its own (see sep.c). jit_rx NULL: its own JIT mapping. */
int hv_sep_start(HvVmapple *b, const char *rom_path, const char *storage_path, void *jit_rx, void *jit_rw, size_t jit_bytes);
void hv_sep_stop(void);

#endif
