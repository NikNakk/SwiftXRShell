@preconcurrency import AVFoundation
import CoreAudio
import Foundation

enum VideoAudioRouting {
    struct Device {
        let id: AudioDeviceID
        let name: String
        let uid: String?
    }

    @discardableResult
    static func routeToPSVR2(_ player: AVPlayer) -> Device? {
        guard let device = findPSVR2Device() else {
            fputs("[audio] PS VR2 output device not found; using current macOS default output\n", stderr)
            return nil
        }
        guard let uid = device.uid else {
            fputs("[audio] PS VR2 device found but its CoreAudio UID could not be read\n", stderr)
            return nil
        }

        player.audioOutputDeviceUniqueID = uid
        print("[audio] routed AVPlayer to headset: \(device.name)")
        return device
    }

    static func findPSVR2Device() -> Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            system,
            &address,
            0,
            nil,
            &dataSize,
            &devices
        ) == noErr else { return nil }

        for id in devices {
            guard let name = stringProperty(objectID: id, selector: kAudioObjectPropertyName) else {
                continue
            }
            let normalized = name.lowercased().replacingOccurrences(of: " ", with: "")
            if normalized.contains("psvr2") {
                return Device(
                    id: id,
                    name: name,
                    uid: stringProperty(objectID: id, selector: kAudioDevicePropertyDeviceUID)
                )
            }
        }
        return nil
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.stride)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
