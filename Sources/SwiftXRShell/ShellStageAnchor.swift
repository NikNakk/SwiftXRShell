import Foundation
import simd
import SwiftXR

/// Shared world-space stage used by the Shell's built-in surfaces.
///
/// Keeping Home, Video UI and Desktop on the same stage prevents each mode
/// from appearing to jump to a new head-relative position when selected.
/// Recenter requests are captured from the next valid XR frame so every built-in
/// moves together to the same newly centred stage.
final class ShellStageAnchor: @unchecked Sendable {
    static let shared = ShellStageAnchor()
    static let defaultDistance: Float = 1.80

    private struct Pose {
        var headPosition: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var forward: SIMD3<Float>
    }

    private var pose: Pose?
    private var recenterRequested = false
    private var recenterNotBefore: Int64?
    private let lock = NSLock()

    init() {}
    private var revision: UInt64 = 0

    var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return revision
    }

    func requestRecenter(atTime time: Int64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        recenterRequested = true
        recenterNotBefore = time
    }

    /// Capture a yaw-levelled stage from the current headset pose when a global
    /// recenter has been requested. Pitch/roll are deliberately discarded so
    /// Shell panels remain vertical even if the user is looking slightly up,
    /// down or sideways when recentering.
    func updateIfNeeded(from frame: XRFrame) {
        guard
            frame.views.count >= 2,
            frame.trackingState.orientationValid,
            frame.trackingState.positionValid
        else { return }

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
        updateIfNeeded(headPosition: (leftPosition + rightPosition) * 0.5,
                       orientation: orientation, predictedDisplayTime: frame.predictedDisplayTime)
    }

    func updateIfNeeded(headPosition: SIMD3<Float>, orientation: simd_quatf, predictedDisplayTime: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard recenterRequested else { return }
        if let recenterNotBefore, predictedDisplayTime < recenterNotBefore { return }

        let rawForward = orientation.act(SIMD3<Float>(0, 0, -1))
        var forward = SIMD3<Float>(rawForward.x, 0, rawForward.z)
        if simd_length_squared(forward) < 0.000_001 {
            forward = SIMD3<Float>(0, 0, -1)
        } else {
            forward = simd_normalize(forward)
        }
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(forward, up))

        pose = Pose(
            headPosition: headPosition,
            right: right,
            up: up,
            forward: forward
        )
        recenterRequested = false
        recenterNotBefore = nil
        revision &+= 1
    }

    func modelMatrix(
        worldWidth: Float,
        textureAspect: Float,
        distance: Float = ShellStageAnchor.defaultDistance,
        verticalOffset: Float = 0
    ) -> simd_float4x4 {
        lock.lock()
        defer { lock.unlock() }
        let worldHeight = worldWidth / max(textureAspect, 0.001)

        guard let pose else {
            let center = SIMD3<Float>(0, verticalOffset, -distance)
            return simd_float4x4(columns: (
                SIMD4<Float>(worldWidth, 0, 0, 0),
                SIMD4<Float>(0, worldHeight, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(center, 1)
            ))
        }

        let center = pose.headPosition + pose.forward * distance + pose.up * verticalOffset
        return simd_float4x4(columns: (
            SIMD4<Float>(pose.right * worldWidth, 0),
            SIMD4<Float>(pose.up * worldHeight, 0),
            SIMD4<Float>(-pose.forward, 0),
            SIMD4<Float>(center, 1)
        ))
    }
}
