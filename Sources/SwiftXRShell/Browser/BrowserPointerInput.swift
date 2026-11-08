import AppKit
import ApplicationServices
import SwiftXR

enum BrowserCoordinates {
    /// SCWindow and CGEvent use global Quartz points, not Retina texture pixels.
    static func point(uv: SIMD2<Float>, frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + CGFloat(min(max(uv.x, 0), 1)) * max(frame.width - 1, 0),
                y: frame.minY + CGFloat(min(max(uv.y, 0), 1)) * max(frame.height - 1, 0))
    }
}

/// Native events reach browser chrome and Blink's normal input/activation path.
/// Events are addressed to the captured process/window, never posted system-wide.
@MainActor
final class BrowserPointerInput {
    let pid: pid_t
    let windowID: CGWindowID
    var windowFrame: CGRect
    private var lastPoint: CGPoint?
    private(set) var isDown = false
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var clickCount: Int64 = 1
    private let source = CGEventSource(stateID: .privateState)
    private let isTrusted: () -> Bool
    private let deliver: (CGEvent) -> Void
    private let focusApplication: (() -> Void)?

    init(pid: pid_t, windowID: CGWindowID, frame: CGRect,
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         deliver: ((CGEvent) -> Void)? = nil, focusApplication: (() -> Void)? = nil) {
        self.pid = pid
        self.windowID = windowID
        windowFrame = frame
        self.isTrusted = isTrusted
        self.deliver = deliver ?? { $0.postToPid(pid) }
        self.focusApplication = focusApplication
    }

    func focus() {
        if let focusApplication { focusApplication(); return }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        guard !app.isActive else { return }
        if NSApplication.shared.isActive { NSApplication.shared.yieldActivation(to: app) }
        app.activate(options: [])
    }

    func handle(_ event: XRPanelInteractionEvent) {
        guard isTrusted() else { cancel(); return }
        switch event {
        case let .pointerMoved(uv):
            lastPoint = BrowserCoordinates.point(uv: uv, frame: windowFrame)
            mouse(isDown ? .leftMouseDragged : .mouseMoved)
        case .pointerDown(.primary):
            guard lastPoint != nil, !isDown else { return }
            focus()
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastClickTime < NSEvent.doubleClickInterval,
               let point = lastPoint, hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) < 5 {
                clickCount += 1
            } else { clickCount = 1 }
            lastClickTime = now
            lastClickPoint = lastPoint ?? .zero
            isDown = true
            mouse(.leftMouseDown)
        case .pointerUp(.primary):
            if isDown { mouse(.leftMouseUp); isDown = false }
        case .pointerExited:
            cancel()
            lastPoint = nil
        case let .scroll(delta):
            guard let lastPoint else { return }
            focus()
            if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(delta.y * 900), wheel2: Int32(delta.x * 900), wheel3: 0) {
                event.location = lastPoint
                post(event)
            }
        default: break
        }
    }

    func back() {
        guard isTrusted() else { return }
        focus()
        // Chromium's macOS Back shortcut (Command-[); not a DOM-synthetic click.
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 33, keyDown: down)
            event?.flags = .maskCommand
            if let event { deliver(event) }
        }
    }

    func cancel() {
        guard isDown else { return }
        // End outside the window so tracking/focus loss cannot turn a held
        // trigger into an activation at its last valid hit.
        let previous = lastPoint
        lastPoint = CGPoint(x: windowFrame.minX - 32, y: windowFrame.minY - 32)
        mouse(.leftMouseDragged)
        mouse(.leftMouseUp)
        isDown = false
        lastPoint = previous
    }

    private func mouse(_ type: CGEventType) {
        guard let lastPoint,
              let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: lastPoint, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        post(event)
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        deliver(event)
    }
}
