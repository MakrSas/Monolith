#include "virtio_vsock.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define RXQ 0
#define TXQ 1
#define EVQ 2
#define HDR 44
#define GUEST_CID 3ull
#define HOST_CID 2ull
#define BUF_ALLOC (256u << 10) /* what the host side says it can hold per connection */
#define CHUNK 16384u
#define MAXCONN 64
#define MAXFWD 8

enum { OP_REQUEST = 1, OP_RESPONSE, OP_RST, OP_SHUTDOWN, OP_RW, OP_CREDIT_UPDATE, OP_CREDIT_REQUEST };
enum { C_FREE, C_CONNECTING, C_OPEN, C_CLOSING };

typedef struct {
    uint64_t src_cid, dst_cid;
    uint32_t src_port, dst_port, len;
    uint16_t type, op;
    uint32_t flags, buf_alloc, fwd_cnt;
} __attribute__((packed)) Hdr;
_Static_assert(sizeof(Hdr) == HDR, "vsock header");

typedef struct Pkt {
    struct Pkt *next;
    Hdr h;
    uint8_t data[];
} Pkt;

typedef struct {
    int state, fd, scan;
    uint32_t host_port, guest_port;
    uint32_t peer_buf_alloc, peer_fwd_cnt; /* the guest's receive window */
    uint32_t tx_cnt;                       /* bytes sent to the guest */
    uint32_t fwd_cnt;                      /* bytes taken from the guest and handed to the TCP side */
    uint32_t fwd_told;                     /* fwd_cnt the guest last heard */
} Conn;

struct HvVsock {
    HvVirtio vio;
    pthread_mutex_t mu;
    Conn c[MAXCONN];
    Pkt *head, *tail; /* packets for the guest */
    int nqueued;
    int lfd[MAXFWD];
    uint32_t lguest[MAXFWD];
    int nfwd;
    int wake[2];
    uint32_t next_port;
    uint32_t scan_next, scan_end;
    int log;
    volatile int stop;
    pthread_t thread;
    time_t scan_at; /* the scan starts this long after boot, once the guest's services listen */
};

static void queue(HvVsock *s, const Conn *c, uint16_t op, uint32_t flags, const void *data, uint32_t len) {
    Pkt *p = malloc(sizeof *p + len);
    memset(&p->h, 0, sizeof p->h);
    p->next = NULL;
    p->h.src_cid = HOST_CID, p->h.dst_cid = GUEST_CID;
    p->h.src_port = c->host_port, p->h.dst_port = c->guest_port;
    p->h.len = len, p->h.type = 1, p->h.op = op, p->h.flags = flags;
    p->h.buf_alloc = BUF_ALLOC, p->h.fwd_cnt = c->fwd_cnt;
    ((Conn *)c)->fwd_told = c->fwd_cnt;
    if (len) memcpy(p->data, data, len);
    if (s->tail) s->tail->next = p;
    else s->head = p;
    s->tail = p;
    s->nqueued++;
}

static void queue_rst(HvVsock *s, const Hdr *h) {
    Conn t = {.host_port = h->dst_port, .guest_port = h->src_port};
    queue(s, &t, OP_RST, 0, NULL, 0);
}

static void wake_thread(HvVsock *s) {
    char b = 1;
    (void)!write(s->wake[1], &b, 1);
}

static Conn *find(HvVsock *s, uint32_t host_port, uint32_t guest_port) {
    for (int i = 0; i < MAXCONN; i++)
        if (s->c[i].state != C_FREE && s->c[i].host_port == host_port && s->c[i].guest_port == guest_port) return &s->c[i];
    return NULL;
}

static Conn *alloc_conn(HvVsock *s) {
    for (int i = 0; i < MAXCONN; i++)
        if (s->c[i].state == C_FREE) {
            memset(&s->c[i], 0, sizeof s->c[i]);
            s->c[i].fd = -1;
            if (++s->next_port < 1024) s->next_port = 1024;
            s->c[i].host_port = s->next_port;
            return &s->c[i];
        }
    return NULL;
}

static void drop(HvVsock *s, Conn *c) {
    if (c->fd >= 0) close(c->fd);
    c->fd = -1;
    c->state = C_FREE;
    wake_thread(s);
}

static uint32_t credit(const Conn *c) {
    uint32_t used = c->tx_cnt - c->peer_fwd_cnt;
    return used >= c->peer_buf_alloc ? 0 : c->peer_buf_alloc - used;
}

/* ---- the guest's packets (on the CPU that notified) ---- */

static void from_guest(HvVsock *s, const Hdr *h, const uint8_t *data) {
    if (s->log) fprintf(stderr, "vsock: guest %u -> host %u op %u len %u\n", h->src_port, h->dst_port, h->op, h->len);
    pthread_mutex_lock(&s->mu);
    Conn *c = find(s, h->dst_port, h->src_port);
    if (!c) {
        if (h->op != OP_RST) queue_rst(s, h); /* nothing listens on the host for the guest's own connections */
        pthread_mutex_unlock(&s->mu);
        return;
    }
    c->peer_buf_alloc = h->buf_alloc, c->peer_fwd_cnt = h->fwd_cnt;
    switch (h->op) {
    case OP_RESPONSE:
        if (c->scan) {
            fprintf(stderr, "vsock: guest port %u answers\n", c->guest_port);
            queue(s, c, OP_RST, 0, NULL, 0);
            c->state = C_FREE;
        } else c->state = C_OPEN;
        break;
    case OP_RW:
        if (c->fd >= 0 && h->len) {
            uint32_t off = 0;
            while (off < h->len) {
                ssize_t n = send(c->fd, data + off, h->len - off, 0);
                if (n > 0) off += (uint32_t)n;
                else if (n < 0 && errno == EINTR) continue;
                else break;
            }
        }
        c->fwd_cnt += h->len;
        if (c->fwd_cnt - c->fwd_told >= BUF_ALLOC / 4) queue(s, c, OP_CREDIT_UPDATE, 0, NULL, 0);
        break;
    case OP_CREDIT_REQUEST: queue(s, c, OP_CREDIT_UPDATE, 0, NULL, 0); break;
    case OP_CREDIT_UPDATE: break;
    case OP_SHUTDOWN:
        if (c->fd >= 0) shutdown(c->fd, (h->flags & 2) ? SHUT_RDWR : SHUT_WR);
        if ((h->flags & 3) == 3) { queue(s, c, OP_RST, 0, NULL, 0); drop(s, c); }
        break;
    case OP_RST: drop(s, c); break;
    default: break;
    }
    pthread_mutex_unlock(&s->mu);
    wake_thread(s); /* the window may have opened */
}

static void notify(HvVirtio *v, int q) {
    HvVsock *s = v->dev;
    if (q != TXQ) {
        if (q == RXQ) hv_vsock_poll(s); /* new receive buffers: deliver what waits */
        return;
    }
    static HvVirtqElem e;
    static uint8_t buf[HDR + 65536];
    int any = 0;
    while (hv_virtq_pop(v, TXQ, &e) > 0) {
        uint32_t n = hv_virtq_read(v, &e, 0, buf, sizeof buf);
        if (n >= HDR) {
            Hdr h;
            memcpy(&h, buf, HDR);
            if (h.len > n - HDR) h.len = n - HDR;
            if (h.type == 1) from_guest(s, &h, buf + HDR);
        }
        hv_virtq_push(v, TXQ, &e, 0);
        any = 1;
    }
    if (any) hv_virtio_interrupt(v);
    hv_vsock_poll(s);
}

/* ---- packets for the guest (CPU 0's tick, and after the guest's own) ---- */

void hv_vsock_poll(HvVsock *s) {
    if (!s) return;
    HvVirtio *v = &s->vio;
    if (!(v->status & 4) || !v->q[RXQ].enabled) return;
    static HvVirtqElem e;
    int any = 0;
    pthread_mutex_lock(&s->mu);
    while (s->scan_next && s->scan_next <= s->scan_end && s->nqueued < 32 && time(NULL) >= s->scan_at) {
        Conn *c = alloc_conn(s);
        if (!c) break;
        c->state = C_CONNECTING, c->scan = 1, c->guest_port = s->scan_next++;
        queue(s, c, OP_REQUEST, 0, NULL, 0);
        if (s->scan_next > s->scan_end) fprintf(stderr, "vsock: scan done\n");
    }
    while (s->head) {
        Pkt *p = s->head;
        if (hv_virtq_pop(v, RXQ, &e) <= 0) break;
        uint32_t room = hv_virtq_writable(&e);
        if (room < HDR + p->h.len) { /* never: buffers are 4 KB+ and packets at most CHUNK; give it back empty */
            hv_virtq_push(v, RXQ, &e, 0);
            any = 1;
            break;
        }
        hv_virtq_write(v, &e, 0, &p->h, HDR);
        if (p->h.len) hv_virtq_write(v, &e, HDR, p->data, p->h.len);
        hv_virtq_push(v, RXQ, &e, HDR + p->h.len);
        if (s->log) fprintf(stderr, "vsock: host %u -> guest %u op %u len %u\n", p->h.src_port, p->h.dst_port, p->h.op, p->h.len);
        s->head = p->next;
        if (!s->head) s->tail = NULL;
        s->nqueued--;
        free(p);
        any = 1;
    }
    pthread_mutex_unlock(&s->mu);
    if (any) hv_virtio_interrupt(v);
}

/* ---- the TCP side ---- */

static void *tcp_thread(void *arg) {
    HvVsock *s = arg;
    static uint8_t buf[CHUNK];
    while (!s->stop) {
        struct pollfd pf[1 + MAXFWD + MAXCONN];
        Conn *who[1 + MAXFWD + MAXCONN];
        int n = 0;
        pf[n].fd = s->wake[0], pf[n].events = POLLIN, who[n++] = NULL;
        pthread_mutex_lock(&s->mu);
        for (int i = 0; i < s->nfwd; i++) pf[n].fd = s->lfd[i], pf[n].events = POLLIN, who[n++] = NULL;
        for (int i = 0; i < MAXCONN; i++) {
            Conn *c = &s->c[i];
            if (c->state == C_OPEN && c->fd >= 0 && credit(c) && s->nqueued < 256) pf[n].fd = c->fd, pf[n].events = POLLIN, who[n++] = c;
        }
        pthread_mutex_unlock(&s->mu);
        if (poll(pf, (nfds_t)n, 100) < 0) continue;
        if (pf[0].revents) { char b[64]; while (read(s->wake[0], b, sizeof b) > 0) {} }
        for (int i = 0; i < s->nfwd; i++) {
            if (!(pf[1 + i].revents & POLLIN)) continue;
            int fd = accept(s->lfd[i], NULL, NULL);
            if (fd < 0) continue;
            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
            pthread_mutex_lock(&s->mu);
            Conn *c = alloc_conn(s);
            if (!c) { close(fd); pthread_mutex_unlock(&s->mu); continue; }
            c->fd = fd, c->state = C_CONNECTING, c->guest_port = s->lguest[i];
            queue(s, c, OP_REQUEST, 0, NULL, 0);
            if (s->log) fprintf(stderr, "vsock: TCP connection -> guest port %u\n", c->guest_port);
            pthread_mutex_unlock(&s->mu);
        }
        for (int k = 1 + s->nfwd; k < n; k++) {
            if (!pf[k].revents) continue;
            Conn *c = who[k];
            pthread_mutex_lock(&s->mu);
            if (c->state != C_OPEN || c->fd != pf[k].fd) { pthread_mutex_unlock(&s->mu); continue; }
            uint32_t want = credit(c);
            if (want > CHUNK) want = CHUNK;
            pthread_mutex_unlock(&s->mu);
            ssize_t r = want ? recv(c->fd, buf, want, 0) : 0;
            pthread_mutex_lock(&s->mu);
            if (c->state == C_OPEN && c->fd == pf[k].fd) {
                if (r > 0) {
                    queue(s, c, OP_RW, 0, buf, (uint32_t)r);
                    c->tx_cnt += (uint32_t)r;
                } else if (r == 0 || (errno != EINTR && errno != EAGAIN)) {
                    queue(s, c, OP_SHUTDOWN, 3, NULL, 0);
                    close(c->fd);
                    c->fd = -1;
                    c->state = C_CLOSING;
                }
            }
            pthread_mutex_unlock(&s->mu);
        }
    }
    return NULL;
}

int hv_vsock_forward(HvVsock *s, int host_port, uint32_t guest_port) {
    if (!s || s->nfwd >= MAXFWD) return -1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)host_port)};
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 8)) {
        fprintf(stderr, "vsock: cannot listen on 127.0.0.1:%d: %s\n", host_port, strerror(errno));
        close(fd);
        return -1;
    }
    pthread_mutex_lock(&s->mu);
    s->lfd[s->nfwd] = fd, s->lguest[s->nfwd] = guest_port, s->nfwd++;
    pthread_mutex_unlock(&s->mu);
    wake_thread(s);
    fprintf(stderr, "vsock: 127.0.0.1:%d -> guest port %u\n", host_port, guest_port);
    return 0;
}

HvVsock *hv_virtio_vsock_create(HvMachine *m, HvPcie *bus) {
    HvVsock *s = calloc(1, sizeof *s);
    HvVirtio *v = &s->vio;
    hv_virtio_init(v, m, 19, 0x078000, 3, 0);
    v->dev = s;
    v->notify = notify;
    uint64_t cid = GUEST_CID;
    memcpy(v->config, &cid, 8);
    v->config_len = 8;
    pthread_mutex_init(&s->mu, NULL);
    if (pipe(s->wake)) return NULL;
    fcntl(s->wake[0], F_SETFL, O_NONBLOCK), fcntl(s->wake[1], F_SETFL, O_NONBLOCK);
    s->next_port = 49152;
    s->log = getenv("HV_VSOCK_LOG") != NULL;
    hv_pcie_attach(bus, &v->pci);
    pthread_create(&s->thread, NULL, tcp_thread, s);
    const char *fwd = getenv("HV_VSOCK_FWD");
    while (fwd && *fwd) {
        int hp;
        unsigned gp;
        if (sscanf(fwd, "%d:%u", &hp, &gp) == 2) hv_vsock_forward(s, hp, gp);
        fwd = strchr(fwd, ',');
        if (fwd) fwd++;
    }
    const char *scan = getenv("HV_VSOCK_SCAN");
    unsigned a, b;
    if (scan && sscanf(scan, "%u-%u", &a, &b) == 2 && a && b >= a) s->scan_next = a, s->scan_end = b, s->scan_at = time(NULL) + (getenv("HV_VSOCK_SCAN_DELAY") ? atoi(getenv("HV_VSOCK_SCAN_DELAY")) : 240);
    return s;
}

void hv_vsock_destroy(HvVsock *s) {
    if (!s) return;
    s->stop = 1;
    wake_thread(s);
    pthread_join(s->thread, NULL);
    for (int i = 0; i < s->nfwd; i++) close(s->lfd[i]);
    for (int i = 0; i < MAXCONN; i++)
        if (s->c[i].fd >= 0 && s->c[i].state != C_FREE) close(s->c[i].fd);
    while (s->head) { Pkt *p = s->head; s->head = p->next; free(p); }
    close(s->wake[0]), close(s->wake[1]);
    pthread_mutex_destroy(&s->mu);
    free(s);
}
