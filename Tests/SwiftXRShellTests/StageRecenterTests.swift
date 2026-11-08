import simd
import Testing
@testable import SwiftXRShell

struct StageRecenterTests {
    @Test func runtimeResetChangesRevisionAtEffectiveFrameAndMovesFlatVideo() {
        let stage = ShellStageAnchor()
        let head = SIMD3<Float>(1, 1.7, 3)
        let orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        stage.requestRecenter(atTime: 100)
        stage.updateIfNeeded(headPosition: head, orientation: orientation, predictedDisplayTime: 99)
        #expect(stage.generation == 0)
        stage.updateIfNeeded(headPosition: head, orientation: orientation, predictedDisplayTime: 100)
        #expect(stage.generation == 1)
        let model = stage.modelMatrix(worldWidth: 1, textureAspect: 1, distance: 0)
        let videoCenter = model * SIMD4<Float>(0, 0, -2, 1)
        let expected = head + orientation.act(SIMD3<Float>(0, 0, -2))
        #expect(simd_distance(SIMD3(videoCenter.x, videoCenter.y, videoCenter.z), expected) < 0.0001)
        stage.requestRecenter()
        stage.updateIfNeeded(headPosition: .zero, orientation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), predictedDisplayTime: 101)
        #expect(stage.generation == 2)
    }
}
