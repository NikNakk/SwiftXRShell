import AppKit
import Metal
import Testing
@testable import SwiftXRShell

@Suite("Viz IOSurface transport", .serialized)
@MainActor
struct VizTransportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTXR_TEST_VIZ_TRANSPORT"] == "1"))
    func machTransferKeepsSurfaceUntilLastGPUReaderReleasesIt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swiftxr-viz-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent("producer")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = ["-fobjc-arc", "-framework", "Foundation", "-framework", "IOSurface",
            "-I", repo.appendingPathComponent("Sources/CVizBridge/include").path,
            repo.appendingPathComponent("Tools/ChromiumViz/protocol_fixture.m").path, "-o", helper.path]
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let client = VizBrowserClient(profile: root.appendingPathComponent("profile"), executable: helper)
        defer { client.shutdown() }
        try await client.start(device: device)
        // Wait for the last of the three exported surfaces.
        for _ in 0..<100 {
            if try client.latestFrame()?.serial == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        var held = try client.latestFrame()
        try #require(held?.serial == 3)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let buffer = try #require(device.makeBuffer(length: 256, options: .storageModeShared))
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: try #require(held?.texture), sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 1,y: 1,z: 0), sourceSize: MTLSize(width: 1,height: 1,depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        blit.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        #expect(bytes[0] == 0x56 && bytes[1] == 0x34 && bytes[2] == 0x12)
        client.suspend() // Releases the client's cache, but not the GPU reader.
        try await Task.sleep(for: .milliseconds(100))
        let log = try #require(client.logURL)
        let before = try String(contentsOf: log, encoding: .utf8)
        #expect(!before.contains("ACK 3"))
        held = nil
        for _ in 0..<100 {
            if (try String(contentsOf: log, encoding: .utf8)).contains("ACK 3") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = try String(contentsOf: log, encoding: .utf8)
        #expect(after.contains("ACK 1") && after.contains("ACK 2") && after.contains("ACK 3"))
    }
}
