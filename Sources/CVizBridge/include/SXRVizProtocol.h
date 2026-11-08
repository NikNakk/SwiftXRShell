#ifndef SXR_VIZ_PROTOCOL_H
#define SXR_VIZ_PROTOCOL_H
#include <mach/mach.h>
#include <stdint.h>
#define SXR_VIZ_MAGIC 0x53585256u
#define SXR_VIZ_VERSION 2u
#define SXR_VIZ_URL_SIZE 2048
#define SXR_VIZ_TITLE_SIZE 256
#define SXR_VIZ_WIDTH 1440
#define SXR_VIZ_HEIGHT 900
#define SXR_VIZ_MAX_IN_FLIGHT 3

enum { SXR_VIZ_HELLO = 1, SXR_VIZ_FRAME = 2, SXR_VIZ_STATUS = 3, SXR_VIZ_ERROR = 4 };
enum { SXR_VIZ_MOVE = 1, SXR_VIZ_DOWN, SXR_VIZ_UP, SXR_VIZ_SCROLL,
       SXR_VIZ_KEY_DOWN, SXR_VIZ_KEY_UP, SXR_VIZ_NAVIGATE, SXR_VIZ_BACK,
       SXR_VIZ_FORWARD, SXR_VIZ_RELOAD, SXR_VIZ_ACK, SXR_VIZ_SUSPEND,
       SXR_VIZ_RESUME, SXR_VIZ_CANCEL, SXR_VIZ_STOP, SXR_VIZ_ALLOW_VR };

typedef struct {
  uint32_t magic, version, kind, width, height, pixel_format, vr_permission;
  uint64_t serial;
  char url[SXR_VIZ_URL_SIZE];
  char title[SXR_VIZ_TITLE_SIZE];
} SXRVizFrameInfo;

typedef struct {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;
  SXRVizFrameInfo info;
} SXRVizSurfaceMessage;

typedef struct {
  uint32_t magic, version, kind, modifiers;
  uint64_t serial;
  double x, y, delta_x, delta_y;
  uint32_t key_code, repeat;
  char text[SXR_VIZ_URL_SIZE];
} SXRVizCommand;

typedef struct {
  mach_msg_header_t header;
  SXRVizCommand command;
} SXRVizCommandMessage;
#endif
