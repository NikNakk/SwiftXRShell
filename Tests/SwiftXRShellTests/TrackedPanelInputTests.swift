import Foundation
import simd
import SwiftXR
import Testing
@testable import SwiftXRShell

@Suite("Tracked panel geometry")
struct PanelRayTests {
    private let panel = simd_float4x4(columns: (
        SIMD4(2, 0, 0, 0), SIMD4(0, 1, 0, 0),
        SIMD4(0, 0, 1, 0), SIMD4(0, 0, -2, 1)
    ))

    @Test func centerAndEdges() throws {
        #expect(PanelRay.hit(origin: .zero, direction: SIMD3(0, 0, -1), model: panel) == SIMD2(0.5, 0.5))
        #expect(PanelRay.hit(origin: SIMD3(-1, 0.5, 0), direction: SIMD3(0, 0, -1), model: panel) == SIMD2(0, 0))
        #expect(PanelRay.hit(origin: SIMD3(1, -0.5, 0), direction: SIMD3(0, 0, -1), model: panel) == SIMD2(1, 1))
    }

    @Test func missesAndInvalidRays() {
        #expect(PanelRay.hit(origin: .zero, direction: SIMD3(0, 0, 1), model: panel) == nil)
        #expect(PanelRay.hit(origin: .zero, direction: SIMD3(1, 0, 0), model: panel) == nil)
        #expect(PanelRay.hit(origin: SIMD3(2, 0, 0), direction: SIMD3(0, 0, -1), model: panel) == nil)
        #expect(PanelRay.hit(origin: .zero, direction: SIMD3(.nan, 0, -1), model: panel) == nil)
    }

    @Test func rotatedTranslatedPanel() throws {
        let transform = simd_float4x4(simd_quatf(angle: .pi / 3, axis: SIMD3(0, 1, 0)))
        let model = transform * panel
        let ray = transform * SIMD4<Float>(0.3, -0.1, -1, 0)
        let uv = try #require(PanelRay.hit(origin: .zero, direction: SIMD3(ray.x, ray.y, ray.z), model: model))
        #expect(abs(uv.x - 0.8) < 0.0001)
        #expect(abs(uv.y - 0.7) < 0.0001)
    }
}

@Suite("Tracked controller routing")
@MainActor
struct TrackedPanelRoutingTests {
    private func hand(x: Float = 0, pressed: Bool = false) -> TrackedPanelHand {
        var hand = TrackedPanelHand()
        hand.active = true
        hand.origin = SIMD3(x, 0, 1)
        hand.direction = SIMD3(0, 0, -1)
        hand.select = pressed
        return hand
    }

    @Test func prefersRightAndTransfersOnLeftTrigger() {
        let router = TrackedPanelRouter()
        let interaction = XRPanelInteraction()
        let left = hand(x: -0.25)
        let right = hand(x: 0.25)
        _ = router.route(hands: [left, right], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(interaction.pointerPosition == SIMD2(0.75, 0.5))
        var events: [XRPanelInteractionEvent] = []
        interaction.handler = { events.append($0) }
        _ = router.route(hands: [hand(x: -0.25, pressed: true), right], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(interaction.pointerPosition == SIMD2(0.25, 0.5))
        #expect(events.last == .pointerDown(.primary))
    }

    @Test func heldButtonOnConnectDoesNotClick() {
        let router = TrackedPanelRouter()
        let interaction = XRPanelInteraction()
        var events: [XRPanelInteractionEvent] = []
        interaction.handler = { events.append($0) }
        _ = router.route(hands: [.init(), .init()], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        _ = router.route(hands: [.init(), hand(pressed: true)], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(!events.contains(.pointerDown(.primary)))
        _ = router.route(hands: [.init(), hand()], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        _ = router.route(hands: [.init(), hand(pressed: true)], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(events.last == .pointerDown(.primary))
    }

    @Test func lostPoseCancelsOutsidePanelAndDoesNotClickOnReentry() {
        let router = TrackedPanelRouter()
        let interaction = XRPanelInteraction()
        _ = router.route(hands: [.init(), hand()], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        _ = router.route(hands: [.init(), hand(pressed: true)], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        var events: [XRPanelInteractionEvent] = []
        interaction.handler = { events.append($0) }
        var lost = hand(pressed: true)
        lost.origin = nil
        let result = router.route(hands: [.init(), lost], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(result.usesControllers)
        #expect(events == [.pointerExited, .pointerUp(.primary)])
        #expect(interaction.pointerPosition == nil)
        events = []
        _ = router.route(hands: [.init(), hand(pressed: true)], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(!events.contains(.pointerDown(.primary)))
    }

    @Test func focusLossReleasesDragAndSuppressesHeldPressOnReturn() {
        let router = TrackedPanelRouter()
        let interaction = XRPanelInteraction()
        _ = router.route(hands: [.init(), hand()], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        _ = router.route(hands: [.init(), hand(pressed: true)], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        _ = router.route(hands: [.init(), .init()], focused: false, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(interaction.pointerPosition == nil)
        var events: [XRPanelInteractionEvent] = []
        interaction.handler = { events.append($0) }
        _ = router.route(hands: [.init(), hand(pressed: true)], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(!events.contains(.pointerDown(.primary)))
    }

    @Test func disconnectFallsBackToMouseAndReleasesDrag() {
        let router = TrackedPanelRouter()
        let interaction = XRPanelInteraction()
        _ = router.route(hands: [.init(), hand()], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        _ = router.route(hands: [.init(), hand(pressed: true)], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        let result = router.route(hands: [.init(), .init()], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(!result.usesControllers)
        #expect(interaction.pointerPosition == nil)
    }

    @Test func backMenuAndRecenterAreEdges() {
        let router = TrackedPanelRouter()
        let interaction = XRPanelInteraction()
        _ = router.route(hands: [.init(), hand()], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        var pressed = hand()
        pressed.back = true; pressed.menu = true; pressed.recenter = true
        let edge = router.route(hands: [.init(), pressed], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(edge.back && edge.menu && edge.recenter)
        let held = router.route(hands: [.init(), pressed], focused: true, interaction: interaction, model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(!held.back && !held.menu && !held.recenter)
    }
}

@Suite("OpenXR controller integration")
struct ControllerRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTXR_TEST_RUNTIME"] == "1"))
    func discoversInstalledMonadoControlLibrary() throws {
        let control = try XRMonadoRuntimeControl()
        let clients = try control.refreshClients()
        print("[test] Monado runtime control connected; \(clients.count) client(s)")
    }

    // Opt in on a machine with a configured, running OpenXR runtime. Session
    // creation/attachment exercises the real binding validation without beginning
    // an immersive session or taking display focus from another application.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTXR_TEST_RUNTIME"] == "1"))
    func attachesControllerActionsToRuntime() throws {
        let instance = try XRInstance(applicationName: "SwiftXR controller binding check")
        let session = try instance.system().makeSession()
        let input = try XRControllerInput(session: session)
        withExtendedLifetime(input) {}
    }
}

@Suite("Sense video mappings")
@MainActor
struct SenseVideoMappingTests {
    private func activeHand() -> TrackedPanelHand {
        var hand = TrackedPanelHand()
        hand.active = true
        hand.origin = SIMD3(0, 0, 1)
        hand.direction = SIMD3(0, 0, -1)
        return hand
    }

    @Test func gripsAreIndependentSeekEdges() {
        let router = TrackedPanelRouter()
        let interaction = XRPanelInteraction()
        let idle = activeHand()
        func sample(_ left: TrackedPanelHand, _ right: TrackedPanelHand) -> TrackedPanelCommands {
            router.route(hands: [left, right], focused: true, interaction: interaction,
                         model: matrix_identity_float4x4, deltaTime: 0.01)
        }
        _ = sample(idle, idle)
        var grip = idle
        grip.grip = true
        #expect(sample(grip, idle).seekSteps == -1)
        #expect(sample(grip, idle).seekSteps == 0)
        _ = sample(idle, idle)
        #expect(sample(idle, grip).seekSteps == 1)
        _ = sample(idle, idle)
        #expect(sample(grip, grip).seekSteps == 0)
    }

    @Test func onlyRightStickScrollsAndOnlyWhenEnabled() {
        let router = TrackedPanelRouter()
        let interaction = XRPanelInteraction()
        let idle = activeHand()
        var scrolling = idle
        scrolling.stick = SIMD2(0, 1)
        var events: [XRPanelInteractionEvent] = []
        interaction.handler = { events.append($0) }
        _ = router.route(hands: [scrolling, idle], focused: true, interaction: interaction,
                         model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(!events.contains { if case .scroll = $0 { true } else { false } })
        events = []
        _ = router.route(hands: [idle, scrolling], focused: true, interaction: interaction,
                         model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(events.contains(.scroll(SIMD2(0, 0.04))))
        events = []
        _ = router.route(hands: [idle, scrolling], focused: true, interaction: interaction,
                         model: matrix_identity_float4x4, deltaTime: 0.01, scrollEnabled: false)
        #expect(events.isEmpty)
    }

    @Test func faceButtonTogglesPlaybackWithoutPointerClick() {
        let router = TrackedPanelRouter()
        let interaction = XRPanelInteraction()
        let idle = activeHand()
        _ = router.route(hands: [idle, idle], focused: true, interaction: interaction,
                         model: matrix_identity_float4x4, deltaTime: 0.01)
        var face = idle
        face.primary = true
        var events: [XRPanelInteractionEvent] = []
        interaction.handler = { events.append($0) }
        let result = router.route(hands: [idle, face], focused: true, interaction: interaction,
                                  model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(result.togglePlay)
        #expect(!events.contains(.pointerDown(.primary)))
        let held = router.route(hands: [idle, face], focused: true, interaction: interaction,
                                model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(!held.togglePlay)
    }

    @Test func triggerRevealsHiddenPanelWithoutClickingThrough() {
        let router = TrackedPanelRouter()
        let interaction = XRPanelInteraction()
        let idle = activeHand()
        _ = router.route(hands: [idle, idle], focused: true, interaction: interaction,
                         model: matrix_identity_float4x4, deltaTime: 0.01, pointerEnabled: false)
        var trigger = idle
        trigger.select = true
        var events: [XRPanelInteractionEvent] = []
        interaction.handler = { events.append($0) }
        let result = router.route(hands: [idle, trigger], focused: true, interaction: interaction,
                                  model: matrix_identity_float4x4, deltaTime: 0.01, pointerEnabled: false)
        #expect(result.hasActivity)
        #expect(!events.contains(.pointerDown(.primary)))
        _ = router.route(hands: [idle, trigger], focused: true, interaction: interaction,
                         model: matrix_identity_float4x4, deltaTime: 0.01)
        #expect(!events.contains(.pointerDown(.primary)))
    }
}
