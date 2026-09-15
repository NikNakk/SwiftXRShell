import AppKit
import Foundation
import GameController
import SwiftUI
import SwiftXR

@MainActor
private func configure(
    controller: GCController,
    panel: XRSwiftUIPanel<ShellHomeView>
) {
    guard let pad = controller.extendedGamepad else { return }

    func onPress(
        _ button: GCControllerButtonInput,
        _ action: @escaping @MainActor () -> Void
    ) {
        button.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
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

@MainActor
private final class SwiftXRShellAppDelegate: NSObject, NSApplicationDelegate {
    private var instance: XRInstance?
    private var session: XRSession?
    private var swapchain: XRSwapchain?
    private var panel: XRSwiftUIPanel<ShellHomeView>?
    private var renderer: ShellPanelRenderer?
    private var pointerCapture: XRMacPointerCapture?
    private var configuredController: GCController?
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
            try startPointerCaptureIfReady()
        } catch {
            fail(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pointerCapture?.stop()
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

        model.commandHandler = { command in
            switch command {
            case let .launch(application):
                // Video and Desktop are intentionally modeled as normal Shell
                // applications. Their implementations will migrate into this
                // repository next, without changing the Home surface.
                print("Shell launch requested: \(application.title) [\(application.id)]")
            case .settings:
                print("Shell settings requested")
            }
        }

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
        self.panel = panel
        self.renderer = renderer
        self.pointerCapture = pointerCapture

        print("SwiftXR Shell ready")
        print("Move the mouse to point, click to select, Escape to exit")
    }

    @objc
    private func frameStep() {
        guard
            let session,
            let swapchain,
            let panel,
            let renderer,
            let pointerCapture
        else { return }

        do {
            try session.pollEvents()

            if session.shouldExit {
                pointerCapture.stop()
                NSApplication.shared.terminate(nil)
                return
            }

            if pointerCapture.escapeRequested {
                try requestSessionExitIfNeeded()
                scheduleFrameStep(after: 0.005)
                return
            }

            guard session.isRunning else {
                scheduleFrameStep(after: 0.005)
                return
            }

            try startPointerCaptureIfReady()
            pointerCapture.poll()

            let controller = GCController.current ?? GCController.controllers().first
            if controller !== configuredController {
                configuredController = controller
                if let controller {
                    configure(controller: controller, panel: panel)
                }
            }

            try panel.refreshIfNeeded()
            renderer.pointerPosition = panel.interaction.pointerPosition

            try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
                try renderer.encode(
                    frame: frame,
                    texture: texture,
                    commandBuffer: commandBuffer
                )
            }

            scheduleFrameStep()
        } catch {
            fail(error)
        }
    }

    private func startPointerCaptureIfReady() throws {
        guard
            NSApplication.shared.isActive,
            session?.isRunning == true,
            let pointerCapture,
            !pointerCapture.isCaptureRequested
        else { return }

        try pointerCapture.start()
        guard pointerCapture.isCaptured else {
            throw XRMacPointerCaptureError.applicationNotActive
        }
    }

    private func requestSessionExitIfNeeded() throws {
        guard !exitRequested else { return }
        exitRequested = true
        pointerCapture?.stop()

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
        pointerCapture?.stop()
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
