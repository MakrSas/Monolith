/* APFS reading. Layout and field offsets are those of Apple's "Apple File System Reference"; see apfs.h. */
#include "apfs.h"

#include <compression.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define OBJ_TYPE_MASK 0x0000ffffu
#define OBJECT_TYPE_NX_SUPERBLOCK 0x1
#define OBJECT_TYPE_BTREE 0x2
#define OBJECT_TYPE_BTREE_NODE 0x3
#define OBJECT_TYPE_OMAP 0xb
#define OBJECT_TYPE_FS 0xd

#define BTNODE_ROOT 0x1
#define BTNODE_LEAF 0x2
#define BTNODE_FIXED_KV_SIZE 0x4
#define BTNODE_HASHED 0x8
#define BTNODE_NOHEADER 0x10
#define BTREE_INFO_SIZE 40

#define APFS_TYPE_INODE 3
#define APFS_TYPE_XATTR 4
#define APFS_TYPE_FILE_EXTENT 8
#define APFS_TYPE_DIR_REC 9
#define OBJ_ID_MASK 0x0fffffffffffffffULL
#define OBJ_TYPE_SHIFT 60

#define APFS_INCOMPAT_CASE_INSENSITIVE 0x1
#define APFS_INCOMPAT_NORMALIZATION_INSENSITIVE 0x8
#define APFS_INCOMPAT_SEALED_VOLUME 0x20
#define APFS_FS_UNENCRYPTED 0x1

#define INO_EXT_TYPE_DSTREAM 8
#define XATTR_DATA_STREAM 0x1
#define XATTR_DATA_EMBEDDED 0x2

#define MAX_VOLUMES 100

static inline uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static inline uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32; }

struct ApfsVolume {
    ApfsContainer *c;
    uint64_t oid;                         /* virtual, in the container's omap */
    uint64_t omap_root;                   /* physical: the volume's omap B-tree root */
    uint64_t root_tree;                   /* the file-system tree (virtual unless root_physical) */
    int root_physical;
    uint64_t fext_root;                   /* sealed volumes: the file-extent tree (physical), 0 if none */
    uint64_t incompat, fs_flags;
    uint16_t role;
    char name[257];
    int hashed_names;                     /* directory records keyed by name hash */
    uint64_t xid;                         /* the state looked at: the container's, or a snapshot's */
    uint64_t snap_meta;                   /* physical: the snapshot metadata tree */
    /* writing */
    uint64_t sb_paddr, next_obj_id, extentref_root, snap_xid_max;
    int64_t files_added, dirs_added, symlinks_added;
    int64_t alloced;
    int sb_dirty, counted, fs_written;
};

struct ApfsContainer {
    int fd;
    uint64_t base;      /* byte offset of block 0 in the file (an IM4P's payload) */
    uint32_t bs;
    uint64_t blocks;
    uint64_t xid;
    uint64_t omap_root; /* physical */
    int nvol;
    ApfsVolume vol[MAX_VOLUMES];
    struct Writer *w;   /* opened for writing */
};

static int debug_on(void) {
    static int on = -1;
    if (on < 0) on = getenv("APFS_DEBUG") != NULL;
    return on;
}

/* ---- blocks ---- */

static uint64_t fletcher64(const uint8_t *p, size_t len) {
    uint64_t sum1 = 0, sum2 = 0;
    for (size_t i = 8; i < len; i += 4) {
        sum1 = (sum1 + rd32(p + i)) % 0xffffffffULL;
        sum2 = (sum2 + sum1) % 0xffffffffULL;
    }
    uint64_t c1 = 0xffffffffULL - (sum1 + sum2) % 0xffffffffULL;
    uint64_t c2 = 0xffffffffULL - (sum1 + c1) % 0xffffffffULL;
    return c2 << 32 | c1;
}

static int cached_block(ApfsContainer *c, uint64_t paddr, uint8_t *buf);

static int read_block(ApfsContainer *c, uint64_t paddr, uint8_t *buf) {
    if (paddr >= c->blocks) return -1;
    if (c->w && cached_block(c, paddr, buf)) return 0;
    return pread(c->fd, buf, c->bs, (off_t)(c->base + paddr * c->bs)) == (ssize_t)c->bs ? 0 : -1;
}

static int read_object(ApfsContainer *c, uint64_t paddr, uint8_t *buf) {
    if (c->w && cached_block(c, paddr, buf)) return 0; /* changed in this commit: its checksum comes later */
    if (read_block(c, paddr, buf)) return -1;
    return rd64(buf) == fletcher64(buf, c->bs) ? 0 : -1;
}

/* ---- B-trees ---- */

/* A key comparison for one tree: <0, 0, >0 of the search key against a node's key. */
typedef int (*KeyCmp)(const void *search, const uint8_t *key, uint16_t klen, void *ctx);

typedef struct Node {
    uint8_t *b;
    uint16_t flags, level;
    uint32_t nkeys;
    const uint8_t *toc, *keys, *vals_end;
} Node;

static void node_parse(ApfsContainer *c, uint8_t *b, Node *n) {
    n->b = b;
    n->flags = rd16(b + 32);
    n->level = rd16(b + 34);
    n->nkeys = rd32(b + 36);
    uint16_t toff = rd16(b + 40), tlen = rd16(b + 42);
    n->toc = b + 56 + toff;
    n->keys = b + 56 + toff + tlen;
    n->vals_end = b + c->bs - ((n->flags & BTNODE_ROOT) ? BTREE_INFO_SIZE : 0);
}

/* Entry i's key and value (fixed sizes come from the tree's info: omap 16/16, or 16 key + 8 child in
   non-leaf omap nodes). */
static void node_entry(const Node *n, uint32_t i, uint16_t fixed_k, uint16_t fixed_v, const uint8_t **k, uint16_t *kl,
                       const uint8_t **v, uint16_t *vl) {
    if (n->flags & BTNODE_FIXED_KV_SIZE) {
        const uint8_t *e = n->toc + i * 4;
        *k = n->keys + rd16(e);
        *kl = fixed_k;
        uint16_t vo = rd16(e + 2);
        *v = vo == 0xffff ? NULL : n->vals_end - vo;
        *vl = n->level ? 8 : fixed_v;
    } else {
        const uint8_t *e = n->toc + i * 8;
        *k = n->keys + rd16(e);
        *kl = rd16(e + 2);
        uint16_t vo = rd16(e + 4);
        *v = vo == 0xffff ? NULL : n->vals_end - vo;
        *vl = rd16(e + 6);
    }
}

/* Resolves a child pointer: physical trees give the block, virtual ones go through an omap. */
typedef struct Tree {
    ApfsContainer *c;
    uint64_t root;      /* oid of the root node */
    int virtual_;       /* children are virtual oids, resolved in omap_root */
    uint64_t omap_root;
    uint16_t fixed_k, fixed_v;
    KeyCmp cmp;
    void *ctx;
    uint64_t xid;       /* omap lookups see this state */
} Tree;

static int omap_lookup(ApfsContainer *c, uint64_t omap_root, uint64_t oid, uint64_t xid, uint64_t *paddr);

static int tree_node(const Tree *t, uint64_t oid, uint8_t *buf) {
    uint64_t p = oid;
    if (t->virtual_ && omap_lookup(t->c, t->omap_root, oid, t->xid ? t->xid : t->c->xid, &p)) {
        if (debug_on()) fprintf(stderr, "apfs: no mapping for virtual node %llu\n", (unsigned long long)oid);
        return -1;
    }
    int r = read_object(t->c, p, buf);
    if (r && !read_block(t->c, p, buf) && (rd16(buf + 32) & BTNODE_NOHEADER)) {
        /* A sealed volume's tree: headerless nodes (no checksum); their hashes are in the parent. */
        static const uint8_t zero[32];
        if (!memcmp(buf, zero, 32)) r = 0;
    }
    if (debug_on())
        fprintf(stderr, "apfs: node %llu at %llu: %s, flags %#x level %u keys %u\n", (unsigned long long)oid, (unsigned long long)p,
                r ? "bad checksum" : "ok", rd16(buf + 32), rd16(buf + 34), rd32(buf + 36));
    return r;
}

/* Walks every leaf entry whose key compares >= search (lower bound) in order, while cb returns 0.
   cb returns 1 to stop. With search NULL, from the first entry. */
typedef int (*EntryCb)(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user);

static int tree_walk_node(const Tree *t, uint64_t oid, const void *search, EntryCb cb, void *user, int depth) {
    if (depth > 16) return -1;
    uint8_t *buf = malloc(t->c->bs);
    if (!buf || tree_node(t, oid, buf)) { free(buf); return -1; }
    Node n;
    node_parse(t->c, buf, &n);
    int r = 0;
    if (n.level == 0) {
        for (uint32_t i = 0; i < n.nkeys && !r; i++) {
            const uint8_t *k, *v; uint16_t kl, vl;
            node_entry(&n, i, t->fixed_k, t->fixed_v, &k, &kl, &v, &vl);
            if (search && t->cmp(search, k, kl, t->ctx) > 0) continue;
            r = cb(k, kl, v, vl, user);
        }
    } else {
        /* children whose range may hold keys >= search: from the last child with key <= search */
        uint32_t start = 0;
        if (search)
            for (uint32_t i = 0; i < n.nkeys; i++) {
                const uint8_t *k, *v; uint16_t kl, vl;
                node_entry(&n, i, t->fixed_k, t->fixed_v, &k, &kl, &v, &vl);
                /* strictly after: a child starting with an equal (partial) key may have equal ones before it */
                if (t->cmp(search, k, kl, t->ctx) > 0) start = i; else break;
            }
        for (uint32_t i = start; i < n.nkeys && !r; i++) {
            const uint8_t *k, *v; uint16_t kl, vl;
            node_entry(&n, i, t->fixed_k, t->fixed_v, &k, &kl, &v, &vl);
            /* hashed (sealed) trees store children relative to the root's oid */
            uint64_t child = rd64(v) + ((n.flags & BTNODE_HASHED) ? t->root : 0);
            r = tree_walk_node(t, child, search, cb, user, depth + 1);
        }
    }
    free(buf);
    return r;
}

static int tree_walk(const Tree *t, const void *search, EntryCb cb, void *user) {
    int r = tree_walk_node(t, t->root, search, cb, user, 0);
    return r < 0 ? -1 : 0;
}

/* ---- the object map ---- */

typedef struct { uint64_t oid, xid; } OmapKey;

static int omap_cmp(const void *s, const uint8_t *k, uint16_t kl, void *ctx) {
    (void)kl; (void)ctx;
    const OmapKey *a = s;
    uint64_t oid = rd64(k), xid = rd64(k + 8);
    if (a->oid != oid) return a->oid < oid ? -1 : 1;
    if (a->xid != xid) return a->xid < xid ? -1 : 1;
    return 0;
}

typedef struct { uint64_t oid, xid, best_xid, paddr; int found; } OmapFind;

static int omap_find_cb(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    (void)kl; (void)vl;
    OmapFind *f = user;
    uint64_t oid = rd64(k), xid = rd64(k + 8);
    if (oid != f->oid) {
        if (debug_on()) fprintf(stderr, "apfs: omap lookup %llu stops at %llu (xid %llu)\n", (unsigned long long)f->oid,
                                (unsigned long long)oid, (unsigned long long)xid);
        return 1;
    }
    if (xid <= f->xid && v && (!f->found || xid >= f->best_xid)) {
        f->found = 1;
        f->best_xid = xid;
        f->paddr = rd64(v + 8);
    }
    return 0;
}

static int omap_lookup(ApfsContainer *c, uint64_t omap_root, uint64_t oid, uint64_t xid, uint64_t *paddr) {
    Tree t = {c, omap_root, 0, 0, 16, 16, omap_cmp, NULL, 0};
    OmapKey s = {oid, 0};
    OmapFind f = {oid, xid, 0, 0, 0};
    if (tree_walk(&t, &s, omap_find_cb, &f) || !f.found) return -1;
    *paddr = f.paddr;
    return 0;
}

/* The omap object (physical) → its tree's root. */
static int omap_root_of(ApfsContainer *c, uint64_t omap_oid, uint64_t *root) {
    uint8_t *b = malloc(c->bs);
    int r = -1;
    if (b && !read_object(c, omap_oid, b) && (rd32(b + 24) & OBJ_TYPE_MASK) == OBJECT_TYPE_OMAP) {
        *root = rd64(b + 48);
        r = 0;
    }
    free(b);
    return r;
}

/* ---- the container ---- */

static void set_err(char *err, size_t errlen, const char *fmt, ...) {
    if (!err || !errlen) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

/* An IM4P (DER: SEQUENCE { "IM4P", type, description, OCTET STRING payload, ... }): the payload's offset. */
static uint64_t im4p_payload(int fd) {
    uint8_t h[64];
    if (pread(fd, h, sizeof h, 0) != (ssize_t)sizeof h || h[0] != 0x30) return 0;
    size_t i = 1;
    #define DERLEN(len) do { uint8_t b_ = h[i++]; if (b_ & 0x80) { int n_ = b_ & 0x7f; len = 0; while (n_--) len = len << 8 | h[i++]; } else len = b_; } while (0)
    uint64_t len;
    DERLEN(len);
    (void)len;
    for (int field = 0; field < 4 && i < sizeof h - 8; field++) {
        uint8_t tag = h[i++];
        DERLEN(len);
        if (field == 0 && (tag != 0x16 || len != 4 || memcmp(h + i, "IM4P", 4))) return 0;
        if (field == 3) return tag == 0x04 ? i : 0;
        i += len;
    }
    #undef DERLEN
    return 0;
}

/* A GPT disk: the first APFS partition's byte offset (type 7C3457EF-0000-11AA-AA11-00306543ECAC). */
static uint64_t gpt_apfs(int fd) {
    static const uint8_t apfs_type[16] = {0xef, 0x57, 0x34, 0x7c, 0x00, 0x00, 0xaa, 0x11,
                                          0xaa, 0x11, 0x00, 0x30, 0x65, 0x43, 0xec, 0xac};
    for (uint32_t sector = 512; sector <= 4096; sector *= 8) {
        uint8_t h[92];
        if (pread(fd, h, sizeof h, sector) != (ssize_t)sizeof h || memcmp(h, "EFI PART", 8)) continue;
        uint64_t entries = rd64(h + 72);
        uint32_t count = rd32(h + 80), size = rd32(h + 84);
        if (size < 128 || count > 1024) continue;
        uint8_t e[128];
        for (uint32_t i = 0; i < count; i++) {
            if (pread(fd, e, sizeof e, (off_t)(entries * sector + (uint64_t)i * size)) != (ssize_t)sizeof e) break;
            if (!memcmp(e, apfs_type, 16)) return rd64(e + 32) * sector;
        }
    }
    return 0;
}

ApfsContainer *apfs_open(const char *path, char *err, size_t errlen) {
    ApfsContainer *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->fd = open(path, O_RDONLY);
    if (c->fd < 0) { set_err(err, errlen, "cannot open %s", path); free(c); return NULL; }
    uint8_t sb[4096];
    for (int attempt = 0; attempt < 3; attempt++) {
        c->base = attempt == 0 ? 0 : attempt == 1 ? im4p_payload(c->fd) : gpt_apfs(c->fd);
        if (attempt && !c->base) continue;
        if (pread(c->fd, sb, sizeof sb, (off_t)c->base) == (ssize_t)sizeof sb && !memcmp(sb + 32, "NXSB", 4)) goto found;
    }
    set_err(err, errlen, "no APFS container in %s", path);
    apfs_close(c);
    return NULL;
found:
    c->bs = rd32(sb + 36);
    if (c->bs < 4096 || c->bs > 65536) { set_err(err, errlen, "odd block size %u", c->bs); apfs_close(c); return NULL; }
    struct stat st;
    fstat(c->fd, &st);
    c->blocks = rd64(sb + 40);
    uint64_t in_file = ((uint64_t)st.st_size - c->base) / c->bs;
    if (in_file < c->blocks) c->blocks = in_file; /* a ramdisk image may stop before its container's end */
    /* The newest valid superblock in the checkpoint descriptor area. */
    uint32_t desc_blocks = rd32(sb + 104) & 0x7fffffff;
    uint64_t desc_base = rd64(sb + 112);
    uint8_t *b = malloc(c->bs), *best = malloc(c->bs);
    uint64_t best_xid = 0;
    if (!read_object(c, 0, best)) best_xid = rd64(best + 16);
    for (uint32_t i = 0; i < desc_blocks; i++) {
        if (read_object(c, desc_base + i, b)) continue;
        if ((rd32(b + 24) & OBJ_TYPE_MASK) != OBJECT_TYPE_NX_SUPERBLOCK || memcmp(b + 32, "NXSB", 4)) continue;
        if (rd64(b + 16) > best_xid) { best_xid = rd64(b + 16); memcpy(best, b, c->bs); }
    }
    free(b);
    if (!best_xid) { set_err(err, errlen, "no valid superblock"); free(best); apfs_close(c); return NULL; }
    c->xid = best_xid;
    if (omap_root_of(c, rd64(best + 160), &c->omap_root)) {
        set_err(err, errlen, "cannot read the container's object map");
        free(best); apfs_close(c); return NULL;
    }
    uint32_t maxfs = rd32(best + 180);
    if (maxfs > MAX_VOLUMES) maxfs = MAX_VOLUMES;
    uint8_t *vb = malloc(c->bs);
    for (uint32_t i = 0; i < maxfs; i++) {
        uint64_t oid = rd64(best + 184 + 8 * i), p;
        if (!oid) continue;
        if (omap_lookup(c, c->omap_root, oid, c->xid, &p) || read_object(c, p, vb) || memcmp(vb + 32, "APSB", 4)) continue;
        ApfsVolume *v = &c->vol[c->nvol++];
        v->c = c;
        v->oid = oid;
        v->incompat = rd64(vb + 56);
        v->fs_flags = rd64(vb + 264);
        v->root_tree = rd64(vb + 136);
        v->root_physical = (rd32(vb + 116) & 0x40000000) != 0; /* OBJ_PHYSICAL */
        v->fext_root = (v->incompat & APFS_INCOMPAT_SEALED_VOLUME) ? rd64(vb + 1032) : 0;
        v->xid = c->xid;
        v->snap_meta = rd64(vb + 152);
        v->role = rd16(vb + 964);
        memcpy(v->name, vb + 704, 256);
        v->name[256] = 0;
        v->hashed_names = (v->incompat & (APFS_INCOMPAT_CASE_INSENSITIVE | APFS_INCOMPAT_NORMALIZATION_INSENSITIVE)) != 0;
        if (omap_root_of(c, rd64(vb + 128), &v->omap_root)) c->nvol--;
    }
    free(vb);
    free(best);
    return c;
}

static void writer_free(ApfsContainer *c);

void apfs_close(ApfsContainer *c) {
    if (!c) return;
    writer_free(c);
    if (c->fd >= 0) close(c->fd);
    free(c);
}

uint32_t apfs_block_size(ApfsContainer *c) { return c->bs; }
int apfs_volume_count(ApfsContainer *c) { return c->nvol; }
ApfsVolume *apfs_volume(ApfsContainer *c, int i) { return i >= 0 && i < c->nvol ? &c->vol[i] : NULL; }
const char *apfs_volume_name(ApfsVolume *v) { return v->name; }
uint16_t apfs_volume_role(ApfsVolume *v) { return v->role; }
int apfs_volume_encrypted(ApfsVolume *v) { return !(v->fs_flags & APFS_FS_UNENCRYPTED); }
int apfs_volume_sealed(ApfsVolume *v) { return (v->incompat & APFS_INCOMPAT_SEALED_VOLUME) != 0; }

/* ---- the file-system tree ---- */

/* Search key: object id and record type, then (for directory records) a name or its hash. */
typedef struct {
    uint64_t id;
    uint8_t type;
    int with_name; /* compare names too */
    uint32_t hash; /* hashed volumes */
    const char *name;
} FsKey;

static int fs_cmp(const void *s, const uint8_t *k, uint16_t kl, void *ctx) {
    const FsKey *a = s;
    ApfsVolume *v = ctx;
    uint64_t h = rd64(k);
    uint64_t id = h & OBJ_ID_MASK;
    uint8_t type = (uint8_t)(h >> OBJ_TYPE_SHIFT);
    if (a->id != id) return a->id < id ? -1 : 1;
    if (a->type != type) return a->type < type ? -1 : 1;
    if (!a->with_name || type != APFS_TYPE_DIR_REC) return 0;
    if (v->hashed_names) {
        uint32_t hash = rd32(k + 8) >> 10;
        if (a->hash != hash) return a->hash < hash ? -1 : 1;
        return strcmp(a->name, (const char *)k + 12);
    }
    (void)kl;
    return strcmp(a->name, (const char *)k + 10);
}

static Tree fs_tree(ApfsVolume *v) {
    Tree t = {v->c, v->root_tree, !v->root_physical, v->omap_root, 0, 0, fs_cmp, v, v->xid};
    return t;
}

typedef struct { uint64_t id; uint8_t type; EntryCb cb; void *user; } FsWalk;

static int fs_filter(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    FsWalk *w = user;
    uint64_t h = rd64(k);
    if ((h & OBJ_ID_MASK) != w->id || (uint8_t)(h >> OBJ_TYPE_SHIFT) != w->type) return 1;
    return w->cb(k, kl, v, vl, w->user);
}

/* Every record of one type for one object. */
static int fs_records(ApfsVolume *v, uint64_t id, uint8_t type, EntryCb cb, void *user) {
    Tree t = fs_tree(v);
    FsKey s = {id, type, 0, 0, NULL};
    FsWalk w = {id, type, cb, user};
    return tree_walk(&t, &s, fs_filter, &w);
}

/* xfields: the blob after a record's fixed part. */
static const uint8_t *xfield(const uint8_t *x, uint16_t len, uint8_t want, uint16_t *size) {
    if (len < 4) return NULL;
    uint16_t n = rd16(x);
    const uint8_t *hdr = x + 4, *data = x + 4 + 4 * n;
    for (uint16_t i = 0; i < n; i++) {
        uint8_t type = hdr[i * 4];
        uint16_t sz = rd16(hdr + i * 4 + 2);
        if (data + sz > x + len) return NULL;
        if (type == want) { *size = sz; return data; }
        data += (sz + 7) & ~7;
    }
    return NULL;
}

typedef struct { ApfsInode *out; int found; } InodeFind;

static int inode_cb(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    (void)k; (void)kl;
    InodeFind *f = user;
    if (vl < 92) return 1;
    ApfsInode *i = f->out;
    i->parent = rd64(v);
    i->dstream_id = rd64(v + 8);
    i->mtime = rd64(v + 24);
    i->nlink_or_children = (int32_t)rd32(v + 56);
    i->bsd_flags = rd32(v + 68);
    i->uid = rd32(v + 72);
    i->gid = rd32(v + 76);
    i->mode = rd16(v + 80);
    i->compressed = (i->bsd_flags & 0x20) != 0; /* UF_COMPRESSED */
    i->size = 0;
    uint16_t sz;
    const uint8_t *ds = xfield(v + 92, (uint16_t)(vl - 92), INO_EXT_TYPE_DSTREAM, &sz);
    if (ds && sz >= 8) i->size = rd64(ds);
    if (i->compressed) i->size = rd64(v + 84);
    f->found = 1;
    return 1;
}

int apfs_inode(ApfsVolume *v, uint64_t id, ApfsInode *out) {
    memset(out, 0, sizeof *out);
    out->id = id;
    InodeFind f = {out, 0};
    if (fs_records(v, id, APFS_TYPE_INODE, inode_cb, &f) || !f.found) return -1;
    return 0;
}

typedef struct { ApfsVolume *v; int (*cb)(const ApfsDirEntry *, void *); void *user; } DirWalk;

static int dir_cb(const uint8_t *k, uint16_t kl, const uint8_t *val, uint16_t vl, void *user) {
    DirWalk *w = user;
    ApfsDirEntry e;
    memset(&e, 0, sizeof e);
    const char *name;
    size_t nlen;
    if (w->v->hashed_names) { nlen = rd32(k + 8) & 0x3ff; name = (const char *)k + 12; }
    else { nlen = rd16(k + 8); name = (const char *)k + 10; }
    if (nlen > kl) return 1;
    snprintf(e.name, sizeof e.name, "%.*s", (int)nlen, name);
    if (vl < 18) return 0;
    e.id = rd64(val);
    e.type = rd16(val + 16) & 0xf;
    return w->cb(&e, w->user) ? 1 : 0;
}

int apfs_readdir(ApfsVolume *v, uint64_t dir, int (*cb)(const ApfsDirEntry *, void *), void *user) {
    DirWalk w = {v, cb, user};
    return fs_records(v, dir, APFS_TYPE_DIR_REC, dir_cb, &w);
}

typedef struct { const char *name; uint64_t id; int found; } NameFind;

static int name_cb(const ApfsDirEntry *e, void *user) {
    NameFind *f = user;
    if (strcmp(e->name, f->name)) return 0;
    f->id = e->id;
    f->found = 1;
    return 1;
}

int apfs_lookup(ApfsVolume *v, const char *path, ApfsInode *out) {
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
        NameFind f = {part, 0, 0};
        /* A linear scan of the directory: simple and right for both name orders (hashed or not). */
        if (apfs_readdir(v, id, name_cb, &f) || !f.found) return -1;
        id = f.id;
    }
    return apfs_inode(v, id, out);
}

/* ---- data ---- */

typedef struct { ApfsContainer *c; uint8_t *buf; uint64_t size; int err; } ExtentRead;

static int extent_cb(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    (void)kl;
    ExtentRead *r = user;
    if (vl < 16) return 0;
    uint64_t logical = rd64(k + 8);
    uint64_t len = rd64(v) & 0x00ffffffffffffffULL;
    uint64_t phys = rd64(v + 8);
    for (uint64_t off = 0; off < len; off += r->c->bs) {
        if (logical + off >= r->size) break;
        uint64_t n = r->size - (logical + off);
        if (n > r->c->bs) n = r->c->bs;
        if (!phys) { memset(r->buf + logical + off, 0, n); continue; } /* sparse */
        if (pread(r->c->fd, r->buf + logical + off, n, (off_t)(r->c->base + (phys + off / r->c->bs) * r->c->bs)) != (ssize_t)n) {
            r->err = 1;
            return 1;
        }
    }
    return 0;
}

/* Sealed volumes keep extents in their own tree: key {private_id, logical_addr}, value {len_and_flags, phys}. */
typedef struct { uint64_t id; } FextKey;

static int fext_cmp(const void *s, const uint8_t *k, uint16_t kl, void *ctx) {
    (void)kl; (void)ctx;
    uint64_t a = ((const FextKey *)s)->id, id = rd64(k);
    return a == id ? 0 : a < id ? -1 : 1;
}

typedef struct { uint64_t id; ExtentRead *r; } FextWalk;

static int fext_cb(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    FextWalk *w = user;
    if (rd64(k) != w->id) return 1;
    /* the same shape as a file-extent record once the key's header is the id */
    uint8_t key[16];
    memcpy(key, k, 16);
    return extent_cb(key, kl, v, vl, w->r);
}

static int read_stream(ApfsVolume *v, uint64_t stream_id, uint64_t size, uint8_t **out) {
    uint8_t *buf = calloc(1, size ? size : 1);
    if (!buf) return -1;
    ExtentRead r = {v->c, buf, size, 0};
    int e;
    if (v->fext_root) {
        Tree t = {v->c, v->fext_root, 0, 0, 16, 16, fext_cmp, NULL, 0};
        FextKey s = {stream_id};
        FextWalk w = {stream_id, &r};
        e = tree_walk(&t, &s, fext_cb, &w);
    } else {
        e = fs_records(v, stream_id, APFS_TYPE_FILE_EXTENT, extent_cb, &r);
    }
    if (e || r.err) { free(buf); return -1; }
    *out = buf;
    return 0;
}

typedef struct { const char *name; uint8_t **out; size_t *len; ApfsVolume *v; int found, err; } XattrFind;

static int xattr_cb(const uint8_t *k, uint16_t kl, const uint8_t *val, uint16_t vl, void *user) {
    XattrFind *f = user;
    uint16_t nlen = rd16(k + 8);
    if (nlen + 10 > kl || strcmp((const char *)k + 10, f->name)) return 0;
    if (vl < 4) return 1;
    uint16_t flags = rd16(val), dlen = rd16(val + 2);
    f->found = 1;
    if (flags & XATTR_DATA_EMBEDDED) {
        if (4 + dlen > vl) { f->err = 1; return 1; }
        *f->out = malloc(dlen ? dlen : 1);
        memcpy(*f->out, val + 4, dlen);
        *f->len = dlen;
    } else if (flags & XATTR_DATA_STREAM) {
        /* j_xattr_dstream_t: xattr_obj_id u64, then a j_dstream_t whose first field is the size */
        if (vl < 4 + 16) { f->err = 1; return 1; }
        uint64_t id = rd64(val + 4), size = rd64(val + 12);
        if (read_stream(f->v, id, size, f->out)) { f->err = 1; return 1; }
        *f->len = size;
    }
    return 1;
}

int apfs_xattr(ApfsVolume *v, uint64_t id, const char *name, uint8_t **out, size_t *len) {
    XattrFind f = {name, out, len, v, 0, 0};
    if (fs_records(v, id, APFS_TYPE_XATTR, xattr_cb, &f) || !f.found || f.err) return -1;
    return 0;
}

/* decmpfs ("com.apple.decmpfs"): a 16-byte header (magic 'fpmc', type, uncompressed size), then either
   the data itself (inline types) or, for the resource-fork types, a table of chunks in the
   "com.apple.ResourceFork" attribute. Types: 3 zlib inline, 4 zlib fork, 7 LZVN inline, 8 LZVN fork,
   11 LZFSE inline, 12 LZFSE fork, 13 LZBITMAP inline, 14 LZBITMAP fork, 1 stored inline, 9 stored inline
   and 10 stored fork (a 0xcc byte before the data). */
static size_t decode(int algo, const uint8_t *src, size_t slen, uint8_t *dst, size_t dlen) {
    if (algo == 0) { /* zlib (raw-deflate with header) */
        if (slen && (src[0] & 0x0f) == 0x0f) { size_t n = slen - 1 < dlen ? slen - 1 : dlen; memcpy(dst, src + 1, n); return n; }
        uLongf out = dlen;
        return uncompress(dst, &out, src, slen) == Z_OK ? out : 0;
    }
    if (algo == 3) { /* stored: one marker byte, then the data */
        if (!slen) return 0;
        size_t n = slen - 1 < dlen ? slen - 1 : dlen;
        memcpy(dst, src + 1, n);
        return n;
    }
    /* LZVN/LZFSE: a chunk starting 0x06 is stored as it is; LZBITMAP's stored chunks start 0xff */
    if (slen && ((algo != 4 && src[0] == 0x06) || (algo == 4 && src[0] == 0xff))) {
        size_t n = slen - 1 < dlen ? slen - 1 : dlen;
        memcpy(dst, src + 1, n);
        return n;
    }
    compression_algorithm a = algo == 1 ? (compression_algorithm)0x900 /* LZVN */
                              : algo == 4 ? (compression_algorithm)0x702 /* LZBITMAP */ : COMPRESSION_LZFSE;
    return compression_decode_buffer(dst, dlen, src, slen, NULL, a);
}

static int decompress(ApfsVolume *v, const ApfsInode *ino, uint8_t **out, size_t *len) {
    uint8_t *hdr;
    size_t hlen;
    if (apfs_xattr(v, ino->id, "com.apple.decmpfs", &hdr, &hlen) || hlen < 16 || memcmp(hdr, "fpmc", 4)) return -1;
    uint32_t type = rd32(hdr + 4);
    uint64_t size = rd64(hdr + 8);
    uint8_t *dst = malloc(size ? size : 1);
    int algo = (type == 3 || type == 4) ? 0 : (type == 7 || type == 8) ? 1 : (type == 11 || type == 12) ? 2
             : (type == 9 || type == 10) ? 3 : (type == 13 || type == 14) ? 4 : -1;
    int ok = 0;
    if (type == 1) {
        ok = hlen - 16 >= size;
        if (ok) memcpy(dst, hdr + 16, size);
    } else if (algo >= 0 && (type == 3 || type == 7 || type == 9 || type == 11 || type == 13)) {
        ok = decode(algo, hdr + 16, hlen - 16, dst, size) == size;
    } else if (algo >= 0) {
        uint8_t *rf;
        size_t rlen;
        if (!apfs_xattr(v, ino->id, "com.apple.ResourceFork", &rf, &rlen)) {
            uint64_t blocks = (size + 0xffff) / 0x10000, done = 0;
            ok = 1;
            if (algo == 0) {
                /* resource fork: 256-byte header (data offset big-endian at 0), then u32 count and {off,len} */
                if (rlen < 0x104) ok = 0;
                uint32_t data = ok ? (uint32_t)rf[0] << 24 | rf[1] << 16 | rf[2] << 8 | rf[3] : 0;
                const uint8_t *table = rf + data + 4;
                uint32_t count = ok ? rd32(table) : 0;
                for (uint32_t i = 0; ok && i < count && i < blocks; i++) {
                    uint32_t off = rd32(table + 4 + i * 8), clen = rd32(table + 8 + i * 8);
                    if ((size_t)data + 4 + off + clen > rlen) { ok = 0; break; }
                    size_t want = size - done < 0x10000 ? size - done : 0x10000;
                    if (decode(0, table + off, clen, dst + done, want) != want) ok = 0;
                    done += want;
                }
            } else {
                /* LZVN/LZFSE fork: u32 offsets, blocks + 1 of them, from the fork's start */
                for (uint64_t i = 0; ok && i < blocks; i++) {
                    uint32_t a = rd32(rf + i * 4), b = rd32(rf + i * 4 + 4);
                    if (b < a || b > rlen) { ok = 0; break; }
                    size_t want = size - done < 0x10000 ? size - done : 0x10000;
                    if (decode(algo, rf + a, b - a, dst + done, want) != want) ok = 0;
                    done += want;
                }
            }
            free(rf);
        }
    }
    free(hdr);
    if (!ok) { free(dst); return -1; }
    *out = dst;
    *len = size;
    return 0;
}

int apfs_read_file(ApfsVolume *v, const ApfsInode *ino, uint8_t **out, size_t *len) {
    if (ino->compressed) return decompress(v, ino, out, len);
    if (read_stream(v, ino->dstream_id, ino->size, out)) return -1;
    *len = ino->size;
    return 0;
}

/* ---- snapshots ---- */

/* The snapshot metadata tree (physical): key {xid | SNAP_METADATA << 60}, value j_snap_metadata_val_t
   {extentref_tree_oid, sblock_oid, create_time, change_time, inum, extentref_tree_type u32, flags u32,
   name_len u16, name}. Name records (type SNAP_NAME) are skipped. */
typedef struct { int (*cb)(const char *, uint64_t, void *); void *user; } SnapWalk;

static int snap_cmp(const void *s, const uint8_t *k, uint16_t kl, void *ctx) {
    (void)s; (void)k; (void)kl; (void)ctx;
    return -1; /* from the start */
}

static int snap_cb(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    (void)kl;
    SnapWalk *w = user;
    uint64_t h = rd64(k);
    if ((uint8_t)(h >> OBJ_TYPE_SHIFT) != 1 || vl < 50) return 0;
    uint16_t nlen = rd16(v + 48);
    char name[256];
    snprintf(name, sizeof name, "%.*s", nlen > 255 ? 255 : (int)nlen, (const char *)v + 50);
    return w->cb(name, h & OBJ_ID_MASK, w->user);
}

int apfs_snapshots(ApfsVolume *v, int (*cb)(const char *name, uint64_t xid, void *user), void *user) {
    if (!v->snap_meta) return 0;
    Tree t = {v->c, v->snap_meta, 0, 0, 0, 0, snap_cmp, NULL, 0};
    SnapWalk w = {cb, user};
    return tree_walk(&t, NULL, snap_cb, &w);
}

typedef struct { const char *want; uint64_t xid, sblock; } SnapFind;

static int snap_find_cb(const uint8_t *k, uint16_t kl, const uint8_t *v, uint16_t vl, void *user) {
    (void)kl;
    SnapFind *f = user;
    uint64_t h = rd64(k);
    if ((uint8_t)(h >> OBJ_TYPE_SHIFT) != 1 || vl < 50) return 0;
    uint16_t nlen = rd16(v + 48);
    int match = !f->want || (strlen(f->want) + 1 == nlen && !memcmp(v + 50, f->want, nlen - 1));
    if (match && (h & OBJ_ID_MASK) >= f->xid) { f->xid = h & OBJ_ID_MASK; f->sblock = rd64(v + 8); }
    return 0;
}

int apfs_use_snapshot(ApfsVolume *v, const char *name) {
    if (!v->snap_meta) return -1;
    Tree t = {v->c, v->snap_meta, 0, 0, 0, 0, snap_cmp, NULL, 0};
    SnapFind f = {name, 0, 0};
    if (tree_walk(&t, NULL, snap_find_cb, &f) || !f.sblock) return -1;
    uint8_t *vb = malloc(v->c->bs);
    int r = -1;
    if (vb && !read_object(v->c, f.sblock, vb) && !memcmp(vb + 32, "APSB", 4)) {
        v->root_tree = rd64(vb + 136);
        v->root_physical = (rd32(vb + 116) & 0x40000000) != 0;
        uint64_t incompat = rd64(vb + 56);
        v->fext_root = (incompat & APFS_INCOMPAT_SEALED_VOLUME) ? rd64(vb + 1032) : 0;
        v->xid = f.xid;
        r = 0;
    }
    free(vb);
    return r;
}

#include "apfs_write.inc"

static int cached_block(ApfsContainer *c, uint64_t paddr, uint8_t *buf) {
    for (CEnt *e = c->w->bucket[paddr % CACHE_BUCKETS]; e; e = e->next)
        if (paddr >= e->paddr && paddr < e->paddr + e->nblocks && e->paddr == paddr) { memcpy(buf, e->b, c->bs); return 1; }
    return 0;
}

static void writer_free(ApfsContainer *c) {
    Writer *w = c->w;
    if (!w) return;
    for (int i = 0; i < CACHE_BUCKETS; i++)
        for (CEnt *e = w->bucket[i], *n; e; e = n) { n = e->next; free(e->b); free(e); }
    free(w->nx);
    free(w);
    c->w = NULL;
}
