# SwiftXR Shell

SwiftXR Shell is a macOS OpenXR launcher and system environment built on [SwiftXR](https://github.com/NikNakk/SwiftXR).

The intended scope is:

- discover and launch installed OpenXR-compatible applications;
- provide an integrated immersive video player;
- provide an integrated virtual desktop;
- remain available as a lightweight system overlay while another OpenXR application is running;
- expose return-to-Home, quit and eventually runtime/application settings from that overlay.

## Current state

The repository currently contains the first runnable Home shell:

- SwiftUI Home rendered into OpenXR through SwiftXR;
- mouse pointer capture and native SwiftUI interaction;
- controller navigation plumbing;
- built-in Video and Desktop entries represented through the same application model future external OpenXR apps will use.

The Video and Desktop entries are placeholders while their working implementations are migrated from the SwiftXR examples into this repository.

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

Move the mouse to point, click to activate a tile, and press Escape to exit.

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
