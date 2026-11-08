import SwiftXR

struct VizPanelGeometry {
    static let width: Float = 2.8
    static let pageWidth: Float = 1440
    static let pageHeight: Float = 900
    static let toolbarHeight: Float = 104
    static let fraction = toolbarHeight / (pageHeight + toolbarHeight)
    static let toolbarMeters = width * toolbarHeight / pageWidth
    enum Target { case page, toolbar }
    static func hit(_ uv: SIMD2<Float>) -> (Target, SIMD2<Float>) {
        if uv.y < fraction { return (.toolbar, SIMD2(uv.x, uv.y / fraction)) }
        return (.page, SIMD2(uv.x, (uv.y - fraction) / (1 - fraction)))
    }
}

enum VizPageInput: Equatable {
    case move(SIMD2<Float>), down(SIMD2<Float>), up(SIMD2<Float>)
    case scroll(SIMD2<Float>, SIMD2<Float>), cancel
}

/// Routes one continuous controller stream across two adjacent surfaces. A drag
/// crossing their boundary is cancelled, never released into the other surface.
@MainActor
final class VizPanelInput {
    var ready = false
    private(set) var pagePointer: SIMD2<Float>?
    private let toolbar: XRPanelInteraction
    private let page: (VizPageInput) -> Void
    private var hover: VizPanelGeometry.Target?
    private var pressed: VizPanelGeometry.Target?

    init(toolbar: XRPanelInteraction, page: @escaping (VizPageInput) -> Void) {
        self.toolbar = toolbar; self.page = page
    }
    func handle(_ event: XRPanelInteractionEvent) {
        switch event {
        case let .pointerMoved(uv):
            let (target, local) = VizPanelGeometry.hit(uv)
            if target != hover {
                cancel()
                toolbar.send(.pointerExited)
                pagePointer = nil
                hover = target
            }
            if target == .toolbar { toolbar.movePointer(to: local) }
            else { pagePointer = local; page(.move(local)) }
        case .pointerDown(.primary):
            if hover == .toolbar { pressed = .toolbar; toolbar.pointerDown() }
            else if hover == .page, ready, let pagePointer { pressed = .page; page(.down(pagePointer)) }
        case .pointerUp(.primary):
            if pressed == .toolbar { toolbar.pointerUp() }
            else if pressed == .page, let pagePointer { page(.up(pagePointer)) }
            pressed = nil
        case .pointerExited:
            cancel(); toolbar.send(.pointerExited); hover = nil; pagePointer = nil
        case let .scroll(delta):
            if hover == .page, ready, let pagePointer { page(.scroll(pagePointer, delta * 900)) }
        default: break
        }
    }
    func cancel() {
        if pressed == .toolbar { toolbar.send(.pointerExited); toolbar.pointerUp() }
        if pressed == .page { page(.cancel) }
        pressed = nil
    }
    func reset() { handle(.pointerExited) }
}
