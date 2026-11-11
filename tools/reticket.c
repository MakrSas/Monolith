/* reticket: an AP ticket (IM4M) from Apple's TSS for a build identity whose digests changed after the
   restore (a resealed system: new root_hash and static trust cache), for the same device and boot nonce.
   The request is the one idevicerestore makes in recovery mode, built by libtatsu.

   reticket BUILDMANIFEST.plist BOARDCONFIG ECID_HEX APNONCE_HEX OUT.im4m */
#include <plist/plist.h>
#include <libtatsu/tss.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int unhex(const char *s, unsigned char *out, size_t max) {
    size_t n = strlen(s) / 2;
    if (n > max) return -1;
    for (size_t i = 0; i < n; i++) {
        unsigned v;
        if (sscanf(s + 2 * i, "%2x", &v) != 1) return -1;
        out[i] = (unsigned char)v;
    }
    return (int)n;
}

/* The erase identity for this board, as idevicerestore picks it. */
static plist_t identity_for(plist_t manifest, const char *board) {
    plist_t ids = plist_dict_get_item(manifest, "BuildIdentities");
    for (uint32_t i = 0; i < plist_array_get_size(ids); i++) {
        plist_t id = plist_array_get_item(ids, i);
        plist_t info = plist_dict_get_item(id, "Info");
        char *dc = NULL, *rb = NULL;
        plist_get_string_val(plist_dict_get_item(info, "DeviceClass"), &dc);
        plist_get_string_val(plist_dict_get_item(info, "RestoreBehavior"), &rb);
        int ok = dc && rb && !strcasecmp(dc, board) && !strcmp(rb, "Erase");
        free(dc); free(rb);
        if (ok) return id;
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 6) { fprintf(stderr, "usage: reticket BUILDMANIFEST BOARDCONFIG ECID_HEX APNONCE_HEX OUT.im4m\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    char *buf = malloc(len);
    fread(buf, 1, len, f); fclose(f);
    plist_t manifest = NULL;
    plist_from_memory(buf, (uint32_t)len, &manifest, NULL);
    free(buf);
    plist_t identity = manifest ? identity_for(manifest, argv[2]) : NULL;
    if (!identity) { fprintf(stderr, "no erase identity for %s\n", argv[2]); return 1; }

    unsigned char nonce[64], sep[20];
    int nlen = unhex(argv[4], nonce, sizeof nonce);
    if (nlen <= 0) { fprintf(stderr, "bad nonce\n"); return 1; }
    for (int i = 0; i < 20; i++) sep[i] = (unsigned char[]){0xef, 0xbe, 0xad, 0xde}[i % 4];

    plist_t p = plist_new_dict();
    plist_dict_set_item(p, "ApECID", plist_new_uint(strtoull(argv[3], NULL, 16)));
    plist_dict_set_item(p, "ApNonce", plist_new_data((const char *)nonce, nlen));
    plist_dict_set_item(p, "ApSepNonce", plist_new_data((const char *)sep, 20));
    plist_dict_set_item(p, "ApProductionMode", plist_new_bool(1));
    plist_dict_set_item(p, "ApSecurityMode", plist_new_bool(1));
    plist_dict_set_item(p, "ApSupportsImg4", plist_new_bool(1));
    tss_parameters_add_from_manifest(p, identity, true);

    plist_t req = tss_request_new(NULL);
    if (tss_request_add_common_tags(req, p, NULL) < 0 || tss_request_add_ap_tags(req, p, NULL) < 0 ||
        tss_request_add_ap_img4_tags(req, p) < 0) { fprintf(stderr, "cannot build the request\n"); return 1; }
    plist_t resp = tss_request_send(req, NULL);
    if (!resp) { fprintf(stderr, "TSS refused or did not answer\n"); return 1; }
    char *ticket = NULL; uint64_t tlen = 0;
    plist_get_data_val(plist_dict_get_item(resp, "ApImg4Ticket"), &ticket, &tlen);
    if (!ticket || !tlen) { fprintf(stderr, "no ApImg4Ticket in the answer\n"); return 1; }
    f = fopen(argv[5], "wb");
    fwrite(ticket, 1, tlen, f); fclose(f);
    printf("ticket: %llu bytes\n", (unsigned long long)tlen);
    return 0;
}
