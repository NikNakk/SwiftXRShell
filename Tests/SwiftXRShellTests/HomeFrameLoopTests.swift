import Foundation
import Metal
import SwiftXR
import Testing
@testable import SwiftXRShell

@Suite("Home XR worker")
@MainActor
struct HomeFrameLoopTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTXR_TEST_RUNTIME"] == "1"))
    func framesContinueWhileMainThreadIsBusy() throws {
        let instance = try XRInstance(applicationName: "SwiftXR frame isolation check")
        let session = try instance.system().makeSession()
        let input = try XRControllerInput(session: session)
        let swapchain = try session.makeStereoSwapchain()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: 64, height: 64, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try #require(session.device.makeTexture(descriptor: descriptor))
        let pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: 256)
        }
        let renderer = try ShellPanelRenderer(device: session.device, swapchain: swapchain, panelTexture: texture)
        let loop = HomeFrameLoop(session: session, swapchain: swapchain, renderer: renderer,
                                 input: input, texture: texture,
                                 onUpdates: { _ in }, onError: { Issue.record("XR worker error: \($0)") })
        loop.start()
        defer { loop.stop() }
        // Intentionally stall AppKit, like an expensive UI snapshot. The worker
        // must keep submitting XR frames without a synchronous main-thread hop.
        Thread.sleep(forTimeInterval: 0.6)
        let count = loop.frameCount
        print("[test] XR frames during a 600ms main-thread stall: \(count)")
        #expect(count >= 12)
    }
}
