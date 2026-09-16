import Metal
import simd
import SwiftXR

enum ShellPanelPlacement {
    case stage
    case headLocked
}

private struct ShellPanelVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
}

private struct ShellPanelUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var pointer: SIMD4<Float>
}

final class ShellPanelRenderer {
    private let pipeline: any MTLRenderPipelineState
    private let vertexBuffer: any MTLBuffer
    private let vertexCount: Int
    private let panelTexture: any MTLTexture
    private let worldWidth: Float
    private let distance: Float
    private let placement: ShellPanelPlacement
    private let transparentBackground: Bool

    var pointerPosition: SIMD2<Float>?

    init(
        device: any MTLDevice,
        swapchain: XRSwapchain,
        panelTexture: any MTLTexture,
        worldWidth: Float = 2.40,
        distance: Float = ShellStageAnchor.defaultDistance,
        placement: ShellPanelPlacement = .stage,
        transparentBackground: Bool = false
    ) throws {
        self.panelTexture = panelTexture
        self.worldWidth = worldWidth
        self.distance = distance
        self.placement = placement
        self.transparentBackground = transparentBackground

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "shell_panel_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "shell_panel_fragment")
        descriptor.colorAttachments[0].pixelFormat = swapchain.pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let vertices: [ShellPanelVertex] = [
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
                length: pointer.count * MemoryLayout<ShellPanelVertex>.stride,
                options: []
            )
        }
        guard let buffer else {
            throw ShellPanelRendererError.bufferCreationFailed
        }
        vertexBuffer = buffer
    }

    func encode(
        frame: XRFrame,
        texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard frame.views.count >= 2 else { return }

        let textureAspect = Float(panelTexture.width) / Float(max(panelTexture.height, 1))
        let model: simd_float4x4
        switch placement {
        case .stage:
            ShellStageAnchor.shared.updateIfNeeded(from: frame)
            model = ShellStageAnchor.shared.modelMatrix(
                worldWidth: worldWidth,
                textureAspect: textureAspect,
                distance: distance
            )
        case .headLocked:
            model = headLockedModelMatrix(
                frame: frame,
                textureAspect: textureAspect
            )
        }

        for eye in 0..<2 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].slice = eye
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = transparentBackground
                ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                : MTLClearColor(red: 0.008, green: 0.012, blue: 0.022, alpha: 1)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw ShellPanelRendererError.encoderCreationFailed
            }

            let pointer = pointerPosition ?? .zero
            var uniforms = ShellPanelUniforms(
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
                length: MemoryLayout<ShellPanelUniforms>.stride,
                index: 1
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<ShellPanelUniforms>.stride,
                index: 1
            )
            encoder.setFragmentTexture(panelTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            encoder.endEncoding()
        }
    }

    private func headLockedModelMatrix(
        frame: XRFrame,
        textureAspect: Float
    ) -> simd_float4x4 {
        let left = frame.views[0]
        let rightView = frame.views[1]
        let orientation = simd_quatf(
            ix: left.pose.orientation.x,
            iy: left.pose.orientation.y,
            iz: left.pose.orientation.z,
            r: left.pose.orientation.w
        )
        let leftPosition = SIMD3<Float>(
            left.pose.position.x,
            left.pose.position.y,
            left.pose.position.z
        )
        let rightPosition = SIMD3<Float>(
            rightView.pose.position.x,
            rightView.pose.position.y,
            rightView.pose.position.z
        )
        let headPosition = (leftPosition + rightPosition) * 0.5
        let right = simd_normalize(orientation.act(SIMD3<Float>(1, 0, 0)))
        let up = simd_normalize(orientation.act(SIMD3<Float>(0, 1, 0)))
        let forward = simd_normalize(orientation.act(SIMD3<Float>(0, 0, -1)))
        let worldHeight = worldWidth / max(textureAspect, 0.001)
        let center = headPosition + forward * distance

        return simd_float4x4(columns: (
            SIMD4<Float>(right * worldWidth, 0),
            SIMD4<Float>(up * worldHeight, 0),
            SIMD4<Float>(-forward, 0),
            SIMD4<Float>(center, 1)
        ))
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ShellPanelVertex {
        float3 position;
        float2 uv;
    };

    struct ShellPanelUniforms {
        float4x4 viewProjection;
        float4x4 model;
        float4 pointer;
    };

    struct ShellPanelVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex ShellPanelVertexOut shell_panel_vertex(
        uint vertexID [[vertex_id]],
        const device ShellPanelVertex *vertices [[buffer(0)]],
        constant ShellPanelUniforms &uniforms [[buffer(1)]])
    {
        ShellPanelVertexOut output;
        ShellPanelVertex input = vertices[vertexID];
        output.position = uniforms.viewProjection * uniforms.model * float4(input.position, 1.0);
        output.uv = input.uv;
        return output;
    }

    fragment float4 shell_panel_fragment(
        ShellPanelVertexOut input [[stage_in]],
        constant ShellPanelUniforms &uniforms [[buffer(1)]],
        texture2d<float> panel [[texture(0)]])
    {
        constexpr sampler panelSampler(address::clamp_to_edge, filter::linear);
        float4 color = panel.sample(panelSampler, input.uv);

        if (uniforms.pointer.z > 0.5) {
            float2 d = input.uv - uniforms.pointer.xy;
            d.x *= uniforms.pointer.w;
            float distance = length(d);
            if (distance < 0.008) {
                color = float4(1.0, 1.0, 1.0, 1.0);
            } else if (distance < 0.013) {
                color = float4(0.015, 0.015, 0.02, 1.0);
            }
        }

        return color;
    }
    """
}

enum ShellPanelRendererError: Error {
    case bufferCreationFailed
    case encoderCreationFailed
}
