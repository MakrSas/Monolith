#ifndef HENGEVM_NET_SLIRP_H
#define HENGEVM_NET_SLIRP_H

#include "machine.h"
#include "virtio_net.h"

/* Before hv_net_attach: the Unix socket behind the guest's 10.0.2.4:80 (share.c). */
void hv_net_set_share_socket(const char *path);
/* User-mode NAT for the guest's virtio-net (see net_slirp.c). Returns 0 on success. */
int hv_net_attach(HvMachine *m, HvVirtioNet *n);
/* CPUs must be stopped. Joins the network worker before its machine is freed. */
void hv_net_detach(void);
/* CPU thread, from the board's tick: hand frames for the guest to the device. */
void hv_net_poll(void);

#include <netinet/in.h>
/* The guest's address and its gateway (10.0.2.15 and 10.0.2.2, or the host's LAN address: see hv_net_attach). */
extern struct in_addr hv_net_guest, hv_net_gateway;
extern uint64_t hv_net_tx_frames, hv_net_rx_frames;

#endif
