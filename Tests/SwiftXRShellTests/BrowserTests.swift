import AppKit
import Metal
import SwiftXR
import Testing
@testable import SwiftXRShell

@Suite("Browser native input", .serialized)
@MainActor
struct BrowserInputTests {
    @Test func mapsQuartzPointsIncludingRetinaAndNegativeOrigins() {
        let frame = CGRect(x: -1440, y: 120, width: 1440, height: 900)
        #expect(BrowserCoordinates.point(uv: .zero, frame: frame) == CGPoint(x: -1440, y: 120))
        #expect(BrowserCoordinates.point(uv: SIMD2(1, 1), frame: frame) == CGPoint(x: -1, y: 1019))
        #expect(BrowserCoordinates.point(uv: SIMD2(-1, 2), frame: frame) == CGPoint(x: -1440, y: 1019))
        // Capture pixels may be Retina-scaled; input must still use window points.
        #expect(BrowserCoordinates.point(uv: SIMD2(0.5, 0.5), frame: frame) == CGPoint(x: -720.5, y: 569.5))
    }

    @Test func nativeDragTargetsCapturedWindowAndFocusesOnlyOnPress() throws {
        var events: [CGEvent] = []
        var focused = 0
        let input = BrowserPointerInput(pid: 123, windowID: 456, frame: CGRect(x: 30, y: 40, width: 1000, height: 600),
            isTrusted: { true }, deliver: { events.append($0) }, focusApplication: { focused += 1 })
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        #expect(focused == 0)
        input.handle(.pointerDown(.primary))
        input.handle(.pointerMoved(to: SIMD2(0.6, 0.5)))
        input.handle(.pointerUp(.primary))
        #expect(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp])
        #expect(events.allSatisfy { $0.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 456 })
        #expect(focused == 1)
        #expect(!input.isDown)
        let last = try #require(events.last)
        #expect(abs(last.location.x - 629.4) < 0.001)
    }

    @Test func lostPointerReleasesOutsideWindowAndCannotClickOnReentry() {
        var events: [CGEvent] = []
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let input = BrowserPointerInput(pid: 123, windowID: 456, frame: frame,
            isTrusted: { true }, deliver: { events.append($0) }, focusApplication: {})
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.pointerDown(.primary))
        input.handle(.pointerExited)
        input.handle(.pointerUp(.primary)) // Router's subsequent release is harmless.
        #expect(events.filter { $0.type == .leftMouseUp }.count == 1)
        #expect(events.last.map { !frame.contains($0.location) } == true)
        #expect(!input.isDown)
        events.removeAll()
        input.handle(.pointerDown(.primary))
        #expect(events.isEmpty)
    }

    @Test func permissionLossReleasesHeldTriggerAndBlocksFurtherInput() {
        var trusted = true
        var events: [CGEvent] = []
        let input = BrowserPointerInput(pid: 123, windowID: 456, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
            isTrusted: { trusted }, deliver: { events.append($0) }, focusApplication: {})
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.pointerDown(.primary))
        trusted = false
        input.handle(.pointerMoved(to: SIMD2(0.7, 0.5)))
        #expect(!input.isDown)
        #expect(events.last?.type == .leftMouseUp)
        events.removeAll()
        input.handle(.pointerDown(.primary))
        input.handle(.scroll(SIMD2(0, -1)))
        input.back()
        #expect(events.isEmpty)
    }

    @Test func scrollRequiresAnActualPanelHitAndUsesNativePixels() {
        var events: [CGEvent] = []
        let input = BrowserPointerInput(pid: 123, windowID: 456, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
            isTrusted: { true }, deliver: { events.append($0) }, focusApplication: {})
        input.handle(.scroll(SIMD2(0, -0.1)))
        #expect(events.isEmpty)
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.scroll(SIMD2(0, -0.1)))
        #expect(events.last?.type == .scrollWheel)
        #expect(events.last?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -90)
        input.handle(.pointerExited)
        events.removeAll()
        input.handle(.scroll(SIMD2(0, -0.1)))
        #expect(events.isEmpty)
    }

    @Test func browserTileSurvivesCatalogAndResumeUpdates() {
        let model = ShellModel()
        model.showResumeObservedExternal(title: "Chromium")
        model.replaceExternalApplications([])
        model.clearResumeObservedExternal()
        #expect(model.applications.filter { $0.kind == .browser }.count == 1)
        #expect(model.isLaunchEnabled(.browser))
        model.externalActivity = ShellExternalActivity(applicationID: "other", title: "Other", phase: .starting)
        #expect(!model.isLaunchEnabled(.browser))
    }

    @Test func browserAndDesktopMetalShaderCompileWithoutHeadset() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: DesktopRenderer.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "desktop_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "desktop_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        _ = try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

@Suite("Browser configuration")
struct BrowserConfigurationTests {
    @Test func usesOurBuildAndIsolatedPersistentProfile() {
        let config = BrowserConfiguration(environment: [:], home: URL(fileURLWithPath: "/tmp/browser test"))
        #expect(config.executable.path == "/tmp/browser test/Code/chromium/src/out/mac-webxr/Chromium.app/Contents/MacOS/Chromium")
        #expect(config.arguments.contains("--user-data-dir=/tmp/browser test/Library/Application Support/SwiftXRShell/Chromium"))
        #expect(config.arguments.contains("--enable-features=OpenXR"))
        #expect(!config.arguments.contains("--no-sandbox"))
    }

    @Test func acceptsExplicitAppBundleOrExecutable() {
        let app = BrowserConfiguration(environment: ["SWIFTXR_CHROMIUM_PATH": "/tmp/Our Chromium.app"])
        #expect(app.executable.path == "/tmp/Our Chromium.app/Contents/MacOS/Chromium")
        let binary = BrowserConfiguration(environment: ["SWIFTXR_CHROMIUM_PATH": "/tmp/chromium"])
        #expect(binary.executable.path == "/tmp/chromium")
    }
}
