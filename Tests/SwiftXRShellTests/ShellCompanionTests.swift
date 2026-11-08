import AppKit
import Testing
@testable import SwiftXRShell

@Suite("Desktop companion", .serialized)
@MainActor
struct ShellCompanionTests {
    @Test func standardQuitShortcutAndModeValidation() throws {
        let controller = ShellCompanionWindow()
        let oldMain = NSApp.mainMenu
        let oldWindows = NSApp.windowsMenu
        defer { NSApp.mainMenu = oldMain; NSApp.windowsMenu = oldWindows }
        controller.installMenus()
        controller.update(ShellCompanionStatus(foreground: "Audio Trip", detail: "External OpenXR application",
            runtime: "Monado", input: "Sense / tracked controllers", canGoHome: false,
            canSwitchModes: false, canStopApp: true, mouseCaptureEnabled: false))
        let main = try #require(NSApp.mainMenu)
        let app = try #require(main.items.first?.submenu)
        let quit = try #require(app.items.first { $0.keyEquivalent == "q" })
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
        #expect(quit.target === NSApplication.shared)
        #expect(quit.keyEquivalentModifierMask.contains(.command))
        let modes = try #require(main.items.first { $0.title == "Mode" }?.submenu)
        #expect(!controller.validateMenuItem(try #require(modes.items.first { $0.title == "Video" })))
        #expect(controller.validateMenuItem(try #require(modes.items.first { $0.title == "Stop Launched VR App" })))
        let input = try #require(main.items.first { $0.title == "Input" }?.submenu?.items.first)
        #expect(controller.validateMenuItem(input))
        #expect(input.state == .off)
        let window = try #require(controller.window)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let fields = (content.subviews.first as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSTextField } ?? []
        #expect(fields.contains { $0.stringValue == "Audio Trip" })
        #expect(fields.allSatisfy { $0.frame.maxX <= content.bounds.width })
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/swiftxr-companion-window.png"))
        controller.update(ShellCompanionStatus(foreground: "Headset unavailable", detail: "Retry connection",
            runtime: "OpenXR disconnected", input: "Desktop mouse released", canGoHome: false,
            canSwitchModes: false, canStopApp: false, mouseCaptureEnabled: false, canRetryConnection: true))
        let retry = try #require(modes.items.first { $0.keyEquivalent == "k" })
        #expect(controller.validateMenuItem(retry))
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
    }
}
