@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import simd
import SwiftXR

enum AmbisonicAudioError: Error, CustomStringConvertible {
    case ffmpegUnavailable(Error)
    case ffmpegFailed(Int32)
    case invalidCache(String)
    case channelLayoutCreationFailed
    case formatCreationFailed
    case psvr2AudioDeviceMissing
    case outputAudioUnitMissing
    case outputRoutingFailed(OSStatus)

    var description: String {
        switch self {
        case let .ffmpegUnavailable(error): return "Could not launch ffmpeg: \(error.localizedDescription)"
        case let .ffmpegFailed(status): return "ffmpeg AmbiX conversion exited with status \(status)"
        case let .invalidCache(message): return "Invalid AmbiX cache: \(message)"
        case .channelLayoutCreationFailed: return "Could not create ACN/SN3D Ambisonic channel layout"
        case .formatCreationFailed: return "Could not create four-channel Ambisonic processing format"
        case .psvr2AudioDeviceMissing: return "PS VR2 CoreAudio output device not found"
        case .outputAudioUnitMissing: return "AVAudioEngine output node has no AudioUnit"
        case let .outputRoutingFailed(status): return "Could not route AVAudioEngine to PS VR2 (OSStatus \(status))"
        }
    }
}

@MainActor
final class AmbisonicAudio {
    private let cacheURL: URL
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let playerNode = AVAudioPlayerNode()
    private let file: AVAudioFile

    init(sidecarURL: URL) throws {
        cacheURL = sidecarURL
            .deletingPathExtension()
            .appendingPathExtension("gav-foa-acn-sn3d.caf")

        try Self.buildNativeCacheIfNeeded(source: sidecarURL, cache: cacheURL)

        let file = try AVAudioFile(forReading: cacheURL)
        guard file.processingFormat.channelCount == 4 else {
            throw AmbisonicAudioError.invalidCache(
                "expected 4 channels, found \(file.processingFormat.channelCount)"
            )
        }
        self.file = file

        let hoaTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | AudioChannelLayoutTag(4)
        guard let channelLayout = AVAudioChannelLayout(layoutTag: hoaTag) else {
            throw AmbisonicAudioError.channelLayoutCreationFailed
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: channelLayout
        ), format.channelCount == 4 else {
            throw AmbisonicAudioError.formatCreationFailed
        }

        engine.attach(environment)
        engine.attach(playerNode)
        engine.connect(playerNode, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        environment.outputType = .headphones
        environment.listenerPosition = AVAudioMake3DPoint(0, 0, 0)
        playerNode.renderingAlgorithm = .auto
        playerNode.sourceMode = .ambienceBed
        playerNode.reverbBlend = 0
        playerNode.position = AVAudioMake3DPoint(0, 0, -1)
        engine.mainMixerNode.outputVolume = 1

        try routeEngineToPSVR2()
        engine.prepare()
        try engine.start()
    }

    func startSynchronized(videoPlayer: AVPlayer, mediaTimeSeconds: Double) throws {
        let mediaTime = max(mediaTimeSeconds, 0)
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((mediaTime * sampleRate).rounded())

        playerNode.stop()
        guard startFrame < file.length else { return }

        let remaining = file.length - startFrame
        let frameCount = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionHandler: nil
        )

        if !engine.isRunning { try engine.start() }

        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let startTime = CMTimeAdd(
            hostNow,
            CMTime(seconds: 0.100, preferredTimescale: 1_000_000_000)
        )
        let hostTime = CMClockConvertHostTimeToSystemUnits(startTime)
        playerNode.play(at: AVAudioTime(hostTime: hostTime))

        let itemTime = CMTime(seconds: mediaTime, preferredTimescale: 600)
        let hostClockTime = CMClockMakeHostTimeFromSystemUnits(hostTime)
        videoPlayer.setRate(1, time: itemTime, atHostTime: hostClockTime)
    }

    func pause() { playerNode.pause() }

    func setVolume(_ value: Float) {
        engine.mainMixerNode.outputVolume = min(max(value, 0), 1)
    }

    func updateHeadOrientation(
        from view: XRView,
        sceneAnchor: VideoProjectionAnchor?
    ) {
        let orientation = view.pose.orientation
        let q = simd_quatf(
            ix: orientation.x,
            iy: orientation.y,
            iz: orientation.z,
            r: orientation.w
        )
        let worldForward = simd_normalize(q.act(SIMD3<Float>(0, 0, -1)))
        let worldUp = simd_normalize(q.act(SIMD3<Float>(0, 1, 0)))

        let forward: SIMD3<Float>
        let up: SIMD3<Float>
        if let anchor = sceneAnchor {
            forward = SIMD3(
                simd_dot(worldForward, anchor.right),
                simd_dot(worldForward, anchor.up),
                -simd_dot(worldForward, anchor.forward)
            )
            up = SIMD3(
                simd_dot(worldUp, anchor.right),
                simd_dot(worldUp, anchor.up),
                -simd_dot(worldUp, anchor.forward)
            )
        } else {
            forward = worldForward
            up = worldUp
        }

        environment.listenerVectorOrientation = AVAudioMake3DVectorOrientation(
            AVAudioMake3DVector(forward.x, forward.y, forward.z),
            AVAudioMake3DVector(up.x, up.y, up.z)
        )
    }

    private func routeEngineToPSVR2() throws {
        guard let device = VideoAudioRouting.findPSVR2Device() else {
            throw AmbisonicAudioError.psvr2AudioDeviceMissing
        }
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw AmbisonicAudioError.outputAudioUnitMissing
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.stride)
        )
        guard status == noErr else {
            throw AmbisonicAudioError.outputRoutingFailed(status)
        }
    }

    private static func buildNativeCacheIfNeeded(source: URL, cache: URL) throws {
        if FileManager.default.fileExists(atPath: cache.path) { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-i", source.path,
            "-map", "0:a:0",
            "-c:a", "pcm_f32le",
            "-ar", "48000",
            "-f", "caf",
            cache.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw AmbisonicAudioError.ffmpegUnavailable(error)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: cache.path)
        else {
            throw AmbisonicAudioError.ffmpegFailed(process.terminationStatus)
        }
    }
}
