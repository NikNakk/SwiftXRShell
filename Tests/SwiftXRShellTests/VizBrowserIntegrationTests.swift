import AppKit
import CVizBridge
import Metal
@preconcurrency import Network
import Testing
@testable import SwiftXRShell

/// Real Chromium/Viz acceptance, independent of Screen Recording,
/// Accessibility and OpenXR hardware. Uses a disposable browser profile.
@Suite("Offscreen Chromium acceptance", .serialized)
@MainActor
struct VizBrowserIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTXR_TEST_VIZ"] == "1"))
    func gpuFramesTrustedInputKeyboardAndResumeWithoutDesktopWindow() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swiftxr-viz-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("fixture.html")
        try """
        <!doctype html><title>Loading fixture</title>
        <style>body{margin:0;background:#123456;height:3000px}
        .corner{position:fixed;width:60px;height:60px;pointer-events:none}
        button{position:absolute;left:120px;top:120px;width:240px;height:80px}
        textarea{position:absolute;left:120px;top:280px;width:240px;height:80px}</style>
        <div class="corner" style="left:0;top:0;background:red"></div>
        <div class="corner" style="right:0;top:0;background:lime"></div>
        <div class="corner" style="left:0;bottom:0;background:blue"></div>
        <button id="button">Click</button><textarea id="text"></textarea>
        <script>
        const loads=Number(sessionStorage.getItem('loads')||0)+1; sessionStorage.setItem('loads',loads);
        document.title='loaded:'+innerWidth+'x'+innerHeight+':'+loads;
        button.addEventListener('click',e=>document.title='click:'+e.isTrusted+':'+navigator.userActivation.isActive+':'+document.hasFocus()+':'+document.visibilityState);
        text.addEventListener('input',e=>document.title='typed:'+e.isTrusted+':'+text.value);
        window.addEventListener('scroll',()=>document.title='scroll:'+Math.round(scrollY));
        </script>
        """.write(to: page, atomically: true, encoding: .utf8)
        let server = try VizHTTPFixture(body: Data(contentsOf: page))
        let pageURL = try await server.start()
        defer { server.stop() }
        let client = VizBrowserClient(profile: root.appendingPathComponent("profile"))
        defer { client.shutdown() }
        do {
            try await client.start(device: device)
            client.navigate(pageURL.absoluteString)
            try await wait(client, title: "loaded:1440x900:1")
            #expect(client.metadata.vrPermission == 0)
            // A stale/different origin must never receive consent.
            let otherOrigin = pageURL.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost")
            client.send(kind: UInt32(SXR_VIZ_ALLOW_VR), text: otherOrigin)
            try await Task.sleep(for: .milliseconds(150))
            _ = try client.latestFrame()
            #expect(client.metadata.vrPermission == 0)
            client.send(kind: UInt32(SXR_VIZ_ALLOW_VR), text: client.metadata.url)
            try await wait(client, title: "loaded:1440x900:2")
            #expect(client.metadata.vrPermission == 1)
            // Navigation/title IPC may arrive before the first painted frame.
            var painted: VizBrowserFrame?
            for _ in 0..<200 {
                if let candidate = try client.latestFrame() {
                    let red = try pixel(candidate, device: device, x: 20, y: 20)
                    let green = try pixel(candidate, device: device, x: 1420, y: 20)
                    let blue = try pixel(candidate, device: device, x: 20, y: 880)
                    if red[2] > 220 && red[0] < 30 && green[1] > 220 && green[2] < 30 && blue[0] > 220 && blue[2] < 30 {
                        painted = candidate; break
                    }
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            let frame = try #require(painted, "The offscreen page must paint the three coloured orientation markers")
            #expect(frame.texture.width == 1440 && frame.texture.height == 900)
            let pid = try #require(client.processIdentifier)
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            #expect(!windows.contains { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) &&
                ($0[kCGWindowLayer as String] as? Int) == 0 })
            click(client, x: 200, y: 160)
            try await wait(client, title: "click:true:true:true:visible")
            click(client, x: 200, y: 320)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
            client.send(kind: UInt32(SXR_VIZ_KEY_DOWN), event: event)
            let up = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
            client.send(kind: UInt32(SXR_VIZ_KEY_UP), event: up)
            try await wait(client, title: "typed:true:q")
            let serial = try client.latestFrame()?.serial
            client.suspend()
            try await Task.sleep(for: .milliseconds(250))
            try await client.start(device: device)
            for _ in 0..<200 {
                if try client.latestFrame()?.serial != serial { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(try client.latestFrame()?.serial != serial)
            client.send(kind: UInt32(SXR_VIZ_SCROLL), uv: SIMD2(0.8, 0.7), scroll: SIMD2(0, -180))
            for _ in 0..<200 {
                _ = try client.latestFrame()
                if client.metadata.title.hasPrefix("scroll:") { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(client.metadata.title.hasPrefix("scroll:"))
            #expect(client.metadata.title != "scroll:0")
        } catch {
            if let log = client.logURL, let contents = try? String(contentsOf: log, encoding: .utf8) {
                print("[viz-test] Chromium log tail:\n" + String(contents.suffix(5000)))
            }
            throw error
        }
    }
    private func click(_ client: VizBrowserClient, x: Float, y: Float) {
        let uv = SIMD2(x / 1440, y / 900)
        client.send(kind: UInt32(SXR_VIZ_MOVE), uv: uv)
        client.send(kind: UInt32(SXR_VIZ_DOWN), uv: uv)
        client.send(kind: UInt32(SXR_VIZ_UP), uv: uv)
    }
    private func wait(_ client: VizBrowserClient, title: String) async throws {
        for _ in 0..<200 {
            _ = try client.latestFrame()
            if client.metadata.title == title { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "VizAcceptance", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Expected title '\(title)', got '\(client.metadata.title)'"])
    }
    private func pixel(_ frame: VizBrowserFrame, device: any MTLDevice, x: Int, y: Int) throws -> [UInt8] {
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let buffer = try #require(device.makeBuffer(length: 256, options: .storageModeShared))
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: frame.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: 4))
    }
}

private final class VizHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "swiftxr.viz.http-fixture")
    private let body: Data
    private let lock = NSLock()
    private var finished = false

    init(body: Data) throws {
        self.body = body
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, request: Data())
        }
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                let result: Result<URL, Error>
                switch state {
                case .ready:
                    guard let port = listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else { return }
                    result = .success(url)
                case let .failed(error): result = .failure(error)
                default: return
                }
                let shouldFinish = lock.withLock { if finished { return false }; finished = true; return true }
                if shouldFinish { continuation.resume(with: result) }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); listener.stateUpdateHandler = nil }
    private func receive(_ connection: NWConnection, request: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            var request = request
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() })
            } else if !complete && error == nil && request.count < 8192 { receive(connection, request: request) }
            else { connection.cancel() }
        }
    }
}
