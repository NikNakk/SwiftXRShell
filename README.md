# SwiftXR Shell

SwiftXR Shell is a macOS OpenXR launcher and system environment built on [SwiftXR](https://github.com/NikNakk/SwiftXR).

The intended scope is:

- discover and launch installed OpenXR-compatible applications;
- provide an integrated immersive video player;
- provide an integrated virtual desktop;
- remain available as a lightweight system overlay while another OpenXR application is running;
- expose return-to-Home, quit and eventually runtime/application settings from that overlay.

## Current state

The repository currently contains a runnable Home shell with built-in Video and Desktop modes sharing one OpenXR session:

- SwiftUI Home rendered into OpenXR through SwiftXR;
- mouse pointer capture and native SwiftUI interaction;
- controller navigation plumbing;
- integrated immersive video player with local files and YouTube support;
- integrated ScreenCaptureKit virtual desktop;
- Home ↔ Video and Home ↔ Desktop transitions without creating a second OpenXR client.

## Build

SwiftXR Shell currently depends on the `swiftxr-video-player-poc` SwiftXR development branch while the required APIs are being upstreamed to SwiftXR `main`.

A Khronos OpenXR loader must be installed where SwiftPM can link it (currently `/usr/local/lib`).

```bash
swift build
```

Run with a configured OpenXR runtime, for example:

```bash
XR_RUNTIME_JSON=~/Code/monado/build-macos-psvr2-display/openxr_monado-dev.json \
swift run swiftxr-shell
```

Move the mouse to point and click to activate a tile. Escape returns from a built-in mode to Home; Escape from Home exits the Shell.

## Virtual desktop size

The virtual desktop preserves the captured display's aspect ratio. Its default physical width is **3.2 metres** at the current 2.0 metre viewing distance.

Override the width with `SWIFTXR_DESKTOP_WIDTH_METERS`. Values are clamped to 0.75–8.0 metres. For example:

```bash
SWIFTXR_DESKTOP_WIDTH_METERS=4.0 \
XR_RUNTIME_JSON=~/Code/monado/build-macos-psvr2-display/openxr_monado-dev.json \
swift run swiftxr-shell
```

The selected physical width and resulting height are printed when Desktop starts.

## Direction

The planned high-level architecture is:

```text
SwiftXR Shell
├── Home / app launcher
├── integrated Video Player
├── integrated Virtual Desktop
├── external OpenXR application discovery + launch
└── persistent system overlay
    ├── Resume
    ├── Home
    ├── Settings
    └── Quit
         ↓
       SwiftXR
         ↓
   OpenXR runtime
```

The Shell should stay separate from SwiftXR itself: SwiftXR is the reusable SDK/framework; SwiftXR Shell is a user-facing environment built with it.
