# SwiftXR YouTube WebXR streaming experiment

This is an unpacked Chromium extension for the macOS OpenXR/WebXR port. It is
intended to prove native YouTube streaming into an OpenXR headset without
`yt-dlp`. The streaming path is runtime-neutral; Meta XR Simulator, Monado,
and other macOS OpenXR runtimes can be used.

## Architecture

```text
YouTube player
  -> MediaSource / adaptive streaming / Chromium decode
  -> live HTMLVideoElement
  -> WebGL video texture
  -> EAC360 or equirectangular projection shader
  -> XRWebGLLayer
  -> Chromium OpenXR
  -> selected macOS OpenXR runtime
  -> headset
```

YouTube remains responsible for adaptive bitrate selection, seeking,
authentication, buffering and ordinary audio playback.

## Why not XRMediaBinding yet?

Chromium 156 already contains `XRMediaBinding`, and its media drawing context
pulls the current decoded `media::VideoFrame` directly from the
`HTMLVideoElement`. That is an excellent future zero/low-copy route.

However, YouTube's high-quality 360 video commonly uses an EAC cubemap atlas.
`XRMediaBinding.createEquirectLayer()` treats the decoded texture as
equirectangular, so feeding an EAC stream directly into that layer produces the
wrong projection. This experiment therefore keeps Chromium's native YouTube
stream/decode path but applies SwiftXRShell's existing EAC mapping in WebGL.

## Runtime and SwiftXR Shell handoff

The current WebGL experiment uses a standard `XRWebGLLayer`; it does not
require WebXR Layers or any Monado-specific extension.

When SwiftXR Shell is running, the extension coordinates runtime ownership over
a loopback-only bridge on port 49375. Before Chromium requests an immersive
session, the Shell destroys its OpenXR session and instance. When the browser
session ends, the Shell recreates them. This is deliberately outside OpenXR so
it works on runtimes that do not provide Monado's client-control API.

## Load it

Launch the Chromium build from the `macos-openxr-webxr` branch using whichever
OpenXR runtime you are testing, and load this directory as an unpacked
extension, for example:

```bash
out/Default/Chromium.app/Contents/MacOS/Chromium \
  --load-extension=/path/to/SwiftXRShell/Tools/YouTubeWebXR
```

Open a YouTube 360 video. A **Stream in VR** button is injected into the page.
Click it while the video has loaded.

The current heuristic chooses EAC for video near a 3:2 aspect ratio and ordinary
equirectangular projection for wider (~2:1) video.

## Diagnostic value

If the immersive session opens but the extension reports **Video texture
blocked**, Chromium is enforcing origin-clean restrictions on the live YouTube
video texture. In that case the next implementation should move the same EAC
mapping into Chromium's `XRMediaDrawingContext`, where the browser already has
direct access to the decoded `media::VideoFrame`.

If it renders successfully, this gives us the desired streaming architecture
without any YouTube URL extraction or duplicate decoder.
