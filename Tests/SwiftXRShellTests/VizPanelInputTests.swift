import SwiftXR
import Testing
@testable import SwiftXRShell

@Suite("Viz two-surface input")
@MainActor
struct VizPanelInputTests {
    @Test func addressBarHandlesLocalWebXRServersAndRejectsUnsupportedSchemes() {
        #expect(VizBrowserClient.normalizedURL("localhost:8000/demo") == "http://localhost:8000/demo")
        #expect(VizBrowserClient.normalizedURL("127.0.0.1:9000") == "http://127.0.0.1:9000")
        #expect(VizBrowserClient.normalizedURL("example.com:8443/test") == "https://example.com:8443/test")
        #expect(VizBrowserClient.normalizedURL(" https://example.com/x ") == "https://example.com/x")
        #expect(VizBrowserClient.normalizedURL("about:blank") == "about:blank")
        #expect(VizBrowserClient.normalizedURL("javascript:alert(1)") == nil)
        #expect(VizBrowserClient.normalizedURL("data:text/html,test") == nil)
        #expect(VizBrowserClient.normalizedURL("") == nil)
    }
    @Test func mapsPageAndToolbarWithoutOverlappingEdges() {
        let (top, topUV) = VizPanelGeometry.hit(SIMD2(0.5, 0))
        #expect(top == .toolbar && topUV == SIMD2(0.5, 0))
        let (edge, edgeUV) = VizPanelGeometry.hit(SIMD2(0.5, VizPanelGeometry.fraction))
        #expect(edge == .page && edgeUV == SIMD2(0.5, 0))
        let (_, bottom) = VizPanelGeometry.hit(SIMD2(1, 1))
        #expect(bottom == SIMD2(1, 1))
    }
    @Test func crossSurfaceDragCancelsInsteadOfActivatingToolbar() {
        let toolbar = XRPanelInteraction()
        var events: [VizPageInput] = []
        var toolbarEvents: [XRPanelInteractionEvent] = []
        toolbar.handler = { toolbarEvents.append($0) }
        let router = VizPanelInput(toolbar: toolbar, page: { events.append($0) })
        router.ready = true
        router.handle(.pointerMoved(to: SIMD2(0.5, 0.6)))
        router.handle(.pointerDown(.primary))
        router.handle(.pointerMoved(to: SIMD2(0.5, 0.04)))
        router.handle(.pointerUp(.primary))
        #expect(events.last == .cancel)
        #expect(!toolbarEvents.contains(.pointerDown(.primary)))
        #expect(!toolbarEvents.contains(.pointerUp(.primary)))
        #expect(router.pagePointer == nil)
    }
    @Test func toolbarDragCannotReleaseIntoPage() {
        let toolbar = XRPanelInteraction()
        var events: [VizPageInput] = []
        var toolbarEvents: [XRPanelInteractionEvent] = []
        toolbar.handler = { toolbarEvents.append($0) }
        let router = VizPanelInput(toolbar: toolbar, page: { events.append($0) })
        router.ready = true
        router.handle(.pointerMoved(to: SIMD2(0.5, 0.04)))
        router.handle(.pointerDown(.primary))
        router.handle(.pointerMoved(to: SIMD2(0.5, 0.6)))
        router.handle(.pointerUp(.primary))
        #expect(toolbarEvents.filter { $0 == .pointerUp(.primary) }.count == 1)
        if let index = toolbarEvents.firstIndex(of: .pointerUp(.primary)) {
            #expect(index > 0 && toolbarEvents[index - 1] == .pointerExited)
        }
        #expect(events.count == 1)
        #expect(events.last == router.pagePointer.map { .move($0) })
    }
    @Test func focusLossAndResetReleaseOnceAndClearScrollTarget() {
        let toolbar = XRPanelInteraction()
        var events: [VizPageInput] = []
        let router = VizPanelInput(toolbar: toolbar, page: { events.append($0) })
        router.ready = true
        router.handle(.pointerMoved(to: SIMD2(0.5, 0.6)))
        router.handle(.pointerDown(.primary))
        router.reset()
        router.reset()
        #expect(events.filter { $0 == .cancel }.count == 1)
        events.removeAll()
        router.handle(.scroll(SIMD2(0, -1)))
        router.handle(.pointerUp(.primary))
        #expect(events.isEmpty)
    }
    @Test func noClicksBeforeFirstFrameAndBothTilesSurviveCatalogRefresh() {
        let router = VizPanelInput(toolbar: XRPanelInteraction(), page: { event in
            if case .down = event { Issue.record("Clicked an unready page") }
        })
        router.handle(.pointerMoved(to: SIMD2(0.5, 0.6)))
        router.handle(.pointerDown(.primary))
        let model = ShellModel()
        model.replaceExternalApplications([])
        model.showResumeObservedExternal(title: "WebXR")
        model.clearResumeObservedExternal()
        #expect(model.applications.filter { $0.kind == .browser }.count == 1)
        #expect(model.applications.filter { $0.kind == .browserViz }.count == 1)
    }
}
