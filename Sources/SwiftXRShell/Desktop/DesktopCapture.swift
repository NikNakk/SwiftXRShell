import CoreMedia
import CoreVideo
import Foundation
import Metal
import ScreenCaptureKit

struct DesktopCaptureFrame {
    let texture: any MTLTexture
    let width: Int
    let height: Int
    let presentationTime: CMTime
}

enum DesktopCaptureError: Error, CustomStringConvertible {
    case noDisplayAvailable
    case metalTextureCacheCreationFailed(CVReturn)
    case metalTextureCreationFailed(CVReturn)
    case missingMetalTexture

    var description: String {
        switch self {
        case .noDisplayAvailable:
            return "ScreenCaptureKit did not report a captureable display"
        case let .metalTextureCacheCreationFailed(status):
            return "Could not create CVMetalTextureCache (CVReturn \(status))"
        case let .metalTextureCreationFailed(status):
            return "Could not wrap the captured desktop frame as a Metal texture (CVReturn \(status))"
        case .missingMetalTexture:
            return "Core Video created a texture wrapper without an MTLTexture"
        }
    }
}

final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let display: SCDisplay

    private let textureCache: CVMetalTextureCache
    private let outputQueue = DispatchQueue(
        label: "com.niknakk.swiftxrshell.virtual-desktop.capture",
        qos: .userInteractive
    )
    private let lock = NSLock()

    private var stream: SCStream?
    private var retainedCVTexture: CVMetalTexture?
    private var retainedFrame: DesktopCaptureFrame?
    private var retainedError: Error?

    private init(display: SCDisplay, textureCache: CVMetalTextureCache) {
        self.display = display
        self.textureCache = textureCache
        super.init()
    }

    @MainActor
    static func primaryDisplay(device: any MTLDevice) async throws -> DesktopCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard let display = content.displays.first(where: { $0.frame.origin == .zero })
            ?? content.displays.first
        else {
            throw DesktopCaptureError.noDisplayAvailable
        }

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let cache else {
            throw DesktopCaptureError.metalTextureCacheCreationFailed(status)
        }

        return DesktopCapture(display: display, textureCache: cache)
    }

    var pixelSize: CGSize {
        CGSize(width: display.width, height: display.height)
    }

    var displayFrame: CGRect { display.frame }

    func start() async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: outputQueue
        )

        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws {
        guard let stream else { return }
        try await stream.stopCapture()
        self.stream = nil
        clearRetainedState()
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    func latestFrame() throws -> DesktopCaptureFrame? {
        lock.lock()
        defer { lock.unlock() }
        if let retainedError { throw retainedError }
        return retainedFrame
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard
            type == .screen,
            sampleBuffer.isValid,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        do {
            let frame = try makeFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
            lock.lock()
            retainedCVTexture = frame.cvTexture
            retainedFrame = frame.frame
            lock.unlock()
        } catch {
            lock.lock()
            retainedError = error
            lock.unlock()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        retainedError = error
        lock.unlock()
    }

    private func clearRetainedState() {
        lock.lock()
        retainedCVTexture = nil
        retainedFrame = nil
        retainedError = nil
        lock.unlock()
    }

    private func makeFrame(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) throws -> (cvTexture: CVMetalTexture, frame: DesktopCaptureFrame) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?

        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else {
            throw DesktopCaptureError.metalTextureCreationFailed(status)
        }
        guard let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw DesktopCaptureError.missingMetalTexture
        }

        texture.label = "SwiftXR Shell captured macOS desktop"
        return (
            cvTexture,
            DesktopCaptureFrame(
                texture: texture,
                width: width,
                height: height,
                presentationTime: presentationTime
            )
        )
    }
}
