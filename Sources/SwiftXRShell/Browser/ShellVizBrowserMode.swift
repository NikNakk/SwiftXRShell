import AppKit
import Combine
import CVizBridge
import Metal
import SwiftUI
import SwiftXR

@MainActor
final class VizToolbarModel: ObservableObject {
    @Published var address = "about:blank"
    @Published var title = "Starting offscreen Chromium…"
    @Published var editingAddress = false
    @Published var vrPermission: UInt32 = 0
    var navigate: ((String) -> Void)?
    var action: ((UInt32) -> Void)?
    var home: (() -> Void)?
    var allowVR: (() -> Void)?
}

@MainActor
struct VizToolbar: View {
    @ObservedObject var model: VizToolbarModel
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("Home") { model.home?() }
                Button { model.action?(UInt32(SXR_VIZ_BACK)) } label: { Image(systemName: "chevron.left") }
                Button { model.action?(UInt32(SXR_VIZ_FORWARD)) } label: { Image(systemName: "chevron.right") }
                Button { model.action?(UInt32(SXR_VIZ_RELOAD)) } label: { Image(systemName: "arrow.clockwise") }
                TextField("Address", text: $model.address, onEditingChanged: { model.editingAddress = $0 }, onCommit: {
                    model.editingAddress = false
                    model.navigate?(model.address)
                })
                .textFieldStyle(.roundedBorder)
                Button("Go") { model.editingAddress = false; model.navigate?(model.address) }
                Button(model.vrPermission == 1 ? "VR allowed" : model.vrPermission == 2 ? "VR blocked" : model.vrPermission == 3 ? "VR needs HTTPS" : "Allow VR & reload") {
                    model.allowVR?()
                }
                .disabled(model.editingAddress || model.vrPermission != 0 ||
                    !(model.address.hasPrefix("https://") || model.address.hasPrefix("http://")))
            }
            .controlSize(.large)
            HStack {
                Text("Browser (Viz) · offscreen GPU surface")
                Spacer()
                Text(model.title).lineLimit(1)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: 1440, height: 104)
        .background(Color(red: 0.035, green: 0.055, blue: 0.09))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

/// A genuine Chromium/Viz page surface. The SwiftUI toolbar is a separate panel;
/// neither pixels nor input pass through ScreenCaptureKit or Accessibility.
@MainActor
final class ShellVizBrowserMode: ShellBrowserPresentation {
    private let session: XRSession
    private let swapchain: XRSwapchain
    private let trackedInput: ShellTrackedInput
    private let client: VizBrowserClient
    private let onRequestHome: () -> Void
    private let onFailure: (Error) -> Void
    private let model = VizToolbarModel()
    private let interaction = XRPanelInteraction()
    private let toolbar: XRSwiftUIPanel<VizToolbar>
    private let toolbarRenderer: VideoControlPanelRenderer
    private let pageRenderer: DesktopRenderer
    private var observation: AnyCancellable?
    private var keyboardMonitor: Any?
    private var setupTask: Task<Void, Never>?
    private var active = false
    private var transitionRequested = false
    private lazy var inputRouter = VizPanelInput(toolbar: toolbar.interaction) { [weak self] event in
        guard let self else { return }
        switch event {
        case let .move(uv): self.client.send(kind: UInt32(SXR_VIZ_MOVE), uv: uv)
        case let .down(uv): self.focusPage(); self.client.send(kind: UInt32(SXR_VIZ_DOWN), uv: uv)
        case let .up(uv): self.client.send(kind: UInt32(SXR_VIZ_UP), uv: uv)
        case let .scroll(uv, delta): self.client.send(kind: UInt32(SXR_VIZ_SCROLL), uv: uv, scroll: delta)
        case .cancel: self.client.send(kind: UInt32(SXR_VIZ_CANCEL))
        }
    }
    private var lastStatusUpdate: TimeInterval = 0
    var onStatusChanged: (() -> Void)?
    private(set) var status = "Starting offscreen Chromium…"

    private static let width = VizPanelGeometry.width
    private static let toolbarHeight = VizPanelGeometry.toolbarMeters

    init(session: XRSession, swapchain: XRSwapchain, trackedInput: ShellTrackedInput,
         client: VizBrowserClient, onRequestHome: @escaping () -> Void,
         onFailure: @escaping (Error) -> Void) throws {
        self.session = session; self.swapchain = swapchain; self.trackedInput = trackedInput
        self.client = client; self.onRequestHome = onRequestHome; self.onFailure = onFailure
        let toolbarModel = model
        toolbar = try XRSwiftUIPanel(device: session.device, pointSize: CGSize(width: 1440, height: 104), scale: 1) {
            VizToolbar(model: toolbarModel)
        }
        toolbar.refreshesOnPointerMovement = false
        toolbarRenderer = try VideoControlPanelRenderer(device: session.device, swapchain: swapchain, panelTexture: toolbar.texture)
        pageRenderer = try DesktopRenderer(device: session.device, swapchain: swapchain,
            capturedPixelSize: CGSize(width: 1440, height: 900), widthMeters: Self.width)
        observation = model.objectWillChange.sink { [weak toolbar] _ in
            DispatchQueue.main.async { toolbar?.invalidate() }
        }
        model.home = { [weak self] in self?.requestHome() }
        model.navigate = { [weak self] url in
            guard let self else { return }
            if self.client.navigate(url) { self.focusPage() }
            else { self.model.title = "Enter a valid http(s), file or about URL" }
        }
        model.action = { [weak self] kind in self?.client.send(kind: kind); self?.focusPage() }
        model.allowVR = { [weak self] in
            guard let self, !self.model.editingAddress,
                  self.model.address == self.client.metadata.url else { return }
            self.client.send(kind: UInt32(SXR_VIZ_ALLOW_VR), text: self.model.address)
            self.focusPage()
        }
        interaction.handler = { [weak self] event in self?.inputRouter.handle(event) }
    }

    func activate() {
        active = true; transitionRequested = false
        trackedInput.reset(interaction: interaction)
        inputRouter.reset()
        inputRouter.ready = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.active else { return event }
            if event.type == .keyDown && event.keyCode == 4 &&
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] {
                self.requestHome(); return nil
            }
            if event.type == .keyDown && event.keyCode == 37 && event.modifierFlags.contains(.command) {
                self.focusAddress(); return nil
            }
            // Let Shell menus retain their standard Home/Quit/mode shortcuts.
            if event.modifierFlags.contains(.command), [UInt16(12), 18, 19, 20, 21].contains(event.keyCode) { return event }
            guard !self.model.editingAddress else { return event }
            self.client.send(kind: UInt32(event.type == .keyDown ? SXR_VIZ_KEY_DOWN : SXR_VIZ_KEY_UP), event: event)
            return nil
        }
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await client.start(device: session.device)
                try Task.checkCancellation()
                inputRouter.ready = true
                status = "Viz offscreen · Sense pointer · physical keyboard · ⇧⌘H Home"
                model.title = "Offscreen Chromium ready"
                onStatusChanged?()
            } catch {
                guard !Task.isCancelled else { return }
                fail(error)
            }
        }
    }
    func deactivate() {
        active = false
        setupTask?.cancel(); setupTask = nil
        trackedInput.suspend(interaction: interaction)
        inputRouter.reset()
        client.suspend()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
    }
    func renderFrame() throws {
        guard active, !transitionRequested else { _ = try session.nextFrame(); return }
        if session.state != .focused { trackedInput.suspend(interaction: interaction) }
        let captured: VizBrowserFrame?
        do { captured = try client.latestFrame() }
        catch { fail(error); _ = try session.nextFrame(); return }
        updateMetadata()
        _ = try toolbar.refreshIfNeeded()
        var commands = TrackedPanelCommands()
        _ = try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
            ShellStageAnchor.shared.updateIfNeeded(from: frame)
            commands = try trackedInput.update(frame: frame, interaction: interaction,
                model: ShellStageAnchor.shared.modelMatrix(worldWidth: Self.width,
                    textureAspect: 1440.0 / 1004.0, verticalOffset: Self.toolbarHeight / 2), faceButtonsSelect: false)
            try pageRenderer.encode(frame: frame, swapchainTexture: texture, desktopTexture: captured?.texture,
                commandBuffer: commandBuffer, pointerPosition: inputRouter.pagePointer)
            try toolbarRenderer.encode(frame: frame, swapchainTexture: texture, panelTexture: toolbar.texture,
                pointerPosition: toolbar.interaction.pointerPosition, commandBuffer: commandBuffer,
                worldWidth: Self.width, verticalOffset: Self.width * 900 / 1440 / 2 + Self.toolbarHeight / 2)
            if let captured { commandBuffer.addCompletedHandler { _ in withExtendedLifetime(captured) {} } }
        }
        if commands.back { client.send(kind: UInt32(SXR_VIZ_BACK)) }
        if commands.recenter { ShellStageAnchor.shared.requestRecenter() }
        if commands.menu { requestHome() }
    }
    private func focusPage() {
        model.editingAddress = false
        // Remove any insertion point from the Shell address bar before routing
        // subsequent physical keystrokes to the browser process.
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
    }
    private func focusAddress() {
        toolbar.interaction.movePointer(to: SIMD2(0.55, 0.30))
        toolbar.interaction.pointerDown(); toolbar.interaction.pointerUp()
        DispatchQueue.main.async { [weak self] in
            guard self?.model.editingAddress == true else { return }
            NSApplication.shared.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }
    private func updateMetadata() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStatusUpdate > 0.1 else { return }
        lastStatusUpdate = now
        let metadata = client.metadata
        if model.vrPermission != metadata.vrPermission { model.vrPermission = metadata.vrPermission }
        if !model.editingAddress && model.address != metadata.url { model.address = metadata.url }
        if model.title != metadata.title { model.title = metadata.title }
    }
    private func requestHome() { guard !transitionRequested else { return }; transitionRequested = true; onRequestHome() }
    private func fail(_ error: Error) {
        guard !transitionRequested else { return }
        transitionRequested = true
        print("[browser-viz] \(error.localizedDescription)")
        onFailure(error)
    }
}
