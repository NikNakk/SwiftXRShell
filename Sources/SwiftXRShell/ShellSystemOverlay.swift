import GameController
import SwiftUI
import SwiftXR

enum ShellSystemOverlayAction: Equatable {
    case resume
    case desktop
    case home
    case quitApplication

    var title: String {
        switch self {
        case .resume: return "Resume"
        case .desktop: return "Desktop"
        case .home: return "Home"
        case .quitApplication: return "Quit Application"
        }
    }

    var systemImage: String {
        switch self {
        case .resume: return "play.fill"
        case .desktop: return "desktopcomputer"
        case .home: return "house.fill"
        case .quitApplication: return "xmark.circle.fill"
        }
    }
}

@MainActor
final class ShellSystemOverlayModel: ObservableObject {
    @Published var applicationTitle = "OpenXR application"
    @Published var actions: [ShellSystemOverlayAction] = [.resume, .quitApplication]
    @Published var selectedIndex = 0
    @Published var isPerformingAction = false

    var onAction: ((ShellSystemOverlayAction) -> Void)?

    func reset(
        applicationTitle: String,
        actions: [ShellSystemOverlayAction]
    ) {
        self.applicationTitle = applicationTitle
        self.actions = actions
        selectedIndex = 0
        isPerformingAction = false
    }

    func moveSelection(_ delta: Int) {
        guard !isPerformingAction, !actions.isEmpty else { return }
        selectedIndex = max(0, min(actions.count - 1, selectedIndex + delta))
    }

    func activateSelection() {
        guard
            !isPerformingAction,
            actions.indices.contains(selectedIndex)
        else { return }

        let action = actions[selectedIndex]
        if action == .quitApplication {
            isPerformingAction = true
        }
        onAction?(action)
    }
}

struct ShellSystemOverlayView: View {
    @ObservedObject var model: ShellSystemOverlayModel

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("SwiftXR")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.applicationTitle)
                    .font(.system(size: 31, weight: .bold))
                    .lineLimit(1)
            }

            if model.isPerformingAction {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Closing application…")
                        .font(.system(size: 23, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(model.actions.enumerated()), id: \.offset) { index, action in
                        choiceRow(
                            title: action.title,
                            systemImage: action.systemImage,
                            selected: model.selectedIndex == index
                        )
                    }
                }
            }

            Text("D-pad: choose   •   Cross / A: select   •   Circle / B: resume")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 26)
        .frame(width: 640, height: 410)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.black.opacity(0.90))
        )
    }

    private func choiceRow(
        title: String,
        systemImage: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .frame(width: 30)
            Text(title)
                .font(.system(size: 23, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
        .padding(.horizontal, 20)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.07))
        )
    }
}

@MainActor
final class ShellSystemOverlayController {
    var onAction: ((ShellSystemOverlayAction) -> Void)?

    private let triggerButton: ShellOverlayButton
    private let model = ShellSystemOverlayModel()

    private var instance: XRInstance?
    private var session: XRSession?
    private var swapchain: XRSwapchain?
    private var panel: XRSwiftUIPanel<ShellSystemOverlayView>?
    private var renderer: ShellPanelRenderer?

    private var configuredController: GCController?
    private var foregroundApplicationActive = false
    private(set) var isVisible = false

    init(triggerButton: ShellOverlayButton) {
        self.triggerButton = triggerButton
        model.onAction = { [weak self] action in
            guard let self else { return }
            if action == .resume {
                self.hide()
                return
            }

            self.onAction?(action)
            self.panel?.invalidate()
        }
    }

    func prepare(
        applicationTitle: String,
        actions: [ShellSystemOverlayAction] = [.resume, .quitApplication]
    ) throws {
        shutdown()

        let instance = try XRInstance(
            applicationName: "SwiftXR Shell Overlay",
            enableOverlay: true
        )
        let session = try instance.system().makeSession(
            kind: .overlay(layerPlacement: 100)
        )
        let swapchain = try session.makeStereoSwapchain()

        model.reset(applicationTitle: applicationTitle, actions: actions)
        let panel = try XRSwiftUIPanel(
            device: session.device,
            pointSize: CGSize(width: 640, height: 410),
            scale: 1
        ) {
            ShellSystemOverlayView(model: self.model)
        }
        let renderer = try ShellPanelRenderer(
            device: session.device,
            swapchain: swapchain,
            panelTexture: panel.texture,
            worldWidth: 1.05,
            distance: 1.20,
            placement: .headLocked,
            transparentBackground: true
        )

        self.instance = instance
        self.session = session
        self.swapchain = swapchain
        self.panel = panel
        self.renderer = renderer
        foregroundApplicationActive = false
        isVisible = false

        print("[overlay] prepared XR_EXTX_overlay session; trigger=\(triggerButton.rawValue)")
    }

    func foregroundApplicationDidBecomeActive() {
        guard session != nil else { return }
        foregroundApplicationActive = true
        ensureControllerConfigured()
    }

    func actionRequestFailed() {
        model.isPerformingAction = false
        panel?.invalidate()
    }

    func renderFrame() throws {
        guard let session else { return }

        ensureControllerConfigured()
        try session.pollEvents()
        guard !session.shouldExit, session.isRunning else { return }

        guard isVisible,
              let panel,
              let renderer,
              let swapchain
        else {
            _ = try session.nextFrame()
            return
        }

        try panel.refreshIfNeeded()
        _ = try session.renderFrame(
            to: swapchain,
            compositionLayerOptions: [.blendTextureSourceAlpha]
        ) { frame, texture, commandBuffer in
            try renderer.encode(
                frame: frame,
                texture: texture,
                commandBuffer: commandBuffer
            )
        }
    }

    func shutdown() {
        clearControllerHandlers()
        foregroundApplicationActive = false
        isVisible = false
        renderer = nil
        panel = nil
        swapchain = nil
        session = nil
        instance = nil
    }

    private func show() {
        guard session != nil, foregroundApplicationActive, !model.isPerformingAction else {
            return
        }
        isVisible = true
        model.selectedIndex = 0
        panel?.invalidate()
        installMenuHandlers()
        print("[overlay] shown")
    }

    private func hide() {
        guard isVisible, !model.isPerformingAction else { return }
        isVisible = false
        panel?.invalidate()
        installTriggerHandler()
        print("[overlay] hidden")
    }

    private func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    private func ensureControllerConfigured() {
        guard session != nil, foregroundApplicationActive else { return }
        let controller = GCController.current ?? GCController.controllers().first
        guard controller !== configuredController else { return }

        clearControllerHandlers()
        configuredController = controller
        installTriggerHandler()
    }

    private func installTriggerHandler() {
        guard session != nil, let pad = configuredController?.extendedGamepad else { return }

        pad.dpad.up.pressedChangedHandler = nil
        pad.dpad.down.pressedChangedHandler = nil
        pad.buttonA.pressedChangedHandler = nil
        pad.buttonB.pressedChangedHandler = nil

        guard let button = triggerInput(for: pad) else {
            print(
                "[overlay] configured trigger \(triggerButton.rawValue) "
                    + "is not available on this controller"
            )
            return
        }
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                self?.toggle()
            }
        }
    }

    private func installMenuHandlers() {
        installTriggerHandler()
        guard let pad = configuredController?.extendedGamepad else { return }

        pad.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                self?.model.moveSelection(-1)
                self?.panel?.invalidate()
            }
        }
        pad.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                self?.model.moveSelection(1)
                self?.panel?.invalidate()
            }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                self?.model.activateSelection()
                self?.panel?.invalidate()
            }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                self?.hide()
            }
        }
    }

    private func triggerInput(for pad: GCExtendedGamepad) -> GCControllerButtonInput? {
        switch triggerButton {
        case .home:
            return pad.buttonHome
        case .menu:
            return pad.buttonMenu
        case .options:
            return pad.buttonOptions
        }
    }

    private func clearControllerHandlers() {
        guard let pad = configuredController?.extendedGamepad else {
            configuredController = nil
            return
        }

        triggerInput(for: pad)?.pressedChangedHandler = nil
        pad.dpad.up.pressedChangedHandler = nil
        pad.dpad.down.pressedChangedHandler = nil
        pad.buttonA.pressedChangedHandler = nil
        pad.buttonB.pressedChangedHandler = nil
        configuredController = nil
    }
}
