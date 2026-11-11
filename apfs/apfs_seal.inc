/* Sealed volumes (included at the end of apfs.c, after the writer).

   What a seal is, as read off sealed system volumes (no Apple code looked into):
   - the fs tree is physical-or-virtual with headerless nodes (their first 32 bytes zero); an index entry's
     value is the child's oid, relative to the root's, then the SHA-256 of the child's whole block;
   - the volume's root hash (integrity_meta_phys_t, at im_root_hash_offset) is the SHA-256 of the root
     node's block, and it is what the boot chain's root_hash (isys) names;
   - every data stream (a file's, or an xattr's such as a compressed file's resource fork) has FILE_INFO
     records (type 13) keyed {stream id, info = DATA_HASH (1) << 56 | logical byte offset}: the stream in
     chunks of 4 blocks, each value {hashed_len in blocks (u16), hash size (u8), SHA-256 of the chunk
     zero-padded to whole blocks}. */

#include <CommonCrypto/CommonDigest.h>

#define SEAL_CHUNK_BLOCKS 4
#define APFS_TYPE_FILE_INFO 13

typedef struct { uint64_t logical, len, phys; } SealExtent;
typedef struct { SealExtent *e; size_t n, cap; } SealExtents;

static int seal_extent_add(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    (void)kl;
    SealExtents *x = user;
    if (vl < 16) return 0;
    if (x->n == x->cap) {
        size_t cap = x->cap ? x->cap * 2 : 16;
        SealExtent *e = realloc(x->e, cap * sizeof *e);
        if (!e) return -1;
        x->e = e; x->cap = cap;
    }
    x->e[x->n++] = (SealExtent){rd64(k + 8), rd64(v) & 0x00ffffffffffffffULL, rd64(v + 8)};
    return 0;
}

typedef struct { uint64_t id; SealExtents *x; } SealFext;

static int seal_fext_cb(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    SealFext *f = user;
    if (rd64(k) != f->id) return 1;
    return seal_extent_add(k, kl, v, vl, f->x);
}

static int seal_extents(ApfsVolume *v, uint64_t id, SealExtents *x) {
    x->n = 0;
    if (v->fext_root) {
        Tree t = {v->c, v->fext_root, 0, 0, 16, 16, fext_cmp, NULL, 0};
        FextKey s = {id};
        SealFext f = {id, x};
        return tree_walk(&t, &s, seal_fext_cb, &f) < 0 ? -1 : 0;
    }
    return fs_records(v, id, APFS_TYPE_FILE_EXTENT, seal_extent_add, x) < 0 ? -1 : 0;
}

/* Bytes [off, off+len) of a stream, holes as zeros. */
static int seal_read(ApfsVolume *v, const SealExtents *x, uint64_t off, uint64_t len, uint8_t *buf) {
    ApfsContainer *c = v->c;
    memset(buf, 0, len);
    for (size_t i = 0; i < x->n; i++) {
        const SealExtent *e = &x->e[i];
        uint64_t a = e->logical > off ? e->logical : off;
        uint64_t b = e->logical + e->len < off + len ? e->logical + e->len : off + len;
        if (a >= b || !e->phys) continue;
        for (uint64_t p = a; p < b;) {
            uint64_t blk = (p - e->logical) / c->bs, in = (p - e->logical) % c->bs;
            uint64_t n = c->bs - in;
            if (n > b - p) n = b - p;
            uint8_t tmp[65536];
            if (read_block(c, e->phys + blk, tmp)) return -1; /* through the cache: written data counts */
            memcpy(buf + (p - off), tmp + in, n);
            p += n;
        }
    }
    return 0;
}

/* ---- the streams and their FILE_INFO records ---- */

/* What a run of FILE_INFO records hashes: a data stream (id, size), or a compressed file's content
   (inode set: its decompressed data, the records under its resource fork's stream id, or its own). */
typedef struct { uint64_t id, size, inode; } SealStream;
typedef struct { uint64_t id, off; uint16_t blocks; uint8_t hash[32]; } SealInfo;

typedef struct {
    SealStream *s; size_t ns, cs;
    SealInfo *f; size_t nf, cf;
    int err;
    uint64_t compressed; /* the last compressed inode, its target at s[ns - 1] */
} SealScan;

static int seal_scan_cb(const uint8_t *k, uint16_t kl, const uint8_t *val, uint16_t vl, void *user) {
    SealScan *s = user;
    uint64_t h = rd64(k), id = h & OBJ_ID_MASK;
    uint8_t type = (uint8_t)(h >> OBJ_TYPE_SHIFT);
    SealStream add = {0, 0, 0};
    if (type == APFS_TYPE_INODE && vl >= 92) {
        uint16_t size;
        const uint8_t *ds = xfield(val + 92, vl - 92, 8 /* INO_EXT_TYPE_DSTREAM */, &size);
        if (rd32(val + 68) & 0x20 /* UF_COMPRESSED */) add = (SealStream){0, rd64(val + 84), id}; /* records only with a resource fork */
        else if (ds && size >= 8) add = (SealStream){rd64(val + 8), rd64(ds), 0};
        s->compressed = add.inode;
    } else if (type == APFS_TYPE_XATTR && vl >= 4 + 16 && (rd16(val) & 1 /* XATTR_DATA_STREAM */)) {
        if (id == s->compressed && s->ns && rd16(k + 8) == 23 && !memcmp(k + 10, "com.apple.ResourceFork", 23)) {
            s->s[s->ns - 1].id = rd64(val + 4);
            return 0;
        }
        add = (SealStream){rd64(val + 4), rd64(val + 12), 0};
    } else if (type == APFS_TYPE_FILE_INFO && kl >= 16 && vl >= 3 + 32) {
        uint64_t info = rd64(k + 8);
        if (info >> 56 != 1 || val[2] != 32) return 0;
        if (s->nf == s->cf) {
            size_t cap = s->cf ? s->cf * 2 : 1024;
            SealInfo *f = realloc(s->f, cap * sizeof *f);
            if (!f) { s->err = 1; return 1; }
            s->f = f; s->cf = cap;
        }
        SealInfo *f = &s->f[s->nf++];
        f->id = id; f->off = info & 0x00ffffffffffffffULL; f->blocks = rd16(val);
        memcpy(f->hash, val + 3, 32);
        return 0;
    }
    if (!add.id && !add.inode) return 0;
    if (s->ns == s->cs) {
        size_t cap = s->cs ? s->cs * 2 : 1024;
        SealStream *n = realloc(s->s, cap * sizeof *n);
        if (!n) { s->err = 1; return 1; }
        s->s = n; s->cs = cap;
    }
    s->s[s->ns++] = add;
    return 0;
}

static int seal_cmp_stream(const void *a, const void *b) {
    uint64_t x = ((const SealStream *)a)->id, y = ((const SealStream *)b)->id;
    return x < y ? -1 : x > y;
}
static int seal_cmp_info(const void *a, const void *b) {
    const SealInfo *x = a, *y = b;
    if (x->id != y->id) return x->id < y->id ? -1 : 1;
    return x->off < y->off ? -1 : x->off > y->off;
}

/* A stream's expected records. */
static int seal_stream_infos(ApfsVolume *v, const SealStream *st, SealExtents *x, SealInfo **out, size_t *n) {
    ApfsContainer *c = v->c;
    uint64_t chunk = (uint64_t)SEAL_CHUNK_BLOCKS * c->bs;
    uint8_t *whole = NULL;
    uint64_t size = st->size;
    if (st->inode) {
        ApfsInode ino;
        size_t len;
        if (apfs_inode(v, st->inode, &ino) || apfs_read_file(v, &ino, &whole, &len)) return -1;
        size = len;
    } else if (size && seal_extents(v, st->id, x)) {
        return -1;
    }
    size_t count = (size_t)((size + chunk - 1) / chunk);
    *n = count;
    *out = NULL;
    if (!count) { free(whole); return 0; }
    SealInfo *r = calloc(count, sizeof *r);
    uint8_t *buf = malloc(chunk);
    if (!r || !buf) { free(r); free(buf); free(whole); return -1; }
    for (size_t i = 0; i < count; i++) {
        uint64_t off = i * chunk, len = size - off < chunk ? size - off : chunk;
        uint64_t blocks = (len + c->bs - 1) / c->bs;
        if (whole) memcpy(buf, whole + off, len);
        else if (seal_read(v, x, off, len, buf)) { free(r); free(buf); return -1; }
        if (blocks * c->bs > len) memset(buf + len, 0, blocks * c->bs - len);
        r[i].id = st->id; r[i].off = off; r[i].blocks = (uint16_t)blocks;
        CC_SHA256(buf, (CC_LONG)(blocks * c->bs), r[i].hash);
    }
    free(buf);
    free(whole);
    *out = r;
    return 0;
}

/* ---- node hashes ---- */

typedef struct { int verify; uint64_t bad; } SealNodes;

/* The hash of a node's block, after its children's: verifying, compares what its index entries hold;
   resealing, writes them (wt: the fs tree for writing). */
static int seal_node(ApfsVolume *v, WTree *wt, const Tree *t, uint64_t oid, uint8_t hash[32], SealNodes *sn, int depth) {
    ApfsContainer *c = v->c;
    if (depth > 16) return -1;
    uint8_t *b = malloc(c->bs);
    if (!b || tree_node(t, oid, b)) { free(b); return -1; }
    Node n;
    node_parse(c, b, &n);
    if (!(n.flags & BTNODE_HASHED)) { free(b); return -1; }
    if (n.level) {
        for (uint32_t i = 0; i < n.nkeys; i++) {
            const uint8_t *k, *val; uint16_t kl, vl;
            node_entry(&n, i, t->fixed_k, t->fixed_v, &k, &kl, &val, &vl);
            if (vl < 40) { free(b); return -1; }
            uint8_t h[32];
            if (seal_node(v, wt, t, rd64(val) + t->root, h, sn, depth + 1)) { free(b); return -1; }
            if (memcmp(val + 8, h, 32)) {
                sn->bad++;
                if (!sn->verify) memcpy((uint8_t *)val + 8, h, 32);
            }
        }
        if (!sn->verify) {
            /* the node as it will be written: into the cache, its header zero (headerless) */
            uint8_t *w = wnode(wt, oid);
            if (!w) { free(b); return -1; }
            memcpy(w, b, c->bs);
            memset(w, 0, 32);
            memcpy(b, w, c->bs);
        }
    }
    memset(b, 0, 32);
    CC_SHA256(b, (CC_LONG)c->bs, hash);
    free(b);
    return 0;
}

static int seal_im(ApfsVolume *v, uint64_t *paddr, uint8_t *im) {
    ApfsContainer *c = v->c;
    uint8_t *sb = malloc(c->bs);
    if (!sb || read_block(c, v->sb_paddr, sb)) { free(sb); return -1; }
    uint64_t oid = rd64(sb + 1024);
    free(sb);
    if (!oid || omap_lookup(c, v->omap_root, oid, c->xid, paddr)) return -1;
    return read_block(c, *paddr, im);
}

/* ---- the API ---- */

/* Checks a sealed volume's seal: every FILE_INFO record and node hash against the data, and the root hash.
   Returns 0 when the seal holds; counts of what does not go to *bad_info / *bad_nodes. */
int apfs_seal_check(ApfsVolume *v, uint8_t root_hash[32], uint64_t *bad_info, uint64_t *bad_nodes, uint64_t *streams) {
    ApfsContainer *c = v->c;
    if (!(v->incompat & APFS_INCOMPAT_SEALED_VOLUME)) return -1;
    SealScan s = {0};
    Tree t = fs_tree(v);
    if (tree_walk(&t, NULL, seal_scan_cb, &s) < 0 || s.err) { free(s.s); free(s.f); return -1; }
    qsort(s.s, s.ns, sizeof *s.s, seal_cmp_stream);
    qsort(s.f, s.nf, sizeof *s.f, seal_cmp_info);
    SealExtents x = {0};
    uint64_t bad = 0;
    size_t fi = 0;
    for (size_t i = 0; i < s.ns; i++) {
        if (!s.s[i].id || (i && s.s[i].id == s.s[i - 1].id)) continue; /* inline-compressed: the xattr is in the tree */
        SealInfo *want; size_t n;
        if (seal_stream_infos(v, &s.s[i], &x, &want, &n)) { bad++; continue; }
        while (fi < s.nf && s.f[fi].id < s.s[i].id) { bad++; fi++; } /* records of no stream */
        for (size_t j = 0; j < n; j++) {
            if (fi < s.nf && s.f[fi].id == want[j].id && s.f[fi].off == want[j].off) {
                if (s.f[fi].blocks != want[j].blocks || memcmp(s.f[fi].hash, want[j].hash, 32)) {
                    if (debug_on() && bad < 20)
                        fprintf(stderr, "apfs: seal: stream %#llx at %llu differs\n", (unsigned long long)want[j].id, (unsigned long long)want[j].off);
                    bad++;
                }
                fi++;
            } else {
                if (debug_on() && bad < 20)
                    fprintf(stderr, "apfs: seal: stream %#llx at %llu has no record\n", (unsigned long long)want[j].id, (unsigned long long)want[j].off);
                bad++;
            }
        }
        while (fi < s.nf && s.f[fi].id == s.s[i].id) { bad++; fi++; }
        free(want);
    }
    bad += s.nf - fi;
    if (streams) *streams = s.ns;
    free(x.e); free(s.s); free(s.f);
    if (bad_info) *bad_info = bad;

    SealNodes sn = {1, 0};
    uint8_t h[32];
    if (seal_node(v, NULL, &t, t.root, h, &sn, 0)) return -1;
    if (bad_nodes) *bad_nodes = sn.bad;
    if (root_hash) memcpy(root_hash, h, 32);
    uint8_t *im = malloc(c->bs);
    uint64_t p;
    int r = -1;
    if (im && !seal_im(v, &p, im)) {
        uint32_t off = rd32(im + 44);
        r = (off + 32 <= c->bs && !memcmp(im + off, h, 32) && !(rd32(im + 36) & 1) && !bad && !sn.bad) ? 0 : 1;
    }
    free(im);
    return r;
}
