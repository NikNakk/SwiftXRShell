import AppKit
import CVizBridge
import CoreVideo
import IOSurface
import Metal

struct VizBrowserMetadata: Sendable {
    var url = "about:blank"
    var title = "Starting Chromium Viz…"
    var frames: UInt64 = 0
    var vrPermission: UInt32 = 0
}

private final class VizMachConnection: @unchecked Sendable {
    let receiver: OpaquePointer
    private let ackQueue = DispatchQueue(label: "com.nickkennedy.swiftxr.viz.acks")
    private let lock = NSLock()
    private var closed = false
    init(service: String) throws {
        var error: Int32 = 0
        guard let receiver = sxr_viz_receiver_create(service, &error) else {
            throw NSError(domain: "SwiftXR.Viz", code: Int(error), userInfo: [NSLocalizedDescriptionKey: "Could not create the Viz Mach endpoint (\(error))"])
        }
        self.receiver = receiver
    }
    deinit { sxr_viz_receiver_destroy(receiver) }
    @discardableResult func send(_ command: SXRVizCommand) -> Bool {
        var command = command
        return sxr_viz_receiver_send(receiver, &command) == 0
    }
    func close() { lock.withLock { closed = true } }
    func acknowledge(_ serial: UInt64) {
        var command = SXRVizCommand()
        command.kind = UInt32(SXR_VIZ_ACK)
        command.serial = serial
        ackQueue.async { [self, command] in deliverAcknowledgement(command) }
    }
    private func deliverAcknowledgement(_ value: SXRVizCommand) {
        guard !lock.withLock({ closed }) else { return }
        var command = value
        let result = sxr_viz_receiver_send(receiver, &command)
        if result == MACH_SEND_TIMED_OUT {
            // A busy Chromium UI thread must not lose a frame-pool credit.
            ackQueue.asyncAfter(deadline: .now() + 0.01) { [self, value] in deliverAcknowledgement(value) }
        }
    }
}

final class VizBrowserFrame: @unchecked Sendable {
    let texture: any MTLTexture
    let surface: IOSurface
    let serial: UInt64
    private let connection: VizMachConnection
    fileprivate init(texture: any MTLTexture, surface: IOSurface, serial: UInt64, connection: VizMachConnection) {
        self.texture = texture; self.surface = surface; self.serial = serial; self.connection = connection
    }
    // Viz may recycle this IOSurface only after the last Shell/GPU reader lets go.
    deinit { connection.acknowledge(serial) }
}

private final class VizFrameStream: @unchecked Sendable {
    let connection: VizMachConnection
    private let device: any MTLDevice
    private let lock = NSLock()
    private var running = true
    private var ready = false
    private var latest: VizBrowserFrame?
    private var metadata = VizBrowserMetadata()
    private var failure: String?
    private let queue = DispatchQueue(label: "com.nickkennedy.swiftxr.viz.frames", qos: .userInteractive)

    init(service: String, device: any MTLDevice) throws {
        connection = try VizMachConnection(service: service)
        self.device = device
    }
    func start(pid: pid_t) {
        sxr_viz_receiver_expect_pid(connection.receiver, pid)
        queue.async { [self] in
            while isRunning {
                autoreleasepool { receive() }
            }
        }
    }
    private var isRunning: Bool { lock.withLock { running } }
    var isReady: Bool { lock.withLock { ready } }
    func stop() { lock.withLock { running = false; latest = nil }; connection.close() }
    func dropFrame() { lock.withLock { latest = nil } }
    func snapshot() -> (VizBrowserFrame?, VizBrowserMetadata, String?) {
        lock.withLock { (latest, metadata, failure) }
    }
    func setFailure(_ message: String) { lock.withLock { failure = message } }

    private func receive() {
        var info = SXRVizFrameInfo()
        var pointer: UnsafeMutableRawPointer?
        let result = sxr_viz_receiver_poll(connection.receiver, 50, &info, &pointer)
        guard result > 0 else {
            if result < 0 { setFailure("Viz IPC receive failed (\(result))") }
            return
        }
        if info.kind == SXR_VIZ_HELLO { lock.withLock { ready = true }; return }
        let url = Self.string(info.url), title = Self.string(info.title)
        if info.kind == SXR_VIZ_ERROR { setFailure(title); return }
        lock.withLock {
            if !url.isEmpty { metadata.url = url }
            if !title.isEmpty { metadata.title = title }
            metadata.vrPermission = info.vr_permission
        }
        guard info.kind == SXR_VIZ_FRAME else { return }
        guard let pointer else { connection.acknowledge(info.serial); setFailure("Could not import Viz's IOSurface"); return }
        let surface = Unmanaged<IOSurface>.fromOpaque(pointer).takeRetainedValue()
        guard info.width == SXR_VIZ_WIDTH, info.height == SXR_VIZ_HEIGHT,
              IOSurfaceGetWidth(surface) == Int(info.width), IOSurfaceGetHeight(surface) == Int(info.height),
              IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32BGRA else {
            connection.acknowledge(info.serial)
            setFailure("Viz returned an unsupported surface size or pixel format")
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: Int(info.width), height: Int(info.height), mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            connection.acknowledge(info.serial); setFailure("Could not open Viz's IOSurface as a Metal texture"); return
        }
        let frame = VizBrowserFrame(texture: texture, surface: surface, serial: info.serial, connection: connection)
        lock.withLock { latest = frame; metadata.frames &+= 1 }
    }
    private static func string<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

@MainActor
final class VizBrowserClient {
    private var process: Process?
    private let profileOverride: URL?
    private let executableOverride: URL?
    private(set) var logURL: URL?
    var processIdentifier: pid_t? { process?.processIdentifier }
    private var stream: VizFrameStream?
    private var wantsPresentation = false
    private var appliedPresentation: Bool?
    private var pendingURL: String?
    private var logHandle: FileHandle?
    private(set) var metadata = VizBrowserMetadata()

    init(profile: URL? = nil, executable: URL? = nil) {
        profileOverride = profile; executableOverride = executable
    }

    func start(device: any MTLDevice) async throws {
        wantsPresentation = true
        if process?.isRunning != true || stream?.snapshot().2 != nil {
            let previous = process
            shutdown()
            for _ in 0..<40 where previous?.isRunning == true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
            if previous?.isRunning == true { throw error("The previous offscreen browser is still stopping. Try Browser (Viz) again shortly.") }
            wantsPresentation = true
            let service = "com.nickkennedy.swiftxr.viz.\(UUID().uuidString)"
            let stream = try VizFrameStream(service: service, device: device)
            let config = BrowserConfiguration()
            let path = ProcessInfo.processInfo.environment["SWIFTXR_VIZ_CHROMIUM_PATH"]
            let executable = executableOverride ?? path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? config.executable
            let binary = executable.pathExtension == "app" ? executable.appendingPathComponent("Contents/MacOS/Chromium") : executable
            guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw BrowserError.chromiumMissing(binary.path) }
            let profile = profileOverride ?? config.profile.deletingLastPathComponent().appendingPathComponent("ChromiumViz", isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let logURL = profile.appendingPathComponent("swiftxr-viz.log")
            self.logURL = logURL
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logHandle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
                "--headless", "--enable-gpu", "--enable-features=OpenXR", "--force-device-scale-factor=1",
                "--window-size=1440,900", "--swiftxr-viz-service=\(service)", "about:blank"]
            process.standardOutput = logHandle
            process.standardError = logHandle
            try process.run()
            self.process = process
            self.stream = stream
            appliedPresentation = nil
            stream.start(pid: process.processIdentifier)
            print("[browser-viz] launched pid \(process.processIdentifier), GPU surface endpoint \(service)")
        }
        for _ in 0..<300 {
            try Task.checkCancellation()
            if process?.isRunning != true { throw error("Offscreen Chromium exited. Check ChromiumViz/swiftxr-viz.log.") }
            synchronizePresentation()
            let (frame, _, failure) = stream?.snapshot() ?? (nil, VizBrowserMetadata(), nil)
            if let failure { throw error(failure) }
            if frame != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        stream?.setFailure("Viz startup timed out")
        throw error("No Viz frames arrived. Build Chromium with scripts/apply-chromium-viz.py and check ChromiumViz/swiftxr-viz.log.")
    }

    func latestFrame() throws -> VizBrowserFrame? {
        synchronizePresentation()
        if process?.isRunning == false { throw error("Offscreen Chromium exited. Reopen Browser (Viz) to retry.") }
        let (frame, metadata, failure) = stream?.snapshot() ?? (nil, VizBrowserMetadata(), nil)
        self.metadata = metadata
        if let failure { throw error(failure) }
        return frame
    }
    func suspend() {
        send(kind: UInt32(SXR_VIZ_CANCEL))
        wantsPresentation = false
        synchronizePresentation()
        stream?.dropFrame()
    }
    func shutdown() {
        stream?.stop()
        stream = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        appliedPresentation = nil
    }
    @discardableResult func navigate(_ input: String) -> Bool {
        guard let value = Self.normalizedURL(input), value.utf8.count < Int(SXR_VIZ_URL_SIZE) else { return false }
        if stream?.isReady == true { send(kind: UInt32(SXR_VIZ_NAVIGATE), text: value) }
        else { pendingURL = value }
        return true
    }
    nonisolated static func normalizedURL(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if !["http://", "https://", "about:", "file:"].contains(where: lower.hasPrefix) {
            guard !value.contains("://") else { return nil }
            let host = lower.split(separator: "/").first.map(String.init) ?? ""
            let local = host == "localhost" || host.hasPrefix("localhost:") ||
                host == "127.0.0.1" || host.hasPrefix("127.0.0.1:") || host.hasPrefix("[::1]")
            value = (local ? "http://" : "https://") + value
        }
        guard let components = URLComponents(string: value), let url = components.url,
              let scheme = components.scheme?.lowercased(), ["http", "https", "about", "file"].contains(scheme),
              scheme == "about" || scheme == "file" || components.host?.isEmpty == false else { return nil }
        return url.absoluteString
    }
    func send(kind: UInt32, uv: SIMD2<Float>? = nil, scroll: SIMD2<Float> = .zero,
              event: NSEvent? = nil, text: String? = nil) {
        guard let stream, stream.isReady else { return }
        var command = SXRVizCommand()
        command.kind = kind
        command.x = Double(uv?.x ?? 0)
        command.y = Double(uv?.y ?? 0)
        command.delta_x = Double(scroll.x)
        command.delta_y = Double(scroll.y)
        command.key_code = UInt32(event?.keyCode ?? 0)
        command.modifiers = UInt32(truncatingIfNeeded: event?.modifierFlags.rawValue ?? 0)
        command.repeat = event?.isARepeat == true ? 1 : 0
        let bytes = Array((text ?? event?.characters ?? "").utf8.prefix(Int(SXR_VIZ_URL_SIZE) - 1))
        withUnsafeMutableBytes(of: &command.text) { destination in
            bytes.withUnsafeBytes { source in destination.copyMemory(from: source) }
        }
        if !stream.connection.send(command) { stream.setFailure("The Viz input connection stopped responding") }
    }
    private func synchronizePresentation() {
        guard stream?.isReady == true else { return }
        if appliedPresentation != wantsPresentation {
            send(kind: UInt32(wantsPresentation ? SXR_VIZ_RESUME : SXR_VIZ_SUSPEND))
            appliedPresentation = wantsPresentation
        }
        if let pendingURL { self.pendingURL = nil; navigate(pendingURL) }
    }
    private func error(_ message: String) -> NSError {
        NSError(domain: "SwiftXR.Viz", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
