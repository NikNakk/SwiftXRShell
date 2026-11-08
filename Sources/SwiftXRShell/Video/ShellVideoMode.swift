@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreMedia
import Foundation
import QuartzCore
import SwiftXR

@MainActor
final class ShellVideoMode {
    var onStatusChanged: (() -> Void)?
    var mouseCaptureEnabled = true {
        didSet { if !mouseCaptureEnabled { pointerCapture.stop() } }
    }
    var statusTitle: String {
        switch libraryModel.mode {
        case .files: return "Video library"
        case .youtube: return "YouTube"
        case .loading: return "Opening video…"
        case .controls: return controlsModel.title
        }
    }
    private let session: XRSession
    private let swapchain: XRSwapchain
    private let onRequestHome: () -> Void
    private let trackedInput: ShellTrackedInput
    private var libraryObservation: AnyCancellable?

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
        trackedInput: ShellTrackedInput,
        onRequestHome: @escaping () -> Void
    ) throws {
        self.session = session
        self.swapchain = swapchain
        self.trackedInput = trackedInput
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
        panel.refreshesOnPointerMovement = false
        libraryObservation = library.objectWillChange.sink { [weak self, weak panel] _ in
            DispatchQueue.main.async { panel?.invalidate(); self?.onStatusChanged?() }
        }

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
        trackedInput.reset(interaction: panel.interaction)
        source?.pause()
        ambisonic?.pause()
        playbackStarted = false
    }

    func shutdown() {
        deactivate()
        youtubeBrowser.shutdown()
    }

    func renderFrame() throws {
        if session.state != .focused {
            trackedInput.suspend(interaction: panel.interaction)
            pointerCapture.stop()
        }
        if pointerCapture.escapeRequested {
            onRequestHome()
            return
        }

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

        if libraryModel.mode == .youtube {
            youtubeBrowser.tick()
        }

        updatePanelVisibility()
        updateControlsModelIfNeeded()
        let refreshStarted = CACurrentMediaTime()
        let refreshed = try panel.refreshIfNeeded()
        ShellDiagnostics.shared.recordPanelUpdate(seconds: CACurrentMediaTime() - refreshStarted, refreshed: refreshed)

        let videoFrame = try source?.latestFrame()
        let currentRenderer = renderer
        let presentation = panelPresentation(for: libraryModel.mode)
        var trackedCommands = TrackedPanelCommands()

        let xrFrame = try session.renderFrame(to: swapchain) {
            frame,
            texture,
            commandBuffer in

            ShellStageAnchor.shared.updateIfNeeded(from: frame)
            trackedCommands = try trackedInput.update(
                frame: frame, interaction: panel.interaction,
                model: ShellStageAnchor.shared.modelMatrix(
                    worldWidth: presentation.width,
                    textureAspect: Float(panel.texture.width) / Float(panel.texture.height),
                    distance: presentation.distance, verticalOffset: presentation.verticalOffset
                ),
                pointerEnabled: libraryModel.mode != .controls || panelVisible,
                faceButtonsSelect: libraryModel.mode != .controls,
                scrollEnabled: libraryModel.mode == .youtube
            )
            if trackedCommands.usesControllers || !trackedInput.isFocused {
                pointerCapture.stop()
            } else {
                try startPointerCaptureIfReady()
                pointerCapture.poll()
            }
            if trackedCommands.hasActivity && !trackedCommands.menu { notePanelActivity(redraw: false) }

            if let currentRenderer {
                try currentRenderer.encode(
                    frame: frame,
                    swapchainTexture: texture,
                    videoTexture: videoFrame?.texture,
                    commandBuffer: commandBuffer
                )
            }

            if libraryModel.mode != .controls || panelVisible {
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

        if trackedInput.isFocused {
            if trackedCommands.usesControllers { try applyTrackedCommands(trackedCommands) }
            else { try applyController(controller.poll()) }
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
                let progress: MediaInputProgressHandler = { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.mediaOpenGeneration else { return }
                        self.libraryModel.showLoading(message)
                        self.panel.invalidate()
                    }
                }

                let resolved = try await Task.detached(priority: .userInitiated) {
                    try MediaInputResolver.resolve(input, progress: progress)
                }.value
                try Task.checkCancellation()
                guard generation == self.mediaOpenGeneration else { return }

                self.libraryModel.showLoading("Preparing playback…")
                self.panel.invalidate()

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
                self.onStatusChanged?()
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
        case .youtube: return (2.85, 1.50, -0.03)
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
        switch event {
        case .pointerMoved, .pointerMovedBy, .pointerExited:
            if !trackedInput.usesControllers { notePanelActivity(redraw: false) }
        default: notePanelActivity()
        }
        guard libraryModel.mode == .youtube else { return }

        switch event {
        case .pointerMoved, .pointerMovedBy:
            youtubeBrowser.pointerMoved()
        case .pointerUp(.primary):
            guard let point = panel.interaction.pointerPosition else { return }
            if point.y <= 0.075 && point.x <= 0.08 {
                leaveYouTubeToFiles()
            } else if point.y <= 0.075 && point.x <= 0.15 {
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
            ShellStageAnchor.shared.requestRecenter()
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
            if controls.seekSteps != 0 { try handle(.seekBy(Double(controls.seekSteps) * 10)) }
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

    private func applyTrackedCommands(_ commands: TrackedPanelCommands) throws {
        if commands.seekSteps != 0 { try handle(.seekBy(Double(commands.seekSteps) * 10)) }
        if commands.togglePlay && libraryModel.mode == .controls { try handle(.togglePlayback) }
        if commands.recenter {
            ShellStageAnchor.shared.requestRecenter()
            if renderer != nil { try handle(.recenter) }
        }
        if commands.back {
            if libraryModel.mode == .youtube {
                if !youtubeBrowser.back() { leaveYouTubeToFiles() }
            } else { onRequestHome() }
        }
        if commands.menu {
            if libraryModel.mode == .controls {
                panelVisible.toggle()
                lastPanelActivity = Date()
                panel.invalidate()
            } else { onRequestHome() }
        }
    }

    private func notePanelActivity(redraw: Bool = true) {
        lastPanelActivity = Date()
        let wasVisible = panelVisible
        if libraryModel.mode == .controls { panelVisible = true }
        if redraw || !wasVisible { panel.invalidate() }
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
            mouseCaptureEnabled,
            !trackedInput.usesControllers,
            trackedInput.isFocused,
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
