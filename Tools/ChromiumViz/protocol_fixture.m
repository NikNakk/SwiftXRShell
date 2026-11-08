// Test-only IOSurface producer; not used by either Browser tile.
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <servers/bootstrap.h>
#include <unistd.h>
#include "SXRVizProtocol.h"

static int publish(mach_port_t shell, uint32_t kind, mach_port_t port, uint32_t disposition,
                   IOSurfaceRef surface, uint64_t serial) {
  SXRVizSurfaceMessage m = {0};
  m.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0) | MACH_MSGH_BITS_COMPLEX;
  m.header.msgh_size = sizeof(m); m.header.msgh_remote_port = shell;
  m.body.msgh_descriptor_count = port ? 1 : 0;
  m.port.name = port; m.port.disposition = disposition; m.port.type = MACH_MSG_PORT_DESCRIPTOR;
  m.info.magic = SXR_VIZ_MAGIC; m.info.version = SXR_VIZ_VERSION;
  m.info.kind = kind; m.info.serial = serial;
  if(surface) {
    m.info.width = IOSurfaceGetWidth(surface); m.info.height = IOSurfaceGetHeight(surface);
    m.info.pixel_format = IOSurfaceGetPixelFormat(surface);
  }
  return mach_msg(&m.header,MACH_SEND_MSG,sizeof(m),0,MACH_PORT_NULL,MACH_MSG_TIMEOUT_NONE,MACH_PORT_NULL);
}
int main(int argc, char **argv) {
  @autoreleasepool {
    setbuf(stdout,NULL);
    const char *service = NULL;
    const char prefix[]="--swiftxr-viz-service=";
    for(int i=1;i<argc;++i) if(strncmp(argv[i],prefix,sizeof(prefix)-1)==0) service=argv[i]+sizeof(prefix)-1;
    if(!service) return 2;
    mach_port_t shell=0, input=0;
    if(bootstrap_look_up(bootstrap_port,service,&shell)) return 3;
    if(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&input)) return 4;
    if(publish(shell,SXR_VIZ_HELLO,input,MACH_MSG_TYPE_MAKE_SEND,NULL,0)) return 5;
    IOSurfaceRef surfaces[3] = {0};
    for(int i=0;i<3;++i) {
      NSDictionary *properties = @{
        (NSString *)kIOSurfaceWidth:@(SXR_VIZ_WIDTH), (NSString *)kIOSurfaceHeight:@(SXR_VIZ_HEIGHT),
        (NSString *)kIOSurfaceBytesPerElement:@4, (NSString *)kIOSurfaceBytesPerRow:@(SXR_VIZ_WIDTH*4),
        (NSString *)kIOSurfacePixelFormat:@(0x42475241)};
      surfaces[i]=IOSurfaceCreate((__bridge CFDictionaryRef)properties);
      if(!surfaces[i]) return 6;
      IOSurfaceLock(surfaces[i],0,NULL);
      uint32_t *pixel=IOSurfaceGetBaseAddress(surfaces[i]);
      for(int y=0;y<SXR_VIZ_HEIGHT;++y) for(int x=0;x<SXR_VIZ_WIDTH;++x) pixel[y*SXR_VIZ_WIDTH+x]=0xff123456;
      IOSurfaceUnlock(surfaces[i],0,NULL);
      if(publish(shell,SXR_VIZ_FRAME,IOSurfaceCreateMachPort(surfaces[i]),MACH_MSG_TYPE_MOVE_SEND,surfaces[i],i+1)) return 7;
    }
    while(1) {
      struct { SXRVizCommandMessage m; mach_msg_trailer_t trailer; } buffer={0};
      SXRVizCommandMessage *m=&buffer.m;
      if(mach_msg(&m->header,MACH_RCV_MSG,0,sizeof(buffer),input,MACH_MSG_TIMEOUT_NONE,MACH_PORT_NULL)) return 8;
      if(m->command.kind==SXR_VIZ_ACK) {
        printf("ACK %llu\n",m->command.serial);
        uint64_t i=m->command.serial-1;
        if(i<3 && surfaces[i]) { CFRelease(surfaces[i]); surfaces[i]=NULL; }
      }
    }
  }
}
