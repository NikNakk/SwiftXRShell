@preconcurrency import GameController
import Foundation

struct VideoControllerSnapshot {
    var togglePlay = false
    var select = false
    var seekSteps = 0
    var volumeSteps = 0
    var navX = 0
    var navY = 0
    var recenter = false
    var menu = false
    var back = false
    var leftX: Float = 0
    var leftY: Float = 0
    var rightX: Float = 0
    var rightY: Float = 0
}

@MainActor
final class VideoControllerInput {
    private var lastControllerIdentifier: ObjectIdentifier?
    private var previousA = false
    private var previousB = false
    private var previousY = false
    private var previousMenu = false
    private var previousL1 = false
    private var previousR1 = false
    private var previousDpadLeft = false
    private var previousDpadRight = false
    private var previousDpadUp = false
    private var previousDpadDown = false

    init() {
        GCController.shouldMonitorBackgroundEvents = true
    }

    func poll() -> VideoControllerSnapshot {
        guard let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }),
              let pad = controller.extendedGamepad
        else {
            lastControllerIdentifier = nil
            resetEdges()
            return VideoControllerSnapshot()
        }

        let identifier = ObjectIdentifier(controller)
        if identifier != lastControllerIdentifier {
            lastControllerIdentifier = identifier
            resetEdges()
        }

        var result = VideoControllerSnapshot()
        let a = rising(pad.buttonA.isPressed, previous: &previousA)
        result.togglePlay = a
        result.select = a
        result.back = rising(pad.buttonB.isPressed, previous: &previousB)
        result.recenter = rising(pad.buttonY.isPressed, previous: &previousY)
        result.menu = rising(pad.buttonMenu.isPressed, previous: &previousMenu)

        if rising(pad.leftShoulder.isPressed, previous: &previousL1) { result.seekSteps -= 1 }
        if rising(pad.rightShoulder.isPressed, previous: &previousR1) { result.seekSteps += 1 }

        if rising(pad.dpad.left.isPressed, previous: &previousDpadLeft) {
            result.navX -= 1
            result.seekSteps -= 1
        }
        if rising(pad.dpad.right.isPressed, previous: &previousDpadRight) {
            result.navX += 1
            result.seekSteps += 1
        }
        if rising(pad.dpad.up.isPressed, previous: &previousDpadUp) {
            result.navY -= 1
            result.volumeSteps += 1
        }
        if rising(pad.dpad.down.isPressed, previous: &previousDpadDown) {
            result.navY += 1
            result.volumeSteps -= 1
        }

        result.leftX = pad.leftThumbstick.xAxis.value
        result.leftY = pad.leftThumbstick.yAxis.value
        result.rightX = pad.rightThumbstick.xAxis.value
        result.rightY = pad.rightThumbstick.yAxis.value
        return result
    }

    private func rising(_ current: Bool, previous: inout Bool) -> Bool {
        let result = current && !previous
        previous = current
        return result
    }

    private func resetEdges() {
        previousA = false
        previousB = false
        previousY = false
        previousMenu = false
        previousL1 = false
        previousR1 = false
        previousDpadLeft = false
        previousDpadRight = false
        previousDpadUp = false
        previousDpadDown = false
    }
}
