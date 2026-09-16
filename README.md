# SwiftXR Shell

SwiftXR Shell is a macOS OpenXR launcher and system environment built on [SwiftXR](https://github.com/NikNakk/SwiftXR).

The intended scope is:

- discover and launch installed OpenXR-compatible applications;
- provide an integrated immersive video player;
- provide an integrated virtual desktop;
- remain available as a lightweight system environment while another OpenXR application is running;
- expose return-to-Home, quit and eventually runtime/application settings.

## Current state

The repository currently contains a runnable Home shell with built-in Video and Desktop modes sharing one OpenXR session, plus external OpenXR application launching on Monado:

- SwiftUI Home rendered into OpenXR through SwiftXR;
- mouse pointer capture and native SwiftUI interaction;
- controller navigation plumbing;
- integrated immersive video player with local files and YouTube support;
- integrated ScreenCaptureKit virtual desktop;
- Home ↔ Video and Home ↔ Desktop transitions without creating a second OpenXR client;
- explicit external application catalog;
- `.app` bundle and raw executable launching;
- Monado primary/focused-client handoff through SwiftXR's optional `libmonado` wrapper;
- automatic return to Home when the launched OpenXR client disconnects.

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

## External OpenXR applications

For now, external application discovery is deliberately explicit and deterministic. SwiftXR Shell reads:

```text
~/Library/Application Support/SwiftXRShell/apps.json
```

The Shell creates this file containing an empty JSON array the first time it runs. Set `SWIFTXR_SHELL_APPS` to use a different catalog path.

A catalog entry looks like this:

```json
[
  {
    "id": "open-brush",
    "title": "Open Brush",
    "subtitle": "3D painting",
    "systemImage": "paintbrush.fill",
    "path": "/Applications/Open Brush.app",
    "arguments": [],
    "environment": {},
    "openXRApplicationName": "Open Brush"
  }
]
```

`path` may point either to a macOS `.app` bundle or directly to an executable. `~` is expanded. `arguments` and `environment` are optional. External applications inherit the Shell process environment and then apply any per-application environment overrides.

`openXRApplicationName` is optional. When supplied, the launcher uses it to disambiguate the new Monado client if launching the application creates more than one OpenXR client. In the usual one-client case it is not required.

See [`apps.example.json`](apps.example.json) for a larger example.

### Monado handoff

The launcher uses `XRMonadoRuntimeControl` from SwiftXR rather than spawning `monado-ctl`. SwiftXR dynamically loads `libmonado.dylib`, snapshots the current Monado client list, launches the application, detects the new non-overlay OpenXR client, and makes it primary and focused.

While the external application is primary, SwiftXR Shell remains connected and submits empty frames rather than rendering Home. When the external OpenXR client disappears, the Shell makes its original client primary/focused again and returns to Home.

SwiftXR searches for `libmonado.dylib` in this order:

1. `SWIFTXR_LIBMONADO_PATH`, if set;
2. the Monado build tree inferred from `XR_RUNTIME_JSON`;
3. the normal dynamic-loader search path;
4. `/usr/local/lib`;
5. `/opt/homebrew/lib`.

If the Monado development build places the library somewhere else, set for example:

```bash
SWIFTXR_LIBMONADO_PATH=~/Code/monado/build-macos-psvr2-display/src/xrt/targets/libmonado/libmonado.dylib \
XR_RUNTIME_JSON=~/Code/monado/build-macos-psvr2-display/openxr_monado-dev.json \
swift run swiftxr-shell
```

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
├── external OpenXR application catalog + launch
└── persistent system environment
    ├── Resume
    ├── Home
    ├── Settings
    └── Quit
         ↓
       SwiftXR
         ├── OpenXR wrapper
         └── optional Monado runtime control
               ↓
          OpenXR runtime / Monado service
```

The Shell remains separate from SwiftXR itself: SwiftXR is the reusable SDK/framework; SwiftXR Shell is a user-facing environment built with it.
