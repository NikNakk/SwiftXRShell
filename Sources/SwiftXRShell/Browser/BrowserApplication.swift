import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

enum BrowserError: Error, LocalizedError {
    case chromiumMissing(String)
    case noWindow
    case screenRecordingDenied
    case accessibilityDenied
    case windowClosed

    var errorDescription: String? {
        switch self {
        case let .chromiumMissing(path):
            return "Chromium was not found at \(path). Set SWIFTXR_CHROMIUM_PATH to our Chromium.app or executable."
        case .noWindow: return "Chromium did not open a captureable window. Check its desktop window and try Browser again."
        case .screenRecordingDenied: return "Allow Screen Recording for SwiftXR Shell in System Settings, then restart the Shell."
        case .accessibilityDenied: return "Allow Accessibility for SwiftXR Shell in System Settings to use Sense input in Chromium. A physical mouse and keyboard still work."
        case .windowClosed: return "The Chromium window is closed or minimised. Open Browser again to create a visible window."
        }
    }
}

struct BrowserConfiguration {
    let executable: URL
    let profile: URL

    init(executable: URL, profile: URL) {
        self.executable = executable
        self.profile = profile
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let path = environment["SWIFTXR_CHROMIUM_PATH"]
            ?? home.appendingPathComponent("Code/chromium/src/out/mac-webxr/Chromium.app").path
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        executable = url.pathExtension == "app"
            ? url.appendingPathComponent("Contents/MacOS/Chromium") : url
        profile = home.appendingPathComponent("Library/Application Support/SwiftXRShell/Chromium", isDirectory: true)
    }

    var arguments: [String] {
        ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
         "--enable-features=OpenXR", "--window-size=1440,900", "--new-window", "about:blank"]
    }
}

/// Owns only the dedicated browser process/profile, never the user's other Chromium windows.
/// The process intentionally survives leaving Browser and quitting the Shell.
@MainActor
final class BrowserApplication {
    let configuration: BrowserConfiguration
    private var process: Process?
    private var windowID: CGWindowID?

    init(configuration: BrowserConfiguration = BrowserConfiguration()) {
        self.configuration = configuration
    }

    func window() async throws -> SCWindow {
        if let pid = runningPID() {
            let windows = try await availableWindows(pid: pid)
            if let window = choose(windows) { return window }
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path) else {
            throw BrowserError.chromiumMissing(configuration.executable.path)
        }
        try FileManager.default.createDirectory(at: configuration.profile, withIntermediateDirectories: true)
        let opener = Process()
        opener.executableURL = configuration.executable
        opener.arguments = configuration.arguments
        // Inherit XR_RUNTIME_JSON and runtime/IPC environment from the Shell.
        try opener.run()
        if process?.isRunning != true { process = opener }
        for _ in 0..<100 {
            try Task.checkCancellation()
            if let pid = runningPID(), let window = choose(try await availableWindows(pid: pid)) { return window }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw BrowserError.noWindow
    }

    /// Chromium's POSIX profile lock identifies the browser that survived a
    /// Shell restart. Validate the executable before reattaching to its window.
    private func runningPID() -> pid_t? {
        if let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: configuration.profile.appendingPathComponent("SingletonLock").path),
           let suffix = destination.split(separator: "-").last, let pid = pid_t(suffix), pid > 0,
           let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
           app.executableURL?.resolvingSymlinksInPath() == configuration.executable.resolvingSymlinksInPath() {
            return pid
        }
        if let process, process.isRunning { return process.processIdentifier }
        return nil
    }

    private func availableWindows(pid: pid_t) async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0
                && $0.isOnScreen && $0.frame.width > 300 && $0.frame.height > 200
        }
    }

    private func choose(_ windows: [SCWindow]) -> SCWindow? {
        let window = windows.first { $0.windowID == windowID }
            ?? windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        windowID = window?.windowID
        return window
    }
}
