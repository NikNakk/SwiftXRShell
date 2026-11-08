import Foundation
import Metal
import QuartzCore
import simd
import SwiftXR

struct HomeFrameUpdate: Sendable {
    let frame: XRFrame?
    let controllers: XRControllerState?
    let focused: Bool
    let running: Bool
    let shouldExit: Bool
    let referenceGeneration: UInt64
    let referenceTime: Int64
}

/// Owns all primary-session XR calls while Home is active. No AppKit/SwiftUI
/// work or synchronous main-queue dispatch is permitted on this queue. A slow
/// UI snapshot may delay the panel image, but cannot delay head/cursor frames.
final class HomeFrameLoop: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SwiftXR Shell Home frames", qos: .userInteractive)
    private let session: XRSession
    private let swapchain: XRSwapchain
    private let renderer: ShellPanelRenderer
    private let input: XRControllerInput
    private let onUpdates: @MainActor @Sendable ([HomeFrameUpdate]) -> Void
    private let onError: @MainActor @Sendable (Error) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var texture: any MTLTexture
    private var scrollInfo: XRPanelScrollInfo?
    private var contentRevision = 0
    private var capturedTexture: (any MTLTexture)?
    private var capturedScrollInfo: XRPanelScrollInfo?
    private var capturedRevision = -1
    private var scrollAnimation = PanelScrollAnimation()
    private var mousePointer: SIMD2<Float>?
    private var mouseButtonDown = false
    private var pending: [HomeFrameUpdate] = []
    private var deliveryScheduled = false
    private var selectedHand = 1
    private var previousSelect = [false, false]
    private var lastButtons: [Bool] = []
    private var completedFrames = 0

    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return completedFrames
    }

    init(session: XRSession, swapchain: XRSwapchain, renderer: ShellPanelRenderer,
         input: XRControllerInput, texture: any MTLTexture,
         onUpdates: @escaping @MainActor @Sendable ([HomeFrameUpdate]) -> Void,
         onError: @escaping @MainActor @Sendable (Error) -> Void) {
        self.session = session; self.swapchain = swapchain; self.renderer = renderer
        self.input = input; self.texture = texture
        self.onUpdates = onUpdates; self.onError = onError
    }

    func start() { queue.async { self.run() } }

    func publish(texture: any MTLTexture, mousePointer: SIMD2<Float>?,
                 scrollInfo: XRPanelScrollInfo? = nil, contentRevision: Int = 0,
                 mouseButtonDown: Bool = false) {
        lock.lock()
        self.texture = texture; self.mousePointer = mousePointer
        self.scrollInfo = scrollInfo; self.contentRevision = contentRevision
        self.mouseButtonDown = mouseButtonDown
        lock.unlock()
    }

    /// Joining before another mode uses the session enforces OpenXR's external
    /// synchronization requirements and makes renderer ownership unambiguous.
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.sync {}
    }

    private func state() -> (stopped: Bool, texture: any MTLTexture, mouse: SIMD2<Float>?, scroll: XRPanelScrollInfo?, revision: Int, mouseDown: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (stopped, texture, mousePointer, scrollInfo, contentRevision, mouseButtonDown)
    }

    private func run() {
        var timingStart = CACurrentMediaTime()
        var count = 0
        var rendered = 0
        var lastFrameTime: Double?
        var maxGap = 0.0
        while !state().stopped {
            do {
                try autoreleasepool {
                    try session.pollEvents()
                    if session.shouldExit {
                        enqueue(update(frame: nil, controllers: nil), preserve: true)
                        return
                    }
                    guard session.isRunning else {
                        enqueue(update(frame: nil, controllers: nil), preserve: false)
                        Thread.sleep(forTimeInterval: 0.005)
                        return
                    }
                    var controllers: XRControllerState?
                    let frame = try session.renderFrame(to: swapchain) { frame, texture, commands in
                        let current = state()
                        renderer.panelTexture = current.texture
                        ShellStageAnchor.shared.updateIfNeeded(from: frame)
                        let sample = try input.poll(predictedDisplayTime: frame.predictedDisplayTime)
                        controllers = sample
                        updateScroll(texture: current.texture, info: current.scroll,
                                     revision: current.revision, controllers: sample,
                                     mouseDown: current.mouseDown)
                        renderer.pointerPosition = pointer(sample, frame: frame, fallback: current.mouse)
                        try renderer.encode(frame: frame, texture: texture, commandBuffer: commands)
                    }
                    let buttons = controllers.map(Self.buttons) ?? []
                    if controllers != nil {
                        lock.lock(); completedFrames += 1; lock.unlock()
                        rendered += 1
                    }
                    let changed = buttons != lastButtons
                    lastButtons = buttons
                    enqueue(update(frame: frame, controllers: controllers), preserve: changed)
                    let now = CACurrentMediaTime()
                    if let lastFrameTime { maxGap = max(maxGap, now - lastFrameTime) }
                    lastFrameTime = now
                    count += 1
                    if now - timingStart >= 2 {
                        print(String(format: "[xr-home] %.1f frames/s %.1f rendered/s maxGap=%.2fms predictedPeriod=%.2fms",
                                     Double(count) / (now - timingStart), Double(rendered) / (now - timingStart), maxGap * 1000,
                                     Double(frame.predictedDisplayPeriod) / 1_000_000))
                        timingStart = now; count = 0; rendered = 0; maxGap = 0
                    }
                }
                if session.shouldExit { return }
            } catch {
                Task { @MainActor in self.onError(error) }
                return
            }
        }
    }

    private func update(frame: XRFrame?, controllers: XRControllerState?) -> HomeFrameUpdate {
        HomeFrameUpdate(frame: frame, controllers: controllers, focused: session.state == .focused,
                        running: session.isRunning, shouldExit: session.shouldExit,
                        referenceGeneration: session.referenceSpaceChangeGeneration,
                        referenceTime: session.referenceSpaceChangeTime)
    }

    private func updateScroll(texture: any MTLTexture, info: XRPanelScrollInfo?,
                              revision: Int, controllers: XRControllerState, mouseDown: Bool) {
        let now = CACurrentMediaTime()
        if capturedTexture !== texture {
            if revision == capturedRevision, let info, let oldInfo = capturedScrollInfo,
               info.viewport == oldInfo.viewport {
                if info.offset != oldInfo.offset {
                    renderer.previousPanelTexture = capturedTexture
                    scrollAnimation.update(offset: info.offset, at: now)
                }
            } else {
                renderer.previousPanelTexture = nil
                scrollAnimation.reset(offset: info?.offset ?? 0, at: now)
            }
            capturedTexture = texture; capturedScrollInfo = info; capturedRevision = revision
        }
        if mouseDown || controllers.left.select || controllers.right.select ||
            controllers.left.primaryButton || controllers.right.primaryButton {
            scrollAnimation.finish(at: now)
        }
        if let info {
            renderer.scrollViewport = info.viewport
            renderer.scrollOffsets = SIMD4(scrollAnimation.targetOffset, scrollAnimation.previousOffset,
                                           scrollAnimation.value(at: now), 1)
        } else {
            renderer.scrollOffsets = .zero
        }
    }

    private static func buttons(_ input: XRControllerState) -> [Bool] {
        [input.isFocused] + [input.left, input.right].flatMap {
            [$0.isActive, $0.select, $0.primaryButton, $0.back, $0.menu, $0.recenter, $0.grip]
        }
    }

    private func pointer(_ sample: XRControllerState, frame: XRFrame,
                         fallback: SIMD2<Float>?) -> SIMD2<Float>? {
        guard sample.isFocused else { previousSelect = [false, false]; return nil }
        let hands = [sample.left, sample.right]
        guard hands.contains(where: { $0.isActive }) else { return fallback }
        if !hands[selectedHand].isActive { selectedHand = hands[1].isActive ? 1 : 0 }
        let presses = hands.map { $0.select || $0.primaryButton }
        if !previousSelect[selectedHand] {
            let other = 1 - selectedHand
            if hands[other].isActive && presses[other] && !previousSelect[other] { selectedHand = other }
        }
        previousSelect = presses
        let hand = TrackedPanelHand(hands[selectedHand])
        guard let origin = hand.origin, let direction = hand.direction else { return nil }
        return PanelRay.hit(origin: origin, direction: direction,
                            model: ShellStageAnchor.shared.modelMatrix(worldWidth: 2.40,
                                textureAspect: Float(renderer.panelTexture.width) / Float(renderer.panelTexture.height)))
    }

    private func enqueue(_ update: HomeFrameUpdate, preserve: Bool) {
        lock.lock()
        if stopped { lock.unlock(); return }
        // Coalesce motion while the main thread is busy; keep every button edge
        // so a press and release cannot disappear during a UI capture.
        if !preserve && !pending.isEmpty { pending[pending.count - 1] = update }
        else { pending.append(update) }
        guard !deliveryScheduled else { lock.unlock(); return }
        deliveryScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            deliveryScheduled = false
            let active = !stopped
            lock.unlock()
            if active { onUpdates(batch) }
        }
    }
}
