/* APFS: reading (and, later, writing) an Apple File System container held in a file, with no mounting,
   no kernel and nothing of Apple's. Written from Apple's public "Apple File System Reference" and checked
   against real images; no Apple code or binary was looked into for it.

   One container image (a raw disk image, or an image wrapped in an IM4P as Apple's ramdisks are). */
#ifndef HENGE_APFS_H
#define HENGE_APFS_H

#include <stddef.h>
#include <stdint.h>

typedef struct ApfsContainer ApfsContainer;
typedef struct ApfsVolume ApfsVolume;

typedef struct ApfsInode {
    uint64_t id, parent;
    uint16_t mode;
    uint32_t uid, gid, bsd_flags;
    int32_t nlink_or_children;
    uint64_t size;       /* logical size of the data stream (or the uncompressed size when compressed) */
    uint64_t dstream_id; /* the extents' owner: private_id */
    int compressed;      /* decmpfs */
    uint64_t mtime;
} ApfsInode;

typedef struct ApfsDirEntry {
    char name[256];
    uint64_t id;
    uint16_t type; /* DT_* */
} ApfsDirEntry;

/* Opens an image read-only. err gets a reason on failure. */
ApfsContainer *apfs_open(const char *path, char *err, size_t errlen);
void apfs_close(ApfsContainer *c);
uint32_t apfs_block_size(ApfsContainer *c);
int apfs_volume_count(ApfsContainer *c);
ApfsVolume *apfs_volume(ApfsContainer *c, int index); /* NULL if absent; owned by the container */
const char *apfs_volume_name(ApfsVolume *v);
uint16_t apfs_volume_role(ApfsVolume *v);
int apfs_volume_encrypted(ApfsVolume *v);
int apfs_volume_sealed(ApfsVolume *v);

/* Snapshots: each one's name and transaction. apfs_use_snapshot makes the volume show one (NULL: the
   newest); a sealed system boots from its snapshot, not from the live tree. */
int apfs_snapshots(ApfsVolume *v, int (*cb)(const char *name, uint64_t xid, void *user), void *user);
int apfs_use_snapshot(ApfsVolume *v, const char *name);

/* The root directory is inode 2. */
int apfs_inode(ApfsVolume *v, uint64_t id, ApfsInode *out);
/* Every entry of a directory: cb returns nonzero to stop. Returns 0, or -1 on error. */
int apfs_readdir(ApfsVolume *v, uint64_t dir, int (*cb)(const ApfsDirEntry *e, void *user), void *user);
/* A path ("/usr/bin/true"), followed through directories (not symlinks). */
int apfs_lookup(ApfsVolume *v, const char *path, ApfsInode *out);
/* A file's contents (decompressed if it is compressed). *out is malloc'd. */
int apfs_read_file(ApfsVolume *v, const ApfsInode *ino, uint8_t **out, size_t *len);
/* An extended attribute's value. */
int apfs_xattr(ApfsVolume *v, uint64_t id, const char *name, uint8_t **out, size_t *len);

/* ---- writing (apfs_write.inc) ----
   Changes are kept in memory until apfs_commit, which writes them and the checkpoint's superblock.
   Names are ASCII. A replaced file's old blocks stay allocated (a snapshot may use them). */
ApfsContainer *apfs_open_rw(const char *path, char *err, size_t errlen);
const char *apfs_error(ApfsContainer *c);
int apfs_mkdir(ApfsVolume *v, uint64_t parent, const char *name, uint16_t mode, uint32_t uid, uint32_t gid, uint64_t *id);
int apfs_mkdirs(ApfsVolume *v, const char *path, uint16_t mode, uint32_t uid, uint32_t gid, uint64_t *id);
/* Creates the file, or replaces an existing one's contents (and drops its compression). */
int apfs_write_file(ApfsVolume *v, uint64_t parent, const char *name, const uint8_t *data, size_t len, uint16_t mode,
                    uint32_t uid, uint32_t gid);
int apfs_set_xattr(ApfsVolume *v, uint64_t id, const char *name, const uint8_t *data, size_t len);
int apfs_symlink(ApfsVolume *v, uint64_t parent, const char *name, const char *target, uint32_t uid, uint32_t gid);
int apfs_readlink(ApfsVolume *v, uint64_t id, char *out, size_t len);
/* Mode bits (07777) and owner; (uint32_t)-1 keeps an id. */
int apfs_chmod(ApfsVolume *v, uint64_t id, uint16_t mode, uint32_t uid, uint32_t gid);
/* A file, symlink or empty directory. */
int apfs_unlink(ApfsVolume *v, uint64_t parent, const char *name);
int apfs_rename(ApfsVolume *v, uint64_t from_dir, const char *from, uint64_t to_dir, const char *to);
int apfs_commit(ApfsContainer *c);
/* One entry of a directory by name, and all of them (*out malloc'd). */
int apfs_child(ApfsVolume *v, uint64_t dir, const char *name, uint64_t *id, uint16_t *type);
int apfs_list(ApfsVolume *v, uint64_t dir, ApfsDirEntry **out, size_t *count);

#endif
