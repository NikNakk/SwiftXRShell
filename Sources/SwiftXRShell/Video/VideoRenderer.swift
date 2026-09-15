import CoreGraphics
import Metal
import simd
import SwiftXR

struct VideoSurfaceGeometry {
    let center: SIMD3<Float>
    let widthMeters: Float
    let heightMeters: Float

    init(displaySize: CGSize) {
        let width = max(Float(displaySize.width), 1)
        let height = max(Float(displaySize.height), 1)
        let aspect = width / height

        var panelHeight: Float = 1.20
        var panelWidth = panelHeight * aspect

        if panelWidth > 2.40 {
            panelWidth = 2.40
            panelHeight = panelWidth / aspect
        }
        if panelHeight > 1.60 {
            panelHeight = 1.60
            panelWidth = panelHeight * aspect
        }

        self.center = SIMD3<Float>(0, 0, -2.0)
        self.widthMeters = panelWidth
        self.heightMeters = panelHeight
    }
}

enum VideoRendererError: Error, CustomStringConvertible {
    case shaderFunctionMissing(String)
    case vertexBufferCreationFailed
    case samplerCreationFailed
    case renderEncoderCreationFailed

    var description: String {
        switch self {
        case let .shaderFunctionMissing(name): return "Metal shader function not found: \(name)"
        case .vertexBufferCreationFailed: return "Could not create the video-surface vertex buffer"
        case .samplerCreationFailed: return "Could not create the video-surface sampler"
        case .renderEncoderCreationFailed: return "Could not create the video render encoder"
        }
    }
}

private struct VideoVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
}

private struct FlatVideoUniforms {
    var viewProjection: simd_float4x4
}

private struct ImmersiveVideoUniforms {
    var viewOrientation: SIMD4<Float>
    var fovTangents: SIMD4<Float>
    var anchorRight: SIMD4<Float>
    var anchorUp: SIMD4<Float>
    var anchorForward: SIMD4<Float>
    var parameters: SIMD4<Float>
    var stereoParameters: SIMD4<Float>
}

final class VideoRenderer {
    let geometry: VideoSurfaceGeometry
    private(set) var projectionMode: VideoProjectionMode
    private(set) var stereoLayout: VideoStereoLayout

    private let flatPipelineState: any MTLRenderPipelineState
    private let immersivePipelineState: any MTLRenderPipelineState
    private let samplerState: any MTLSamplerState
    private let vertexBuffer: any MTLBuffer
    private var anchor: VideoProjectionAnchor?

    init(
        device: any MTLDevice,
        swapchain: XRSwapchain,
        displaySize: CGSize,
        projectionMode: VideoProjectionMode,
        stereoLayout: VideoStereoLayout
    ) throws {
        self.geometry = VideoSurfaceGeometry(displaySize: displaySize)
        self.projectionMode = projectionMode
        self.stereoLayout = stereoLayout

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let flatVertex = library.makeFunction(name: "flat_video_vertex") else {
            throw VideoRendererError.shaderFunctionMissing("flat_video_vertex")
        }
        guard let flatFragment = library.makeFunction(name: "flat_video_fragment") else {
            throw VideoRendererError.shaderFunctionMissing("flat_video_fragment")
        }
        guard let immersiveVertex = library.makeFunction(name: "immersive_video_vertex") else {
            throw VideoRendererError.shaderFunctionMissing("immersive_video_vertex")
        }
        guard let immersiveFragment = library.makeFunction(name: "immersive_video_fragment") else {
            throw VideoRendererError.shaderFunctionMissing("immersive_video_fragment")
        }

        let flatDescriptor = MTLRenderPipelineDescriptor()
        flatDescriptor.label = "SwiftXR Shell flat video pipeline"
        flatDescriptor.vertexFunction = flatVertex
        flatDescriptor.fragmentFunction = flatFragment
        flatDescriptor.colorAttachments[0].pixelFormat = swapchain.pixelFormat
        flatDescriptor.rasterSampleCount = 1
        self.flatPipelineState = try device.makeRenderPipelineState(descriptor: flatDescriptor)

        let immersiveDescriptor = MTLRenderPipelineDescriptor()
        immersiveDescriptor.label = "SwiftXR Shell immersive video pipeline"
        immersiveDescriptor.vertexFunction = immersiveVertex
        immersiveDescriptor.fragmentFunction = immersiveFragment
        immersiveDescriptor.colorAttachments[0].pixelFormat = swapchain.pixelFormat
        immersiveDescriptor.rasterSampleCount = 1
        self.immersivePipelineState = try device.makeRenderPipelineState(descriptor: immersiveDescriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.label = "SwiftXR Shell video sampler"
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw VideoRendererError.samplerCreationFailed
        }
        self.samplerState = sampler

        let c = geometry.center
        let halfWidth = geometry.widthMeters * 0.5
        let halfHeight = geometry.heightMeters * 0.5
        let vertices = [
            VideoVertex(position: SIMD3(c.x - halfWidth, c.y + halfHeight, c.z), uv: SIMD2(0, 0)),
            VideoVertex(position: SIMD3(c.x - halfWidth, c.y - halfHeight, c.z), uv: SIMD2(0, 1)),
            VideoVertex(position: SIMD3(c.x + halfWidth, c.y + halfHeight, c.z), uv: SIMD2(1, 0)),
            VideoVertex(position: SIMD3(c.x + halfWidth, c.y - halfHeight, c.z), uv: SIMD2(1, 1)),
        ]

        let buffer = vertices.withUnsafeBufferPointer { pointer -> (any MTLBuffer)? in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: pointer.count * MemoryLayout<VideoVertex>.stride,
                options: []
            )
        }
        guard let buffer else { throw VideoRendererError.vertexBufferCreationFailed }
        buffer.label = "SwiftXR Shell video surface vertices"
        self.vertexBuffer = buffer
    }

    func setProjectionMode(_ mode: VideoProjectionMode) {
        guard mode != projectionMode else { return }
        projectionMode = mode
        if mode == .flat || mode == .eac360 {
            stereoLayout = .mono
        } else if stereoLayout == .mono {
            stereoLayout = .sideBySide
        }
        anchor = nil
    }

    func setStereoLayout(_ layout: VideoStereoLayout) {
        guard layout != stereoLayout else { return }
        stereoLayout = layout
    }

    func recenter() { anchor = nil }

    func tilt(yawRadians: Float, pitchRadians: Float) {
        anchor?.tilt(yawRadians: yawRadians, pitchRadians: pitchRadians)
    }

    var sceneAnchor: VideoProjectionAnchor? { anchor }

    func encode(
        frame: XRFrame,
        swapchainTexture: any MTLTexture,
        videoTexture: (any MTLTexture)?,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard frame.views.count >= 2 else { return }

        if projectionMode != .flat,
           anchor == nil,
           frame.trackingState.orientationValid {
            anchor = .from(view: frame.views[0])
        }

        for eye in 0..<2 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = swapchainTexture
            pass.colorAttachments[0].slice = eye
            pass.colorAttachments[0].level = 0
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = videoTexture == nil
                ? MTLClearColor(red: 0.16, green: 0.0, blue: 0.10, alpha: 1)
                : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw VideoRendererError.renderEncoderCreationFailed
            }

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

            if let videoTexture {
                encoder.setCullMode(.none)
                encoder.setFragmentTexture(videoTexture, index: 0)
                encoder.setFragmentSamplerState(samplerState, index: 0)

                if projectionMode == .flat {
                    encodeFlat(encoder: encoder, frame: frame, eye: eye)
                } else if let anchor {
                    encodeImmersive(
                        encoder: encoder,
                        frame: frame,
                        eye: eye,
                        texture: videoTexture,
                        anchor: anchor
                    )
                }
            }
            encoder.endEncoding()
        }
    }

    private func encodeFlat(
        encoder: any MTLRenderCommandEncoder,
        frame: XRFrame,
        eye: Int
    ) {
        encoder.setRenderPipelineState(flatPipelineState)
        var uniforms = FlatVideoUniforms(
            viewProjection: frame.views[eye].viewProjectionMatrix(nearZ: 0.05, farZ: 50)
        )
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<FlatVideoUniforms>.stride,
            index: 1
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func encodeImmersive(
        encoder: any MTLRenderCommandEncoder,
        frame: XRFrame,
        eye: Int,
        texture: any MTLTexture,
        anchor: VideoProjectionAnchor
    ) {
        let view = frame.views[eye]
        let q = view.pose.orientation
        let fov = view.fov

        encoder.setRenderPipelineState(immersivePipelineState)
        var uniforms = ImmersiveVideoUniforms(
            viewOrientation: SIMD4(q.x, q.y, q.z, q.w),
            fovTangents: SIMD4(
                tan(fov.angleLeft),
                tan(fov.angleRight),
                tan(fov.angleDown),
                tan(fov.angleUp)
            ),
            anchorRight: SIMD4(anchor.right.x, anchor.right.y, anchor.right.z, 0),
            anchorUp: SIMD4(anchor.up.x, anchor.up.y, anchor.up.z, 0),
            anchorForward: SIMD4(anchor.forward.x, anchor.forward.y, anchor.forward.z, 0),
            parameters: SIMD4(
                Float(eye),
                Float(projectionMode.rawValue),
                Float(texture.width),
                Float(texture.height)
            ),
            stereoParameters: SIMD4(Float(stereoLayout.rawValue), 0, 0, 0)
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<ImmersiveVideoUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float PI = 3.14159265358979323846;

    struct VideoVertex { float3 position; float2 uv; };
    struct FlatVideoUniforms { float4x4 viewProjection; };
    struct ImmersiveVideoUniforms {
        float4 viewOrientation;
        float4 fovTangents;
        float4 anchorRight;
        float4 anchorUp;
        float4 anchorForward;
        float4 parameters;
        float4 stereoParameters;
    };
    struct VideoVertexOut { float4 position [[position]]; float2 uv; };
    struct ImmersiveVertexOut { float4 position [[position]]; float2 ndc; };

    vertex VideoVertexOut flat_video_vertex(
        uint vertexID [[vertex_id]],
        const device VideoVertex *vertices [[buffer(0)]],
        constant FlatVideoUniforms &uniforms [[buffer(1)]]) {
        VideoVertexOut output;
        VideoVertex input = vertices[vertexID];
        output.position = uniforms.viewProjection * float4(input.position, 1.0);
        output.uv = input.uv;
        return output;
    }

    fragment float4 flat_video_fragment(
        VideoVertexOut input [[stage_in]],
        texture2d<float> video [[texture(0)]],
        sampler videoSampler [[sampler(0)]]) {
        return video.sample(videoSampler, input.uv);
    }

    vertex ImmersiveVertexOut immersive_video_vertex(uint vertexID [[vertex_id]]) {
        const float2 p[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        ImmersiveVertexOut output;
        output.position = float4(p[vertexID], 0.0, 1.0);
        output.ndc = p[vertexID];
        return output;
    }

    static float3 rotateByQuaternion(float3 v, float4 q) {
        const float3 qv = q.xyz;
        return v + 2.0 * cross(qv, cross(qv, v) + q.w * v);
    }

    static float2 projectEAC(float3 w, uint textureWidth, uint textureHeight) {
        float3 p = float3(w.x, -w.y, -w.z);
        float ax = fabs(p.x), ay = fabs(p.y), az = fabs(p.z);
        float uf = 0.0, vf = 0.0;
        int col = 1, row = 0;
        int rotation = 0;

        if (ax >= ay && ax >= az) {
            if (p.x >= 0.0) {
                uf = -p.z / p.x; vf = p.y / p.x; col = 2; row = 0;
            } else {
                uf = -p.z / p.x; vf = -p.y / p.x; col = 0; row = 0;
            }
        } else if (ay >= ax && ay >= az) {
            if (p.y >= 0.0) {
                uf = p.x / p.y; vf = -p.z / p.y; col = 0; row = 1; rotation = 3;
            } else {
                uf = -p.x / p.y; vf = -p.z / p.y; col = 2; row = 1; rotation = 3;
            }
        } else {
            if (p.z >= 0.0) {
                uf = p.x / p.z; vf = p.y / p.z; col = 1; row = 0;
            } else {
                uf = p.x / p.z; vf = -p.y / p.z; col = 1; row = 1; rotation = 1;
            }
        }

        if (rotation == 1) {
            float t = uf; uf = -vf; vf = t;
        } else if (rotation == 3) {
            float t = -uf; uf = vf; vf = t;
        }

        uf = (2.0 / PI) * atan(uf) + 0.5;
        vf = (2.0 / PI) * atan(vf) + 0.5;
        const float uPad = 2.0 / float(max(textureWidth, 1u));
        const float vPad = 2.0 / float(max(textureHeight, 1u));
        return float2(
            (uf + float(col)) * (1.0 - 2.0 * uPad) / 3.0 + uPad,
            vf * (0.5 - 2.0 * vPad) + vPad + 0.5 * float(row)
        );
    }

    fragment float4 immersive_video_fragment(
        ImmersiveVertexOut input [[stage_in]],
        constant ImmersiveVideoUniforms &uniforms [[buffer(0)]],
        texture2d<float> video [[texture(0)]],
        sampler videoSampler [[sampler(0)]]) {
        const float2 unit = (input.ndc + 1.0) * 0.5;
        const float viewX = mix(uniforms.fovTangents.x, uniforms.fovTangents.y, unit.x);
        const float viewY = mix(uniforms.fovTangents.z, uniforms.fovTangents.w, unit.y);
        const float3 viewRay = normalize(float3(viewX, viewY, -1.0));
        const float3 worldRay = normalize(rotateByQuaternion(viewRay, uniforms.viewOrientation));

        const float localX = dot(worldRay, uniforms.anchorRight.xyz);
        const float localY = dot(worldRay, uniforms.anchorUp.xyz);
        const float localForward = dot(worldRay, uniforms.anchorForward.xyz);
        const int eye = int(uniforms.parameters.x + 0.5);
        const int projectionMode = int(uniforms.parameters.y + 0.5);
        const int stereoLayout = int(uniforms.stereoParameters.x + 0.5);

        if (projectionMode == 3) {
            const float3 gavDirection = float3(localX, localY, -localForward);
            const float2 uv = projectEAC(
                gavDirection,
                uint(uniforms.parameters.z),
                uint(uniforms.parameters.w)
            );
            return video.sample(videoSampler, uv);
        }

        if (localForward <= 0.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        float2 eyeUV;
        if (projectionMode == 2) {
            const float theta = acos(clamp(localForward, -1.0, 1.0));
            if (theta > PI * 0.5) {
                return float4(0.0, 0.0, 0.0, 1.0);
            }
            const float phi = atan2(localY, localX);
            const float radius = 0.5 * theta / (PI * 0.5);
            eyeUV = float2(
                0.5 + radius * cos(phi),
                0.5 - radius * sin(phi)
            );
        } else {
            const float longitude = atan2(localX, localForward);
            const float latitude = asin(clamp(localY, -1.0, 1.0));
            eyeUV = float2(
                longitude / PI + 0.5,
                0.5 - latitude / PI
            );
        }

        if (any(eyeUV < 0.0) || any(eyeUV > 1.0)) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        float2 uv = eyeUV;
        if (stereoLayout == 1) {
            uv = float2((eyeUV.x + float(eye)) * 0.5, eyeUV.y);
        } else if (stereoLayout == 2) {
            uv = float2(eyeUV.x, (eyeUV.y + float(eye)) * 0.5);
        }
        return video.sample(videoSampler, uv);
    }
    """
}
