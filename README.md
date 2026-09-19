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
- automatic handoff to independently-started immersive OpenXR sessions while Home or Desktop is active;
- automatic restoration of the previous Home/Desktop mode when that immersive session ends;
- an `XR_EXTX_overlay` system dashboard over both Shell-launched and independently-started immersive applications;
- Resume / Desktop / Home dashboard actions for independently-started sessions, with a temporary Home tile for resuming a still-active session;
- automatic return to Home when a Shell-launched OpenXR application stops presenting or disconnects.

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

While the external application is primary, SwiftXR Shell remains connected and submits empty frames rather than rendering Home. Once a launched client's session has become active, the Shell restores itself when that session stops presenting even if the OpenXR client remains connected.

### Independently-started immersive sessions

SwiftXR Shell also watches Monado's client state for immersive sessions that were not launched by the Shell. This is intended for flows such as Chromium WebXR:

```text
SwiftXR Desktop
      |
      +-- Chromium window
             |
             +-- user selects Enter VR
                      |
                      v
              Chromium sessionActive
                      |
                      v
              Shell yields HMD
                      |
                 WebXR session
                      |
                 session ends
                      |
                      v
              Shell restores Desktop
```

A connected OpenXR client by itself does **not** trigger a handoff. This is important for browsers, which may keep an OpenXR instance connected for device/runtime polling while no immersive WebXR session exists. The watcher waits for Monado's `sessionActive` state, makes that client primary/focused, and restores SwiftXR Shell as soon as the session becomes inactive or the client disappears.

For the initial implementation, automatic handoff/resume is enabled from **Home and Desktop**. Desktop capture is stopped while the external application is presenting to avoid consuming GPU and ScreenCaptureKit resources, then restarted on return; the macOS desktop and browser window themselves are never closed or recreated. Video mode is deliberately excluded until playback-preserving suspend/resume semantics are added.

Shell-launched applications continue to use the explicit launcher path, including process ownership. The automatic watcher is suppressed while that launcher path is active so the two mechanisms cannot race.

When an independently-started session is foreground, SwiftXR Shell also prepares its `XR_EXTX_overlay` dashboard. Pressing the configured system-menu button can **Resume** the immersive application, switch to the integrated **Desktop**, or return to **Home**. Desktop/Home hand presentation back to the Shell without terminating the external OpenXR session. That client is then suppressed from automatic takeover and Home shows a temporary **Resume <application>** tile. Selecting it restores the still-active session as primary/focused. If the external session ends while suppressed, the tile disappears automatically.

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

## System overlay

SwiftXR Shell creates a small independent OpenXR overlay session using `XR_EXTX_overlay` for foreground external applications. This now covers both applications launched from the Shell and independently-started sessions such as Chromium WebXR. The overlay normally submits no visible layer. Pressing the configured controller button displays a small head-locked system menu over the foreground XR application.

The default trigger is `home`, which maps to `GCExtendedGamepad.buttonHome` and is intended to be the PS button on a DualSense controller. SwiftXR Shell enables GameController background monitoring while an external application has macOS foreground focus.

The menu controls are:

- configured trigger button: show/hide the overlay;
- D-pad up/down: choose an action;
- Cross / A: activate the selected action;
- Circle / B: resume and hide the overlay.

For applications launched by SwiftXR Shell, the actions are **Resume** and **Quit Application**. Quit asks the process owned by the Shell to terminate.

For independently-started applications such as Chromium WebXR, the actions are **Resume**, **Desktop**, and **Home**. The Shell does not try to kill a process it does not own. Desktop/Home instead switch Monado primary/focus back to SwiftXR Shell while keeping the external OpenXR session alive and resumable.

The first run creates:

```text
~/Library/Application Support/SwiftXRShell/settings.json
```

with:

```json
{
  "systemOverlayButton": "home"
}
```

Supported values are `home`, `menu`, and `options`. Restart SwiftXR Shell after changing the setting.

The runtime must expose `XR_EXTX_overlay` for the true composited overlay. If overlay creation fails, the external application still launches and the failure is logged; the system menu is simply unavailable for that launch.

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
├── automatic external-session handoff (WebXR and other independently-started apps)
└── persistent system environment
    ├── controller-triggered XR dashboard
    │   ├── Resume
    │   ├── Desktop / Home for independently-started sessions
    │   └── Quit Application for Shell-launched sessions
    ├── Home
    ├── Settings
    └── Quit
         ↓
       SwiftXR
         ├── OpenXR wrapper + XR_EXTX_overlay support
         └── optional Monado runtime control
               ↓
          OpenXR runtime / Monado service
```

The Shell remains separate from SwiftXR itself: SwiftXR is the reusable SDK/framework; SwiftXR Shell is a user-facing environment built with it.
