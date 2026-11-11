/*
 * openavb.h
 * The stage-0 image identity OpenAVB needs before it takes an iBSS over DFU.
 *
 * Not part of upstream idevicerestore. See openavb.c.
 */

#ifndef IDEVICERESTORE_OPENAVB_H
#define IDEVICERESTORE_OPENAVB_H

#include <stddef.h>
#include <libirecovery.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Before an iBSS goes over DFU: when the device in DFU is OpenAVB, upload
 * the identity of `image` (the personalized iBSS about to be sent) into the
 * ROM's iBSS patch-store slot. Apple's ROM does not answer the probe, and
 * then nothing is sent.
 *
 * Returns 0 when the identity was accepted or the ROM is not OpenAVB, and -1
 * when it is OpenAVB and the identity could not be built or uploaded; the
 * ROM would refuse the iBSS, so the restore stops there.
 */
int openavb_describe_ibss(irecv_client_t client, const void *image, size_t size);

#ifdef __cplusplus
}
#endif

#endif
