// Temporary SwiftXR comparison bridge. Enabled only by --swiftxr-viz-service.
#include "chrome/browser/swiftxr_viz_bridge_mac.h"
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#include <bsm/libbsm.h>
#include <servers/bootstrap.h>
#include <unistd.h>
#include <map>
#include <string>
#include "base/apple/owned_objc.h"
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/strings/string_util.h"
#include "base/timer/timer.h"
#include "chrome/browser/swiftxr_viz_protocol.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "content/public/browser/render_frame_host.h"
#include "services/network/public/cpp/is_potentially_trustworthy.h"
#include "url/origin.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/viz/host/client_frame_sink_video_capturer.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/referrer.h"
#include "media/capture/mojom/video_capture_buffer.mojom.h"
#include "media/capture/mojom/video_capture_types.mojom.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "third_party/blink/public/common/input/web_mouse_wheel_event.h"
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"

class SwiftXRVizBridgeMac::Impl : public content::WebContentsObserver,
                                public viz::mojom::FrameSinkVideoConsumer {
 public:
  Impl() : parent_pid_(getppid()) {
    std::string service = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("swiftxr-viz-service");
    if (service.empty()) return;
    if (bootstrap_look_up(bootstrap_port, service.c_str(), &shell_) != KERN_SUCCESS) {
      LOG(ERROR) << "[swiftxr-viz] could not find Shell Mach endpoint";
      return;
    }
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &input_) != KERN_SUCCESS) return;
    mach_port_limits_t limits = { .mpl_qlimit = 128 };
    mach_port_set_attributes(mach_task_self(), input_, MACH_PORT_LIMITS_INFO,
        reinterpret_cast<mach_port_info_t>(&limits), MACH_PORT_LIMITS_INFO_COUNT);
    Send(SXR_VIZ_HELLO, input_, MACH_MSG_TYPE_MAKE_SEND);
    timer_.Start(FROM_HERE, base::Milliseconds(8), base::BindRepeating(&Impl::Poll, base::Unretained(this)));
  }
  ~Impl() override {
    timer_.Stop();
    StopCapture();
    for (auto& [id, callback] : frames_) callback->Done();
    if (input_) mach_port_mod_refs(mach_task_self(), input_, MACH_PORT_RIGHT_RECEIVE, -1);
    if (shell_) mach_port_deallocate(mach_task_self(), shell_);
  }

  void OnFrameCaptured(media::mojom::VideoBufferHandlePtr data,
      media::mojom::VideoFrameInfoPtr info, const gfx::Rect& content_rect,
      mojo::PendingRemote<viz::mojom::FrameSinkVideoConsumerFrameCallbacks> callbacks) override {
    mojo::Remote<viz::mojom::FrameSinkVideoConsumerFrameCallbacks> done(std::move(callbacks));
    if (suspended_ || frames_.size() >= SXR_VIZ_MAX_IN_FLIGHT) { done->Done(); return; }
    if (!data->is_gpu_memory_buffer_handle() || !data->get_gpu_memory_buffer_handle().io_surface()) {
      done->Done();
      if (!reported_format_error_) {
        reported_format_error_ = true;
        Send(SXR_VIZ_ERROR, MACH_PORT_NULL, 0, 0, "Viz did not supply a GPU IOSurface");
      }
      return;
    }
    IOSurfaceRef surface = data->get_gpu_memory_buffer_handle().io_surface().get();
    uint64_t serial = ++serial_;
    mach_port_t port = IOSurfaceCreateMachPort(surface);
    if (port && Send(SXR_VIZ_FRAME, port, MACH_MSG_TYPE_MOVE_SEND, serial, nullptr, surface)) {
      frames_.emplace(serial, std::move(done));
    } else {
      if (port) mach_port_deallocate(mach_task_self(), port);
      done->Done();
    }
  }
  void OnNewCaptureVersion(const media::CaptureVersion&) override {}
  void OnFrameWithEmptyRegionCapture() override {}
  void OnStopped() override { current_view_ = nullptr; }
  void OnLog(const std::string& message) override { VLOG(1) << "[swiftxr-viz] " << message; }
  void WebContentsDestroyed() override { StopCapture(); Observe(nullptr); }
  void PrimaryPageChanged(content::Page&) override { StopCapture(); }

 private:
  bool Send(uint32_t kind, mach_port_t port = MACH_PORT_NULL, uint8_t disposition = 0,
            uint64_t serial = 0, const char* error = nullptr, IOSurfaceRef surface = nullptr) {
    SXRVizSurfaceMessage message = {};
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = shell_;
    message.body.msgh_descriptor_count = port ? 1 : 0;
    message.port.name = port;
    message.port.disposition = disposition;
    message.port.type = MACH_MSG_PORT_DESCRIPTOR;
    message.info.magic = SXR_VIZ_MAGIC;
    message.info.version = SXR_VIZ_VERSION;
    message.info.kind = kind;
    message.info.serial = serial;
    if (surface) {
      message.info.width = IOSurfaceGetWidth(surface);
      message.info.height = IOSurfaceGetHeight(surface);
      message.info.pixel_format = IOSurfaceGetPixelFormat(surface);
    }
    if (web_contents()) {
      base::strlcpy(message.info.url, web_contents()->GetVisibleURL().spec());
      base::strlcpy(message.info.title, base::UTF16ToUTF8(web_contents()->GetTitle()));
      auto origin = web_contents()->GetPrimaryMainFrame()->GetLastCommittedOrigin();
      if (!origin.opaque()) {
        auto* settings = HostContentSettingsMapFactory::GetForProfile(
            Profile::FromBrowserContext(web_contents()->GetBrowserContext()));
        auto permission = settings->GetContentSetting(origin.GetURL(), origin.GetURL(), ContentSettingsType::VR);
        message.info.vr_permission = !origin.GetURL().SchemeIsHTTPOrHTTPS() ||
            !network::IsOriginPotentiallyTrustworthy(origin) ? 3 :
            permission == CONTENT_SETTING_ALLOW ? 1 : permission == CONTENT_SETTING_BLOCK ? 2 : 0;
      }
    }
    if (error) base::strlcpy(message.info.title, error);
    return mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(message), 0,
        MACH_PORT_NULL, 0, MACH_PORT_NULL) == KERN_SUCCESS;
  }
  void StopCapture(bool release_visibility = true) {
    if (capturer_) capturer_->StopAndResetConsumer();
    capturer_.reset();
    if (release_visibility) capture_lifetime_.RunAndReset();
    current_view_ = nullptr;
    pressed_ = false;
  }
  void FindTarget() {
    auto* collection = GlobalBrowserCollection::GetInstance();
    if (!collection) return;
    auto* browser = collection->GetLastActiveBrowser();
    if (!browser) collection->ForEach([&browser](BrowserWindowInterface* candidate) { browser = candidate; return false; });
    if (!browser) return;
    content::WebContents* contents = browser->GetTabStripModel()->GetActiveWebContents();
    if (!contents) return;
    if (contents != web_contents()) { StopCapture(); Observe(contents); }
    auto* view = contents->GetRenderWidgetHostView();
    if (!view || suspended_ || (view == current_view_ && capturer_)) return;
    StopCapture(false);
    view->SetBounds(gfx::Rect(SXR_VIZ_WIDTH, SXR_VIZ_HEIGHT));
    if (!capture_lifetime_) capture_lifetime_ = contents->IncrementCapturerCount(
        gfx::Size(SXR_VIZ_WIDTH, SXR_VIZ_HEIGHT), false, false, false);
    current_view_ = view;
    capturer_ = view->CreateVideoCapturer();
    capturer_->SetFormat(media::PIXEL_FORMAT_ARGB);
    capturer_->SetMinCapturePeriod(base::Seconds(1.0 / 60));
    capturer_->SetMinSizeChangePeriod(base::TimeDelta());
    capturer_->SetResolutionConstraints(gfx::Size(SXR_VIZ_WIDTH, SXR_VIZ_HEIGHT),
        gfx::Size(SXR_VIZ_WIDTH, SXR_VIZ_HEIGHT), true);
    capturer_->SetAutoThrottlingEnabled(false);
    capturer_->Start(this, viz::mojom::BufferFormatPreference::kPreferMappableSharedImage);
    contents->Focus();
    view->GetRenderWidgetHost()->SetActive(true);
    view->GetRenderWidgetHost()->Focus();
    Send(SXR_VIZ_STATUS);
  }
  void Poll() {
    for (int i = 0; i < 128; ++i) {
      struct { SXRVizCommandMessage message; mach_msg_audit_trailer_t trailer; } buffer = {};
      auto kr = mach_msg(&buffer.message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT |
          MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
          0, sizeof(buffer), input_, 0, MACH_PORT_NULL);
      if (kr != KERN_SUCCESS) break;
      auto& message = buffer.message;
      auto* trailer = &buffer.trailer;
      if (message.header.msgh_size == sizeof(message) && trailer->msgh_trailer_size >= sizeof(*trailer) &&
          audit_token_to_pid(trailer->msgh_audit) == parent_pid_ &&
          message.command.magic == SXR_VIZ_MAGIC && message.command.version == SXR_VIZ_VERSION) {
        message.command.text[SXR_VIZ_URL_SIZE - 1] = 0;
        Command(message.command);
      }
      mach_msg_destroy(&message.header);
    }
    if (++ticks_ % 12 == 0) {
      FindTarget();
      if (web_contents()) {
        std::string url = web_contents()->GetVisibleURL().spec();
        std::string title = base::UTF16ToUTF8(web_contents()->GetTitle());
        if (url != last_url_ || title != last_title_) { last_url_ = url; last_title_ = title; Send(SXR_VIZ_STATUS); }
      }
    }
  }
  void Command(const SXRVizCommand& command) {
    if (command.kind == SXR_VIZ_ACK) {
      auto frame = frames_.find(command.serial);
      if (frame != frames_.end()) { frame->second->Done(); frames_.erase(frame); }
      return;
    }
    if (command.kind == SXR_VIZ_SUSPEND) { suspended_ = true; StopCapture(false); return; }
    if (command.kind == SXR_VIZ_RESUME) { suspended_ = false; FindTarget(); return; }
    if (!web_contents()) return;
    auto* view = web_contents()->GetRenderWidgetHostView();
    if (!view) return;
    auto* host = view->GetRenderWidgetHost();
    if (command.kind == SXR_VIZ_ALLOW_VR) {
      // Consent is explicit in the Shell, scoped to the origin the user saw.
      // Reload also clears an already-pending, invisible native VR prompt.
      auto origin = web_contents()->GetPrimaryMainFrame()->GetLastCommittedOrigin();
      if (!origin.opaque() && origin == url::Origin::Create(GURL(command.text)) &&
          origin.GetURL().SchemeIsHTTPOrHTTPS() && network::IsOriginPotentiallyTrustworthy(origin)) {
        auto* settings = HostContentSettingsMapFactory::GetForProfile(
            Profile::FromBrowserContext(web_contents()->GetBrowserContext()));
        settings->SetContentSettingDefaultScope(origin.GetURL(), origin.GetURL(),
            ContentSettingsType::VR, CONTENT_SETTING_ALLOW);
        web_contents()->GetController().Reload(content::ReloadType::NORMAL, false);
        Send(SXR_VIZ_STATUS);
      }
      return;
    }
    if (command.kind == SXR_VIZ_NAVIGATE) {
      GURL url(command.text);
      if (url.is_valid() && (url.SchemeIsHTTPOrHTTPS() || url.SchemeIs("about") || url.SchemeIs("file")))
        web_contents()->GetController().LoadURL(url, content::Referrer(), ui::PAGE_TRANSITION_TYPED, std::string());
      return;
    }
    if (command.kind == SXR_VIZ_BACK) { if (web_contents()->GetController().CanGoBack()) web_contents()->GetController().GoBack(); return; }
    if (command.kind == SXR_VIZ_FORWARD) { if (web_contents()->GetController().CanGoForward()) web_contents()->GetController().GoForward(); return; }
    if (command.kind == SXR_VIZ_RELOAD) { web_contents()->GetController().Reload(content::ReloadType::NORMAL, false); return; }
    if (command.kind == SXR_VIZ_KEY_DOWN || command.kind == SXR_VIZ_KEY_UP) {
      NSString* text = [NSString stringWithUTF8String:command.text] ?: @"";
      NSEvent* native = [NSEvent keyEventWithType:command.kind == SXR_VIZ_KEY_DOWN ? NSEventTypeKeyDown : NSEventTypeKeyUp
          location:NSZeroPoint modifierFlags:command.modifiers timestamp:NSProcessInfo.processInfo.systemUptime
          windowNumber:0 context:nil characters:text charactersIgnoringModifiers:text
          isARepeat:command.repeat != 0 keyCode:command.key_code];
      input::NativeWebKeyboardEvent event{gfx::NativeEvent(native)};
      host->ForwardKeyboardEvent(event);
      if (command.kind == SXR_VIZ_KEY_DOWN && text.length != 0 &&
          !(command.modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl))) {
        event.SetType(blink::WebInputEvent::Type::kChar);
        host->ForwardKeyboardEvent(event);
      }
      return;
    }
    if (suspended_) return;
    float x = command.x * SXR_VIZ_WIDTH, y = command.y * SXR_VIZ_HEIGHT;
    auto type = blink::WebInputEvent::Type::kMouseMove;
    if (command.kind == SXR_VIZ_DOWN) {
      web_contents()->Focus(); host->SetActive(true); host->Focus(); pressed_ = true;
      type = blink::WebInputEvent::Type::kMouseDown;
    }
    if (command.kind == SXR_VIZ_UP || command.kind == SXR_VIZ_CANCEL) {
      if (!pressed_) return;
      type = blink::WebInputEvent::Type::kMouseUp;
      if (command.kind == SXR_VIZ_CANCEL) { x = -32; y = -32; }
      pressed_ = false;
    }
    if (command.kind == SXR_VIZ_SCROLL) {
      blink::WebMouseWheelEvent event(blink::WebInputEvent::Type::kMouseWheel, 0, base::TimeTicks::Now());
      event.SetPositionInWidget(x, y); event.SetPositionInScreen(x, y);
      event.delta_x = command.delta_x; event.delta_y = command.delta_y;
      event.wheel_ticks_y = command.delta_y / 120;
      event.delta_units = ui::ScrollGranularity::kScrollByPrecisePixel;
      event.event_action = blink::WebMouseWheelEvent::EventAction::kScroll;
      host->ForwardWheelEvent(event);
    } else if (command.kind == SXR_VIZ_MOVE || command.kind == SXR_VIZ_DOWN ||
               command.kind == SXR_VIZ_UP || command.kind == SXR_VIZ_CANCEL) {
      blink::WebMouseEvent event(type, gfx::PointF(x, y), gfx::PointF(x, y),
          command.kind == SXR_VIZ_MOVE ? blink::WebPointerProperties::Button::kNoButton : blink::WebPointerProperties::Button::kLeft,
          1, pressed_ ? blink::WebInputEvent::kLeftButtonDown : 0, base::TimeTicks::Now());
      host->ForwardMouseEvent(event);
    }
  }
  pid_t parent_pid_;
  mach_port_t shell_ = MACH_PORT_NULL, input_ = MACH_PORT_NULL;
  base::RepeatingTimer timer_;
  std::unique_ptr<viz::ClientFrameSinkVideoCapturer> capturer_;
  base::ScopedClosureRunner capture_lifetime_;
  raw_ptr<content::RenderWidgetHostView> current_view_ = nullptr;
  std::map<uint64_t, mojo::Remote<viz::mojom::FrameSinkVideoConsumerFrameCallbacks>> frames_;
  uint64_t serial_ = 0;
  uint32_t ticks_ = 0;
  bool suspended_ = false, pressed_ = false, reported_format_error_ = false;
  std::string last_url_, last_title_;
};
SwiftXRVizBridgeMac::SwiftXRVizBridgeMac() : impl_(std::make_unique<Impl>()) {}
SwiftXRVizBridgeMac::~SwiftXRVizBridgeMac() = default;
