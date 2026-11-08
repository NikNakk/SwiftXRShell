import Testing
@testable import SwiftXRShell

@Suite("Scroll snapshot interpolation")
struct PanelScrollAnimationTests {
    @Test func interpolatesWithinBothCapturedViewports() {
        var animation = PanelScrollAnimation()
        animation.reset(offset: 0, at: 0)
        animation.update(offset: 0.1, at: 0.03)
        #expect(animation.value(at: 0.03) == 0)
        #expect(animation.value(at: 0.038) > 0)
        #expect(animation.value(at: 0.038) < 0.1)
        #expect(animation.value(at: 0.1) == 0.1)
        animation.update(offset: 0.2, at: 0.06)
        #expect(animation.previousOffset == 0.1)
        #expect(animation.value(at: 0.075) > 0.1)
        #expect(animation.value(at: 0.075) < 0.2)
    }

    @Test func reversalsRemainInsideAvailableCaptures() {
        var animation = PanelScrollAnimation()
        animation.reset(offset: 1, at: 0)
        animation.update(offset: 2, at: 0.03)
        animation.update(offset: 1.5, at: 0.035)
        for step in 0...10 {
            let value = animation.value(at: 0.035 + Double(step) * 0.003)
            #expect(value >= 1.5 && value <= 2)
        }
    }

    @Test func clicksSnapToNativeHitTestPosition() {
        var animation = PanelScrollAnimation()
        animation.reset(offset: 0, at: 0)
        animation.update(offset: 0.2, at: 0.03)
        animation.finish(at: 0.035)
        #expect(animation.value(at: 0.035) == 0.2)
        animation.reset(offset: 0, at: 1)
        #expect(animation.value(at: 1) == 0)
    }
}
