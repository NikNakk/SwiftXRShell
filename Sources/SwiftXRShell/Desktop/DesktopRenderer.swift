import CoreGraphics
import Metal
import simd
import SwiftXR

struct DesktopSurfaceHit {
    let distance: Float
    let worldPosition: SIMD3<Float>
    let uv: SIMD2<Float>
    let pixel: SIMD2<Float>
}

struct DesktopSurfaceGeometry {
    var center = SIMD3<Float>(0, 0, -2.0)
    var widthMeters: Float = 2.2
    var pixelSize: SIMD2<Int>

    var aspectRatio: Float {
        guard pixelSize.y > 0 else { return 16.0 / 9.0 }
        return Float(pixelSize.x) / Float(pixelSize.y)
    }

    var heightMeters: Float { widthMeters / aspectRatio }

    func pixelCoordinate(forUV uv: SIMD2<Float>) -> SIMD2<Float> {
        let clamped = SIMD2<Float>(
            min(max(uv.x, 0), 1),
            min(max(uv.y, 0), 1)
        )
        return SIMD2<Float>(
            clamped.x * Float(max(pixelSize.x - 1, 0)),
            clamped.y * Float(max(pixelSize.y - 1, 0))
        )
    }

    func worldPoint(forUV uv: SIMD2<Float>) -> SIMD3<Float> {
        let x = center.x + (uv.x - 0.5) * widthMeters
        let y = center.y + (0.5 - uv.y) * heightMeters
        return SIMD3<Float>(x, y, center.z)
    }

    func hitTest(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>
    ) -> DesktopSurfaceHit? {
        guard abs(rayDirection.z) > 0.000_001 else { return nil }
        let distance = (center.z - rayOrigin.z) / rayDirection.z
        guard distance >= 0 else { return nil }

        let world = rayOrigin + rayDirection * distance
        let halfWidth = widthMeters * 0.5
        let halfHeight = heightMeters * 0.5
        let localX = world.x - center.x
        let localY = world.y - center.y

        guard
            localX >= -halfWidth,
            localX <= halfWidth,
            localY >= -halfHeight,
            localY <= halfHeight
        else { return nil }

        let uv = SIMD2<Float>(
            localX / widthMeters + 0.5,
            0.5 - localY / heightMeters
        )
        return DesktopSurfaceHit(
            distance: distance,
            worldPosition: world,
            uv: uv,
            pixel: pixelCoordinate(forUV: uv)
        )
    }
}

enum DesktopRendererError: Error, CustomStringConvertible {
    case shaderFunctionMissing(String)
    case bufferCreationFailed
    case samplerCreationFailed
    case renderEncoderCreationFailed

    var description: String {
        switch self {
        case let .shaderFunctionMissing(name):
            return "Metal shader function not found: \(name)"
        case .bufferCreationFailed:
            return "Could not create the virtual-desktop vertex buffer"
        case .samplerCreationFailed:
            return "Could not create the virtual-desktop texture sampler"
        case .renderEncoderCreationFailed:
            return "Could not create the virtual-desktop render encoder"
        }
    }
}

private struct DesktopVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
}

private struct DesktopUniforms {
    var viewProjection: simd_float4x4
}

final class DesktopRenderer {
    let geometry: DesktopSurfaceGeometry

    private let pipelineState: any MTLRenderPipelineState
    private let samplerState: any MTLSamplerState
    private let vertexBuffer: any MTLBuffer

    init(
        device: any MTLDevice,
        swapchain: XRSwapchain,
        capturedPixelSize: CGSize
    ) throws {
        let pixelWidth = max(Int(capturedPixelSize.width.rounded()), 1)
        let pixelHeight = max(Int(capturedPixelSize.height.rounded()), 1)
        self.geometry = DesktopSurfaceGeometry(
            pixelSize: SIMD2(pixelWidth, pixelHeight)
        )

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vertexFunction = library.makeFunction(name: "desktop_vertex") else {
            throw DesktopRendererError.shaderFunctionMissing("desktop_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "desktop_fragment") else {
            throw DesktopRendererError.shaderFunctionMissing("desktop_fragment")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "SwiftXR Shell virtual desktop pipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = swapchain.pixelFormat
        pipelineDescriptor.rasterSampleCount = 1
        self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.label = "SwiftXR Shell virtual desktop sampler"
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw DesktopRendererError.samplerCreationFailed
        }
        self.samplerState = sampler

        let halfWidth = geometry.widthMeters * 0.5
        let halfHeight = geometry.heightMeters * 0.5
        let c = geometry.center
        let vertices = [
            DesktopVertex(position: SIMD3(c.x - halfWidth, c.y + halfHeight, c.z), uv: SIMD2(0, 0)),
            DesktopVertex(position: SIMD3(c.x - halfWidth, c.y - halfHeight, c.z), uv: SIMD2(0, 1)),
            DesktopVertex(position: SIMD3(c.x + halfWidth, c.y + halfHeight, c.z), uv: SIMD2(1, 0)),
            DesktopVertex(position: SIMD3(c.x + halfWidth, c.y - halfHeight, c.z), uv: SIMD2(1, 1)),
        ]

        let buffer = vertices.withUnsafeBufferPointer { pointer -> (any MTLBuffer)? in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: pointer.count * MemoryLayout<DesktopVertex>.stride,
                options: []
            )
        }
        guard let buffer else { throw DesktopRendererError.bufferCreationFailed }
        buffer.label = "SwiftXR Shell virtual desktop vertices"
        self.vertexBuffer = buffer
    }

    func encode(
        frame: XRFrame,
        swapchainTexture: any MTLTexture,
        desktopTexture: (any MTLTexture)?,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard frame.views.count >= 2 else { return }

        for eye in 0..<2 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = swapchainTexture
            pass.colorAttachments[0].slice = eye
            pass.colorAttachments[0].level = 0
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0.012,
                green: 0.016,
                blue: 0.026,
                alpha: 1
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw DesktopRendererError.renderEncoderCreationFailed
            }

            encoder.label = eye == 0
                ? "SwiftXR Shell desktop left eye"
                : "SwiftXR Shell desktop right eye"
            encoder.setViewport(
                MTLViewport(
                    originX: 0,
                    originY: 0,
                    width: Double(swapchainTexture.width),
                    height: Double(swapchainTexture.height),
                    znear: 0,
                    zfar: 1
                )
            )

            if let desktopTexture {
                encoder.setRenderPipelineState(pipelineState)
                encoder.setCullMode(.none)
                var uniforms = DesktopUniforms(
                    viewProjection: frame.views[eye].viewProjectionMatrix(
                        nearZ: 0.05,
                        farZ: 50
                    )
                )
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(
                    &uniforms,
                    length: MemoryLayout<DesktopUniforms>.stride,
                    index: 1
                )
                encoder.setFragmentTexture(desktopTexture, index: 0)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            encoder.endEncoding()
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DesktopVertex {
        float3 position;
        float2 uv;
    };

    struct DesktopUniforms {
        float4x4 viewProjection;
    };

    struct DesktopVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex DesktopVertexOut desktop_vertex(
        uint vertexID [[vertex_id]],
        const device DesktopVertex *vertices [[buffer(0)]],
        constant DesktopUniforms &uniforms [[buffer(1)]])
    {
        DesktopVertexOut output;
        DesktopVertex input = vertices[vertexID];
        output.position = uniforms.viewProjection * float4(input.position, 1.0);
        output.uv = input.uv;
        return output;
    }

    fragment float4 desktop_fragment(
        DesktopVertexOut input [[stage_in]],
        texture2d<float> desktop [[texture(0)]],
        sampler desktopSampler [[sampler(0)]])
    {
        return desktop.sample(desktopSampler, input.uv);
    }
    """
}
