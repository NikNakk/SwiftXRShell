# SwiftXR Shell

SwiftXR Shell is a macOS OpenXR launcher and system environment built on [SwiftXR](https://github.com/NikNakk/SwiftXR).

The intended scope is:

- discover and launch installed OpenXR-compatible applications;
- provide an integrated immersive video player;
- provide an integrated virtual desktop;
- remain available as a lightweight system environment while another OpenXR application is running;
- expose return-to-Home, quit and eventually runtime/application settings.

## Current state

The repository currently contains a runnable Home shell with built-in Video, Desktop and Browser modes sharing one OpenXR session, plus external OpenXR application launching on Monado:

- SwiftUI Home rendered into OpenXR through SwiftXR;
- mouse pointer capture and native SwiftUI interaction;
- controller navigation plumbing;
- integrated immersive video player with local files and YouTube support;
- integrated ScreenCaptureKit virtual desktop;
- Home-launchable Chromium browser window with Sense pointing and physical-keyboard text input;
- Home ↔ Video, Home ↔ Desktop and Home ↔ Browser transitions without creating a second OpenXR client;
- explicit external application catalog;
- `.app` bundle and raw executable launching;
- Monado primary/focused-client handoff through SwiftXR's optional `libmonado` wrapper;
- automatic handoff to independently-started immersive OpenXR sessions while Home or Desktop is active;
- automatic restoration of the previous Home/Desktop/Browser mode when that immersive session ends;
- an `XR_EXTX_overlay` system dashboard over both Shell-launched and independently-started immersive applications;
- Resume / Desktop / Home dashboard actions for independently-started sessions, with a temporary Home tile for resuming a still-active session;
- automatic return to Home when a Shell-launched OpenXR application stops presenting or disconnects.

## Build

SwiftXR Shell currently uses the sibling `../SwiftXR` checkout, including the OpenXR controller-action and pointer-refresh changes developed with this app. Keep the two repositories next to each other; a standalone checkout of this app also needs that SDK checkout. The SDK is based on the `swiftxr-video-player-poc` development branch while the required APIs are being upstreamed to SwiftXR `main`.

A Khronos OpenXR loader must be installed where SwiftPM can link it (currently `/usr/local/lib`). Build it with `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0` to match the Shell's minimum macOS version. Leaving this unset can make CMake use the build machine's macOS version, producing a linker warning and a loader that declares a newer OS requirement.

For the sibling Khronos `OpenXR-SDK` checkout:

```sh
cmake -S ../OpenXR-SDK -B .build/openxr-loader-macos14 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DDYNAMIC_LOADER=ON -DBUILD_TESTS=OFF -DBUILD_API_LAYERS=OFF \
  -DBUILD_WITH_SYSTEM_JSONCPP=OFF \
  -DCMAKE_CXX_FLAGS=-DJSONCPP_USING_SECURE_MEMORY=0
cmake --build .build/openxr-loader-macos14 --target openxr_loader --parallel
sudo install -m 755 .build/openxr-loader-macos14/src/loader/libopenxr_loader.dylib /usr/local/lib/libopenxr_loader.dylib
```

The JsonCpp define matches this checkout's bundled JsonCpp configuration. The loader's minimum OS can be checked with `xcrun vtool -show-build /usr/local/lib/libopenxr_loader.dylib`. CI also sets the deployment target explicitly.

```bash
swift build
```

Run with a configured OpenXR runtime, for example:

```bash
XR_RUNTIME_JSON=~/Code/monado/build-macos-psvr2-display/openxr_monado-dev.json \
swift run swiftxr-shell
```

To install it as `SwiftXR Shell.app` (in `/Applications`, or another folder given as an argument):

```bash
scripts/make-app.zsh
```

The installer converts the checked-in 1024px artwork in `Resources/AppIcon.png` into a full macOS `.icns` icon, includes it in the bundle, and registers it in `Info.plist` before signing. Replace that PNG to update the app icon on the next install.

The app finds the runtime from the GUI environment or `/usr/local/share/openxr/1/active_runtime.json`, and still loads the OpenXR loader from `/usr/local/lib`. It is signed with the keychain's Apple Development identity when there is exactly one, and otherwise ad hoc; set `SIGN_IDENTITY` to choose an identity, or `-` for ad hoc. With ad hoc signing, macOS may ask again for Screen Recording and Accessibility after each rebuild. Logs, including frame timing, are written to `~/Library/Logs/SwiftXRShell/shell.log` (rotated between launches above 4 MB).

Tracked controllers are the default input in Home and Video whenever OpenXR reports an active hand. Monado maps PS VR2 Sense controllers to the standard Touch interaction profile. With no active tracked controllers, mouse capture and conventional gamepad controls remain available. Tracking occlusion hides the pointer and cancels a drag; it does not switch to the mouse. Losing OpenXR focus or changing modes also releases any held pointer button.

- Aim at a panel and press its trigger to click; hold the trigger to drag sliders. The right hand is preferred initially; pressing the other hand's trigger transfers the pointer when no drag is in progress.
- Use the **right thumbstick** to scroll where vertical scrolling is available (Home and YouTube). Home targets the view under the pointer, or its main scroll view when the ray is outside it. The left stick does not scroll. The paginated Video file list uses its on-screen page controls.
- During video playback, **left grip** jumps back **10 seconds**, **right grip** jumps forward **10 seconds**, and **Cross / A** toggles pause/play. Square / X on the left hand also toggles playback. Face buttons select items in the library; triggers always operate the pointed-at UI. Conventional gamepads use Cross / A for playback and L1/R1 for the same 10-second seek steps.
- **Circle / B** returns from Video to Home, or navigates back within YouTube. **Triangle / Y** on the left controller recentres the shared stage. The Touch menu action toggles playback controls, or returns Home from the library; availability of the Sense PS/menu button depends on runtime bindings.
- Playback controls auto-hide after inactivity. A trigger press reveals hidden controls without clicking through them; the next press can activate a control.
- **Escape** returns from Video/Desktop to Home; Escape from Home exits the Shell. Browser keeps Escape for Chromium and uses **Shift+Cmd+H** or its controller menu action for Home.
- Holding **Options** to reset Monado's stage also recentres the Shell. The Shell follows the runtime's LOCAL/STAGE reference-space-change event at its effective display time, rather than implementing a second hold gesture that could race the runtime.

Home's OpenXR wait, tracking, cursor and stereo rendering run on a dedicated thread. AppKit input and panel snapshots remain on the main thread and publish immutable textures; a button or scroll update cannot hold up headset frames. Button edges are preserved while motion updates are coalesced if the UI is busy. Ordinary pointer movement does not re-rasterize the panel. Panel updates reuse a CPU bitmap and upload directly, without making a temporary GPU texture and reading it back. Native scrolling preserves fractional points instead of rounding each XR input sample. A process activity prevents App Nap during built-in XR presentation.

Home scrolling is interpolated on the GPU between adjacent captures, using their captured viewport and scroll positions. Headers and footers remain fixed. Native scrollbars use a dedicated gutter; the complete content viewport is interpolated up to its real edge, without a fixed-width excluded strip. The interpolation adds up to one capture of visual latency; a pointer press catches up to the native hit-test position immediately. Content/model changes reset interpolation. Off-screen windows honor the requested panel scale, so Home's scale 1 does not silently acquire four times the pixel work on a Retina Mac.

Run `swift test` for routing, hit-testing and redraw regression checks. With a configured OpenXR runtime, `SWIFTXR_TEST_RUNTIME=1 swift test --filter ControllerRuntimeTests` additionally validates real action bindings and session attachment without beginning an immersive session.

Run `SWIFTXR_TEST_RUNTIME=1 swift test --filter HomeFrameLoopTests` **separately** to check that XR rendering continues through a deliberate 600 ms main-thread stall. This test briefly begins an XR session. Do not run it concurrently with the controller runtime test: the OpenXR loader allows one live instance per process. The log distinguishes `[xr-home]` headset frames/rendered frames from `[timing] home UI` updates and reports maximum frame gaps and UI update times.

`SWIFTXR_TEST_HOME_PERFORMANCE=1 swift test --filter HomePanelPerformanceTests` measures capture costs while scrolling the installed Steam library; it does not launch games.

## Desktop status window and menus

A lightweight desktop window shows the foreground Shell mode or external VR app,
the current video title when applicable, the runtime and the preferred input.
It updates when status changes. If the initial OpenXR connection fails, it stays open with a Headset unavailable status and a **Mode → Connect / Retry Headset** action (Cmd+K). Closing it leaves VR running; use **Window →
Show Status Window** (Cmd+0) to reopen it, or **Quit SwiftXR Shell** (Cmd+Q) to quit.

The **Mode** menu provides Home (Cmd+1), Video (Cmd+2), Desktop (Cmd+3), Browser (Cmd+4), Recenter
Shell (Cmd+R), and Stop Launched VR App. Mode switches are disabled while an owned
external VR app is foreground; stop it first. Independently-started sessions can
return Home through the existing handoff path. **Input → Capture Mouse in
Headset** (Cmd+Shift+M) releases/re-enables mouse capture so desktop controls remain
usable with mouse fallback. XR pointer hover does not steal desktop window focus.
A GPU graph is deferred; no GPU polling is added to this window.

Shared stage resets now invalidate the immersive video's projection anchor and
transform flat video through the same stage. Panel captures start with a cleared
alpha channel, so switching from the library to playback leaves transparent
margins and repeated refreshes preserve the overlay's intended opacity.

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

### Steam launch diagnostics

Windows Steam entries run through the configured Wine runner. The runner
provisions the Win64 Khronos `openxr_loader.dll` into the selected prefix for
xrizer. The host Mac's OpenXR loader dylib is a separate component.

The normal Steam launch entry is preserved. If it is 32-bit and the selected
Wine runtime lacks WoW64's 32-bit `ntdll.dll`, a preflight rejects it with the
specific compatibility error. Assetto Corsa's default launcher is such an entry;
it is not silently replaced with the 64-bit race engine. Failed runner output
is captured and shown in Home with a Dismiss action, as well as in `shell.log`.

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

Automatic handoff/resume is enabled from **Home, Desktop and Browser**. Desktop capture is stopped while the external application is presenting to avoid consuming GPU and ScreenCaptureKit resources, then restarted on return; the macOS desktop and browser window themselves are never closed or recreated. Browser mode uses the same capture suspension and restores its selected Chromium window on return. Video mode is deliberately excluded until playback-preserving suspend/resume semantics are added.

Shell-launched applications continue to use the explicit launcher path, including process ownership. The automatic watcher is suppressed while that launcher path is active so the two mechanisms cannot race.

When an independently-started session is foreground, SwiftXR Shell also prepares its `XR_EXTX_overlay` dashboard. Pressing the configured system-menu button can **Resume** the immersive application, switch to the integrated **Desktop**, or return to **Home**. Desktop/Home hand presentation back to the Shell without terminating the external OpenXR session. That client is then suppressed from automatic takeover and Home shows a temporary **Resume <application>** tile. Selecting it restores the still-active session as primary/focused. If the external session ends while suppressed, the tile disappears automatically.

SwiftXR searches for `libmonado.dylib` in this order:

1. `SWIFTXR_LIBMONADO_PATH`, if set;
2. the active runtime manifest's `MND_libmonado_path` and runtime-library directory, resolving manifest symlinks and relative paths, followed by development-build locations;
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

## Chromium browser

Select **Browser** in Home, or **Mode → Browser** (Cmd+4). The Shell launches
our Chromium build with OpenXR enabled, captures the complete window (including
tabs and address bar) into a 2.8 metre panel, and keeps Chromium running when you
leave Browser. Returning to Browser reuses the selected window and its tabs.
The dedicated profile also allows reattachment after restarting the Shell.

The default build is:

```text
~/Code/chromium/src/out/mac-webxr/Chromium.app
```

Set `SWIFTXR_CHROMIUM_PATH` to a different Chromium `.app` or executable before
starting the Shell. This must be the macOS OpenXR Chromium fork; ordinary
Chromium does not supply this fork's macOS WebXR backend. Browser inherits the
Shell's runtime and IPC environment. Quit the dedicated Chromium process as
well if changing that environment between runs.

The persistent browser profile is separate from your regular Chromium profile:

```text
~/Library/Application Support/SwiftXRShell/Chromium
```

Screen Recording permission is required for the window surface. Accessibility
permission is required for Sense-generated native input and the global Home
shortcut; Browser requests it on entry. Grant the permissions to the installed
Shell app (or the launching terminal when running through SwiftPM). macOS may
require restarting the Shell after a permission change. Browser failures return
to Home with an error instead of terminating the Shell.

- Aim with Sense; trigger clicks and drags, and the right stick scrolls under
  the pointer. A cyan cursor is drawn by the Shell. Tracking/focus loss and mode
  changes release a held trigger outside the browser window.
- Clicking a text field or address bar focuses Chromium for a **physical
  keyboard**. There is no virtual keyboard in this version.
- Circle / B navigates back. The Touch menu action returns Home (its availability
  on Sense depends on runtime bindings). **Shift+Cmd+H** also returns Home while
  Chromium has keyboard focus. Escape is left to Chromium for browser UI and
  exiting immersive content. The Shell's Mode menu remains available too.
- A website's **Enter VR** action uses Chromium's own WebXR session. With
  Monado/libmonado handoff available, the Shell suspends its browser capture,
  yields the HMD, and restores Browser when that session ends. Tabs stay alive.
  The existing XR dashboard can also return Home or Desktop while keeping the
  immersive session resumable.

This version uses a **normal macOS window**, which is also present on the Mac's
current display. It does not capture the surrounding desktop. Single-window
capture excludes other windows covering Chromium, but Chromium still needs
keyboard focus for typing. Keep it open and unminimised; capture of separate native menus/dialogs is future work for this path. The
temporary Browser (Viz) tile below provides a separate headset-only experiment. Resizing
the desktop window scales its full contents into the fixed browser panel; input
coordinates follow the current window bounds in Quartz points, including Retina
and multiple-display origins. Physical mouse input remains available in the
Mac window; the headset cursor in this version follows Sense.

`swift test --filter Browser` runs configuration, controller-to-native input and
Metal shader checks without starting VR. The optional desktop acceptance test:

```sh
SWIFTXR_TEST_BROWSER=1 swift test --filter BrowserIntegrationTests
```

requires Screen Recording and Accessibility already granted to the test runner.
It opens a local fixture in a temporary Chromium profile, checks native trusted
click activation and text input, and compares window-capture pixels before and
after covering the window. It closes only that test browser. It does not start
an XR session. In-headset acceptance still needs to check Sense aim alignment,
scroll/drag behaviour, keyboard focus, Enter VR, exit-to-Browser, and return Home
without closing tabs. Quest store downloads and APK launch are not included.

## Temporary Browser (Viz) comparison

Home now also contains **Browser (Viz)** beside the existing **Browser** tile.
Both use our macOS WebXR Chromium fork and a 2.8 metre wide page/window surface.
The two paths are deliberately separate:

| | Browser | Browser (Viz) |
|---|---|---|
| Pixels | ScreenCaptureKit captures a normal Chromium window | Viz captures the page into an IOSurface, imported by Metal |
| Mac window | Open and unminimised; may be covered | Chromium runs headless, with no visible desktop window |
| Browser controls | Chromium tabs, address bar and native UI | Shell Home / Back / Forward / Reload / address bar / Allow VR |
| Input | Native events addressed to the Chromium window | Browser-process IPC forwards input through Chromium's input APIs |
| Permissions for this surface | Screen Recording; Accessibility for Sense input | Neither Screen Recording nor Accessibility |
| Profile | `SwiftXRShell/Chromium` | `SwiftXRShell/ChromiumViz` |

Viz capture can involve a GPU copy inside Chromium. The Shell imports the
exported IOSurface without a CPU pixel readback; it does not use screenshots,
ScreenCaptureKit, CEF, DevTools screencasting or a network debugging port.
The bridge holds Viz's frame-pool credit until the last Shell/GPU reader releases
that frame, and limits the number of outstanding surfaces. The Mach endpoint is
unique to each launch and both ends validate the sender's process ID.

Use Sense aim/trigger for both the page and toolbar, and the right stick for
page scrolling. A drag crossing the toolbar/page boundary is cancelled. Select
the address field or press **Cmd+L** to enter a URL; click a page field for
physical-keyboard typing. **Shift+Cmd+H**, the toolbar's **Home**, or the controller
menu action returns Home. Circle / B navigates back.

Before using a site's Enter VR button, select **Allow VR & reload** once. This
explicitly grants VR to the current secure HTTP(S) origin in the comparison
profile, then reloads the page to clear any already-pending invisible prompt.
The button becomes **VR allowed** for that site. Navigation races cannot grant
a different origin. This does not grant camera, microphone, eye tracking or
other permissions; their native prompts remain outside this prototype's UI.

The offscreen process keeps its page alive through Home visits. Capture stops
while Home or another immersive client is presenting. The page remains logically
visible during suspension so entering WebXR does not immediately lose page
visibility/focus. Physical keys continue to reach its WebXR session while the
Shell remains the foreground Mac app. The hidden browser is stopped when the
Shell quits; its profile persists on disk.

This comparison exposes a single active page rather than Chromium's complete
browser UI. Native menus, popup windows, file dialogs, permission prompts,
download UI and extension UI are not yet adapted into the headset surface.
They should not be treated as equivalent to the normal Browser path. The
experiment does not change Chromium's behaviour without its explicit bridge
switch. Existing windows opened before rebuilding Chromium should be restarted
before comparing browser versions.

### Build the experiment

The opt-in Chromium source and an idempotent installer are kept in this repo:

```sh
python3 scripts/apply-chromium-viz.py ../chromium/src
cd ../chromium/src
PATH="$HOME/Code/depot_tools:$PATH" autoninja -C out/mac-webxr chrome -j 8
cd ../SwiftXRShell
swift build
```

The installer adds the bridge and macOS startup/shutdown hooks to the sibling
checkout, preserving its existing WebXR changes. Keep using **autoninja**, which
selects the configured Siso runner for this output directory. Rebuild the Shell
app with `scripts/make-app.zsh` to get both Home tiles in an installed bundle.

`SWIFTXR_VIZ_CHROMIUM_PATH` optionally selects a different patched Chromium
`.app` or executable for the comparison tile. The ordinary Browser tile keeps
using `SWIFTXR_CHROMIUM_PATH`. Both default to `out/mac-webxr/Chromium.app`.
The experiment uses `--headless --enable-gpu --enable-features=OpenXR` plus a private
`--swiftxr-viz-service` endpoint. If that build has no bridge or fails to produce
GPU frames, the tile returns Home with a diagnostic; it never substitutes the
window-capture path. Browser logs are at:

```text
~/Library/Application Support/SwiftXRShell/ChromiumViz/swiftxr-viz.log
```

`swift test --filter VizPanelInputTests` checks geometry, boundary/drag
cancellation and both Home tiles. The additional desktop-only tests are:

```sh
SWIFTXR_TEST_VIZ_TRANSPORT=1 swift test --filter VizTransportTests
SWIFTXR_TEST_VIZ=1 swift test --filter VizBrowserIntegrationTests
```

The transport test uses a test-only IOSurface producer to check Mach transfer,
Metal import and frame-release lifetime. The Chromium acceptance test uses a
disposable real browser profile and local fixture to check page orientation,
trusted clicks/user activation, keyboard input, scrolling, suspension/resume,
and absence of an on-screen browser window. Neither starts an OpenXR session
or requires Screen Recording/Accessibility. In-headset WebXR handoff, controller
alignment, visual quality and perceived latency still need hardware acceptance.

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
├── Chromium Browser window + Sense input
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
