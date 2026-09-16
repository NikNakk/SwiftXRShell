import Metal
import simd
import SwiftXR

private struct VideoControlPanelVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
}

private struct VideoControlPanelUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var pointer: SIMD4<Float>
}

enum VideoControlPanelRendererError: Error {
    case bufferCreationFailed
    case encoderCreationFailed
}

final class VideoControlPanelRenderer {
    private let pipeline: any MTLRenderPipelineState
    private let vertexBuffer: any MTLBuffer
    private let vertexCount: Int
    private let textureAspect: Float

    init(
        device: any MTLDevice,
        swapchain: XRSwapchain,
        panelTexture: any MTLTexture
    ) throws {
        textureAspect = Float(panelTexture.width) / Float(max(panelTexture.height, 1))

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "SwiftXR Shell video control panel pipeline"
        descriptor.vertexFunction = library.makeFunction(name: "video_controls_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "video_controls_fragment")
        descriptor.colorAttachments[0].pixelFormat = swapchain.pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let vertices: [VideoControlPanelVertex] = [
            .init(position: SIMD3(-0.5,  0.5, 0), uv: SIMD2(0, 0)),
            .init(position: SIMD3(-0.5, -0.5, 0), uv: SIMD2(0, 1)),
            .init(position: SIMD3( 0.5, -0.5, 0), uv: SIMD2(1, 1)),
            .init(position: SIMD3(-0.5,  0.5, 0), uv: SIMD2(0, 0)),
            .init(position: SIMD3( 0.5, -0.5, 0), uv: SIMD2(1, 1)),
            .init(position: SIMD3( 0.5,  0.5, 0), uv: SIMD2(1, 0)),
        ]
        vertexCount = vertices.count

        let buffer = vertices.withUnsafeBufferPointer { pointer -> (any MTLBuffer)? in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: pointer.count * MemoryLayout<VideoControlPanelVertex>.stride,
                options: []
            )
        }
        guard let buffer else { throw VideoControlPanelRendererError.bufferCreationFailed }
        vertexBuffer = buffer
    }

    /// Kept for the existing Video mode lifecycle. Ordinary mode/panel changes
    /// must not move the shared Shell stage; explicit Recenter controls request
    /// that separately through ShellStageAnchor.
    func recenter() {}

    func encode(
        frame: XRFrame,
        swapchainTexture: any MTLTexture,
        panelTexture: any MTLTexture,
        pointerPosition: SIMD2<Float>?,
        commandBuffer: any MTLCommandBuffer,
        clearBeforePanel: Bool = false,
        worldWidth: Float = 2.0,
        distance: Float = ShellStageAnchor.defaultDistance,
        verticalOffset: Float = 0
    ) throws {
        guard frame.views.count >= 2 else { return }

        ShellStageAnchor.shared.updateIfNeeded(from: frame)
        let model = ShellStageAnchor.shared.modelMatrix(
            worldWidth: worldWidth,
            textureAspect: textureAspect,
            distance: ShellStageAnchor.defaultDistance,
            verticalOffset: 0
        )

        for eye in 0..<2 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = swapchainTexture
            pass.colorAttachments[0].slice = eye
            pass.colorAttachments[0].level = 0
            pass.colorAttachments[0].loadAction = clearBeforePanel ? .clear : .load
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0.012,
                green: 0.016,
                blue: 0.026,
                alpha: 1
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw VideoControlPanelRendererError.encoderCreationFailed
            }

            let pointer = pointerPosition ?? .zero
            var uniforms = VideoControlPanelUniforms(
                viewProjection: frame.views[eye].viewProjectionMatrix(nearZ: 0.05, farZ: 20),
                model: model,
                pointer: SIMD4(
                    pointer.x,
                    pointer.y,
                    pointerPosition == nil ? 0 : 1,
                    textureAspect
                )
            )

            encoder.setRenderPipelineState(pipeline)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<VideoControlPanelUniforms>.stride,
                index: 1
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<VideoControlPanelUniforms>.stride,
                index: 1
            )
            encoder.setFragmentTexture(panelTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            encoder.endEncoding()
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VideoControlPanelVertex { float3 position; float2 uv; };
    struct VideoControlPanelUniforms {
        float4x4 viewProjection;
        float4x4 model;
        float4 pointer;
    };
    struct PanelOut { float4 position [[position]]; float2 uv; };

    vertex PanelOut video_controls_vertex(
        uint vertexID [[vertex_id]],
        const device VideoControlPanelVertex *vertices [[buffer(0)]],
        constant VideoControlPanelUniforms &uniforms [[buffer(1)]]) {
        PanelOut out;
        const VideoControlPanelVertex input = vertices[vertexID];
        out.position = uniforms.viewProjection * uniforms.model * float4(input.position, 1.0);
        out.uv = input.uv;
        return out;
    }

    fragment float4 video_controls_fragment(
        PanelOut input [[stage_in]],
        constant VideoControlPanelUniforms &uniforms [[buffer(1)]],
        texture2d<float> panel [[texture(0)]]) {
        constexpr sampler panelSampler(address::clamp_to_edge, filter::linear);
        float4 color = panel.sample(panelSampler, input.uv);
        if (uniforms.pointer.z > 0.5) {
            float2 d = input.uv - uniforms.pointer.xy;
            d.x *= uniforms.pointer.w;
            const float distance = length(d);
            if (distance < 0.010) color = float4(1.0, 1.0, 1.0, 1.0);
            else if (distance < 0.016) color = float4(0.02, 0.02, 0.02, 1.0);
        }
        return color;
    }
    """
}
