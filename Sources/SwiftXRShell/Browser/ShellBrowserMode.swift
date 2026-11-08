import AppKit
@preconcurrency import ApplicationServices
import Metal
import SwiftXR

@MainActor
final class ShellBrowserMode: ShellBrowserPresentation {
    private let session: XRSession
    private let swapchain: XRSwapchain
    private let trackedInput: ShellTrackedInput
    private let browser: BrowserApplication
    private let onRequestHome: () -> Void
    private let onFailure: (Error) -> Void
    var onStatusChanged: (() -> Void)?
    private(set) var status = "Starting Chromium…" {
        didSet { onStatusChanged?() }
    }
    private let interaction = XRPanelInteraction()
    private var input: BrowserPointerInput?
    private var capture: BrowserWindowCapture?
    private var renderer: DesktopRenderer?
    private var setupTask: Task<Void, Never>?
    private var lastWindowCheck: TimeInterval = 0
    private var active = false
    private var transitionRequested = false

    init(session: XRSession, swapchain: XRSwapchain, trackedInput: ShellTrackedInput,
         browser: BrowserApplication, onRequestHome: @escaping () -> Void,
         onFailure: @escaping (Error) -> Void) {
        self.session = session
        self.swapchain = swapchain
        self.trackedInput = trackedInput
        self.browser = browser
        self.onRequestHome = onRequestHome
        self.onFailure = onFailure
        interaction.handler = { [weak self] event in self?.input?.handle(event) }
    }

    func activate() {
        active = true
        transitionRequested = false
        status = "Starting Chromium…"
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var startingCapture: BrowserWindowCapture?
            do {
                guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                    throw BrowserError.screenRecordingDenied
                }
                let window = try await browser.window()
                try Task.checkCancellation()
                guard let pid = window.owningApplication?.processID else { throw BrowserError.noWindow }
                let capture = try BrowserWindowCapture(window: window, device: session.device)
                startingCapture = capture
                let renderer = try DesktopRenderer(device: session.device, swapchain: swapchain,
                    capturedPixelSize: window.frame.size, widthMeters: 2.8)
                try await capture.start()
                try Task.checkCancellation()
                self.capture = capture
                self.renderer = renderer
                let input = BrowserPointerInput(pid: pid, windowID: window.windowID, frame: window.frame)
                self.input = input
                trackedInput.reset(interaction: interaction)
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                let trusted = AXIsProcessTrustedWithOptions(options)
                status = trusted ? "Chromium · trigger selects · right stick scrolls · menu returns Home"
                    : BrowserError.accessibilityDenied.localizedDescription
                input.focus()
                print("[browser] capturing Chromium window \(window.windowID); profile: \(browser.configuration.profile.path)")
            } catch {
                await startingCapture?.stop()
                guard !Task.isCancelled else { return }
                requestFailure(error)
            }
        }
    }

    /// Stops capture and releases held input; never closes Chromium or its tabs.
    func deactivate() {
        active = false
        setupTask?.cancel()
        setupTask = nil
        trackedInput.suspend(interaction: interaction)
        input?.cancel()
        input = nil
        if let capture { Task { await capture.stop() } }
        capture = nil
        renderer = nil
    }

    func renderFrame() throws {
        guard active, !transitionRequested else {
            _ = try session.nextFrame()
            return
        }
        if session.state != .focused { trackedInput.suspend(interaction: interaction) }
        refreshWindowFrame()
        if transitionRequested { _ = try session.nextFrame(); return }
        let captured: BrowserWindowCapture.Frame?
        do { captured = try capture?.latestFrame() }
        catch { requestFailure(error); _ = try session.nextFrame(); return }
        var commands = TrackedPanelCommands()
        _ = try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
            ShellStageAnchor.shared.updateIfNeeded(from: frame)
            if let renderer {
                commands = try trackedInput.update(frame: frame, interaction: interaction,
                    model: ShellStageAnchor.shared.modelMatrix(worldWidth: renderer.geometry.widthMeters,
                        textureAspect: renderer.geometry.aspectRatio), faceButtonsSelect: false)
                try renderer.encode(frame: frame, swapchainTexture: texture, desktopTexture: captured?.texture,
                    commandBuffer: commandBuffer, pointerPosition: interaction.pointerPosition)
                if let captured { commandBuffer.addCompletedHandler { _ in withExtendedLifetime(captured) {} } }
            } else {
                try ShellDesktopMode.clearFrame(frame: frame, texture: texture, commandBuffer: commandBuffer)
            }
        }
        if commands.recenter { ShellStageAnchor.shared.requestRecenter() }
        if commands.back { input?.back() }
        if commands.menu { transitionRequested = true; onRequestHome() }
    }

    private func refreshWindowFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWindowCheck > 0.25, let input else { return }
        lastWindowCheck = now
        // Cheap WindowServer metadata lookup; no frame readback or AX polling.
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, input.windowID) as? [[String: Any]],
              let info = windows.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
            requestFailure(BrowserError.windowClosed)
            return
        }
        input.windowFrame = rect
    }

    private func requestFailure(_ error: Error) {
        guard active, !transitionRequested else { return }
        transitionRequested = true
        input?.cancel()
        print("[browser] \(error.localizedDescription)")
        onFailure(error)
    }
}
