/* The guest's Bonjour services, published on the host's network (HV_NET_PUBLISH=1, or the app's switch).

   Behind the NAT nobody sees the guest's multicast DNS, so a HomePod guest is invisible to the iPhones and
   Macs around. Its announcements (and its answers to the queries we send it) still pass through here: each
   service it offers (PTR + SRV + TXT) is registered with the host's own mDNSResponder under the guest's name,
   type and TXT, at a host port forwarded into the guest. The same port number is tried first, so a port the
   guest names inside a protocol (AirPlay hands some out over its own encrypted channel) still lands right.

   Runs on the network thread, like libslirp: frames are handed over from transmit() (CPU thread). */
#include "mdns_proxy.h"
#include "net_slirp.h"

#include <arpa/inet.h>
#include <dns_sd.h>
#include <libslirp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

#define MAX_SERVICES 48
#define MAX_NAME 256

typedef struct Service {
    int used;
    char instance[MAX_NAME]; /* "HomePod._airplay._tcp.local" */
    char type[MAX_NAME];     /* "_airplay._tcp" */
    char name[MAX_NAME];     /* "HomePod", unescaped */
    int udp;
    uint16_t guest_port, host_port; /* 0 until the SRV came */
    uint8_t txt[1300];
    uint16_t txt_len;
    int have_txt;
    DNSServiceRef ref;
} Service;

static Service services[MAX_SERVICES];
static void note_type(const char *instance_or_type);
static int enabled = -1;
static Slirp *slirp_for_fwd;

int hv_mdns_proxy_enabled(void) {
    if (enabled < 0) {
        const char *e = getenv("HV_NET_PUBLISH");
        enabled = e && *e && *e != '0';
    }
    return enabled;
}

void hv_mdns_proxy_set_enabled(int on) { enabled = on; }

/* A DNS name at off (following compression) as dotted text with the labels' bytes as they are. */
static int read_name(const uint8_t *m, int len, int off, char *out, int cap, int *next) {
    int o = off, jumped = 0, n = 0, hops = 0;
    out[0] = 0;
    while (o < len) {
        uint8_t l = m[o];
        if (l == 0) { o++; break; }
        if ((l & 0xc0) == 0xc0) {
            if (o + 1 >= len || ++hops > 32) return -1;
            if (!jumped && next) *next = o + 2;
            jumped = 1;
            o = ((l & 0x3f) << 8) | m[o + 1];
            continue;
        }
        if (o + 1 + l > len || n + l + 2 >= cap) return -1;
        if (n) out[n++] = '.';
        memcpy(out + n, m + o + 1, l);
        n += l;
        out[n] = 0;
        o += 1 + l;
    }
    if (!jumped && next) *next = o;
    return 0;
}

static Service *find(const char *instance, int create) {
    for (int i = 0; i < MAX_SERVICES; i++)
        if (services[i].used && !strcasecmp(services[i].instance, instance)) return &services[i];
    if (!create) return NULL;
    for (int i = 0; i < MAX_SERVICES; i++)
        if (!services[i].used) {
            memset(&services[i], 0, sizeof services[i]);
            services[i].used = 1;
            snprintf(services[i].instance, MAX_NAME, "%s", instance);
            return &services[i];
        }
    return NULL;
}

/* "HomePod._airplay._tcp.local" → name "HomePod", type "_airplay._tcp". The name may hold dots. */
static int split(Service *s) {
    char *t = strstr(s->instance, "._tcp.local");
    if (!t) t = strstr(s->instance, "._udp.local");
    if (!t) return -1;
    s->udp = t[2] == 'u';
    char *dot = t - 1;
    while (dot > s->instance && *dot != '.') dot--;
    if (dot <= s->instance) return -1;
    snprintf(s->name, MAX_NAME, "%.*s", (int)(dot - s->instance), s->instance);
    snprintf(s->type, MAX_NAME, "%.*s", (int)(t + 5 - dot - 1), dot + 1);
    return 0;
}

static void registered(DNSServiceRef ref, DNSServiceFlags flags, DNSServiceErrorType err, const char *name,
                       const char *type, const char *domain, void *ctx) {
    (void)ref; (void)flags; (void)domain; (void)ctx;
    fprintf(stderr, "hengevm: published %s %s: %d\n", name, type, err);
}

/* AirPlay hands the sender more ports inside its encrypted setup (events, buffered audio, timing, control),
   from the guest's ephemeral range, where its first listeners (49152, 49153: companion-link, pairing) are.
   They can't be read off the wire, so the start of that range is forwarded up front, TCP and UDP, at the
   same port numbers. HV_NET_PUBLISH_RANGE=first-last changes it. */
static int range_done;

static void forward_range(void) {
    if (range_done) return;
    range_done = 1;
    int first = 49154, last = 49400;
    const char *e = getenv("HV_NET_PUBLISH_RANGE");
    if (e) sscanf(e, "%d-%d", &first, &last);
    struct rlimit rl;
    if (!getrlimit(RLIMIT_NOFILE, &rl) && rl.rlim_cur < 4096) {
        rl.rlim_cur = rl.rlim_max < 4096 ? rl.rlim_max : 4096;
        setrlimit(RLIMIT_NOFILE, &rl);
    }
    struct in_addr any, guest;
    inet_pton(AF_INET, "0.0.0.0", &any);
    guest = hv_net_guest;
    int tcp = 0, udp = 0;
    for (int p = first; p <= last; p++) {
        int taken = 0;
        for (int i = 0; i < MAX_SERVICES; i++)
            if (services[i].used && services[i].host_port == p) taken = 1;
        if (taken) continue;
        tcp += slirp_add_hostfwd(slirp_for_fwd, 0, any, p, guest, p) == 0;
        udp += slirp_add_hostfwd(slirp_for_fwd, 1, any, p, guest, p) == 0;
    }
    /* AirPlay 2's clock: PTP event and general messages. A host that keeps its own (a Mac's timed) holds them. */
    for (int p = 319; p <= 320; p++)
        if (slirp_add_hostfwd(slirp_for_fwd, 1, any, p, guest, p) != 0)
            fprintf(stderr, "hengevm: PTP port %d is the host's own: AirPlay audio to the guest will not start\n", p);
    fprintf(stderr, "hengevm: forwarded guest ports %d-%d: %d TCP, %d UDP\n", first, last, tcp, udp);
}

static void publish(Service *s) {
    if (s->ref || !s->guest_port || !s->have_txt || !s->type[0]) return;
    if (!strcmp(s->type, "_sleep-proxy._udp")) return; /* a host's job, not a guest's */
    if (!strcmp(s->type, "_remotepairing._tcp")) return; /* a fresh identity each time it asks, and not for this */
    struct in_addr any, guest;
    inet_pton(AF_INET, "0.0.0.0", &any);
    guest = hv_net_guest;
    for (int i = 0; i < MAX_SERVICES && !s->host_port; i++) /* one forward per guest port */
        if (services[i].used && &services[i] != s && services[i].host_port && services[i].guest_port == s->guest_port &&
            services[i].udp == s->udp)
            s->host_port = services[i].host_port;
    if (!s->host_port) {
        for (int p = s->guest_port, tries = 0; tries < 40; tries++, p = 20000 + (s->guest_port + tries * 7919) % 40000)
            if (slirp_add_hostfwd(slirp_for_fwd, s->udp, any, p, guest, s->guest_port) == 0) { s->host_port = (uint16_t)p; break; }
        if (!s->host_port) { fprintf(stderr, "hengevm: no host port for %s\n", s->instance); return; }
    }
    if (strstr(s->type, "_airplay") || strstr(s->type, "_raop")) forward_range();
    DNSServiceErrorType e = DNSServiceRegister(&s->ref, 0, 0, s->name, s->type, NULL, NULL, htons(s->host_port),
                                               s->txt_len, s->txt, registered, NULL);
    fprintf(stderr, "hengevm: publishing %s (%s) guest port %u on host port %u: %d\n", s->name, s->type,
            s->guest_port, s->host_port, e);
    if (e) s->ref = NULL;
}

/* One multicast DNS message the guest sent. */
static void take_message(const uint8_t *m, int len) {
    if (len < 12) return;
    int qd = m[4] << 8 | m[5], an = m[6] << 8 | m[7], ns = m[8] << 8 | m[9], ar = m[10] << 8 | m[11];
    int o = 12;
    char name[MAX_NAME], target[MAX_NAME];
    for (int i = 0; i < qd; i++) {
        if (read_name(m, len, o, name, sizeof name, &o)) return;
        o += 4;
    }
    for (int i = 0; i < an + ns + ar; i++) {
        if (read_name(m, len, o, name, sizeof name, &o) || o + 10 > len) return;
        int type = m[o] << 8 | m[o + 1];
        int rdlen = m[o + 8] << 8 | m[o + 9];
        int rd = o + 10;
        if (rd + rdlen > len) return;
        if (type == 12 /* PTR */ && !strncmp(name, "_services.", 10)) {
            if (!read_name(m, len, rd, target, sizeof target, NULL)) note_type(target);
        } else if (type == 12 /* PTR */) {
            if (!read_name(m, len, rd, target, sizeof target, NULL) && (strstr(target, "._tcp.local") || strstr(target, "._udp.local"))) {
                note_type(target);
                Service *s = find(target, 1);
                if (s && !s->type[0]) split(s);
            }
        } else if (type == 33 /* SRV */ && rdlen >= 7) {
            Service *s = find(name, 1);
            if (s) {
                if (!s->type[0]) split(s);
                s->guest_port = (uint16_t)(m[rd + 4] << 8 | m[rd + 5]);
            }
        } else if (type == 16 /* TXT */) {
            Service *s = find(name, 1);
            if (s && rdlen <= (int)sizeof s->txt) {
                if (!s->type[0]) split(s);
                int changed = !s->have_txt || s->txt_len != rdlen || memcmp(s->txt, m + rd, (size_t)rdlen);
                memcpy(s->txt, m + rd, (size_t)rdlen);
                s->txt_len = (uint16_t)rdlen;
                s->have_txt = 1;
                if (changed && s->ref) DNSServiceUpdateRecord(s->ref, NULL, 0, s->txt_len, s->txt, 0);
            }
        }
        o = rd + rdlen;
    }
    for (int i = 0; i < MAX_SERVICES; i++)
        if (services[i].used) publish(&services[i]);
}

int hv_mdns_proxy_is_mdns(const uint8_t *f, uint32_t len) {
    /* Ethernet, IPv4, UDP to port 5353 */
    if (len < 42 || f[12] != 0x08 || f[13] != 0x00 || (f[14] >> 4) != 4 || f[23] != 17) return 0;
    int ihl = (f[14] & 15) * 4;
    if (14 + ihl + 8 > (int)len) return 0;
    const uint8_t *u = f + 14 + ihl;
    return (u[2] << 8 | u[3]) == 5353;
}

void hv_mdns_proxy_frame(Slirp *slirp, const uint8_t *f, uint32_t len) {
    if (!hv_mdns_proxy_enabled() || !hv_mdns_proxy_is_mdns(f, len)) return;
    slirp_for_fwd = slirp;
    int ihl = (f[14] & 15) * 4;
    const uint8_t *u = f + 14 + ihl;
    int ulen = u[4] << 8 | u[5];
    if (ulen < 8 || 14 + ihl + ulen > (int)len) return;
    take_message(u + 8, ulen - 8);
}

/* Questions into the guest, so it answers with its services even after its boot-time announcements are gone:
   first which service types it has, then each type's instances. */
static char types[24][64];
static int ntypes;
static int64_t last_query;

static int put_name(uint8_t *p, const char *name) {
    int n = 0;
    while (*name) {
        const char *dot = strchr(name, '.');
        int l = dot ? (int)(dot - name) : (int)strlen(name);
        p[n++] = (uint8_t)l;
        memcpy(p + n, name, (size_t)l);
        n += l;
        name += l + (dot ? 1 : 0);
    }
    p[n++] = 0;
    return n;
}

static void note_type(const char *instance_or_type) {
    const char *t = strstr(instance_or_type, "._tcp.local");
    if (!t) t = strstr(instance_or_type, "._udp.local");
    if (!t) return;
    const char *dot = t - 1;
    while (dot > instance_or_type && *dot != '.') dot--;
    if (*dot == '.') dot++;
    char type[64];
    snprintf(type, sizeof type, "%.*s", (int)(t + 11 - dot), dot);
    for (int i = 0; i < ntypes; i++) if (!strcmp(types[i], type)) return;
    if (ntypes < 24) snprintf(types[ntypes++], 64, "%s", type);
}

void hv_mdns_proxy_tick(int64_t now_ms, void (*send)(const uint8_t *frame, uint32_t len)) {
    if (!hv_mdns_proxy_enabled() || now_ms - last_query < 15000) return;
    last_query = now_ms;
    uint8_t f[1500];
    memset(f, 0, 42);
    static const uint8_t dst[6] = {0x01, 0x00, 0x5e, 0x00, 0x00, 0xfb}, src[6] = {0x52, 0x55, 0x0a, 0x00, 0x02, 0x02};
    memcpy(f, dst, 6);
    memcpy(f + 6, src, 6);
    f[12] = 0x08;
    uint8_t *ip = f + 14, *udp = ip + 20, *dns = udp + 8;
    int n = 12, q = 0;
    n += put_name(dns + n, "_services._dns-sd._udp.local");
    dns[n + 1] = 12; dns[n + 3] = 1; n += 4; q++;
    for (int i = 0; i < ntypes && n < 1300; i++, q++) {
        n += put_name(dns + n, types[i]);
        dns[n + 1] = 12; dns[n + 3] = 1; n += 4;
    }
    dns[5] = (uint8_t)q;
    int ulen = 8 + n, tot = 20 + ulen;
    ip[0] = 0x45; ip[2] = (uint8_t)(tot >> 8); ip[3] = (uint8_t)tot; ip[8] = 255; ip[9] = 17;
    memcpy(ip + 12, &hv_net_gateway, 4);
    ip[16] = 224; ip[17] = 0; ip[18] = 0; ip[19] = 251;
    uint32_t sum = 0;
    for (int i = 0; i < 20; i += 2) sum += (uint32_t)(ip[i] << 8 | ip[i + 1]);
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    ip[10] = (uint8_t)(~sum >> 8); ip[11] = (uint8_t)~sum;
    udp[0] = 0x14; udp[1] = 0xe9; udp[2] = 0x14; udp[3] = 0xe9; /* 5353 → 5353 */
    udp[4] = (uint8_t)(ulen >> 8); udp[5] = (uint8_t)ulen;
    send(f, (uint32_t)(14 + tot));
}

void hv_mdns_proxy_stop(void) {
    range_done = 0;
    enabled = -1; /* the next machine reads HV_NET_PUBLISH again */
    ntypes = 0;
    last_query = 0;
    for (int i = 0; i < MAX_SERVICES; i++) {
        if (services[i].ref) DNSServiceRefDeallocate(services[i].ref);
        services[i].ref = NULL;
        services[i].used = 0;
    }
    slirp_for_fwd = NULL;
}
