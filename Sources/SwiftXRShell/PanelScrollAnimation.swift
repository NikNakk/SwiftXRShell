import Foundation

/// One snapshot of latency buys a continuous scroll position. Sampling either
/// adjacent capture fills the newly exposed strip without stretching pixels.
struct PanelScrollAnimation {
    private(set) var previousOffset: Float = 0
    private(set) var targetOffset: Float = 0
    private var startOffset: Float = 0
    private var startedAt: Double = 0
    private var duration: Double = 0
    private var lastUpdate: Double?

    mutating func reset(offset: Float, at time: Double) {
        previousOffset = offset; targetOffset = offset; startOffset = offset
        startedAt = time; duration = 0; lastUpdate = nil
    }

    mutating func update(offset: Float, at time: Double) {
        guard offset != targetOffset else { return }
        let current = value(at: time)
        previousOffset = targetOffset
        targetOffset = offset
        let lower = min(previousOffset, targetOffset)
        let upper = max(previousOffset, targetOffset)
        startOffset = min(max(current, lower), upper)
        duration = min(max(lastUpdate.map { time - $0 } ?? 1.0 / 60, 1.0 / 120), 0.06)
        startedAt = time; lastUpdate = time
    }

    mutating func finish(at time: Double) {
        startOffset = targetOffset; duration = 0; startedAt = time
    }

    func value(at time: Double) -> Float {
        guard duration > 0 else { return targetOffset }
        let progress = Float(min(max((time - startedAt) / duration, 0), 1))
        return startOffset + (targetOffset - startOffset) * progress
    }
}
