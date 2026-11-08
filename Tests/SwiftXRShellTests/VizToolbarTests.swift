import AppKit
import Metal
import SwiftXR
import Testing
@testable import SwiftXRShell

@Suite("Viz toolbar native UI", .serialized)
@MainActor
struct VizToolbarTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTXR_TEST_VIZ_UI"] == "1"))
    func addressFieldAcceptsKeyboardAndSubmits() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let model = VizToolbarModel()
        model.address = "https://example.com"
        model.title = "Offscreen browser"
        var submitted: String?
        model.navigate = { submitted = $0 }
        let panel = try XRSwiftUIPanel(device: device, pointSize: CGSize(width: 1440, height: 104), scale: 1) {
            VizToolbar(model: model)
        }
        try await Task.sleep(for: .milliseconds(100))
        try panel.refresh()
        try snapshot(panel.texture, device: device)
        print("[viz-ui] snapshot done")
        panel.interaction.movePointer(to: SIMD2(0.55, 0.30))
        panel.interaction.pointerDown(); panel.interaction.pointerUp()
        print("[viz-ui] pointer delivered")
        try await Task.sleep(for: .milliseconds(50))
        print("[viz-ui] editing=\(model.editingAddress)")
        try #require(model.editingAddress)
        let window = try #require(NSApp.keyWindow)
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        print("[viz-ui] selected text")
        for character in "localhost:8000" {
            let text = String(character)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
            print("[viz-ui] key \(text)")
            NSApp.sendEvent(event)
        }
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        print("[viz-ui] sending Enter")
        NSApp.sendEvent(enter)
        print("[viz-ui] sent Enter")
        try await Task.sleep(for: .milliseconds(50))
        #expect(submitted == "localhost:8000")
    }
    private func snapshot(_ texture: any MTLTexture, device: any MTLDevice) throws {
        let size = texture.width * texture.height * 4
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let buffer = try #require(device.makeBuffer(length: size, options: .storageModeShared))
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: texture.width * 4, destinationBytesPerImage: size)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        let data = Data(bytes: buffer.contents(), count: size)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let color = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = try #require(CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: texture.width * 4, space: color, bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/swiftxr-viz-toolbar.png"))
    }
}
