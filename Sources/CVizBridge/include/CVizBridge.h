#ifndef C_VIZ_BRIDGE_H
#define C_VIZ_BRIDGE_H
#include "SXRVizProtocol.h"
#include <IOSurface/IOSurface.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct SXRVizReceiver SXRVizReceiver;
SXRVizReceiver * _Nullable sxr_viz_receiver_create(const char * _Nonnull service, int32_t * _Nonnull error);
void sxr_viz_receiver_expect_pid(SXRVizReceiver * _Nonnull receiver, pid_t pid);
// 1=message, 0=timeout, negative=Mach error. Returned surface is owned by caller.
int32_t sxr_viz_receiver_poll(SXRVizReceiver * _Nonnull receiver, uint32_t timeout_ms,
                            SXRVizFrameInfo * _Nonnull info, void * _Nullable * _Nonnull surface);
int32_t sxr_viz_receiver_send(SXRVizReceiver * _Nonnull receiver, const SXRVizCommand * _Nonnull command);
void sxr_viz_receiver_destroy(SXRVizReceiver * _Nonnull receiver);
#ifdef __cplusplus
}
#endif
#endif
