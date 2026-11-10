#ifndef MONOLITH_VIRTIO_VSOCK_H
#define MONOLITH_VIRTIO_VSOCK_H

#include "virtio.h"

/* virtio-vsock (device type 19), what Virtualization.framework gives guests as VZVirtioSocketDevice and what
   vphone's guest agent (vphoned) talks over. The guest is CID 3, the host CID 2. Stream sockets only.

   The host side forwards TCP: hv_vsock_forward(host_port, guest_port) listens on 127.0.0.1:host_port, and each
   connection there becomes a vsock connection to the guest's guest_port. HV_VSOCK_FWD="hostport:guestport[,...]"
   sets forwards up at create time; HV_VSOCK_SCAN="from-to" asks every guest port in the range and logs those
   that answer. HV_VSOCK_LOG logs the packets. */
typedef struct HvVsock HvVsock;

HvVsock *hv_virtio_vsock_create(HvMachine *m, HvPcie *bus);
int hv_vsock_forward(HvVsock *s, int host_port, uint32_t guest_port);
/* Host-side work: on CPU 0's thread each tick (the board's poll). */
void hv_vsock_poll(HvVsock *s);
/* The machine is going: its TCP forwards close (so the next machine can listen on the same ports). */
void hv_vsock_destroy(HvVsock *s);

#endif
