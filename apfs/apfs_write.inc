/* APFS writing (included at the end of apfs.c, so it shares the reader's internals).

   Changes go into the container's current transaction, in place: a modified object keeps its block and is
   checksummed again, new objects take free blocks from the space manager, and the checkpoint's own
   superblock is rewritten at the end. That is a valid container as long as nothing else writes it at the
   same time. A node a snapshot still uses is never changed in place: the live tree gets a copy (copy on
   write, in the object map at the current transaction), so the snapshot keeps its own.

   Sealed volumes: the hashes in a hashed tree's index nodes become zero, as when the system volume is
   written to after its seal is broken; booting it needs a kernel that accepts a broken seal. */

#include <time.h>

/* ---- the block cache ---- */

enum { KIND_RAW, KIND_OBJECT, KIND_HEADERLESS };

typedef struct CEnt {
    uint64_t paddr;
    uint32_t nblocks; /* an ephemeral object may span several blocks */
    uint8_t *b;
    int dirty, kind;
    struct CEnt *next;
} CEnt;

#define CACHE_BUCKETS 8192

typedef struct Writer {
    CEnt *bucket[CACHE_BUCKETS];
    uint8_t *nx;            /* the checkpoint's superblock (a copy; written to its slot and to block 0) */
    uint64_t nx_slot;       /* its block in the checkpoint descriptor area */
    uint64_t spaceman;      /* paddr of the space manager */
    uint32_t spaceman_blocks;
    char err[256];
} Writer;

static CEnt *cache_find(ApfsContainer *c, uint64_t paddr) {
    Writer *w = c->w;
    for (CEnt *e = w->bucket[paddr % CACHE_BUCKETS]; e; e = e->next)
        if (e->paddr == paddr) return e;
    return NULL;
}

/* A block (or an object of n blocks) to change: loaded once, then kept until the commit. */
static uint8_t *cache_get(ApfsContainer *c, uint64_t paddr, uint32_t n, int load, int kind) {
    Writer *w = c->w;
    CEnt *e = cache_find(c, paddr);
    if (e) { e->dirty = 1; e->kind = kind; return e->b; }
    if (paddr + n > c->blocks) return NULL;
    e = calloc(1, sizeof *e);
    e->paddr = paddr;
    e->nblocks = n;
    e->b = calloc(n, c->bs);
    if (load && pread(c->fd, e->b, (size_t)n * c->bs, (off_t)(c->base + paddr * c->bs)) != (ssize_t)n * c->bs) {
        free(e->b);
        free(e);
        return NULL;
    }
    e->dirty = 1;
    e->kind = kind;
    e->next = w->bucket[paddr % CACHE_BUCKETS];
    w->bucket[paddr % CACHE_BUCKETS] = e;
    return e->b;
}

static int werr(ApfsContainer *c, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(c->w->err, sizeof c->w->err, fmt, ap);
    va_end(ap);
    if (debug_on()) fprintf(stderr, "apfs: %s\n", c->w->err);
    return -1;
}

const char *apfs_error(ApfsContainer *c) { return c->w ? c->w->err : ""; }

static inline void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void wr32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static inline void wr64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/* ---- the space manager ---- */

/* spaceman_phys_t: blocks per chunk @36, chunks per CIB @40, device 0 {block_count @48, chunk_count @56,
   cib_count u32 @64, cab_count u32 @68, free_count @72, addr_offset u32 @80}. CIB: chunk_info_t[] at 40,
   32 bytes each {xid, addr, block_count u32, free_count u32, bitmap_addr}. A CAB lists CIB addresses at 40. */

static uint8_t *spaceman(ApfsContainer *c) {
    return cache_get(c, c->w->spaceman, c->w->spaceman_blocks, 1, KIND_OBJECT);
}

/* The CIB addresses, through CABs if there are any. */
static int cib_addrs(ApfsContainer *c, uint64_t **out, uint32_t *count) {
    uint8_t *sm = spaceman(c);
    if (!sm) return -1;
    uint32_t cibs = rd32(sm + 64), cabs = rd32(sm + 68), off = rd32(sm + 80);
    uint64_t *a = calloc(cibs ? cibs : 1, 8);
    uint32_t n = 0;
    if (!cabs) {
        for (uint32_t i = 0; i < cibs; i++) a[n++] = rd64(sm + off + 8 * i);
    } else {
        uint8_t *cab = malloc(c->bs);
        for (uint32_t i = 0; i < cabs; i++) {
            if (read_block(c, rd64(sm + off + 8 * i), cab)) { free(cab); free(a); return -1; }
            uint32_t k = rd32(cab + 36);
            for (uint32_t j = 0; j < k && n < cibs; j++) a[n++] = rd64(cab + 40 + 8 * j);
        }
        free(cab);
    }
    *out = a;
    *count = n;
    return 0;
}

/* A block of the space manager's internal pool (where chunk bitmaps live): spaceman ip_block_count @152,
   ip_bm_size_in_blocks @160, ip_bm_base @168, ip_base @176, and at ip_bitmap_offset (@328) the u16 index of
   each block of the pool's current bitmap, counted from ip_bm_base. */
static int alloc_ip_block(ApfsContainer *c, uint64_t *paddr) {
    uint8_t *sm = spaceman(c);
    if (!sm) return werr(c, "cannot read the space manager");
    uint64_t count = rd64(sm + 152), bm_base = rd64(sm + 168), ip_base = rd64(sm + 176);
    uint32_t pieces = rd32(sm + 160), off = rd32(sm + 328), per = c->bs * 8;
    for (uint32_t p = 0; p < pieces; p++) {
        uint8_t *bm = cache_get(c, bm_base + rd16(sm + off + 2 * p), 1, 1, KIND_RAW);
        if (!bm) return werr(c, "cannot read the internal pool's bitmap");
        for (uint32_t k = 0; k < per && (uint64_t)p * per + k < count; k++) {
            if (bm[k / 8] & (1 << (k % 8))) continue;
            bm[k / 8] |= (uint8_t)(1 << (k % 8));
            *paddr = ip_base + (uint64_t)p * per + k;
            return 0;
        }
    }
    return werr(c, "the space manager's internal pool is full");
}

/* Up to want contiguous free blocks (at least one): *got of them from *start. */
static int alloc_run(ApfsContainer *c, uint64_t want, uint64_t *start, uint64_t *got) {
    uint64_t *cibs;
    uint32_t ncib;
    if (cib_addrs(c, &cibs, &ncib)) return werr(c, "cannot read the space manager");
    for (int pass = 0; pass < 2; pass++) /* first a chunk with room for all of it, then any */
        for (uint32_t i = 0; i < ncib; i++) {
            uint8_t cibb[65536];
            if (read_block(c, cibs[i], cibb)) continue;
            uint32_t count = rd32(cibb + 36);
            for (uint32_t j = 0; j < count; j++) {
                const uint8_t *ci = cibb + 40 + 32 * j;
                uint32_t blocks = rd32(ci + 16) & 0xfffff, free_ = rd32(ci + 20);
                uint64_t addr = rd64(ci + 8), bitmap = rd64(ci + 24);
                if (!free_ || (pass == 0 && free_ < want)) continue;
                if (!bitmap) { /* an untouched chunk, all free, has no bitmap yet: it gets one from the pool */
                    if (free_ != blocks || alloc_ip_block(c, &bitmap)) continue;
                    uint8_t *nb = cache_get(c, bitmap, 1, 0, KIND_RAW);
                    memset(nb, 0, c->bs);
                    uint8_t *cibw = cache_get(c, cibs[i], 1, 1, KIND_OBJECT);
                    wr64(cibw + 40 + 32 * j + 24, bitmap);
                }
                uint8_t *bm = cache_get(c, bitmap, 1, 1, KIND_RAW);
                if (!bm) continue;
                /* the longest run here, up to want */
                uint64_t best = 0, best_at = 0, run = 0;
                for (uint32_t k = 0; k < blocks && best < want; k++) {
                    if (bm[k / 8] & (1 << (k % 8))) { run = 0; continue; }
                    if (++run > best) { best = run; best_at = k + 1 - run; }
                }
                if (!best || (pass == 0 && best < want)) continue;
                for (uint64_t k = best_at; k < best_at + best; k++) bm[k / 8] |= (uint8_t)(1 << (k % 8));
                uint8_t *cib = cache_get(c, cibs[i], 1, 1, KIND_OBJECT);
                uint8_t *cw = cib + 40 + 32 * j;
                wr32(cw + 20, free_ - (uint32_t)best);
                wr64(cw, c->xid);
                uint8_t *sm = spaceman(c);
                wr64(sm + 72, rd64(sm + 72) - best);
                *start = addr + best_at;
                *got = best;
                free(cibs);
                return 0;
            }
        }
    free(cibs);
    return werr(c, "the container is full");
}

/* Gives n blocks from start back to the space manager. */
static int free_run(ApfsContainer *c, uint64_t start, uint64_t n) {
    uint64_t *cibs;
    uint32_t ncib;
    if (cib_addrs(c, &cibs, &ncib)) return werr(c, "cannot read the space manager");
    while (n) {
        int found = 0;
        for (uint32_t i = 0; i < ncib && !found; i++) {
            uint8_t cibb[65536];
            if (read_block(c, cibs[i], cibb)) continue;
            uint32_t count = rd32(cibb + 36);
            for (uint32_t j = 0; j < count; j++) {
                const uint8_t *ci = cibb + 40 + 32 * j;
                uint64_t addr = rd64(ci + 8), bitmap = rd64(ci + 24);
                uint32_t blocks = rd32(ci + 16) & 0xfffff;
                if (start < addr || start >= addr + blocks || !bitmap) continue;
                uint64_t k = start - addr, take = blocks - k < n ? blocks - k : n, cleared = 0;
                uint8_t *bm = cache_get(c, bitmap, 1, 1, KIND_RAW);
                for (uint64_t x = k; x < k + take; x++)
                    if (bm[x / 8] & (1 << (x % 8))) { bm[x / 8] &= (uint8_t)~(1 << (x % 8)); cleared++; }
                uint8_t *cib = cache_get(c, cibs[i], 1, 1, KIND_OBJECT);
                wr32(cib + 40 + 32 * j + 20, rd32(cib + 40 + 32 * j + 20) + (uint32_t)cleared);
                uint8_t *sm = spaceman(c);
                wr64(sm + 72, rd64(sm + 72) + cleared);
                start += take;
                n -= take;
                found = 1;
                break;
            }
        }
        if (!found) { free(cibs); return werr(c, "block %llu is in no chunk", (unsigned long long)start); }
    }
    free(cibs);
    return 0;
}

static int alloc_block(ApfsContainer *c, ApfsVolume *v, uint64_t *paddr) {
    uint64_t got;
    if (alloc_run(c, 1, paddr, &got)) return -1;
    if (v) v->alloced += 1;
    return 0;
}

/* ---- nodes ---- */

typedef struct Ent { uint8_t *k, *v; uint16_t kl, vl; } Ent;

typedef struct NodeImg {
    uint16_t flags, level;
    uint32_t n, cap;
    Ent *e;
} NodeImg;

static void img_free(NodeImg *m) {
    for (uint32_t i = 0; i < m->n; i++) { free(m->e[i].k); free(m->e[i].v); }
    free(m->e);
    memset(m, 0, sizeof *m);
}

static void img_add(NodeImg *m, uint32_t at, const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl) {
    if (m->n == m->cap) { m->cap = m->cap ? m->cap * 2 : 64; m->e = realloc(m->e, m->cap * sizeof *m->e); }
    memmove(m->e + at + 1, m->e + at, (m->n - at) * sizeof *m->e);
    Ent *e = &m->e[at];
    e->k = malloc(kl ? kl : 1); memcpy(e->k, k, kl); e->kl = kl;
    e->v = malloc(vl ? vl : 1); if (v) memcpy(e->v, v, vl); e->vl = vl;
    m->n++;
}

static void img_del(NodeImg *m, uint32_t at) {
    free(m->e[at].k); free(m->e[at].v);
    memmove(m->e + at, m->e + at + 1, (m->n - at - 1) * sizeof *m->e);
    m->n--;
}

static void img_load(ApfsContainer *c, const uint8_t *b, const struct Tree *t, NodeImg *m) {
    Node n;
    node_parse(c, (uint8_t *)b, &n);
    memset(m, 0, sizeof *m);
    m->flags = n.flags;
    m->level = n.level;
    for (uint32_t i = 0; i < n.nkeys; i++) {
        const uint8_t *k, *v; uint16_t kl, vl;
        node_entry(&n, i, t->fixed_k, t->fixed_v, &k, &kl, &v, &vl);
        if ((n.flags & BTNODE_FIXED_KV_SIZE) && n.level) vl = 8;
        img_add(m, m->n, k, kl, v, v ? vl : 0);
    }
}

/* The table of contents: a fixed-size node's holds as many entries as the node could ever take; a
   variable one grows in steps of 64 bytes. */
static uint32_t toc_len(ApfsContainer *c, const NodeImg *m, uint32_t n) {
    if (m->flags & BTNODE_FIXED_KV_SIZE) {
        uint32_t k = m->n ? m->e[0].kl : 16, v = m->level ? 8 : (m->n ? m->e[0].vl : 16);
        return (c->bs - 56) / (4 + k + v) * 4;
    }
    uint32_t t = (n * 8 + 63) & ~63u;
    return t ? t : 64;
}

/* Whether entries fit one node (root: the tree info at the end). */
static int img_fits(ApfsContainer *c, const NodeImg *m, int root, uint32_t from, uint32_t to) {
    uint32_t used = 56 + (root ? BTREE_INFO_SIZE : 0);
    used += toc_len(c, m, to - from);
    for (uint32_t i = from; i < to; i++)
        used += m->e[i].kl + m->e[i].vl; /* packed, as Apple lays nodes out */
    return used <= c->bs;
}

/* Lays the entries out in b (keeping its object header): toc, keys forward, values backward. */
static void img_store(ApfsContainer *c, const NodeImg *m, uint32_t from, uint32_t to, int root, uint8_t *b) {
    uint8_t info[BTREE_INFO_SIZE];
    if (root) memcpy(info, b + c->bs - BTREE_INFO_SIZE, BTREE_INFO_SIZE);
    memset(b + 32, 0, c->bs - 32);
    int fixed = m->flags & BTNODE_FIXED_KV_SIZE;
    uint32_t n = to - from, es = fixed ? 4 : 8;
    uint32_t toc = toc_len(c, m, n);
    uint16_t flags = (uint16_t)((m->flags & ~(BTNODE_ROOT | BTNODE_LEAF)) | (root ? BTNODE_ROOT : 0) | (m->level ? 0 : BTNODE_LEAF));
    wr16(b + 32, flags);
    wr16(b + 34, m->level);
    wr32(b + 36, n);
    wr16(b + 40, 0);
    wr16(b + 42, (uint16_t)toc);
    uint8_t *keys = b + 56 + toc, *vend = b + c->bs - (root ? BTREE_INFO_SIZE : 0);
    uint32_t koff = 0, voff = 0;
    for (uint32_t i = 0; i < n; i++) {
        const Ent *e = &m->e[from + i];
        uint8_t *t = b + 56 + i * es;
        memcpy(keys + koff, e->k, e->kl);
        voff += e->vl; /* values packed, as fsck_apfs counts the free space */
        memcpy(vend - voff, e->v, e->vl);
        if (fixed) { wr16(t, (uint16_t)koff); wr16(t + 2, (uint16_t)voff); }
        else { wr16(t, (uint16_t)koff); wr16(t + 2, e->kl); wr16(t + 4, (uint16_t)voff); wr16(t + 6, e->vl); }
        koff += e->kl;
    }
    wr16(b + 44, (uint16_t)koff);
    wr16(b + 46, (uint16_t)((vend - voff) - (keys + koff)));
    wr16(b + 48, 0xffff); wr16(b + 50, 0);
    wr16(b + 52, 0xffff); wr16(b + 54, 0);
    if (root) memcpy(b + c->bs - BTREE_INFO_SIZE, info, BTREE_INFO_SIZE);
}

/* ---- trees: insert and delete ---- */

/* Full-key order for each kind of tree. */
typedef int (*RawCmp)(const uint8_t *a, uint16_t al, const uint8_t *b, uint16_t bl, ApfsVolume *v);

static int cmp_u64(uint64_t a, uint64_t b) { return a == b ? 0 : a < b ? -1 : 1; }

static int raw_omap(const uint8_t *a, uint16_t al, const uint8_t *b, uint16_t bl, ApfsVolume *v) {
    (void)al; (void)bl; (void)v;
    int r = cmp_u64(rd64(a), rd64(b));
    return r ? r : cmp_u64(rd64(a + 8), rd64(b + 8));
}

static int raw_fext(const uint8_t *a, uint16_t al, const uint8_t *b, uint16_t bl, ApfsVolume *v) {
    return raw_omap(a, al, b, bl, v); /* {private_id, logical} */
}

static int raw_fs(const uint8_t *a, uint16_t al, const uint8_t *b, uint16_t bl, ApfsVolume *v) {
    uint64_t ha = rd64(a), hb = rd64(b);
    int r = cmp_u64(ha & OBJ_ID_MASK, hb & OBJ_ID_MASK);
    if (r) return r;
    uint8_t ta = (uint8_t)(ha >> OBJ_TYPE_SHIFT), tb = (uint8_t)(hb >> OBJ_TYPE_SHIFT);
    if (ta != tb) return ta < tb ? -1 : 1;
    switch (ta) {
    case APFS_TYPE_DIR_REC:
        if (v && v->hashed_names) {
            uint32_t xa = rd32(a + 8) >> 10, xb = rd32(b + 8) >> 10;
            if (xa != xb) return xa < xb ? -1 : 1;
            return strcmp((const char *)a + 12, (const char *)b + 12);
        }
        return strcmp((const char *)a + 10, (const char *)b + 10);
    case APFS_TYPE_XATTR:
    case 11: /* SNAP_NAME */
        return strcmp((const char *)a + 10, (const char *)b + 10);
    case APFS_TYPE_FILE_EXTENT:
    case 5:  /* SIBLING_LINK */
    case 13: /* FILE_INFO */
        if (al >= 16 && bl >= 16) return cmp_u64(rd64(a + 8), rd64(b + 8));
        return 0;
    default:
        return 0;
    }
}

static int raw_extentref(const uint8_t *a, uint16_t al, const uint8_t *b, uint16_t bl, ApfsVolume *v) {
    (void)al; (void)bl; (void)v;
    return cmp_u64(rd64(a) & OBJ_ID_MASK, rd64(b) & OBJ_ID_MASK);
}

typedef struct WTree {
    ApfsContainer *c;
    ApfsVolume *v;          /* the volume whose blocks these are (counts), or NULL */
    uint64_t *root;         /* where the root's oid lives (it never changes, but a physical root may move) */
    int virtual_;
    uint64_t omap_root;     /* virtual trees: their object map */
    uint16_t fixed_k, fixed_v;
    RawCmp cmp;
    uint64_t snap_xid;      /* nodes from this transaction or before are shared with a snapshot */
    uint32_t obj_type, obj_subtype; /* for new nodes' headers */
    int headerless, hashed;
} WTree;

static int omap_set(ApfsContainer *c, ApfsVolume *v, uint64_t omap_root, uint64_t oid, uint64_t xid, uint64_t paddr,
                    uint32_t flags);

/* A node to change, by its oid: its buffer in the cache, copied first if a snapshot shares it. */
static uint8_t *wnode(WTree *t, uint64_t oid) {
    ApfsContainer *c = t->c;
    uint64_t p = oid, xid = 0;
    if (t->virtual_) {
        OmapFind f = {oid, c->xid, 0, 0, 0};
        Tree ot = {c, t->omap_root, 0, 0, 16, 16, omap_cmp, NULL, 0};
        OmapKey s = {oid, 0};
        if (tree_walk(&ot, &s, omap_find_cb, &f) || !f.found) { werr(c, "no mapping for node %llu", (unsigned long long)oid); return NULL; }
        p = f.paddr;
        xid = f.best_xid;
    }
    int kind = t->headerless ? KIND_HEADERLESS : KIND_OBJECT;
    if (t->virtual_ && xid <= t->snap_xid) {
        uint8_t *old = malloc(c->bs);
        if (!old || read_block(c, p, old)) { free(old); return NULL; }
        uint64_t np;
        if (alloc_block(c, t->v, &np)) { free(old); return NULL; }
        uint8_t *b = cache_get(c, np, 1, 0, kind);
        memcpy(b, old, c->bs);
        free(old);
        if (omap_set(c, t->v, t->omap_root, oid, c->xid, np, t->headerless ? 8 : 0)) return NULL;
        return b;
    }
    /* changed in place: its transaction stays (a virtual node's must match its object-map entry) */
    return cache_get(c, p, 1, 1, kind);
}

/* A new node: a block, and for virtual trees an oid mapped to it. */
static uint8_t *wnew(WTree *t, uint64_t *oid) {
    ApfsContainer *c = t->c;
    uint64_t p;
    if (alloc_block(c, t->v, &p)) return NULL;
    uint8_t *b = cache_get(c, p, 1, 0, t->headerless ? KIND_HEADERLESS : KIND_OBJECT);
    if (t->virtual_) {
        *oid = rd64(c->w->nx + 88); /* nx_next_oid */
        wr64(c->w->nx + 88, *oid + 1);
        if (omap_set(c, t->v, t->omap_root, *oid, c->xid, p, t->headerless ? 8 : 0)) return NULL;
    } else {
        *oid = p;
    }
    if (!t->headerless) {
        wr64(b + 8, *oid);
        wr64(b + 16, c->xid);
        wr32(b + 24, (t->virtual_ ? 0 : 0x40000000) | t->obj_type);
        wr32(b + 28, t->obj_subtype);
    }
    return b;
}

static void info_bump(WTree *t, int64_t keys, int64_t nodes, uint16_t kl, uint16_t vl) {
    uint8_t *r = wnode(t, *t->root);
    if (!r) return;
    uint8_t *info = r + t->c->bs - BTREE_INFO_SIZE;
    if (kl > rd32(info + 16)) wr32(info + 16, kl);
    if (vl > rd32(info + 20)) wr32(info + 20, vl);
    wr64(info + 24, rd64(info + 24) + (uint64_t)keys);
    wr64(info + 32, rd64(info + 32) + (uint64_t)nodes);
}

/* An index entry's value: the child's oid (relative to the root's in hashed trees, then a zero hash). */
static void child_val(WTree *t, uint64_t child, uint8_t *v, uint16_t *vl) {
    memset(v, 0, 40);
    wr64(v, t->hashed ? child - *t->root : child);
    *vl = t->hashed ? 40 : 8;
}

static uint64_t child_of(WTree *t, const Ent *e) {
    return rd64(e->v) + (t->hashed ? *t->root : 0);
}

/* Index of the child covering key (the last whose first key <= key). */
static uint32_t pick_child(WTree *t, const NodeImg *m, const uint8_t *k, uint16_t kl) {
    uint32_t at = 0;
    for (uint32_t i = 0; i < m->n; i++)
        if (t->cmp(m->e[i].k, m->e[i].kl, k, kl, t->v) <= 0) at = i; else break;
    return at;
}

/* Writes m into node oid; if it does not fit, splits it: returns the new right sibling's first key and
   oid through split_* (split_kl 0: no split). The root never moves: it splits into two new children. */
static int wstore(WTree *t, uint64_t oid, NodeImg *m, int root, uint8_t *split_k, uint16_t *split_kl, uint64_t *split_oid) {
    ApfsContainer *c = t->c;
    *split_kl = 0;
    if (debug_on()) fprintf(stderr, "apfs: store node %llu level %u: %u entries%s\n", (unsigned long long)oid, m->level, m->n, root ? " (root)" : "");
    if (img_fits(c, m, root, 0, m->n)) {
        uint8_t *b = wnode(t, oid);
        if (!b) return -1;
        img_store(c, m, 0, m->n, root, b);
        return 0;
    }
    /* split in two halves by count */
    uint32_t half = m->n / 2;
    if (!img_fits(c, m, 0, 0, half) || !img_fits(c, m, 0, half, m->n)) return werr(c, "an entry does not fit a node");
    if (root) {
        uint64_t lo, ro;
        uint8_t *lb = wnew(t, &lo), *rb = lb ? wnew(t, &ro) : NULL;
        if (!rb) return -1;
        img_store(c, m, 0, half, 0, lb);
        img_store(c, m, half, m->n, 0, rb);
        NodeImg top = {(uint16_t)(m->flags & ~BTNODE_LEAF), (uint16_t)(m->level + 1), 0, 0, NULL};
        uint8_t v[40]; uint16_t vl;
        child_val(t, lo, v, &vl); img_add(&top, 0, m->e[0].k, m->e[0].kl, v, vl);
        child_val(t, ro, v, &vl); img_add(&top, 1, m->e[half].k, m->e[half].kl, v, vl);
        uint8_t *b = wnode(t, oid);
        if (!b) { img_free(&top); return -1; }
        img_store(c, &top, 0, top.n, 1, b);
        img_free(&top);
        info_bump(t, 0, 2, 0, 0);
        return 0;
    }
    uint64_t ro;
    uint8_t *rb = wnew(t, &ro);
    if (!rb) return -1;
    img_store(c, m, half, m->n, 0, rb);
    uint8_t *b = wnode(t, oid);
    if (!b) return -1;
    img_store(c, m, 0, half, 0, b);
    memcpy(split_k, m->e[half].k, m->e[half].kl);
    *split_kl = m->e[half].kl;
    *split_oid = ro;
    info_bump(t, 0, 1, 0, 0);
    return 0;
}

/* A hashed tree's index entries after a change below: their child hashes no longer hold. */
static void zero_hashes(WTree *t, NodeImg *m) {
    if (!t->hashed || !m->level) return;
    for (uint32_t i = 0; i < m->n; i++)
        if (m->e[i].vl > 8) memset(m->e[i].v + 8, 0, m->e[i].vl - 8);
}

/* Inserts (or, with replace, overwrites) one record below oid. */
static int winsert_at(WTree *t, uint64_t oid, int root, const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl,
                      int replace, uint8_t *split_k, uint16_t *split_kl, uint64_t *split_oid, int *added) {
    ApfsContainer *c = t->c;
    uint8_t *raw = malloc(c->bs);
    Tree rt = {c, oid, t->virtual_, t->omap_root, t->fixed_k, t->fixed_v, NULL, NULL, 0};
    if (!raw || tree_node(&rt, oid, raw)) {
        /* a node changed in this commit is read from the cache by read_block */
        free(raw);
        return werr(c, "cannot read node %llu", (unsigned long long)oid);
    }
    NodeImg m;
    img_load(c, raw, (const struct Tree *)&rt, &m);
    free(raw);
    zero_hashes(t, &m);
    int r = 0;
    if (m.level == 0) {
        uint32_t at = 0;
        while (at < m.n && t->cmp(m.e[at].k, m.e[at].kl, k, kl, t->v) < 0) at++;
        if (at < m.n && t->cmp(m.e[at].k, m.e[at].kl, k, kl, t->v) == 0) {
            if (!replace) { img_free(&m); return werr(c, "the record exists (id %llu type %u)", (unsigned long long)(rd64(k) & OBJ_ID_MASK), (unsigned)(rd64(k) >> OBJ_TYPE_SHIFT)); }
            img_del(&m, at);
        } else {
            *added = 1;
        }
        img_add(&m, at, k, kl, v, vl);
        r = wstore(t, oid, &m, root, split_k, split_kl, split_oid);
    } else {
        if (!m.n) { img_free(&m); return werr(c, "an empty index node"); }
        uint32_t at = pick_child(t, &m, k, kl);
        uint8_t ck[1024]; uint16_t ckl = 0; uint64_t coid = 0;
        r = winsert_at(t, child_of(t, &m.e[at]), 0, k, kl, v, vl, replace, ck, &ckl, &coid, added);
        int first_changed = !r && at == 0 && t->cmp(k, kl, m.e[0].k, m.e[0].kl, t->v) < 0;
        if (!r && (ckl || first_changed)) {
            if (first_changed) { /* the first key of the subtree is now smaller */
                free(m.e[0].k);
                m.e[0].k = malloc(kl); memcpy(m.e[0].k, k, kl); m.e[0].kl = kl;
            }
            if (ckl) {
                uint8_t cv[40]; uint16_t cvl;
                child_val(t, coid, cv, &cvl);
                img_add(&m, at + 1, ck, ckl, cv, cvl);
            }
            r = wstore(t, oid, &m, root, split_k, split_kl, split_oid);
        } else if (!r && t->hashed) {
            r = wstore(t, oid, &m, root, split_k, split_kl, split_oid); /* the child's hash is gone: zero here too */
        }
    }
    img_free(&m);
    return r;
}

static int winsert(WTree *t, const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, int replace) {
    uint8_t sk[1024]; uint16_t skl; uint64_t so; int added = 0;
    if (winsert_at(t, *t->root, 1, k, kl, v, vl, replace, sk, &skl, &so, &added)) return -1;
    info_bump(t, added, 0, kl, vl);
    return 0;
}

/* Deletes every record for which match() says so, below oid (records of one object sit together). */
typedef int (*Match)(const uint8_t *k, uint16_t kl, void *ctx);

static int wdelete_at(WTree *t, uint64_t oid, int root, const uint8_t *from, uint16_t fl, Match match, void *ctx,
                      int *removed, int *empty, uint8_t *split_k, uint16_t *split_kl, uint64_t *split_oid,
                      uint8_t *first_k, uint16_t *first_kl) {
    *split_kl = 0;
    ApfsContainer *c = t->c;
    uint8_t *raw = malloc(c->bs);
    Tree rt = {c, oid, t->virtual_, t->omap_root, t->fixed_k, t->fixed_v, NULL, NULL, 0};
    if (!raw || tree_node(&rt, oid, raw)) { free(raw); return werr(c, "cannot read node"); }
    NodeImg m;
    img_load(c, raw, (const struct Tree *)&rt, &m);
    free(raw);
    zero_hashes(t, &m);
    int r = 0, changed = 0;
    if (m.level == 0) {
        for (uint32_t i = 0; i < m.n;)
            if (match(m.e[i].k, m.e[i].kl, ctx)) { img_del(&m, i); (*removed)++; changed = 1; } else i++;
    } else {
        uint32_t at = pick_child(t, &m, from, fl);
        for (uint32_t i = at; i < m.n && !r;) {
            if (i > at && !match(m.e[i].k, m.e[i].kl, ctx) && t->cmp(m.e[i].k, m.e[i].kl, from, fl, t->v) > 0) break;
            int child_empty = 0, before = *removed;
            uint8_t ck[1024], fk[1024]; uint16_t ckl = 0, fkl = 0; uint64_t coid = 0;
            r = wdelete_at(t, child_of(t, &m.e[i]), 0, from, fl, match, ctx, removed, &child_empty, ck, &ckl, &coid, fk, &fkl);
            if (!r && !child_empty && fkl && (fkl != m.e[i].kl || memcmp(fk, m.e[i].k, fkl))) {
                free(m.e[i].k); /* the child's first key changed: so does its separator here */
                m.e[i].k = malloc(fkl); memcpy(m.e[i].k, fk, fkl); m.e[i].kl = fkl;
                changed = 1;
            }
            if (!r && ckl) { /* rewritten, the child no longer fit one node */
                uint8_t cv[40]; uint16_t cvl;
                child_val(t, coid, cv, &cvl);
                img_add(&m, i + 1, ck, ckl, cv, cvl);
                changed = 1;
            }
            if (*removed != before) changed = 1;
            if (debug_on()) fprintf(stderr, "apfs: delete below %llu child %u/%u: removed %d, empty %d\n", (unsigned long long)oid, i, m.n, *removed - before, child_empty);
            if (child_empty) { img_del(&m, i); info_bump(t, 0, -1, 0, 0); } else i++;
        }
    }
    *empty = !root && m.n == 0;
    if (root && m.level && m.n == 0) { /* every record is gone: the root is an empty leaf again */
        m.level = 0;
        changed = 1;
    }
    *first_kl = 0;
    if (m.n) { memcpy(first_k, m.e[0].k, m.e[0].kl); *first_kl = m.e[0].kl; }
    if (!r && changed && !*empty) r = wstore(t, oid, &m, root, split_k, split_kl, split_oid);
    img_free(&m);
    return r;
}

static int wdelete(WTree *t, const uint8_t *from, uint16_t fl, Match match, void *ctx) {
    int removed = 0, empty = 0;
    uint8_t sk[1024], fk[1024]; uint16_t skl, fkl; uint64_t so;
    if (wdelete_at(t, *t->root, 1, from, fl, match, ctx, &removed, &empty, sk, &skl, &so, fk, &fkl)) return -1;
    if (removed) info_bump(t, -removed, 0, 0, 0);
    return removed;
}

/* ---- the object map ---- */

static int omap_set(ApfsContainer *c, ApfsVolume *v, uint64_t omap_root, uint64_t oid, uint64_t xid, uint64_t paddr,
                    uint32_t flags) {
    uint64_t root = omap_root;
    WTree t = {c, v, &root, 0, 0, 16, 16, raw_omap, 0, OBJECT_TYPE_BTREE_NODE, OBJECT_TYPE_OMAP, 0, 0};
    uint8_t k[16], val[16];
    wr64(k, oid); wr64(k + 8, xid);
    wr32(val, flags); wr32(val + 4, c->bs); wr64(val + 8, paddr);
    return winsert(&t, k, 16, val, 16, 1);
}

/* ---- commit ---- */

int apfs_commit(ApfsContainer *c) {
    Writer *w = c->w;
    if (!w) return -1;
    for (int i = 0; i < CACHE_BUCKETS; i++)
        for (CEnt *e = w->bucket[i]; e; e = e->next) {
            if (!e->dirty) continue;
            size_t len = (size_t)e->nblocks * c->bs;
            if (e->kind == KIND_OBJECT) wr64(e->b, fletcher64(e->b, len));
            else if (e->kind == KIND_HEADERLESS) memset(e->b, 0, 32);
            if (pwrite(c->fd, e->b, len, (off_t)(c->base + e->paddr * c->bs)) != (ssize_t)len) return werr(c, "write failed");
            e->dirty = 0;
        }
    /* a sealed volume written to: its seal is broken (integrity_meta_phys_t: im_flags @36 |=
       APFS_SEAL_BROKEN, im_broken_xid @48), as the macOS kernel marks it, so a guest kernel that allows a
       broken seal stops checking the tree's hashes instead of refusing the volume */
    for (int i = 0; i < c->nvol; i++) {
        ApfsVolume *v = &c->vol[i];
        if (!v->fs_written || v->resealed || !(v->incompat & APFS_INCOMPAT_SEALED_VOLUME)) continue;
        uint8_t sb[65536];
        uint64_t im = 0, p;
        if (!read_block(c, v->sb_paddr, sb)) im = rd64(sb + 1024);
        if (!im || omap_lookup(c, v->omap_root, im, c->xid, &p)) continue;
        uint8_t *b = cache_get(c, p, 1, 1, KIND_OBJECT);
        if (!b) continue;
        if (!(rd32(b + 36) & 1)) { wr32(b + 36, rd32(b + 36) | 1); wr64(b + 48, c->xid); }
        if (pwrite(c->fd, (wr64(b, fletcher64(b, c->bs)), b), c->bs, (off_t)(c->base + p * c->bs)) != (ssize_t)c->bs) return werr(c, "write failed");
        if (debug_on()) fprintf(stderr, "apfs: %s: seal marked broken\n", v->name);
    }
    /* volumes' counters */
    for (int i = 0; i < c->nvol; i++) {
        ApfsVolume *v = &c->vol[i];
        uint8_t *sb = malloc(c->bs);
        if (pread(c->fd, sb, c->bs, (off_t)(c->base + v->sb_paddr * c->bs)) != (ssize_t)c->bs) { free(sb); return werr(c, "volume superblock"); }
        if (!v->alloced && !v->sb_dirty && !v->files_added && !v->dirs_added && !v->symlinks_added && !v->counted &&
            rd64(sb + 176) == v->next_obj_id) { free(sb); continue; }
        v->counted = 0;
        wr64(sb + 88, rd64(sb + 88) + v->alloced);      /* fs_alloc_count */
        wr64(sb + 176, v->next_obj_id);                 /* next_obj_id */
        wr64(sb + 184, rd64(sb + 184) + v->files_added);
        wr64(sb + 192, rd64(sb + 192) + v->dirs_added);
        wr64(sb + 200, rd64(sb + 200) + v->symlinks_added);
        wr64(sb + 256, now_ns());                        /* last_mod_time */
        wr64(sb, fletcher64(sb, c->bs));
        if (pwrite(c->fd, sb, c->bs, (off_t)(c->base + v->sb_paddr * c->bs)) != (ssize_t)c->bs) { free(sb); return werr(c, "write failed"); }
        free(sb);
        v->alloced = v->files_added = v->dirs_added = v->symlinks_added = 0;
        v->sb_dirty = 0;
    }
    wr64(w->nx, fletcher64(w->nx, c->bs));
    if (pwrite(c->fd, w->nx, c->bs, (off_t)(c->base + w->nx_slot * c->bs)) != (ssize_t)c->bs ||
        pwrite(c->fd, w->nx, c->bs, (off_t)c->base) != (ssize_t)c->bs)
        return werr(c, "write failed");
    fsync(c->fd);
    return 0;
}

/* ---- opening for writing ---- */

static int snap_max_cb(const char *name, uint64_t xid, void *user) {
    (void)name;
    uint64_t *m = user;
    if (xid > *m) *m = xid;
    return 0;
}

ApfsContainer *apfs_open_rw(const char *path, char *err, size_t errlen) {
    ApfsContainer *c = apfs_open(path, err, errlen);
    if (!c) return NULL;
    int fd = open(path, O_RDWR);
    if (fd < 0) { set_err(err, errlen, "cannot open %s for writing", path); apfs_close(c); return NULL; }
    close(c->fd);
    c->fd = fd;
    Writer *w = calloc(1, sizeof *w);
    c->w = w;
    /* the checkpoint: its superblock's slot and the space manager's address (checkpoint map) */
    uint8_t *b0 = malloc(c->bs), *b = malloc(c->bs);
    pread(fd, b0, c->bs, (off_t)c->base);
    uint32_t desc_blocks = rd32(b0 + 104) & 0x7fffffff;
    uint64_t desc_base = rd64(b0 + 112);
    w->nx = malloc(c->bs);
    for (uint32_t i = 0; i < desc_blocks; i++) {
        if (read_object(c, desc_base + i, b) || memcmp(b + 32, "NXSB", 4) || rd64(b + 16) != c->xid) continue;
        memcpy(w->nx, b, c->bs);
        w->nx_slot = desc_base + i;
    }
    uint64_t sm_oid = rd64(w->nx + 152);
    uint32_t idx = rd32(w->nx + 136), len = rd32(w->nx + 140);
    for (uint32_t i = 0; i < len && !w->spaceman; i++) {
        if (read_object(c, desc_base + (idx + i) % desc_blocks, b) || (rd32(b + 24) & OBJ_TYPE_MASK) != 0xc) continue;
        uint32_t n = rd32(b + 36);
        for (uint32_t j = 0; j < n; j++) {
            const uint8_t *m = b + 40 + 40 * j;
            if (rd64(m + 24) == sm_oid) { w->spaceman = rd64(m + 32); w->spaceman_blocks = (rd32(m + 8) + c->bs - 1) / c->bs; }
        }
    }
    free(b0);
    free(b);
    if (!w->nx_slot || !w->spaceman) { set_err(err, errlen, "cannot find the checkpoint"); apfs_close(c); return NULL; }
    for (int i = 0; i < c->nvol; i++) {
        ApfsVolume *v = &c->vol[i];
        omap_lookup(c, c->omap_root, v->oid, c->xid, &v->sb_paddr);
        uint8_t sb[65536];
        read_block(c, v->sb_paddr, sb);
        v->next_obj_id = rd64(sb + 176);
        v->extentref_root = rd64(sb + 144);
        apfs_snapshots(v, snap_max_cb, &v->snap_xid_max);
    }
    return c;
}

/* ---- records ---- */

static uint32_t crc32c(uint32_t crc, const uint8_t *p, size_t n) {
    while (n--) {
        crc ^= *p++;
        for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (crc & 1 ? 0x82f63b78u : 0);
    }
    return crc;
}

/* Directory-record name hash: CRC-32C of the name as UTF-32 (normalized; ASCII only here, folded to lower
   case on case-insensitive volumes), low 22 bits. */
static int name_hash(ApfsVolume *v, const char *name, uint32_t *hash) {
    uint32_t crc = 0xffffffff;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) {
        if (*p >= 0x80) return -1;
        unsigned ch = *p;
        if ((v->incompat & APFS_INCOMPAT_CASE_INSENSITIVE) && ch >= 'A' && ch <= 'Z') ch += 32;
        uint8_t u[4] = {(uint8_t)ch, 0, 0, 0};
        crc = crc32c(crc, u, 4);
    }
    *hash = crc & 0x3fffff;
    return 0;
}

static WTree fs_wtree(ApfsVolume *v) {
    v->fs_written = 1;
    v->resealed = 0; /* a write after a reseal breaks it again */
    uint8_t b[65536];
    Tree rt = {v->c, v->root_tree, !v->root_physical, v->omap_root, 0, 0, NULL, NULL, 0};
    uint16_t flags = tree_node(&rt, v->root_tree, b) ? 0 : rd16(b + 32);
    WTree t = {v->c, v, &v->root_tree, !v->root_physical, v->omap_root, 0, 0, raw_fs, v->snap_xid_max,
               OBJECT_TYPE_BTREE_NODE, 0xe /* FSTREE */, (flags & BTNODE_NOHEADER) != 0, (flags & BTNODE_HASHED) != 0};
    return t;
}

static int dir_key(ApfsVolume *v, uint64_t parent, const char *name, uint8_t *k, uint16_t *kl) {
    size_t n = strlen(name) + 1;
    if (n > 255) return -1;
    wr64(k, parent | (uint64_t)APFS_TYPE_DIR_REC << OBJ_TYPE_SHIFT);
    if (v->hashed_names) {
        uint32_t h;
        if (name_hash(v, name, &h)) return -1;
        wr32(k + 8, (uint32_t)n | h << 10);
        memcpy(k + 12, name, n);
        *kl = (uint16_t)(12 + n);
    } else {
        wr16(k + 8, (uint16_t)n);
        memcpy(k + 10, name, n);
        *kl = (uint16_t)(10 + n);
    }
    return 0;
}

/* j_inode_val_t (92 bytes), then xfields: the name (as Apple writes it) and, for files, the data stream. */
static uint16_t inode_val(uint8_t *v, uint64_t parent, uint64_t id, uint16_t mode, uint32_t uid, uint32_t gid, int32_t links,
                          int file, uint64_t size, uint64_t alloced, const char *name) {
    memset(v, 0, 512);
    uint64_t t = now_ns();
    wr64(v, parent);
    wr64(v + 8, id);
    wr64(v + 16, t); wr64(v + 24, t); wr64(v + 32, t); wr64(v + 40, t);
    wr64(v + 48, 0x8000);            /* INODE_NO_RSRC_FORK */
    wr32(v + 56, (uint32_t)links);
    wr32(v + 72, uid);
    wr32(v + 76, gid);
    wr16(v + 80, mode);
    uint8_t *x = v + 92;
    uint16_t nlen = name ? (uint16_t)(strlen(name) + 1) : 0, n = 0, data = 0;
    uint8_t *hdr = x + 4;
    int fields = (nlen ? 1 : 0) + (file ? 1 : 0);
    uint8_t *d = x + 4 + 4 * fields;
    if (nlen) {
        hdr[0] = 4 /* INO_EXT_TYPE_NAME */; hdr[1] = 0x02 /* XF_DO_NOT_COPY */; wr16(hdr + 2, nlen);
        memcpy(d, name, nlen);
        d += (nlen + 7) & ~7; data += (nlen + 7) & ~7; hdr += 4; n++;
    }
    if (file) {
        hdr[0] = INO_EXT_TYPE_DSTREAM; hdr[1] = 0x20 /* XF_SYSTEM_FIELD */; wr16(hdr + 2, 40);
        wr64(d, size); wr64(d + 8, alloced); wr64(d + 24, size); /* total_bytes_written */
        d += 40; data += 40; n++;
    }
    if (!n) return 92;
    wr16(x, n);
    wr16(x + 2, data);
    return (uint16_t)(92 + 4 + 4 * n + data);
}

static int inode_put(ApfsVolume *v, const uint8_t *val, uint16_t vl, uint64_t id, int replace) {
    WTree t = fs_wtree(v);
    uint8_t k[8];
    wr64(k, id | (uint64_t)APFS_TYPE_INODE << OBJ_TYPE_SHIFT);
    return winsert(&t, k, 8, val, vl, replace);
}

/* The raw inode record, to change. */
typedef struct { uint8_t v[1024]; uint16_t vl; int found; } RawFind;

static int raw_cb(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    (void)k; (void)kl;
    RawFind *f = user;
    if (vl > sizeof f->v) return 1;
    memcpy(f->v, v, vl);
    f->vl = vl;
    f->found = 1;
    return 1;
}

static int inode_raw(ApfsVolume *v, uint64_t id, RawFind *f) {
    memset(f, 0, sizeof *f);
    return fs_records(v, id, APFS_TYPE_INODE, raw_cb, f) || !f->found ? -1 : 0;
}

/* A directory's child count and times, after an entry came or went. */
static int dir_touch(ApfsVolume *v, uint64_t dir, int delta) {
    RawFind f;
    if (inode_raw(v, dir, &f)) return werr(v->c, "no directory %llu", (unsigned long long)dir);
    wr32(f.v + 56, (uint32_t)((int32_t)rd32(f.v + 56) + delta));
    uint64_t t = now_ns();
    wr64(f.v + 24, t); wr64(f.v + 32, t);
    return inode_put(v, f.v, f.vl, dir, 1);
}

typedef struct { const char *name; uint64_t id; uint16_t type; int found; } ChildFind;

static int child_cb(const ApfsDirEntry *e, void *user) {
    ChildFind *f = user;
    if (strcmp(e->name, f->name)) return 0;
    f->id = e->id; f->type = e->type; f->found = 1;
    return 1;
}

static int add_entry(ApfsVolume *v, uint64_t parent, const char *name, uint64_t id, uint16_t dtype) {
    uint8_t k[300], val[18];
    uint16_t kl;
    if (dir_key(v, parent, name, k, &kl)) return werr(v->c, "name %s: only ASCII names are written", name);
    wr64(val, id);
    wr64(val + 8, now_ns());
    wr16(val + 16, dtype);
    WTree t = fs_wtree(v);
    if (winsert(&t, k, kl, val, 18, 0)) return -1;
    return dir_touch(v, parent, 1);
}

int apfs_mkdir(ApfsVolume *v, uint64_t parent, const char *name, uint16_t mode, uint32_t uid, uint32_t gid, uint64_t *out) {
    ChildFind f = {name, 0, 0, 0};
    if (apfs_readdir(v, parent, child_cb, &f)) return werr(v->c, "no directory %llu", (unsigned long long)parent);
    if (f.found) {
        if (f.type != 4) return werr(v->c, "%s exists and is not a directory", name);
        *out = f.id;
        return 0;
    }
    uint64_t id = v->next_obj_id++;
    uint8_t val[512];
    uint16_t vl = inode_val(val, parent, id, (uint16_t)(0040000 | (mode & 07777)), uid, gid, 0, 0, 0, 0, name);
    if (inode_put(v, val, vl, id, 0) || add_entry(v, parent, name, id, 4)) return -1;
    v->dirs_added++;
    *out = id;
    return 0;
}

/* ---- file data ---- */

typedef struct { uint64_t id; } IdMatch;

static int match_extent(const uint8_t *k, uint16_t kl, void *ctx) {
    (void)kl;
    uint64_t h = rd64(k);
    return (h & OBJ_ID_MASK) == ((IdMatch *)ctx)->id && (uint8_t)(h >> OBJ_TYPE_SHIFT) == APFS_TYPE_FILE_EXTENT;
}

static int match_fext(const uint8_t *k, uint16_t kl, void *ctx) {
    (void)kl;
    return rd64(k) == ((IdMatch *)ctx)->id;
}

static int match_xattr_name(const uint8_t *k, uint16_t kl, void *ctx) {
    const char **names = ctx; /* {id as text pointer hack avoided: names[0] is id, names[1..] names} */
    (void)kl;
    uint64_t h = rd64(k), id = (uint64_t)(uintptr_t)names[0];
    if ((h & OBJ_ID_MASK) != id || (uint8_t)(h >> OBJ_TYPE_SHIFT) != APFS_TYPE_XATTR) return 0;
    for (int i = 1; names[i]; i++)
        if (!strcmp((const char *)k + 10, names[i])) return 1;
    return 0;
}

static WTree fext_wtree(ApfsVolume *v) {
    WTree t = {v->c, v, &v->fext_root, 0, 0, 16, 16, raw_fext, 0, OBJECT_TYPE_BTREE_NODE, 0x1f /* FEXT_TREE */, 0, 0};
    return t;
}

static WTree eref_wtree(ApfsVolume *v) {
    WTree t = {v->c, v, &v->extentref_root, 0, 0, 0, 0, raw_extentref, 0, OBJECT_TYPE_BTREE_NODE, 0xf /* BLOCKREFTREE */, 0, 0};
    return t;
}

/* Writes data to newly allocated blocks and records the extents for stream id. */
static int write_stream(ApfsVolume *v, uint64_t id, const uint8_t *data, size_t len, uint64_t *alloced) {
    ApfsContainer *c = v->c;
    uint64_t blocks = (len + c->bs - 1) / c->bs, done = 0;
    *alloced = 0;
    uint8_t *pad = calloc(1, c->bs);
    while (done < blocks) {
        uint64_t start, got;
        if (alloc_run(c, blocks - done, &start, &got)) { free(pad); return -1; }
        v->alloced += got;
        uint64_t bytes = got * c->bs, have = len - done * c->bs;
        if (have > bytes) have = bytes;
        if (pwrite(c->fd, data + done * c->bs, have, (off_t)(c->base + start * c->bs)) != (ssize_t)have) { free(pad); return werr(c, "write failed"); }
        if (have < bytes) pwrite(c->fd, pad, (size_t)(bytes - have), (off_t)(c->base + start * c->bs + have));
        uint64_t logical = done * c->bs;
        if (v->fext_root) {
            uint8_t k[16], val[16];
            wr64(k, id); wr64(k + 8, logical);
            wr64(val, bytes); wr64(val + 8, start);
            WTree t = fext_wtree(v);
            if (winsert(&t, k, 16, val, 16, 1)) { free(pad); return -1; }
        } else {
            uint8_t k[16], val[24];
            wr64(k, id | (uint64_t)APFS_TYPE_FILE_EXTENT << OBJ_TYPE_SHIFT); wr64(k + 8, logical);
            wr64(val, bytes); wr64(val + 8, start); wr64(val + 16, 0);
            WTree t = fs_wtree(v);
            if (winsert(&t, k, 16, val, 24, 1)) { free(pad); return -1; }
        }
        if (v->extentref_root) {
            uint8_t k[8], val[20];
            wr64(k, start | (uint64_t)2 << OBJ_TYPE_SHIFT);       /* APFS_TYPE_EXTENT */
            wr64(val, got | (uint64_t)1 << 60);                     /* APFS_KIND_NEW */
            wr64(val + 8, id);
            wr32(val + 16, 1);
            WTree t = eref_wtree(v);
            if (winsert(&t, k, 8, val, 20, 1)) { free(pad); return -1; }
        }
        *alloced += bytes;
        done += got;
    }
    free(pad);
    return 0;
}

/* The data stream's own object (its reference count), for a stream with data. */
static int stream_id_put(ApfsVolume *v, uint64_t id, size_t len) {
    if (!len) return 0;
    uint8_t dk[8], dv[4];
    wr64(dk, id | (uint64_t)6 << OBJ_TYPE_SHIFT); /* APFS_TYPE_DSTREAM_ID */
    wr32(dv, 1);
    WTree t = fs_wtree(v);
    return winsert(&t, dk, 8, dv, 4, 1);
}

typedef struct { uint64_t phys[4096], len[4096]; uint32_t n; } Extents;

static int collect_cb(const uint8_t *k, uint16_t kl, const uint8_t *val, uint16_t vl, void *user) {
    (void)k; (void)kl;
    Extents *e = user;
    if (vl < 16 || e->n == 4096) return 0;
    uint64_t phys = rd64(val + 8);
    if (phys) { e->phys[e->n] = phys; e->len[e->n] = rd64(val) & 0x00ffffffffffffffULL; e->n++; }
    return 0;
}

typedef struct { uint64_t id; Extents *e; } FextCollect;

static int fext_collect_cb(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    FextCollect *f = user;
    if (rd64(k) != f->id) return 1;
    return collect_cb(k, kl, v, vl, f->e);
}

static int match_eref(const uint8_t *k, uint16_t kl, void *ctx) {
    (void)kl;
    Extents *e = ctx;
    uint64_t p = rd64(k) & OBJ_ID_MASK;
    for (uint32_t i = 0; i < e->n; i++) if (e->phys[i] == p) return 1;
    return 0;
}

static int match_dstream_id(const uint8_t *k, uint16_t kl, void *ctx) {
    (void)kl;
    uint64_t h = rd64(k);
    return (h & OBJ_ID_MASK) == ((IdMatch *)ctx)->id && (uint8_t)(h >> OBJ_TYPE_SHIFT) == 6;
}

/* A stream's data goes: its extent records, their references, its id object, and its blocks unless a
   snapshot may still read them. */
static int drop_stream(ApfsVolume *v, uint64_t stream) {
    ApfsContainer *c = v->c;
    Extents *e = calloc(1, sizeof *e);
    IdMatch m = {stream};
    uint8_t from[16];
    int r = 0;
    if (v->fext_root) {
        Tree rt = {c, v->fext_root, 0, 0, 16, 16, fext_cmp, NULL, 0};
        FextKey s = {stream};
        FextCollect fc = {stream, e};
        tree_walk(&rt, &s, fext_collect_cb, &fc);
        WTree t = fext_wtree(v);
        wr64(from, stream); wr64(from + 8, 0);
        r = wdelete(&t, from, 16, match_fext, &m) < 0;
    } else {
        fs_records(v, stream, APFS_TYPE_FILE_EXTENT, collect_cb, e);
        WTree t = fs_wtree(v);
        wr64(from, stream | (uint64_t)APFS_TYPE_FILE_EXTENT << OBJ_TYPE_SHIFT); wr64(from + 8, 0);
        r = wdelete(&t, from, 16, match_extent, &m) < 0;
    }
    if (!r) {
        WTree t = fs_wtree(v);
        wr64(from, stream | (uint64_t)6 << OBJ_TYPE_SHIFT);
        r = wdelete(&t, from, 8, match_dstream_id, &m) < 0;
    }
    if (!r && e->n && v->extentref_root) {
        uint64_t lo = e->phys[0];
        for (uint32_t i = 1; i < e->n; i++) if (e->phys[i] < lo) lo = e->phys[i];
        WTree t = eref_wtree(v);
        wr64(from, lo | (uint64_t)2 << OBJ_TYPE_SHIFT);
        r = wdelete(&t, from, 8, match_eref, e) < 0;
    }
    if (!r && !v->snap_xid_max)
        for (uint32_t i = 0; i < e->n && !r; i++) {
            uint64_t blocks = (e->len[i] + c->bs - 1) / c->bs;
            r = free_run(c, e->phys[i], blocks);
            v->alloced -= (int64_t)blocks;
        }
    free(e);
    return r ? -1 : 0;
}

typedef struct { const char *name; int found; uint16_t flags; uint64_t stream; } RawXattr;

static int rawx_cb(const uint8_t *k, uint16_t kl, const uint8_t *val, uint16_t vl, void *user) {
    (void)kl;
    RawXattr *x = user;
    if (strcmp((const char *)k + 10, x->name) || vl < 4) return 0;
    x->found = 1;
    x->flags = rd16(val);
    if (vl >= 12) x->stream = rd64(val + 4);
    return 1;
}

int apfs_write_file(ApfsVolume *v, uint64_t parent, const char *name, const uint8_t *data, size_t len, uint16_t mode,
                    uint32_t uid, uint32_t gid) {
    ChildFind f = {name, 0, 0, 0};
    if (apfs_readdir(v, parent, child_cb, &f)) return werr(v->c, "no directory %llu", (unsigned long long)parent);
    uint64_t id, alloced;
    uint8_t val[512];
    if (f.found) {
        if (f.type != 8) return werr(v->c, "%s exists and is not a file", name);
        id = f.id;
        RawFind rf;
        if (inode_raw(v, id, &rf)) return werr(v->c, "no inode for %s", name);
        uint64_t stream = rd64(rf.v + 8);
        /* the new contents first, in a stream of their own: a failure leaves the old file as it was */
        uint64_t fresh = v->next_obj_id++;
        if (write_stream(v, fresh, data, len, &alloced) || stream_id_put(v, fresh, len)) return -1;
        /* then the old contents go: their extents, references and (unless a snapshot keeps them) blocks,
           and a resource fork kept as its own stream */
        if (drop_stream(v, stream)) return -1;
        RawXattr rx = {"com.apple.ResourceFork", 0, 0, 0};
        fs_records(v, id, APFS_TYPE_XATTR, rawx_cb, &rx);
        if (rx.found && (rx.flags & XATTR_DATA_STREAM) && drop_stream(v, rx.stream)) return -1;
        const char *names[] = {(const char *)(uintptr_t)id, "com.apple.decmpfs", "com.apple.ResourceFork", NULL};
        WTree t = fs_wtree(v);
        uint8_t xk[12];
        wr64(xk, id | (uint64_t)APFS_TYPE_XATTR << OBJ_TYPE_SHIFT); wr16(xk + 8, 0); xk[10] = 0;
        if (wdelete(&t, xk, 11, match_xattr_name, names) < 0) return -1;
        uint16_t vl = inode_val(val, parent, id, (uint16_t)(0100000 | (mode & 07777)), uid, gid, (int32_t)rd32(rf.v + 56), 1, len, alloced, name);
        wr64(val + 8, fresh); /* private_id: the new stream */
        wr64(val + 16, rd64(rf.v + 16)); /* keep the creation time */
        return inode_put(v, val, vl, id, 1);
    }
    id = v->next_obj_id++;
    if (write_stream(v, id, data, len, &alloced)) return -1;
    if (stream_id_put(v, id, len)) return -1;
    uint16_t vl = inode_val(val, parent, id, (uint16_t)(0100000 | (mode & 07777)), uid, gid, 1, 1, len, alloced, name);
    if (inode_put(v, val, vl, id, 0) || add_entry(v, parent, name, id, 8)) return -1;
    v->files_added++;
    return 0;
}

/* An extended attribute kept in the record (up to 3804 bytes). */
int apfs_set_xattr(ApfsVolume *v, uint64_t id, const char *name, const uint8_t *data, size_t len) {
    size_t n = strlen(name) + 1;
    if (len > 3804 || n > 255) return werr(v->c, "attribute too large");
    uint8_t k[300], *val = malloc(4 + len);
    wr64(k, id | (uint64_t)APFS_TYPE_XATTR << OBJ_TYPE_SHIFT);
    wr16(k + 8, (uint16_t)n);
    memcpy(k + 10, name, n);
    wr16(val, XATTR_DATA_EMBEDDED);
    wr16(val + 2, (uint16_t)len);
    memcpy(val + 4, data, len);
    WTree t = fs_wtree(v);
    int r = winsert(&t, k, (uint16_t)(10 + n), val, (uint16_t)(4 + len), 1);
    free(val);
    return r;
}

/* Creates the directories of path (like mkdir -p) and returns the last one's id. */
int apfs_mkdirs(ApfsVolume *v, const char *path, uint16_t mode, uint32_t uid, uint32_t gid, uint64_t *out) {
    uint64_t id = 2;
    char part[256];
    while (*path) {
        while (*path == '/') path++;
        if (!*path) break;
        size_t n = strcspn(path, "/");
        if (n >= sizeof part) return -1;
        memcpy(part, path, n);
        part[n] = 0;
        path += n;
        if (apfs_mkdir(v, id, part, mode, uid, gid, &id)) return -1;
    }
    *out = id;
    return 0;
}

/* ---- more of a file system: links, removal, renames, owners ---- */

int apfs_symlink(ApfsVolume *v, uint64_t parent, const char *name, const char *target, uint32_t uid, uint32_t gid) {
    ChildFind f = {name, 0, 0, 0};
    if (apfs_readdir(v, parent, child_cb, &f)) return werr(v->c, "no directory %llu", (unsigned long long)parent);
    if (f.found) return werr(v->c, "%s exists", name);
    uint64_t id = v->next_obj_id++;
    uint8_t val[512];
    uint16_t vl = inode_val(val, parent, id, 0120755, uid, gid, 1, 0, 0, 0, name);
    if (inode_put(v, val, vl, id, 0)) return -1;
    size_t n = strlen(target) + 1;
    uint8_t k[40], *xv = malloc(4 + n);
    static const char attr[] = "com.apple.fs.symlink";
    wr64(k, id | (uint64_t)APFS_TYPE_XATTR << OBJ_TYPE_SHIFT);
    wr16(k + 8, sizeof attr);
    memcpy(k + 10, attr, sizeof attr);
    wr16(xv, XATTR_DATA_EMBEDDED | 0x4 /* XATTR_FILE_SYSTEM_OWNED */);
    wr16(xv + 2, (uint16_t)n);
    memcpy(xv + 4, target, n);
    WTree t = fs_wtree(v);
    int r = winsert(&t, k, (uint16_t)(10 + sizeof attr), xv, (uint16_t)(4 + n), 0);
    free(xv);
    if (r || add_entry(v, parent, name, id, 10 /* DT_LNK */)) return -1;
    v->symlinks_added++;
    return 0;
}

int apfs_readlink(ApfsVolume *v, uint64_t id, char *out, size_t len) {
    uint8_t *d;
    size_t n;
    if (apfs_xattr(v, id, "com.apple.fs.symlink", &d, &n)) return -1;
    snprintf(out, len, "%.*s", (int)n, (const char *)d);
    free(d);
    return 0;
}

/* Mode and owner (and the change time). uid/gid of (uint32_t)-1 stay. */
int apfs_chmod(ApfsVolume *v, uint64_t id, uint16_t mode, uint32_t uid, uint32_t gid) {
    RawFind f;
    if (inode_raw(v, id, &f)) return werr(v->c, "no inode %llu", (unsigned long long)id);
    wr16(f.v + 80, (uint16_t)((rd16(f.v + 80) & 0170000) | (mode & 07777)));
    if (uid != (uint32_t)-1) wr32(f.v + 72, uid);
    if (gid != (uint32_t)-1) wr32(f.v + 76, gid);
    wr64(f.v + 32, now_ns());
    return inode_put(v, f.v, f.vl, id, 1);
}

typedef struct { uint64_t hdr; const char *name; int hashed; } DrecMatch;

static int match_one_drec(const uint8_t *k, uint16_t kl, void *ctx) {
    (void)kl;
    const DrecMatch *m = ctx;
    return rd64(k) == m->hdr && !strcmp((const char *)k + (m->hashed ? 12 : 10), m->name);
}

static int del_entry(ApfsVolume *v, uint64_t parent, const char *name) {
    uint8_t k[300];
    uint16_t kl;
    if (dir_key(v, parent, name, k, &kl)) return werr(v->c, "bad name");
    DrecMatch m = {rd64(k), name, v->hashed_names};
    WTree t = fs_wtree(v);
    int n = wdelete(&t, k, kl, match_one_drec, &m);
    if (n < 0) return -1;
    if (n != 1) return werr(v->c, "no entry %s", name);
    return dir_touch(v, parent, -1);
}

typedef struct { uint64_t id; } IdOnly;

static int match_inode_records(const uint8_t *k, uint16_t kl, void *ctx) {
    (void)kl;
    uint64_t h = rd64(k);
    uint8_t type = (uint8_t)(h >> OBJ_TYPE_SHIFT);
    return (h & OBJ_ID_MASK) == ((IdOnly *)ctx)->id && (type == APFS_TYPE_INODE || type == APFS_TYPE_XATTR);
}

/* Removes a file, link or empty directory. */
int apfs_unlink(ApfsVolume *v, uint64_t parent, const char *name) {
    ChildFind f = {name, 0, 0, 0};
    if (apfs_readdir(v, parent, child_cb, &f)) return werr(v->c, "no directory");
    if (!f.found) return werr(v->c, "no entry %s", name);
    RawFind rf;
    if (inode_raw(v, f.id, &rf)) return werr(v->c, "no inode for %s", name);
    uint16_t mode = rd16(rf.v + 80);
    if ((mode & 0170000) == 0040000 && rd32(rf.v + 56)) return werr(v->c, "%s is not empty", name);
    if (del_entry(v, parent, name)) return -1;
    if ((mode & 0170000) == 0100000 && (int32_t)rd32(rf.v + 56) > 1) { /* other hard links stay */
        wr32(rf.v + 56, rd32(rf.v + 56) - 1);
        return inode_put(v, rf.v, rf.vl, f.id, 1);
    }
    /* the data (its own stream and a resource fork's) and every record of the inode */
    RawXattr rx = {"com.apple.ResourceFork", 0, 0, 0};
    fs_records(v, f.id, APFS_TYPE_XATTR, rawx_cb, &rx);
    if (rx.found && (rx.flags & XATTR_DATA_STREAM) && drop_stream(v, rx.stream)) return -1;
    if ((mode & 0170000) == 0100000 && drop_stream(v, rd64(rf.v + 8))) return -1;
    IdOnly io = {f.id};
    uint8_t from[8];
    wr64(from, f.id | (uint64_t)APFS_TYPE_INODE << OBJ_TYPE_SHIFT);
    WTree t = fs_wtree(v);
    if (wdelete(&t, from, 8, match_inode_records, &io) < 0) return -1;
    if ((mode & 0170000) == 0040000) v->dirs_added--;
    else if ((mode & 0170000) == 0120000) v->symlinks_added--;
    else v->files_added--;
    return 0;
}

/* Moves an entry (any kind) to another name or directory; an existing target is replaced if it is not a
   directory. */
int apfs_rename(ApfsVolume *v, uint64_t from_dir, const char *from, uint64_t to_dir, const char *to) {
    ChildFind f = {from, 0, 0, 0};
    if (apfs_readdir(v, from_dir, child_cb, &f) || !f.found) return werr(v->c, "no entry %s", from);
    ChildFind g = {to, 0, 0, 0};
    apfs_readdir(v, to_dir, child_cb, &g);
    if (g.found) {
        if (g.type == 4) return werr(v->c, "%s is a directory", to);
        if (apfs_unlink(v, to_dir, to)) return -1;
    }
    if (del_entry(v, from_dir, from) || add_entry(v, to_dir, to, f.id, f.type)) return -1;
    RawFind rf;
    if (inode_raw(v, f.id, &rf)) return -1;
    wr64(rf.v, to_dir);
    /* the name xfield, if any, says the new name (rebuilt with the same fields) */
    uint16_t mode = rd16(rf.v + 80);
    uint8_t val[512];
    uint16_t sz;
    const uint8_t *ds = xfield(rf.v + 92, (uint16_t)(rf.vl - 92), INO_EXT_TYPE_DSTREAM, &sz);
    uint64_t size = ds ? rd64(ds) : 0, alloced = ds ? rd64(ds + 8) : 0;
    uint16_t vl = inode_val(val, to_dir, f.id, mode, rd32(rf.v + 72), rd32(rf.v + 76), (int32_t)rd32(rf.v + 56), ds != NULL, size,
                            alloced, to);
    memcpy(val + 8, rf.v + 8, 92 - 8); /* everything else as it was */
    wr64(val, to_dir);
    return inode_put(v, val, vl, f.id, 1);
}

/* ---- conveniences for callers in other languages ---- */

int apfs_child(ApfsVolume *v, uint64_t dir, const char *name, uint64_t *id, uint16_t *type) {
    ChildFind f = {name, 0, 0, 0};
    if (apfs_readdir(v, dir, child_cb, &f) || !f.found) return -1;
    *id = f.id;
    *type = f.type;
    return 0;
}

typedef struct { ApfsDirEntry *e; size_t n, cap; } ListAcc;

static int list_cb(const ApfsDirEntry *e, void *user) {
    ListAcc *a = user;
    if (a->n == a->cap) { a->cap = a->cap ? a->cap * 2 : 64; a->e = realloc(a->e, a->cap * sizeof *a->e); }
    a->e[a->n++] = *e;
    return 0;
}

int apfs_list(ApfsVolume *v, uint64_t dir, ApfsDirEntry **out, size_t *count) {
    ListAcc a = {NULL, 0, 0};
    if (apfs_readdir(v, dir, list_cb, &a)) { free(a.e); return -1; }
    *out = a.e;
    *count = a.n;
    return 0;
}

/* ---- hard links ----
   A file with more than one name keeps a sibling link per name: key {inode | SIBLING_LINK, sibling_id},
   value {parent_id, name_len u16, name}, and a sibling map {sibling_id | SIBLING_MAP} -> {file_id}. The
   directory records name the inode itself. */

static int sibling_put(ApfsVolume *v, uint64_t inode, uint64_t parent, const char *name) {
    uint64_t sib = v->next_obj_id++;
    size_t n = strlen(name) + 1;
    uint8_t k[16], val[300], mk[8], mv[8];
    wr64(k, inode | (uint64_t)5 << OBJ_TYPE_SHIFT);
    wr64(k + 8, sib);
    wr64(val, parent);
    wr16(val + 8, (uint16_t)n);
    memcpy(val + 10, name, n);
    wr64(mk, sib | (uint64_t)12 << OBJ_TYPE_SHIFT);
    wr64(mv, inode);
    WTree t = fs_wtree(v);
    if (winsert(&t, k, 16, val, (uint16_t)(10 + n), 0)) return -1;
    t = fs_wtree(v);
    return winsert(&t, mk, 8, mv, 8, 0);
}

typedef struct { int found; } AnySibling;

static int any_sibling_cb(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    (void)k; (void)kl; (void)v; (void)vl;
    ((AnySibling *)user)->found = 1;
    return 1;
}

/* Another name, in parent, for the file `id`. */
int apfs_link(ApfsVolume *v, uint64_t id, uint64_t parent, const char *name) {
    RawFind f;
    if (inode_raw(v, id, &f)) return werr(v->c, "no inode %llu", (unsigned long long)id);
    if ((rd16(f.v + 80) & 0170000) != 0100000) return werr(v->c, "only files get hard links");
    ChildFind c = {name, 0, 0, 0};
    if (apfs_readdir(v, parent, child_cb, &c)) return werr(v->c, "no directory");
    if (c.found) return werr(v->c, "%s exists", name);
    AnySibling any = {0};
    fs_records(v, id, 5, any_sibling_cb, &any);
    if (!any.found) { /* its first name becomes a sibling too */
        uint16_t sz;
        const uint8_t *nm = xfield(f.v + 92, (uint16_t)(f.vl - 92), 4 /* NAME */, &sz);
        char first[256];
        if (nm) snprintf(first, sizeof first, "%.*s", (int)sz, (const char *)nm);
        else return werr(v->c, "inode %llu has no name to keep", (unsigned long long)id);
        if (sibling_put(v, id, rd64(f.v), first)) return -1;
    }
    if (sibling_put(v, id, parent, name) || add_entry(v, parent, name, id, 8)) return -1;
    if (inode_raw(v, id, &f)) return -1;
    wr32(f.v + 56, rd32(f.v + 56) + 1);
    return inode_put(v, f.v, f.vl, id, 1);
}
