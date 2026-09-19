import AppKit
import Foundation
import GameController
import SwiftUI
import SwiftXR

@MainActor
private final class SwiftXRShellAppDelegate: NSObject, NSApplicationDelegate {
    private enum Mode: Equatable {
        case home
        case video
        case desktop
        case external
    }

    private var mode: Mode = .home

    private var instance: XRInstance?
    private var session: XRSession?
    private var swapchain: XRSwapchain?

    private var homePanel: XRSwiftUIPanel<ShellHomeView>?
    private var homeRenderer: ShellPanelRenderer?
    private var homePointerCapture: XRMacPointerCapture?
    private var configuredHomeController: GCController?

    private var videoMode: ShellVideoMode?
    private var desktopMode: ShellDesktopMode?
    private var desktopEscapeMonitor: Any?
    private let externalLauncher = ExternalOpenXRLauncher()
    private let externalActivityMonitor = ExternalOpenXRActivityMonitor()
    private var systemOverlay: ShellSystemOverlayController?
    private var shellModel: ShellModel?
    private var resumeModeAfterObservedExternal: Mode?

    private var exitRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        do {
            try setUpShell()
            scheduleFrameStep()
        } catch {
            fail(error)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        do {
            switch mode {
            case .home:
                try startHomePointerCaptureIfReady()
            case .video, .desktop, .external:
                break
            }
        } catch {
            fail(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemOverlay?.shutdown()
        externalActivityMonitor.shutdown()
        externalLauncher.shutdown()
        removeDesktopEscapeMonitor()
        homePointerCapture?.stop()
        videoMode?.shutdown()
        desktopMode?.deactivate()
        if session?.isRunning == true && !exitRequested {
            try? session?.requestExit()
        }
    }

    private func setUpShell() throws {
        // The system overlay must continue to receive its configured controller
        // button while the launched XR application owns macOS foreground focus.
        GCController.shouldMonitorBackgroundEvents = true

        let capabilities = try XRRuntime.capabilities()
        try capabilities.requireMetal()

        let instance = try XRInstance(applicationName: "SwiftXR Shell")
        print("Runtime: \(instance.runtime.name) \(instance.runtime.version)")

        let session = try instance.system().makeSession()
        let swapchain = try session.makeStereoSwapchain()
        let model = ShellModel()
        self.shellModel = model

        let panel = try XRSwiftUIPanel(
            device: session.device,
            pointSize: CGSize(width: 1280, height: 720),
            scale: 1
        ) {
            ShellHomeView(model: model)
        }

        let renderer = try ShellPanelRenderer(
            device: session.device,
            swapchain: swapchain,
            panelTexture: panel.texture
        )
        let pointerCapture = XRMacPointerCapture(panel: panel)

        self.instance = instance
        self.session = session
        self.swapchain = swapchain
        self.homePanel = panel
        self.homeRenderer = renderer
        self.homePointerCapture = pointerCapture

        let settings: ShellSettings
        do {
            settings = try ShellSettings.load()
            print(
                "[overlay] system menu trigger: \(settings.systemOverlayButton.rawValue) ("
                    + ShellSettings.settingsURL.path + ")"
            )
        } catch {
            settings = ShellSettings()
            print("[overlay] could not load settings; using Home/PS button: \(error)")
        }

        let systemOverlay = ShellSystemOverlayController(
            triggerButton: settings.systemOverlayButton
        )
        systemOverlay.onAction = { [weak self] action in
            self?.handleSystemOverlayAction(action)
        }
        self.systemOverlay = systemOverlay

        do {
            let externalApplications = try ExternalApplicationCatalog.loadApplications()
            model.replaceExternalApplications(externalApplications)
            print(
                "[shell] loaded \(externalApplications.count) external application(s) from "
                    + ExternalApplicationCatalog.catalogURL.path
            )
        } catch {
            print("[shell] could not load external application catalog: \(error)")
            print("[shell] catalog path: \(ExternalApplicationCatalog.catalogURL.path)")
        }

        externalLauncher.onSwitchedToApplication = { [weak self] client in
            print("[shell] external application is primary/focused: \(client.name)")
            self?.systemOverlay?.foregroundApplicationDidBecomeActive()
        }
        externalLauncher.onReturnedToShell = { [weak self] in
            self?.returnHomeFromExternal()
        }
        externalLauncher.onError = { [weak self] error in
            self?.handleExternalLaunchError(error)
        }

        externalActivityMonitor.canTakeOver = { [weak self] in
            guard let self else { return false }
            guard !self.externalLauncher.isRunningExternalApplication else {
                return false
            }

            // The first automatic handoff milestone deliberately covers the
            // shell modes used for browser/WebXR entry. Video resume semantics
            // need separate treatment because playback state should be
            // preserved rather than restarted.
            return self.mode == .home || self.mode == .desktop
        }
        externalActivityMonitor.onExternalSessionBecameActive = { [weak self] client in
            self?.yieldToObservedExternalSession(client)
        }
        externalActivityMonitor.onExternalSessionEnded = { [weak self] client in
            self?.resumeAfterObservedExternalSession(client)
        }
        externalActivityMonitor.onSuppressedExternalSessionEnded = { [weak self] client in
            self?.observedExternalSessionEndedWhileInShell(client)
        }
        externalActivityMonitor.onError = { error in
            fputs("swiftxr-shell external activity monitor: \(error)\n", stderr)
        }
        externalActivityMonitor.start()

        model.commandHandler = { [weak self] command in
            guard let self else { return }
            switch command {
            case let .launch(application):
                do {
                    try self.launch(application)
                } catch {
                    if case .external = application.kind {
                        self.handleExternalLaunchError(error)
                    } else {
                        self.fail(error)
                    }
                }
            case .settings:
                print("Shell settings requested (not implemented yet)")
            }
        }

        print("SwiftXR Shell ready")
        print("Video and Desktop run in-process on the Shell OpenXR session")
    }

    private func launch(_ application: ShellApplication) throws {
        switch application.kind {
        case .videoPlayer:
            try enterVideo()
        case .virtualDesktop:
            enterDesktop()
        case .resumeObservedExternal:
            try resumeObservedExternalSession()
        case let .external(external):
            try enterExternal(application, external: external)
        }
    }

    private func enterVideo() throws {
        guard
            mode == .home,
            let session,
            let swapchain
        else { return }

        leaveHomeInput()

        let video = try ShellVideoMode(
            session: session,
            swapchain: swapchain,
            onRequestHome: { [weak self] in
                DispatchQueue.main.async { self?.returnHome() }
            }
        )
        videoMode = video
        mode = .video
        try video.activate()
    }

    private func enterDesktop() {
        guard
            mode == .home,
            let session,
            let swapchain
        else { return }

        leaveHomeInput()
        installDesktopEscapeMonitor()

        let desktop = ShellDesktopMode(
            session: session,
            swapchain: swapchain,
            onRequestHome: { [weak self] in
                DispatchQueue.main.async { self?.returnHome() }
            }
        )
        desktopMode = desktop
        mode = .desktop
        desktop.activate()
        print("[shell] Desktop active — Escape returns to launcher")
    }

    private func enterExternal(
        _ application: ShellApplication,
        external: ExternalOpenXRApplication
    ) throws {
        guard mode == .home else { return }

        resumeModeAfterObservedExternal = nil
        leaveHomeInput()
        mode = .external

        // Create the overlay client before the launcher snapshots Monado's
        // existing clients, so it can never be mistaken for the new foreground
        // application. Overlay support is optional: a failure here should not
        // stop the requested XR application from launching.
        do {
            try systemOverlay?.prepare(
                applicationTitle: application.title,
                actions: [.resume, .quitApplication]
            )
        } catch {
            systemOverlay?.shutdown()
            print("[overlay] unavailable for this launch: \(error)")
        }

        do {
            try externalLauncher.launch(application, external: external)
            print("[shell] launched \(application.title); waiting for its Monado client")
        } catch {
            systemOverlay?.shutdown()
            mode = .home
            throw error
        }
    }

    private func returnHome() {
        guard mode != .home else { return }

        switch mode {
        case .video:
            videoMode?.shutdown()
            videoMode = nil
        case .desktop:
            desktopMode?.deactivate()
            desktopMode = nil
            removeDesktopEscapeMonitor()
        case .external:
            return
        case .home:
            break
        }

        finishReturningHome()
    }

    private func returnHomeFromExternal() {
        guard mode == .external else { return }
        resumeModeAfterObservedExternal = nil
        systemOverlay?.shutdown()
        finishReturningHome()
    }

    private func yieldToObservedExternalSession(_ client: XRMonadoClient) {
        guard resumeModeAfterObservedExternal == nil else { return }
        guard mode == .home || mode == .desktop else { return }

        let previousMode = mode
        switch previousMode {
        case .home:
            leaveHomeInput()
        case .desktop:
            // ScreenCaptureKit and the desktop renderer are unnecessary while
            // another client owns the HMD. Stop them to reduce GPU/bandwidth
            // load; the desktop itself (and Chromium window) remains untouched.
            desktopMode?.deactivate()
            removeDesktopEscapeMonitor()
        case .video, .external:
            return
        }

        shellModel?.clearResumeObservedExternal()
        homePanel?.invalidate()
        resumeModeAfterObservedExternal = previousMode
        mode = .external

        do {
            try systemOverlay?.prepare(
                applicationTitle: client.name,
                actions: [.resume, .desktop, .home]
            )
            systemOverlay?.foregroundApplicationDidBecomeActive()
        } catch {
            systemOverlay?.shutdown()
            print("[overlay] unavailable for observed external session: \(error)")
        }

        print(
            "[shell] yielding \(previousMode) to independently-started OpenXR client "
                + "\(client.id): \(client.name)"
        )
    }

    private func resumeAfterObservedExternalSession(_ client: XRMonadoClient) {
        guard mode == .external, let previousMode = resumeModeAfterObservedExternal else {
            return
        }

        systemOverlay?.shutdown()
        shellModel?.clearResumeObservedExternal()
        homePanel?.invalidate()
        resumeModeAfterObservedExternal = nil
        mode = previousMode
        NSApplication.shared.activate(ignoringOtherApps: true)

        switch previousMode {
        case .home:
            homePanel?.interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
            homePanel?.invalidate()
            do {
                try startHomePointerCaptureIfReady()
            } catch {
                fail(error)
                return
            }

        case .desktop:
            installDesktopEscapeMonitor()
            desktopMode?.activate()

        case .video, .external:
            break
        }

        print("[shell] resumed \(previousMode) after \(client.name) left immersive XR")
    }

    private func observedExternalSessionEndedWhileInShell(_ client: XRMonadoClient) {
        shellModel?.clearResumeObservedExternal()
        homePanel?.invalidate()
        print("[shell] \(client.name) ended its suppressed immersive session")
    }

    private func resumeObservedExternalSession() throws {
        guard mode == .home else { return }
        _ = try externalActivityMonitor.resumeSuppressedSession()
    }

    private func handleSystemOverlayAction(_ action: ShellSystemOverlayAction) {
        switch action {
        case .resume:
            return

        case .quitApplication:
            quitExternalApplicationFromOverlay()

        case .desktop, .home:
            guard resumeModeAfterObservedExternal != nil else { return }

            do {
                let client = try externalActivityMonitor.returnForegroundSessionToShell()
                systemOverlay?.shutdown()
                resumeModeAfterObservedExternal = nil

                shellModel?.showResumeObservedExternal(title: client.name)
                homePanel?.invalidate()

                // Any existing Desktop mode was suspended when the external
                // session took over. Recreate it if Desktop was selected so
                // ScreenCaptureKit starts from a clean state.
                desktopMode?.deactivate()
                desktopMode = nil
                removeDesktopEscapeMonitor()

                mode = .home
                if action == .desktop {
                    enterDesktop()
                } else {
                    finishReturningHome()
                }

                print(
                    "[overlay] returned to SwiftXR \(action == .desktop ? "Desktop" : "Home"); "
                        + "\(client.name) remains available to resume"
                )
            } catch {
                systemOverlay?.actionRequestFailed()
                fputs("swiftxr-shell overlay handoff: \(error)\n", stderr)
            }
        }
    }

    private func finishReturningHome() {
        mode = .home
        NSApplication.shared.activate(ignoringOtherApps: true)
        homePanel?.interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
        homePanel?.invalidate()
        do {
            try startHomePointerCaptureIfReady()
        } catch {
            fail(error)
            return
        }
        print("[shell] returned Home")
    }

    private func quitExternalApplicationFromOverlay() {
        guard mode == .external else { return }

        do {
            let title = externalLauncher.currentApplicationTitle ?? "OpenXR application"
            try externalLauncher.terminateForegroundApplication()
            print("[overlay] requested termination of \(title)")
        } catch {
            systemOverlay?.actionRequestFailed()
            fputs("swiftxr-shell overlay quit: \(error)\n", stderr)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not quit OpenXR application"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func handleExternalLaunchError(_ error: Error) {
        fputs("swiftxr-shell external launch: \(error)\n", stderr)
        systemOverlay?.shutdown()

        if mode == .external {
            finishReturningHome()
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not launch OpenXR application"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func leaveHomeInput() {
        homePointerCapture?.stop()
        clearHomeControllerHandlers()
    }

    @objc
    private func frameStep() {
        guard let session, let swapchain else { return }

        do {
            try session.pollEvents()

            if session.shouldExit {
                systemOverlay?.shutdown()
                externalActivityMonitor.shutdown()
                externalLauncher.shutdown()
                homePointerCapture?.stop()
                videoMode?.shutdown()
                desktopMode?.deactivate()
                NSApplication.shared.terminate(nil)
                return
            }

            // The Shell's primary session can become non-visible/non-running
            // while an external primary app owns the HMD. Drive the independent
            // overlay session before checking the primary Shell session state.
            if mode == .external {
                try systemOverlay?.renderFrame()
            }

            guard session.isRunning else {
                scheduleFrameStep(after: 0.005)
                return
            }

            switch mode {
            case .home:
                try renderHome(session: session, swapchain: swapchain)
            case .video:
                try videoMode?.renderFrame()
            case .desktop:
                try desktopMode?.renderFrame()
            case .external:
                _ = try session.nextFrame()
            }

            scheduleFrameStep()
        } catch {
            fail(error)
        }
    }

    private func renderHome(session: XRSession, swapchain: XRSwapchain) throws {
        guard
            let panel = homePanel,
            let renderer = homeRenderer,
            let pointerCapture = homePointerCapture
        else { return }

        try startHomePointerCaptureIfReady()

        if pointerCapture.escapeRequested {
            try requestSessionExitIfNeeded()
            return
        }

        pointerCapture.poll()
        configureHomeControllerIfNeeded(panel: panel)
        try panel.refreshIfNeeded()
        renderer.pointerPosition = panel.interaction.pointerPosition

        _ = try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
            try renderer.encode(
                frame: frame,
                texture: texture,
                commandBuffer: commandBuffer
            )
        }
    }

    private func configureHomeControllerIfNeeded(panel: XRSwiftUIPanel<ShellHomeView>) {
        let controller = GCController.current ?? GCController.controllers().first
        guard controller !== configuredHomeController else { return }

        clearHomeControllerHandlers()
        configuredHomeController = controller
        guard let pad = controller?.extendedGamepad else { return }

        func onPress(
            _ button: GCControllerButtonInput,
            _ action: @escaping @MainActor () -> Void
        ) {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                DispatchQueue.main.async {
                    guard self?.mode == .home else { return }
                    action()
                }
            }
        }

        onPress(pad.dpad.up) { panel.interaction.navigate(.up) }
        onPress(pad.dpad.down) { panel.interaction.navigate(.down) }
        onPress(pad.dpad.left) { panel.interaction.navigate(.left) }
        onPress(pad.dpad.right) { panel.interaction.navigate(.right) }
        onPress(pad.buttonA) { panel.interaction.select() }
        onPress(pad.buttonB) { panel.interaction.back() }
        onPress(pad.buttonMenu) { panel.interaction.select() }
    }

    private func clearHomeControllerHandlers() {
        guard let pad = configuredHomeController?.extendedGamepad else {
            configuredHomeController = nil
            return
        }
        pad.dpad.up.pressedChangedHandler = nil
        pad.dpad.down.pressedChangedHandler = nil
        pad.dpad.left.pressedChangedHandler = nil
        pad.dpad.right.pressedChangedHandler = nil
        pad.buttonA.pressedChangedHandler = nil
        pad.buttonB.pressedChangedHandler = nil
        pad.buttonMenu.pressedChangedHandler = nil
        configuredHomeController = nil
    }

    private func installDesktopEscapeMonitor() {
        removeDesktopEscapeMonitor()
        desktopEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            DispatchQueue.main.async { self?.returnHome() }
            return nil
        }
    }

    private func removeDesktopEscapeMonitor() {
        if let desktopEscapeMonitor {
            NSEvent.removeMonitor(desktopEscapeMonitor)
            self.desktopEscapeMonitor = nil
        }
    }

    private func startHomePointerCaptureIfReady() throws {
        guard
            mode == .home,
            NSApplication.shared.isActive,
            session?.isRunning == true,
            let homePointerCapture,
            !homePointerCapture.isCaptureRequested
        else { return }

        try homePointerCapture.start()
        guard homePointerCapture.isCaptured else {
            throw XRMacPointerCaptureError.applicationNotActive
        }
    }

    private func requestSessionExitIfNeeded() throws {
        guard !exitRequested else { return }
        exitRequested = true
        systemOverlay?.shutdown()
        externalActivityMonitor.shutdown()
        externalLauncher.shutdown()
        homePointerCapture?.stop()
        videoMode?.shutdown()
        desktopMode?.deactivate()

        if session?.isRunning == true {
            try session?.requestExit()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    private func scheduleFrameStep(after delay: TimeInterval = 0) {
        perform(
            #selector(frameStep),
            with: nil,
            afterDelay: delay,
            inModes: [.common, .eventTracking]
        )
    }

    private func fail(_ error: Error) {
        systemOverlay?.shutdown()
        externalActivityMonitor.shutdown()
        externalLauncher.shutdown()
        homePointerCapture?.stop()
        videoMode?.shutdown()
        desktopMode?.deactivate()
        removeDesktopEscapeMonitor()
        fputs("swiftxr-shell: \(error)\n", stderr)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "SwiftXR Shell"
        alert.informativeText = String(describing: error)
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}

@main
struct SwiftXRShell {
    @MainActor
    static func main() {
        let application = XRMacApplication.shared
        application.setActivationPolicy(.regular)

        let appDelegate = SwiftXRShellAppDelegate()
        application.delegate = appDelegate

        withExtendedLifetime(appDelegate) {
            application.run()
        }
    }
}
