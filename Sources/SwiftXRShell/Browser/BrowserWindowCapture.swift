import CoreMedia
import CoreVideo
import Metal
@preconcurrency import ScreenCaptureKit

/// Captures the full browser window, including tabs and address bar, without desktop occluders.
final class BrowserWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let texture: any MTLTexture
        // Keep both backing objects alive until the consuming GPU work completes.
        let pixelBuffer: CVPixelBuffer
        let cvTexture: CVMetalTexture
    }
    private let cache: CVMetalTextureCache
    private let queue = DispatchQueue(label: "com.niknakk.swiftxrshell.browser.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var frame: Frame?
    private var failure: Error?
    private var stream: SCStream?

    init(window: SCWindow, device: any MTLDevice) throws {
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let cache else {
            throw DesktopCaptureError.metalTextureCacheCreationFailed(result)
        }
        self.cache = cache
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Fixed point-scale capture: resizing changes the input frame mapping,
        // while the stream scales the complete window into this texture.
        config.width = max(Int(window.frame.width), 1)
        config.height = max(Int(window.frame.height), 1)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        config.preservesAspectRatio = false
        super.init()
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws { try await stream?.startCapture() }
    func stop() async { try? await stream?.stopCapture() }

    func latestFrame() throws -> Frame? {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        return frame
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); failure = error; lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, nil,
            .bgra8Unorm, CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel), 0, &cvTexture)
        guard result == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return }
        lock.lock()
        frame = Frame(texture: texture, pixelBuffer: pixel, cvTexture: cvTexture)
        lock.unlock()
    }
}
