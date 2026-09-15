@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Foundation
import SwiftXR

@MainActor
final class ShellVideoMode {
    private let session: XRSession
    private let swapchain: XRSwapchain
    private let onRequestHome: () -> Void

    private var mediaOpenTask: Task<Void, Never>?
    private var mediaOpenGeneration = 0

    private var source: VideoSource?
    private var renderer: VideoRenderer?
    private var controller: VideoControllerInput
    private var ambisonic: AmbisonicAudio?

    private let controlsModel: VideoControlsModel
    private let libraryModel: VideoLibraryModel
    private let panel: XRSwiftUIPanel<VideoPlayerRootView>
    private let panelRenderer: VideoControlPanelRenderer
    private let pointerCapture: XRMacPointerCapture
    private let youtubeBrowser: YouTubeBrowserController

    private var panelVisible = true
    private var lastPanelActivity = Date()
    private let panelAutoHideSeconds: TimeInterval = 4
    private var lastYouTubeControllerUpdate = Date()
    private var playbackStarted = false
    private var lastControlsUpdate = Date.distantPast

    init(
        session: XRSession,
        swapchain: XRSwapchain,
        onRequestHome: @escaping () -> Void
    ) throws {
        self.session = session
        self.swapchain = swapchain
        self.onRequestHome = onRequestHome
        controller = VideoControllerInput()

        let controls = VideoControlsModel(
            title: "SwiftXR Shell Video",
            projectionMode: .flat,
            stereoLayout: .mono
        )
        let library = VideoLibraryModel()
        let youtube = YouTubeBrowserController()

        let panel = try XRSwiftUIPanel(
            device: session.device,
            pointSize: CGSize(
                width: YouTubeBrowserController.width,
                height: YouTubeBrowserController.height
            ),
            scale: 1,
            interactionHandler: { _ in }
        ) {
            VideoPlayerRootView(library: library, controls: controls)
        }
        let panelRenderer = try VideoControlPanelRenderer(
            device: session.device,
            swapchain: swapchain,
            panelTexture: panel.texture
        )
        let pointerCapture = XRMacPointerCapture(panel: panel)

        self.controlsModel = controls
        self.libraryModel = library
        self.youtubeBrowser = youtube
        self.panel = panel
        self.panelRenderer = panelRenderer
        self.pointerCapture = pointerCapture

        controls.commandHandler = { [weak self] command in
            guard let self else { return }
            do { try self.handle(command) }
            catch { self.showError(error) }
        }

        library.openMedia = { [weak self] input in self?.beginOpenMedia(input) }
        library.openYouTube = { [weak self] in self?.enterYouTubeBrowser() }
        library.requestHome = { [weak self] in self?.onRequestHome() }

        youtube.onSnapshot = { [weak self] image in
            self?.libraryModel.setYouTubeSnapshot(image)
            self?.panel.invalidate()
        }
        youtube.onStatus = { [weak self] status in
            self?.libraryModel.setYouTubeStatus(status)
            self?.panel.invalidate()
        }
        youtube.onLaunchURL = { [weak self] url in self?.beginOpenMedia(url) }

        panel.interaction.handler = { [weak self] event in
            self?.handlePanelInteraction(event)
        }
    }

    func activate() throws {
        libraryModel.openInitialDirectory()
        panelVisible = true
        panelRenderer.recenter()
        panel.interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
        panel.invalidate()
        try startPointerCaptureIfReady()
        print("[shell] Video active — Home button or Escape returns to launcher")
    }

    func deactivate() {
        mediaOpenGeneration += 1
        mediaOpenTask?.cancel()
        mediaOpenTask = nil
        youtubeBrowser.close()
        pointerCapture.stop()
        source?.pause()
        ambisonic?.pause()
        playbackStarted = false
    }

    func shutdown() {
        deactivate()
        youtubeBrowser.shutdown()
    }

    func renderFrame() throws {
        if pointerCapture.escapeRequested {
            onRequestHome()
            return
        }

        try startPointerCaptureIfReady()

        if source != nil && !playbackStarted && libraryModel.mode != .loading {
            try startPlayback()
            playbackStarted = true
        }

        if let failure = source?.failureDescription {
            throw NSError(
                domain: "SwiftXRShell.Video",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "AVPlayer failed: \(failure)"]
            )
        }

        pointerCapture.poll()
        try applyController(controller.poll())

        if libraryModel.mode == .youtube {
            youtubeBrowser.tick()
        }

        updatePanelVisibility()
        updateControlsModelIfNeeded()
        try panel.refreshIfNeeded()

        let videoFrame = try source?.latestFrame()
        let currentRenderer = renderer
        let showPanel = libraryModel.mode != .controls || panelVisible
        let presentation = panelPresentation(for: libraryModel.mode)

        let xrFrame = try session.renderFrame(to: swapchain) {
            frame,
            texture,
            commandBuffer in

            if let currentRenderer {
                try currentRenderer.encode(
                    frame: frame,
                    swapchainTexture: texture,
                    videoTexture: videoFrame?.texture,
                    commandBuffer: commandBuffer
                )
            }

            if showPanel {
                try panelRenderer.encode(
                    frame: frame,
                    swapchainTexture: texture,
                    panelTexture: panel.texture,
                    pointerPosition: panel.interaction.pointerPosition,
                    commandBuffer: commandBuffer,
                    clearBeforePanel: currentRenderer == nil,
                    worldWidth: presentation.width,
                    distance: presentation.distance,
                    verticalOffset: presentation.verticalOffset
                )
            }
        }

        if let ambisonic,
           xrFrame.trackingState.orientationValid,
           let view = xrFrame.views.first {
            ambisonic.updateHeadOrientation(
                from: view,
                sceneAnchor: renderer?.sceneAnchor
            )
        }
    }

    private func beginOpenMedia(_ input: String) {
        mediaOpenGeneration += 1
        let generation = mediaOpenGeneration
        mediaOpenTask?.cancel()

        libraryModel.showLoading(input.hasPrefix("http") ? "Resolving YouTube video…" : "Opening video…")
        panelVisible = true
        panel.invalidate()
        youtubeBrowser.close()
        source?.pause()
        ambisonic?.pause()
        playbackStarted = false

        mediaOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolved = try await Task.detached(priority: .userInitiated) {
                    try MediaInputResolver.resolve(input)
                }.value
                try Task.checkCancellation()
                guard generation == self.mediaOpenGeneration else { return }

                let projectionMode = VideoProjectionMode.resolve(
                    inputPath: resolved.url.path,
                    youtubeEACHint: resolved.youtubeEACHint
                )
                let newSource = try await VideoSource.open(
                    url: resolved.url,
                    device: self.session.device
                )
                try await newSource.waitUntilReady()
                try Task.checkCancellation()
                guard generation == self.mediaOpenGeneration else { return }

                let stereoLayout = VideoStereoLayout.resolve(
                    inputPath: resolved.url.path,
                    projectionMode: projectionMode,
                    displaySize: newSource.displaySize
                )
                _ = VideoAudioRouting.routeToPSVR2(newSource.player)

                var newAmbisonic: AmbisonicAudio?
                if let sidecar = resolved.ambisonicURL {
                    do {
                        let spatial = try AmbisonicAudio(sidecarURL: sidecar)
                        spatial.setVolume(newSource.volume)
                        newSource.player.isMuted = true
                        newSource.player.automaticallyWaitsToMinimizeStalling = false
                        newAmbisonic = spatial
                    } catch {
                        fputs("[audio] AmbiX unavailable (\(error)); using stereo audio\n", stderr)
                        newSource.player.isMuted = false
                    }
                }

                let newRenderer = try VideoRenderer(
                    device: self.session.device,
                    swapchain: self.swapchain,
                    displaySize: newSource.displaySize,
                    projectionMode: projectionMode,
                    stereoLayout: stereoLayout
                )

                self.source = newSource
                self.ambisonic = newAmbisonic
                self.renderer = newRenderer
                self.playbackStarted = false

                self.controlsModel.title = resolved.url.deletingPathExtension().lastPathComponent
                _ = self.controlsModel.update(
                    isPlaying: false,
                    currentTime: 0,
                    duration: newSource.durationSeconds ?? 0,
                    volume: newSource.volume,
                    projectionMode: projectionMode,
                    stereoLayout: stereoLayout,
                    spatialAudioEnabled: newAmbisonic != nil
                )

                self.libraryModel.showControls()
                self.panelVisible = true
                self.lastPanelActivity = Date()
                self.panelRenderer.recenter()
                self.panel.interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
                self.panel.invalidate()

                try self.startPlayback()
                self.playbackStarted = true
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.mediaOpenGeneration else { return }
                self.libraryModel.showError(String(describing: error))
                self.panelVisible = true
                self.panelRenderer.recenter()
                self.panel.invalidate()
            }
        }
    }

    private func panelPresentation(for mode: VideoPanelMode) -> (
        width: Float,
        distance: Float,
        verticalOffset: Float
    ) {
        switch mode {
        case .youtube: return (2.55, 1.50, -0.03)
        case .files: return (2.15, 1.50, -0.08)
        case .loading: return (2.00, 1.50, -0.08)
        case .controls: return (2.00, 1.50, -0.14)
        }
    }

    private func enterYouTubeBrowser() {
        libraryModel.mode = .youtube
        panelVisible = true
        lastPanelActivity = Date()
        panelRenderer.recenter()
        panel.interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
        panel.invalidate()
        youtubeBrowser.open()
    }

    private func leaveYouTubeToFiles() {
        youtubeBrowser.close()
        libraryModel.showFiles()
        panelVisible = true
        panelRenderer.recenter()
        panel.invalidate()
    }

    private func handlePanelInteraction(_ event: XRPanelInteractionEvent) {
        notePanelActivity()
        guard libraryModel.mode == .youtube else { return }

        switch event {
        case .pointerMoved, .pointerMovedBy:
            youtubeBrowser.pointerMoved()
        case .pointerUp(.primary):
            guard let point = panel.interaction.pointerPosition else { return }
            if point.y <= 0.075 && point.x <= 0.12 {
                leaveYouTubeToFiles()
            } else if point.y <= 0.075 && point.x <= 0.24 {
                if !youtubeBrowser.back() { leaveYouTubeToFiles() }
            } else {
                youtubeBrowser.click(at: point)
            }
        case let .scroll(delta): youtubeBrowser.scroll(delta)
        case .back:
            if !youtubeBrowser.back() { leaveYouTubeToFiles() }
        default: break
        }
    }

    private func startPlayback() throws {
        guard let source else { return }
        if let ambisonic {
            try ambisonic.startSynchronized(
                videoPlayer: source.player,
                mediaTimeSeconds: source.currentTimeSeconds
            )
        } else {
            source.play()
        }
    }

    private func handle(_ command: VideoControlCommand) throws {
        notePanelActivity()

        switch command {
        case .home:
            onRequestHome()
            return
        case .showFiles:
            youtubeBrowser.close()
            libraryModel.showFiles()
            panelVisible = true
            panelRenderer.recenter()
            panel.invalidate()
            return
        case .showYouTube:
            enterYouTubeBrowser()
            return
        default:
            break
        }

        guard let source, let renderer else { return }

        switch command {
        case .togglePlayback:
            if source.isPlaying {
                source.pause()
                ambisonic?.pause()
            } else {
                try startPlayback()
            }
        case let .seekBy(delta):
            try seek(to: source.currentTimeSeconds + delta)
        case let .seekTo(target):
            try seek(to: target)
        case let .setVolume(value):
            source.setVolume(value)
            ambisonic?.setVolume(value)
        case .recenter:
            renderer.recenter()
            panelRenderer.recenter()
        case let .setProjection(mode):
            renderer.setProjectionMode(mode)
            controlsModel.projectionMode = renderer.projectionMode
            controlsModel.stereoLayout = renderer.stereoLayout
            panel.invalidate()
        case let .setStereoLayout(layout):
            renderer.setStereoLayout(layout)
            controlsModel.stereoLayout = renderer.stereoLayout
            panel.invalidate()
        case .showFiles, .showYouTube, .home:
            break
        }
    }

    private func seek(to requestedTime: Double) throws {
        guard let source else { return }
        var target = max(0, requestedTime)
        if let duration = source.durationSeconds { target = min(target, duration) }

        if let ambisonic, source.isPlaying {
            try ambisonic.startSynchronized(
                videoPlayer: source.player,
                mediaTimeSeconds: target
            )
        } else {
            source.player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    private func applyController(_ controls: VideoControllerSnapshot) throws {
        switch libraryModel.mode {
        case .files:
            if controls.navY != 0 { libraryModel.moveSelection(controls.navY); panel.invalidate() }
            if controls.navX != 0 { libraryModel.page(controls.navX); panel.invalidate() }
            if controls.select { libraryModel.activateSelection(); panel.invalidate() }
            if controls.back || controls.menu { onRequestHome() }

        case .youtube:
            let now = Date()
            let dt = min(max(now.timeIntervalSince(lastYouTubeControllerUpdate), 0), 0.05)
            lastYouTubeControllerUpdate = now
            let lx = controls.leftX
            let ly = controls.leftY
            let magnitude = sqrt(lx * lx + ly * ly)
            let deadZone: Float = 0.16
            if magnitude > deadZone && dt > 0 {
                let response = (min(magnitude, 1) - deadZone) / (1 - deadZone)
                let curved = pow(response, 1.45)
                let speed = Float(0.80 * dt) * curved
                panel.interaction.movePointer(
                    by: SIMD2(lx / magnitude * speed, -ly / magnitude * speed)
                )
            }
            if controls.navX != 0 || controls.navY != 0 {
                panel.interaction.movePointer(
                    by: SIMD2(Float(controls.navX) * 0.075, Float(controls.navY) * 0.10)
                )
            }
            if abs(controls.rightY) > 0.18, dt > 0 {
                youtubeBrowser.scroll(SIMD2(0, controls.rightY * Float(dt) * 4.0))
            }
            if controls.select, let point = panel.interaction.pointerPosition {
                youtubeBrowser.click(at: point)
            }
            if controls.back {
                if !youtubeBrowser.back() { leaveYouTubeToFiles() }
            }
            if controls.menu { onRequestHome() }

        case .loading:
            if controls.back || controls.menu { onRequestHome() }

        case .controls:
            if controls.menu {
                panelVisible.toggle()
                lastPanelActivity = Date()
                if panelVisible { panelRenderer.recenter() }
                panel.invalidate()
            }
            if controls.back { onRequestHome() }
            if controls.togglePlay { try handle(.togglePlayback) }
            if controls.seekSteps != 0 { try handle(.seekBy(Double(controls.seekSteps) * 15)) }
            if controls.volumeSteps != 0, let source {
                try handle(.setVolume(source.volume + Float(controls.volumeSteps) * 0.05))
            }
            if controls.recenter { try handle(.recenter) }

            let stickX = stickAfterDeadZone(controls.rightX)
            let stickY = stickAfterDeadZone(controls.rightY)
            if stickX != 0 || stickY != 0 {
                renderer?.tilt(
                    yawRadians: stickX * abs(stickX) * 0.010,
                    pitchRadians: -stickY * abs(stickY) * 0.010
                )
            }
        }
    }

    private func updateControlsModelIfNeeded() {
        guard
            Date().timeIntervalSince(lastControlsUpdate) >= 0.20,
            let source,
            let renderer
        else { return }

        lastControlsUpdate = Date()
        let changed = controlsModel.update(
            isPlaying: source.isPlaying,
            currentTime: source.currentTimeSeconds,
            duration: source.durationSeconds ?? 0,
            volume: source.volume,
            projectionMode: renderer.projectionMode,
            stereoLayout: renderer.stereoLayout,
            spatialAudioEnabled: ambisonic != nil
        )
        if changed, libraryModel.mode == .controls, panelVisible { panel.invalidate() }
    }

    private func notePanelActivity() {
        lastPanelActivity = Date()
        if libraryModel.mode == .controls { panelVisible = true }
        panel.invalidate()
    }

    private func updatePanelVisibility() {
        guard libraryModel.mode == .controls else {
            panelVisible = true
            return
        }
        guard panelVisible, !controlsModel.isScrubbing else { return }
        if Date().timeIntervalSince(lastPanelActivity) >= panelAutoHideSeconds {
            panelVisible = false
        }
    }

    private func startPointerCaptureIfReady() throws {
        guard
            NSApplication.shared.isActive,
            session.isRunning,
            !pointerCapture.isCaptureRequested
        else { return }

        try pointerCapture.start()
        guard pointerCapture.isCaptured else {
            throw XRMacPointerCaptureError.applicationNotActive
        }
    }

    private func showError(_ error: Error) {
        fputs("swiftxr-shell video: \(error)\n", stderr)
        libraryModel.showError(String(describing: error))
        panelVisible = true
        panel.invalidate()
    }

    private func stickAfterDeadZone(_ value: Float) -> Float {
        let deadZone: Float = 0.18
        guard abs(value) > deadZone else { return 0 }
        let scaled = (abs(value) - deadZone) / (1 - deadZone)
        return value.sign == .minus ? -scaled : scaled
    }
}
