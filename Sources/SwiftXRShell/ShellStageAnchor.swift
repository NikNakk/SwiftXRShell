import simd

/// Shared world-space stage used by the Shell's built-in surfaces.
///
/// Keeping Home, Video UI and Desktop on the same stage prevents each mode
/// from appearing to jump to a new head-relative position when selected.
final class ShellStageAnchor: @unchecked Sendable {
    static let shared = ShellStageAnchor()
    static let defaultDistance: Float = 1.80

    private init() {}

    func modelMatrix(
        worldWidth: Float,
        textureAspect: Float,
        distance: Float = ShellStageAnchor.defaultDistance,
        verticalOffset: Float = 0
    ) -> simd_float4x4 {
        let worldHeight = worldWidth / max(textureAspect, 0.001)
        let center = SIMD3<Float>(0, verticalOffset, -distance)

        return simd_float4x4(columns: (
            SIMD4<Float>(worldWidth, 0, 0, 0),
            SIMD4<Float>(0, worldHeight, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(center, 1)
        ))
    }
}
