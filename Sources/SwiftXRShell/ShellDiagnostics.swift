import Darwin
import Foundation
import QuartzCore

/// Low-rate local diagnostics: distinguish missed app deadlines, expensive UI
/// updates and runtime waits without logging one line per XR frame.
@MainActor
final class ShellDiagnostics {
    static let shared = ShellDiagnostics()
    private var windowStart = CACurrentMediaTime()
    private var lastFrame: Double?
    private var frameCount = 0
    private var longestGap = 0.0
    private var longestFrame = 0.0
    private var panelUpdates = 0
    private var panelTotal = 0.0
    private var panelMax = 0.0

    func startLogging() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SwiftXRShell")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent("shell.log").path
            // Bound the log between launches. Each frame window emits one line
            // per two seconds, rather than adding to the runtime's verbose log.
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber,
               size.intValue > 4_000_000 {
                try? FileManager.default.removeItem(atPath: folder.appendingPathComponent("shell-previous.log").path)
                try? FileManager.default.moveItem(atPath: path, toPath: folder.appendingPathComponent("shell-previous.log").path)
            }
            freopen(path, "a", stdout)
            freopen(path, "a", stderr)
            setbuf(stdout, nil)
            setbuf(stderr, nil)
            print("\n[shell] launch \(Date()) pid=\(ProcessInfo.processInfo.processIdentifier)")
        } catch {
            print("[shell] could not open diagnostics log: \(error)")
        }
    }

    func recordPanelUpdate(seconds: Double, refreshed: Bool) {
        guard refreshed else { return }
        panelUpdates += 1
        panelTotal += seconds
        panelMax = max(panelMax, seconds)
    }

    func recordFrame(mode: String, startedAt: Double) {
        let now = CACurrentMediaTime()
        if let lastFrame { longestGap = max(longestGap, now - lastFrame) }
        lastFrame = now
        frameCount += 1
        longestFrame = max(longestFrame, now - startedAt)
        let elapsed = now - windowStart
        guard elapsed >= 2 else { return }
        print(String(format:
            "[timing] %@ %.1f frames/s maxGap=%.1fms frameWithWaitMax=%.1fms UIupdates=%d UIavg=%.2fms UImax=%.2fms",
            mode, Double(frameCount) / elapsed, longestGap * 1000, longestFrame * 1000,
            panelUpdates, panelUpdates == 0 ? 0 : panelTotal * 1000 / Double(panelUpdates), panelMax * 1000))
        windowStart = now
        frameCount = 0; longestGap = 0; longestFrame = 0
        panelUpdates = 0; panelTotal = 0; panelMax = 0
    }
}
