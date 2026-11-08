#include "CVizBridge.h"
#include <bsm/libbsm.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>

struct SXRVizReceiver {
  mach_port_t receive, peer;
  pid_t expected_pid;
  pthread_mutex_t lock;
};

SXRVizReceiver *sxr_viz_receiver_create(const char *service, int32_t *error) {
  SXRVizReceiver *r = calloc(1, sizeof(*r));
  if (!r) { *error = KERN_RESOURCE_SHORTAGE; return NULL; }
  pthread_mutex_init(&r->lock, NULL);
  *error = bootstrap_check_in(bootstrap_port, service, &r->receive);
  if (*error) { pthread_mutex_destroy(&r->lock); free(r); return NULL; }
  mach_port_limits_t limits = { .mpl_qlimit = 16 };
  mach_port_set_attributes(mach_task_self(), r->receive, MACH_PORT_LIMITS_INFO,
                           (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
  return r;
}
void sxr_viz_receiver_expect_pid(SXRVizReceiver *r, pid_t pid) {
  pthread_mutex_lock(&r->lock); r->expected_pid = pid; pthread_mutex_unlock(&r->lock);
}
int32_t sxr_viz_receiver_poll(SXRVizReceiver *r, uint32_t timeout_ms, SXRVizFrameInfo *info, void **surface) {
  struct { SXRVizSurfaceMessage message; mach_msg_audit_trailer_t trailer; } buffer = {0};
  *surface = NULL;
  kern_return_t kr = mach_msg(&buffer.message.header,
      MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
      MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT), 0, sizeof(buffer), r->receive, timeout_ms, MACH_PORT_NULL);
  if (kr == MACH_RCV_TIMED_OUT) return 0;
  if (kr) return -(int32_t)kr;
  SXRVizSurfaceMessage *m = &buffer.message;
  if (m->header.msgh_size != sizeof(*m)) { mach_msg_destroy(&m->header); return 0; }
  mach_msg_audit_trailer_t *trailer = (mach_msg_audit_trailer_t *)((char *)m + round_msg(m->header.msgh_size));
  pthread_mutex_lock(&r->lock);
  int valid = trailer->msgh_trailer_size >= sizeof(*trailer) &&
      audit_token_to_pid(trailer->msgh_audit) == r->expected_pid && r->expected_pid > 0;
  pthread_mutex_unlock(&r->lock);
  if (!valid || m->info.magic != SXR_VIZ_MAGIC || m->info.version != SXR_VIZ_VERSION) {
    mach_msg_destroy(&m->header); return 0;
  }
  if (m->info.kind == SXR_VIZ_HELLO && m->body.msgh_descriptor_count == 1 &&
      m->port.type == MACH_MSG_PORT_DESCRIPTOR && m->port.name != MACH_PORT_NULL) {
    pthread_mutex_lock(&r->lock);
    if (r->peer) mach_port_deallocate(mach_task_self(), r->peer);
    r->peer = m->port.name;
    m->port.name = MACH_PORT_NULL;
    pthread_mutex_unlock(&r->lock);
  } else if (m->info.kind == SXR_VIZ_FRAME && m->body.msgh_descriptor_count == 1 &&
             m->port.type == MACH_MSG_PORT_DESCRIPTOR) {
    *surface = (void *)IOSurfaceLookupFromMachPort(m->port.name);
  }
  *info = m->info;
  info->url[SXR_VIZ_URL_SIZE - 1] = 0;
  info->title[SXR_VIZ_TITLE_SIZE - 1] = 0;
  mach_msg_destroy(&m->header);
  return 1;
}
int32_t sxr_viz_receiver_send(SXRVizReceiver *r, const SXRVizCommand *command) {
  pthread_mutex_lock(&r->lock);
  mach_port_t peer = r->peer;
  SXRVizCommandMessage m = {0};
  m.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
  m.header.msgh_size = sizeof(m);
  m.header.msgh_remote_port = peer;
  m.command = *command;
  m.command.magic = SXR_VIZ_MAGIC;
  m.command.version = SXR_VIZ_VERSION;
  kern_return_t kr = peer ? mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
      sizeof(m), 0, MACH_PORT_NULL, 5, MACH_PORT_NULL) : MACH_SEND_INVALID_DEST;
  pthread_mutex_unlock(&r->lock);
  return kr;
}
void sxr_viz_receiver_destroy(SXRVizReceiver *r) {
  if (!r) return;
  if (r->receive) mach_port_mod_refs(mach_task_self(), r->receive, MACH_PORT_RIGHT_RECEIVE, -1);
  if (r->peer) mach_port_deallocate(mach_task_self(), r->peer);
  pthread_mutex_destroy(&r->lock);
  free(r);
}
