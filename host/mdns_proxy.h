#ifndef HENGEVM_MDNS_PROXY_H
#define HENGEVM_MDNS_PROXY_H

#include <stdint.h>

typedef struct Slirp Slirp;

/* The guest's Bonjour services published on the host's network (see mdns_proxy.c). */
int hv_mdns_proxy_enabled(void);
void hv_mdns_proxy_set_enabled(int on);
int hv_mdns_proxy_is_mdns(const uint8_t *frame, uint32_t len);
/* Network thread: a frame the guest sent, before libslirp takes it. */
void hv_mdns_proxy_frame(Slirp *slirp, const uint8_t *frame, uint32_t len);
/* Network thread, now and then: ask the guest for its services again (send queues a frame for it). */
void hv_mdns_proxy_tick(int64_t now_ms, void (*send)(const uint8_t *frame, uint32_t len));
/* Network thread or after it stopped: withdraw everything. */
void hv_mdns_proxy_stop(void);

#endif
