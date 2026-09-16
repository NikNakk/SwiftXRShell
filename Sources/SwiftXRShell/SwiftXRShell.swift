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
        GCController.shouldMonitorBackgroundEvents = false

        let capabilities = try XRRuntime.capabilities()
        try capabilities.requireMetal()

        let instance = try XRInstance(applicationName: "SwiftXR Shell")
        print("Runtime: \(instance.runtime.name) \(instance.runtime.version)")

        let session = try instance.system().makeSession()
        let swapchain = try session.makeStereoSwapchain()
        let model = ShellModel()

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

        externalLauncher.onSwitchedToApplication = { client in
            print("[shell] external application is primary/focused: \(client.name)")
        }
        externalLauncher.onReturnedToShell = { [weak self] in
            self?.returnHomeFromExternal()
        }
        externalLauncher.onError = { [weak self] error in
            self?.handleExternalLaunchError(error)
        }

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

        leaveHomeInput()
        mode = .external

        do {
            try externalLauncher.launch(application, external: external)
            print("[shell] launched \(application.title); waiting for its Monado client")
        } catch {
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
        finishReturningHome()
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

    private func handleExternalLaunchError(_ error: Error) {
        fputs("swiftxr-shell external launch: \(error)\n", stderr)

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
                externalLauncher.shutdown()
                homePointerCapture?.stop()
                videoMode?.shutdown()
                desktopMode?.deactivate()
                NSApplication.shared.terminate(nil)
                return
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
