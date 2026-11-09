#ifndef MONOLITH_USBX_H
#define MONOLITH_USBX_H

#include <pthread.h>
#include <stdint.h>

#include "pcie.h"

/* The USB that vresearch101 guests (iOS, watchOS, tvOS from vphone) get, as vphone-linux gives it:
   an xHCI controller with a HID keyboard on root port 1 and a hub on root port 2, with a
   four-finger HID touch screen and a consumer-control button device behind the hub (iOS enumerates the digitizer only there).
   Input comes from the host UI on any thread; the CPU thread delivers it (hv_usbx_poll). */
typedef struct HvUsbx HvUsbx;

HvUsbx *hv_usbx_create(HvMachine *m, HvPcie *bus);
void hv_usbx_poll(HvUsbx *x);
/* A key (HID usage page 7; 0xe0..0xe7 modifiers) went down or up. */
void hv_usbx_key(HvUsbx *x, uint8_t usage, int down);
/* Finger 0..3 touches (down) at x, y in 0..1 of the screen, or lifts. */
void hv_usbx_touch(HvUsbx *x, int finger, int down, double fx, double fy);
/* A consumer-page button (0x40 Menu: Home, the Digital Crown; 0x95 Help: a watch's side button; 0x30 Power;
   0xe9/0xea volume) went down or up. */
void hv_usbx_consumer(HvUsbx *x, uint16_t usage, int down);
/* The Digital Crown turned by detents (positive: up, away from the wearer). */
void hv_usbx_wheel(HvUsbx *x, int detents);
uint64_t hv_usbx_delivered(HvUsbx *x);

#endif
