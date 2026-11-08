import AppKit
import Metal
import SwiftUI
import SwiftXR
import Testing
@testable import SwiftXRShell

@Suite("Panel pointer rendering")
@MainActor
struct PanelRefreshTests {
    @Test func cursorMotionDoesNotRasterizeStaticContent() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let panel = try XRSwiftUIPanel(device: device, pointSize: CGSize(width: 128, height: 72)) {
            Text("Panel refresh regression")
        }
        panel.refreshesOnPointerMovement = false
        var refreshes = 0
        for i in 0..<200 {
            panel.interaction.movePointer(to: SIMD2(Float(i) / 200, 0.5))
            if try panel.refreshIfNeeded() { refreshes += 1 }
        }
        #expect(refreshes == 0)
        panel.invalidate()
        #expect(try panel.refreshIfNeeded())
        #expect(try !panel.refreshIfNeeded())
        // Preserve the opt-in hover path for clients with hover-driven visuals.
        panel.refreshesOnPointerMovement = true
        panel.interaction.movePointer(to: SIMD2(0.5, 0.5))
        #expect(try panel.refreshIfNeeded())
    }
}

@Suite("Home panel performance")
@MainActor
struct HomePanelPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTXR_TEST_HOME_PERFORMANCE"] == "1"))
    func measureScrollSnapshotsWithInstalledLibrary() async throws {
        let library = SteamGameLibrary(configuration: .default)
        library.reload()
        let deadline = Date().addingTimeInterval(20)
        while library.loadState == .loading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(library.loadState == .loaded)
        let model = ShellModel(steamLibrary: library)
        model.setExternalApplicationsEnabled(true)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let panel = try XRSwiftUIPanel(device: device, pointSize: CGSize(width: 1280, height: 720), scale: 1) {
            ShellHomeView(model: model)
        }
        panel.usesImmutableTextures = true
        panel.refreshesOnPointerMovement = false
        panel.interaction.movePointer(to: SIMD2(0.5, 0.5))
        var times: [Double] = []
        for _ in 0..<12 {
            panel.interaction.scroll(SIMD2(0, -0.5))
            let start = ProcessInfo.processInfo.systemUptime
            try panel.refresh()
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await Task.sleep(for: .milliseconds(12))
        }
        #expect(panel.texture.width == 1280 && panel.texture.height == 720)
        print(String(format: "[test] Home scroll snapshots: average %.2fms max %.2fms at %dx%d",
                     times.reduce(0, +) / Double(times.count), times.max() ?? 0,
                     panel.texture.width, panel.texture.height))
    }
}
