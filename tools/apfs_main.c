/* apfs: look into an APFS image without mounting it (apfs/apfs.c).
   apfs IMAGE                      the volumes
   apfs IMAGE VOL ls [PATH]        a directory
   apfs IMAGE VOL cat PATH > F     a file
   apfs IMAGE VOL find             every path, with sizes (a whole-volume read test)
   apfs IMAGE VOL mkdir PATH       writes: directories (like mkdir -p)
   apfs IMAGE VOL put FILE PATH [MODE]   a file from this machine into the image (created or replaced) */
#include "apfs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { ApfsVolume *v; char path[4096]; unsigned long files, dirs, bytes, errors; int ls; } Walk;

static int ls_cb(const ApfsDirEntry *e, void *user) {
    Walk *w = user;
    ApfsInode ino;
    int ok = apfs_inode(w->v, e->id, &ino) == 0;
    printf("%06o %5u %5u %12llu %s\n", ok ? ino.mode : 0, ok ? ino.uid : 0, ok ? ino.gid : 0,
           ok ? (unsigned long long)ino.size : 0ULL, e->name);
    return 0;
}

static int find_cb(const ApfsDirEntry *e, void *user) {
    Walk *w = user;
    size_t n = strlen(w->path);
    snprintf(w->path + n, sizeof w->path - n, "/%s", e->name);
    ApfsInode ino;
    if (apfs_inode(w->v, e->id, &ino)) { printf("! %s: no inode\n", w->path); w->errors++; }
    else if (e->type == 4 /* DT_DIR */) { w->dirs++; apfs_readdir(w->v, e->id, find_cb, w); }
    else if (e->type == 8 /* DT_REG */) {
        uint8_t *d; size_t len;
        w->files++;
        if (apfs_read_file(w->v, &ino, &d, &len)) { printf("! %s: unreadable%s\n", w->path, ino.compressed ? " (compressed)" : ""); w->errors++; }
        else { w->bytes += len; free(d); }
    }
    w->path[n] = 0;
    return 0;
}

static int snap_cb(const char *name, uint64_t xid, void *user) {
    (void)user;
    printf("%8llu %s\n", (unsigned long long)xid, name);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: apfs IMAGE [VOL ls|cat|find [PATH]]\n"); return 2; }
    char err[256];
    ApfsContainer *c = apfs_open(argv[1], err, sizeof err);
    if (!c) { fprintf(stderr, "apfs: %s\n", err); return 1; }
    if (argc == 2) {
        printf("block size %u, %d volume(s)\n", apfs_block_size(c), apfs_volume_count(c));
        for (int i = 0; i < apfs_volume_count(c); i++) {
            ApfsVolume *v = apfs_volume(c, i);
            printf("%d: %-24s role %#x%s%s\n", i, apfs_volume_name(v), apfs_volume_role(v),
                   apfs_volume_encrypted(v) ? " encrypted" : "", apfs_volume_sealed(v) ? " sealed" : "");
        }
        return 0;
    }
    ApfsVolume *v = apfs_volume(c, atoi(argv[2]));
    if (!v || argc < 4) { fprintf(stderr, "apfs: no such volume\n"); return 1; }
    const char *at = strchr(argv[2], '@'); /* VOL@ the newest snapshot, VOL@NAME that one */
    if (at && apfs_use_snapshot(v, at[1] ? at + 1 : NULL)) { fprintf(stderr, "apfs: no such snapshot\n"); return 1; }
    if (!strcmp(argv[3], "snaps")) return apfs_snapshots(v, snap_cb, NULL) ? 1 : 0;
    if (!strcmp(argv[3], "mkdir") || !strcmp(argv[3], "put")) {
        apfs_close(c);
        c = apfs_open_rw(argv[1], err, sizeof err);
        if (!c) { fprintf(stderr, "apfs: %s\n", err); return 1; }
        v = apfs_volume(c, atoi(argv[2]));
        uint64_t id;
        int r;
        if (!strcmp(argv[3], "mkdir")) {
            r = argc > 4 ? apfs_mkdirs(v, argv[4], 0755, 0, 0, &id) : -1;
        } else {
            if (argc < 6) return 2;
            FILE *f = fopen(argv[4], "rb");
            if (!f) { perror(argv[4]); return 1; }
            fseek(f, 0, SEEK_END);
            long len = ftell(f);
            fseek(f, 0, SEEK_SET);
            uint8_t *d = malloc(len ? (size_t)len : 1);
            fread(d, 1, (size_t)len, f);
            fclose(f);
            char dir[4096];
            snprintf(dir, sizeof dir, "%s", argv[5]);
            char *slash = strrchr(dir, '/');
            const char *name = slash ? slash + 1 : dir;
            if (slash) *slash = 0;
            r = apfs_mkdirs(v, dir, 0755, 0, 0, &id);
            if (!r) r = apfs_write_file(v, id, name, d, (size_t)len, argc > 6 ? (uint16_t)strtol(argv[6], NULL, 8) : 0644, 0, 0);
            free(d);
        }
        if (!r) r = apfs_commit(c);
        if (r) { fprintf(stderr, "apfs: %s\n", apfs_error(c)); return 1; }
        return 0;
    }
    Walk w = {v, "", 0, 0, 0, 0, 0};
    const char *path = argc > 4 ? argv[4] : "/";
    ApfsInode ino;
    if (!strcmp(argv[3], "find")) {
        apfs_readdir(v, 2, find_cb, &w);
        printf("%lu files, %lu directories, %lu bytes read, %lu errors\n", w.files, w.dirs, w.bytes, w.errors);
        return w.errors ? 1 : 0;
    }
    if (apfs_lookup(v, path, &ino)) { fprintf(stderr, "apfs: %s: not found\n", path); return 1; }
    if (!strcmp(argv[3], "ls")) return apfs_readdir(v, ino.id, ls_cb, &w) ? 1 : 0;
    if (!strcmp(argv[3], "cat")) {
        uint8_t *d; size_t len;
        if (apfs_read_file(v, &ino, &d, &len)) { fprintf(stderr, "apfs: %s: unreadable\n", path); return 1; }
        fwrite(d, 1, len, stdout);
        return 0;
    }
    return 2;
}
