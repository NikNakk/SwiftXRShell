import simd
import SwiftXR

/// Geometry shared by tracked pointer hit testing and panel rendering. OpenXR
/// aim poses point along local -Z, and panel UVs start at the top-left.
enum PanelRay {
    static func hit(origin: SIMD3<Float>, direction: SIMD3<Float>, model: simd_float4x4) -> SIMD2<Float>? {
        guard origin.allFinite, direction.allFinite else { return nil }
        let inverse = model.inverse
        let o = inverse * SIMD4(origin, 1)
        let d = inverse * SIMD4(direction, 0)
        guard abs(d.z) > 0.000_001 else { return nil }
        let t = -o.z / d.z
        guard t >= 0, t.isFinite else { return nil }
        let p = o + d * t
        let uv = SIMD2(p.x + 0.5, 0.5 - p.y)
        guard uv.x.isFinite, uv.y.isFinite,
              (0...1).contains(uv.x), (0...1).contains(uv.y) else { return nil }
        return uv
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

struct TrackedPanelHand {
    var active = false
    var origin: SIMD3<Float>?
    var direction: SIMD3<Float>?
    var select = false
    var primary = false
    var grip = false
    var back = false
    var menu = false
    var recenter = false
    var stick: SIMD2<Float> = .zero

    init() {}

    init(_ state: XRControllerHandState) {
        active = state.isActive
        select = state.select
        primary = state.primaryButton
        grip = state.grip
        back = state.back
        menu = state.menu
        recenter = state.recenter
        stick = state.thumbstick
        if let pose = state.aimPose {
            origin = SIMD3(pose.position.x, pose.position.y, pose.position.z)
            direction = simd_quatf(ix: pose.orientation.x, iy: pose.orientation.y,
                                   iz: pose.orientation.z, r: pose.orientation.w).act(SIMD3(0, 0, -1))
        }
    }
}

struct TrackedPanelCommands {
    var usesControllers = false
    var back = false
    var menu = false
    var recenter = false
    var hasActivity = false
    var togglePlay = false
    var seekSteps = 0
}

/// Stateful selection/drag routing, independent of the runtime so hand changes,
/// loss of tracking and held-button transitions can be verified without an HMD.
@MainActor
final class TrackedPanelRouter {
    private var previous: [TrackedPanelHand]?
    private var selectedHand = 1
    private var pointerDown = false
    private var lastFocused = false
    private var activityPosition: SIMD2<Float>?

    func reset(interaction: XRPanelInteraction) {
        cancelPointer(interaction)
        previous = nil
        lastFocused = false
        selectedHand = 1
        activityPosition = nil
    }

    func route(hands: [TrackedPanelHand], focused: Bool, interaction: XRPanelInteraction,
               model: simd_float4x4, deltaTime: Float,
               pointerEnabled: Bool = true, scrollEnabled: Bool = true) -> TrackedPanelCommands {
        precondition(hands.count == 2)
        var result = TrackedPanelCommands()
        result.usesControllers = hands.contains { $0.active }
        guard focused else {
            cancelPointer(interaction)
            previous = nil
            lastFocused = false
            return result
        }
        let old = previous ?? hands // Never turn a held button on entry into a click.
        defer { previous = hands; lastFocused = true }
        guard result.usesControllers else {
            if lastFocused && old.contains(where: { $0.active }) { cancelPointer(interaction) }
            return result
        }

        if !hands[selectedHand].active {
            cancelPointer(interaction)
            selectedHand = hands[1].active ? 1 : 0
        }
        // Right hand is preferred. A fresh trigger press deliberately transfers
        // the pointer to the other hand, except while a drag is in progress.
        if !pointerDown {
            for index in [1 - selectedHand] where hands[index].active && old[index].active && hands[index].select && !old[index].select {
                selectedHand = index
            }
        }
        let hand = hands[selectedHand]
        let previousHand = old[selectedHand]
        let uv: SIMD2<Float>?
        if let origin = hand.origin, let direction = hand.direction {
            uv = PanelRay.hit(origin: origin, direction: direction, model: model)
        } else { uv = nil }

        if let uv, pointerEnabled {
            if interaction.pointerPosition != uv {
                interaction.movePointer(to: uv)
            }
            // Sub-pixel tracking jitter must not keep video controls awake.
            if activityPosition.map({ simd_distance($0, uv) > 0.01 }) ?? true {
                activityPosition = uv
                result.hasActivity = true
            }
            if hand.select && previousHand.active && !previousHand.select {
                interaction.pointerDown()
                pointerDown = true
                result.hasActivity = true
            }
            if pointerDown && !hand.select {
                interaction.pointerUp()
                pointerDown = false
                result.hasActivity = true
            }
        } else {
            // Cancel outside the panel, rather than clicking the last valid hit.
            cancelPointer(interaction)
            // The first trigger press reveals hidden controls without also
            // clicking a button that was invisible when the press began.
            if !pointerEnabled && hand.select && previousHand.active && !previousHand.select {
                result.hasActivity = true
            }
        }
        // A stick scrolls the visible menu even while the controller ray is
        // outside it. The host prefers the scroll view under the last pointer
        // and otherwise finds the panel's main vertical scroll view.
        let stick = hands[1].active ? hands[1].stick : .zero
        if pointerEnabled && scrollEnabled && abs(stick.y) > 0.18 {
            interaction.scroll(SIMD2(0, stick.y * min(max(deltaTime, 0), 0.05) * 4))
            result.hasActivity = true
        }
        for i in 0..<2 where hands[i].active && old[i].active {
            result.back = result.back || (hands[i].back && !old[i].back)
            result.menu = result.menu || (hands[i].menu && !old[i].menu)
            result.recenter = result.recenter || (hands[i].recenter && !old[i].recenter)
            result.togglePlay = result.togglePlay || (hands[i].primary && !old[i].primary)
            if hands[i].grip && !old[i].grip { result.seekSteps += i == 0 ? -1 : 1 }
        }
        result.hasActivity = result.hasActivity || result.back || result.menu || result.recenter || result.togglePlay || result.seekSteps != 0
        return result
    }

    private func cancelPointer(_ interaction: XRPanelInteraction) {
        if interaction.pointerPosition != nil { interaction.send(.pointerExited) }
        if pointerDown { interaction.pointerUp(); pointerDown = false }
    }
}

@MainActor
final class ShellTrackedInput {
    // Runtime calls are serialized by the Home frame worker, or by the main
    // frame loop in other modes. Transitions stop/join the worker first.
    nonisolated(unsafe) let runtimeInput: XRControllerInput
    private let router = TrackedPanelRouter()
    private var lastTime: Int64?
    private(set) var usesControllers = false
    private(set) var isFocused = false

    init(session: XRSession) throws { runtimeInput = try XRControllerInput(session: session) }

    func reset(interaction: XRPanelInteraction) {
        router.reset(interaction: interaction)
        lastTime = nil
    }

    func suspend(interaction: XRPanelInteraction) {
        reset(interaction: interaction)
        isFocused = false
    }

    func update(frame: XRFrame, interaction: XRPanelInteraction,
                model: simd_float4x4, pointerEnabled: Bool = true,
                faceButtonsSelect: Bool = true, scrollEnabled: Bool = true) throws -> TrackedPanelCommands {
        let state = try runtimeInput.poll(predictedDisplayTime: frame.predictedDisplayTime)
        return apply(state: state, frame: frame, interaction: interaction, model: model,
                     pointerEnabled: pointerEnabled, faceButtonsSelect: faceButtonsSelect,
                     scrollEnabled: scrollEnabled)
    }

    func apply(state: XRControllerState, frame: XRFrame, interaction: XRPanelInteraction,
               model: simd_float4x4, pointerEnabled: Bool = true,
               faceButtonsSelect: Bool = true, scrollEnabled: Bool = true) -> TrackedPanelCommands {
        let dt = lastTime.map { Float(frame.predictedDisplayTime - $0) / 1_000_000_000 } ?? 0
        lastTime = frame.predictedDisplayTime
        isFocused = state.isFocused
        // Keep the preferred interface through temporary focus loss. Action
        // states are intentionally inactive while an OpenXR session isn't focused.
        if state.isFocused { usesControllers = state.left.isActive || state.right.isActive }
        var hands = [TrackedPanelHand(state.left), TrackedPanelHand(state.right)]
        if faceButtonsSelect {
            for i in hands.indices { hands[i].select = hands[i].select || hands[i].primary }
        }
        var commands = router.route(hands: hands,
                                    focused: state.isFocused, interaction: interaction,
                                    model: model, deltaTime: dt, pointerEnabled: pointerEnabled,
                                    scrollEnabled: scrollEnabled)
        commands.usesControllers = usesControllers
        return commands
    }
}
