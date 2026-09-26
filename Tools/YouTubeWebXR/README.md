# SwiftXR YouTube WebXR streaming experiment

This is an unpacked Chromium extension for the macOS OpenXR/WebXR port. It is
intended to prove native YouTube streaming into PSVR2 without `yt-dlp`.

## Architecture

```text
YouTube player
  -> MediaSource / adaptive streaming / Chromium decode
  -> live HTMLVideoElement
  -> WebGL video texture
  -> EAC360 or equirectangular projection shader
  -> XRWebGLLayer
  -> Chromium OpenXR
  -> Monado
  -> PSVR2
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

## Runtime prerequisite

Chromium's `layers` feature currently requires the OpenXR runtime to advertise
cylinder, equirect2 and cube composition-layer extensions together. The Monado
branch `macos-wine-openvr-legacy-unity` now enables cube layers by default as
well (commit `6c681e4722bfd752e94f7f6b86880378f5f7b6ca`). This experiment itself
uses a standard `XRWebGLLayer`, so it does not depend on WebXR Layers, but the
runtime change is needed for the later `XRMediaBinding` path.

## Load it

Launch the Chromium build from the `macos-openxr-webxr` branch with this
directory as an unpacked extension, for example:

```bash
XR_RUNTIME_JSON=/path/to/openxr_monado-dev.json \
  out/Default/Chromium.app/Contents/MacOS/Chromium \
  --load-extension=/path/to/SwiftXRShell/Tools/YouTubeWebXR
```

Open a YouTube 360 video. A **Stream in PSVR2** button is injected into the page.
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
