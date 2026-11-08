import AppKit
import Metal
import SwiftUI
import SwiftXR
import Testing
import simd
@testable import SwiftXRShell

private struct ScrollTestVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
}

private struct ScrollTestUniforms {
    var viewProjection = matrix_identity_float4x4
    var model = matrix_identity_float4x4
    var pointer = SIMD4<Float>.zero
    var scrollViewport: SIMD4<Float>
    var scrollOffsets = SIMD4<Float>(0.25, 0, 0.125, 1)
}

@Suite("Panel pixels and native input", .serialized)
@MainActor
struct MetalPanelTests {
    @Test func videoModeChangeClearsTheOldLibraryBackground() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let library = VideoLibraryModel()
        let controls = VideoControlsModel(title: "Transparency test", projectionMode: .flat, stereoLayout: .mono)
        let panel = try XRSwiftUIPanel(device: device, pointSize: CGSize(width: 1280, height: 720), scale: 1) {
            VideoPlayerRootView(library: library, controls: controls)
        }
        library.mode = .controls
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<4 { try panel.refresh() }
        let bytes = try pixels(panel.texture, queue: queue)
        let clearIndex: Int = (20 * 1280 + 640) * 4 + 3
        let overlayIndex: Int = (360 * 1280 + 40) * 4 + 3
        let clearAlpha: UInt8 = bytes[clearIndex]
        let overlayAlpha: UInt8 = bytes[overlayIndex]
        #expect(clearAlpha == 0)
        #expect(overlayAlpha >= 220 && overlayAlpha <= 240)
    }

    @Test func repeatedSnapshotsKeepTransparentCornersAndPartialAlpha() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let panel = try XRSwiftUIPanel(device: device, pointSize: CGSize(width: 128, height: 128), scale: 1) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.5))
                .padding(16)
                .frame(width: 128, height: 128)
        }
        for _ in 0..<5 { try panel.refresh() }
        let bytes = try pixels(panel.texture, queue: queue)
        #expect(bytes[(64 * 128 + 64) * 4 + 3] >= 120)
        #expect(bytes[(64 * 128 + 64) * 4 + 3] <= 135)
        #expect(bytes[(4 * 128 + 4) * 4 + 3] == 0)
    }

    private func pixels(_ texture: any MTLTexture, queue: any MTLCommandQueue) throws -> [UInt8] {
        let length = texture.width * texture.height * 4
        let buffer = try #require(queue.device.makeBuffer(length: length, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: texture.width * 4,
                  destinationBytesPerImage: length)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.status == .completed)
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: length))
    }

    @Test(arguments: [Float(1), Float(0.5)])
    func scrollShaderInterpolatesPixelsAndPreservesChrome(viewportHeight: Float) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: 64, height: 64, mipmapped: false)
        descriptor.storageMode = .shared
        let previous = try #require(device.makeTexture(descriptor: descriptor))
        let current = try #require(device.makeTexture(descriptor: descriptor))
        func fill(_ texture: any MTLTexture, rows: Int) {
            var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
            for y in 0..<64 { for x in 0..<64 {
                bytes[(y * 64 + x) * 4 + 2] = UInt8((y + rows) * 3)
                bytes[(y * 64 + x) * 4 + 3] = 255
            } }
            bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: 256)
            }
        }
        fill(previous, rows: 0)
        fill(current, rows: Int(0.25 * viewportHeight * 64))
        descriptor.usage = [.renderTarget, .shaderRead]
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let library = try device.makeLibrary(source: ShellPanelRenderer.shaderSource, options: nil)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: "shell_panel_vertex")
        pipeline.fragmentFunction = library.makeFunction(name: "shell_panel_fragment")
        pipeline.colorAttachments[0].pixelFormat = .bgra8Unorm
        let state = try device.makeRenderPipelineState(descriptor: pipeline)
        let commands = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
        let vertices: [ScrollTestVertex] = [
            .init(position: SIMD3(-1, 1, 0), uv: SIMD2(0, 0)),
            .init(position: SIMD3(-1, -1, 0), uv: SIMD2(0, 1)),
            .init(position: SIMD3(1, -1, 0), uv: SIMD2(1, 1)),
            .init(position: SIMD3(-1, 1, 0), uv: SIMD2(0, 0)),
            .init(position: SIMD3(1, -1, 0), uv: SIMD2(1, 1)),
            .init(position: SIMD3(1, 1, 0), uv: SIMD2(1, 0)),
        ]
        var uniforms = ScrollTestUniforms(scrollViewport: SIMD4(0, (1 - viewportHeight) / 2, 1, viewportHeight))
        encoder.setRenderPipelineState(state)
        vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ScrollTestUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ScrollTestUniforms>.stride, index: 1)
        encoder.setFragmentTexture(current, index: 0)
        encoder.setFragmentTexture(previous, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commands.commit()
        let bytes = try pixels(output, queue: queue)
        for y in [18, 32, 44] { for x in [16, 32, 63] {
            let expected = (y + Int(0.125 * viewportHeight * 64)) * 3
            #expect(abs(Int(bytes[(y * 64 + x) * 4 + 2]) - expected) <= 2)
        } }
        if viewportHeight == 0.5 {
            let expectedHeader = (4 + 8) * 3
            #expect(abs(Int(bytes[(4 * 64 + 32) * 4 + 2]) - expectedHeader) <= 2)
        }
    }

    @Test func refreshPreservesPixelOrientation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let panel = try XRSwiftUIPanel(device: device, pointSize: CGSize(width: 128, height: 128),
                                      scale: 1) {
            VStack(spacing: 0) {
                Color(red: 1, green: 0, blue: 0)
                Color(red: 0, green: 0, blue: 1)
            }.frame(width: 128, height: 128)
        }
        panel.invalidate()
        try panel.refreshIfNeeded()
        #expect(panel.texture.width == 128)
        #expect(panel.texture.height == 128)
        let bytes = try pixels(panel.texture, queue: queue)
        let top = (panel.texture.height / 8 * panel.texture.width + panel.texture.width / 2) * 4
        let bottom = (panel.texture.height * 7 / 8 * panel.texture.width + panel.texture.width / 2) * 4
        #expect(bytes[top + 2] > 200 && bytes[top] < 20)
        #expect(bytes[bottom] > 200 && bytes[bottom + 2] < 20)
    }

    @Test(arguments: [true, false]) func semanticScrollMovesTheNativeScrollView(pointerOnPanel: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let panel = try XRSwiftUIPanel(device: device, pointSize: CGSize(width: 128, height: 128),
                                      scale: 1) {
            ScrollView {
                VStack(spacing: 0) {
                    Color(red: 1, green: 0, blue: 0).frame(height: 128)
                    Color(red: 0, green: 0, blue: 1).frame(height: 128)
                }
            }.frame(width: 128, height: 128)
        }
        if pointerOnPanel { panel.interaction.movePointer(to: SIMD2(0.5, 0.5)) }
        panel.interaction.scroll(SIMD2(0, -4))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        panel.invalidate()
        try panel.refreshIfNeeded()
        let bytes = try pixels(panel.texture, queue: queue)
        let center = (panel.texture.height / 2 * panel.texture.width + panel.texture.width / 2) * 4
        #expect(bytes[center] > 200 && bytes[center + 2] < 20)
        let scrollInfo = try #require(panel.scrollInfo)
        #expect(scrollInfo.offset > 0.9)
        #expect(abs(scrollInfo.viewport.y) < 0.01)
        #expect(abs(scrollInfo.viewport.w - 1) < 0.01)
    }


}
