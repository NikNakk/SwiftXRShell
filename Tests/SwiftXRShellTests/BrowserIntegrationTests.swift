import AppKit
import ApplicationServices
import Metal
@preconcurrency import ScreenCaptureKit
import Testing
@testable import SwiftXRShell

/// Optional desktop-only acceptance tests. These never create an OpenXR session.
@Suite("Chromium window acceptance", .serialized)
@MainActor
struct BrowserIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTXR_TEST_BROWSER"] == "1"))
    func capturesWindowWhenCovered() async throws {
        try await withBrowser { window, capture, device, _ in
            let before = try pixel(capture: capture, device: device)
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let cover = NSWindow(contentRect: NSRect(x: window.frame.minX, y: top - window.frame.maxY,
                width: window.frame.width, height: window.frame.height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            cover.backgroundColor = .red
            cover.level = .floating
            cover.orderFrontRegardless()
            defer { cover.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(300))
            let after = try pixel(capture: capture, device: device)
            #expect(zip(before, after).allSatisfy { abs(Int($0) - Int($1)) <= 3 })
            #expect(before[0] > before[2]) // BGRA blue fixture, not a black/empty stream.
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTXR_TEST_BROWSER"] == "1"))
    func nativeClickProvidesUserActivationAndTextFocus() async throws {
        try #require(AXIsProcessTrusted(), "Grant Accessibility to the test runner first")
        try await withBrowser { window, _, _, pid in
            let input = BrowserPointerInput(pid: pid, windowID: window.windowID, frame: window.frame)
            input.focus()
            try await Task.sleep(for: .milliseconds(250))
            @MainActor func click(x: Float, y: Float) {
                input.handle(.pointerMoved(to: SIMD2(x / Float(window.frame.width - 1), y / Float(window.frame.height - 1))))
                input.handle(.pointerDown(.primary))
                input.handle(.pointerUp(.primary))
            }
            click(x: 180, y: 130)
            _ = try await waitForWindow(pid: pid, title: "click:true:true")
            click(x: 180, y: 350)
            let text = Array("SwiftXR".utf16)
            for down in [true, false] {
                let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down))
                text.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress!) }
                event.postToPid(pid)
            }
            _ = try await waitForWindow(pid: pid, title: "text:true:SwiftXR")
        }
    }

    private func withBrowser(_ body: @MainActor (SCWindow, BrowserWindowCapture, any MTLDevice, pid_t) async throws -> Void) async throws {
        try #require(CGPreflightScreenCaptureAccess(), "Grant Screen Recording to the test runner first")
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swiftxr-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("input.html")
        try """
        <!doctype html><title>SwiftXR input fixture</title>
        <style>body { background:#123456; margin:0 }
        button { position:absolute;left:60px;top:60px;width:240px;height:120px }
        textarea { position:absolute;left:60px;top:260px;width:240px;height:120px }</style>
        <button id="button">Test trusted activation</button><textarea id="text"></textarea>
        <script>
        button.addEventListener('click', e => document.title = 'click:' + e.isTrusted + ':' + navigator.userActivation.isActive);
        text.addEventListener('input', e => document.title = 'text:' + e.isTrusted + ':' + text.value);
        </script>
        """.write(to: page, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = BrowserConfiguration().executable
        process.arguments = ["--user-data-dir=\(root.appendingPathComponent("profile").path)",
            "--no-first-run", "--no-default-browser-check", "--enable-features=OpenXR",
            "--window-size=900,700", "--app=\(page.absoluteString)"]
        let log = root.appendingPathComponent("chromium.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logFile = try FileHandle(forWritingTo: log)
        process.standardOutput = logFile
        process.standardError = logFile
        let previousApp = NSWorkspace.shared.frontmostApplication
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            previousApp?.activate(options: [])
            try? logFile.close()
        }
        let window = try await waitForWindow(pid: process.processIdentifier, title: "SwiftXR input fixture")
        // A fresh manager has no Process object, as after a Shell restart. It
        // must reattach through this profile's Chromium lock, not open a tab.
        let browser = BrowserApplication(configuration: BrowserConfiguration(
            executable: BrowserConfiguration().executable, profile: root.appendingPathComponent("profile")))
        let reattached = try await browser.window()
        #expect(reattached.windowID == window.windowID)
        let repeated = try await browser.window()
        #expect(repeated.windowID == window.windowID)
        let capture = try BrowserWindowCapture(window: window, device: device)
        try await capture.start()
        do {
            for _ in 0..<100 {
                if try capture.latestFrame() != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await body(window, capture, device, process.processIdentifier)
            await capture.stop()
        } catch {
            await capture.stop()
            throw error
        }
    }

    private func waitForWindow(pid: pid_t, title: String) async throws -> SCWindow {
        for _ in 0..<100 {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            if let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.title == title }) {
                return window
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "BrowserAcceptance", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Chromium did not report expected title: \(title)"])
    }

    private func pixel(capture: BrowserWindowCapture, device: any MTLDevice) throws -> [UInt8] {
        let frame = try #require(try capture.latestFrame())
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let buffer = try #require(device.makeBuffer(length: 256, options: .storageModeShared))
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: frame.texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: frame.texture.width * 3 / 4, y: frame.texture.height * 3 / 4, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: 4))
    }
}
