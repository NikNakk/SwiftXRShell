import AppKit

struct ShellCompanionStatus: Equatable {
    var foreground: String
    var detail: String
    var runtime: String
    var input: String
    var canGoHome: Bool
    var canSwitchModes: Bool
    var canStopApp: Bool
    var mouseCaptureEnabled: Bool
    var canRetryConnection = false
}

@MainActor
final class ShellCompanionWindow: NSWindowController, NSMenuItemValidation {
    enum Action: Int { case home, video, desktop, recenter, stopApp, toggleMouse, showWindow, retryConnection, browser }
    var onAction: ((Action) -> Void)?
    private let foregroundLabel = NSTextField(labelWithString: "Starting…")
    private let detailLabel = NSTextField(labelWithString: "SwiftXR Shell")
    private let runtimeLabel = NSTextField(labelWithString: "")
    private let inputLabel = NSTextField(labelWithString: "")
    private let mouseButton = NSButton(title: "Release Mouse", target: nil, action: nil)
    private var status: ShellCompanionStatus?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SwiftXR Shell"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SwiftXRShellStatus")
        window.center()
        super.init(window: window)
        foregroundLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 14)
        runtimeLabel.font = .systemFont(ofSize: 11)
        runtimeLabel.textColor = .secondaryLabelColor
        inputLabel.font = .systemFont(ofSize: 11)
        inputLabel.textColor = .secondaryLabelColor
        for label in [foregroundLabel, detailLabel, runtimeLabel, inputLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        let heading = NSTextField(labelWithString: "FOREGROUND VR APP / MODE")
        heading.font = .systemFont(ofSize: 10, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        mouseButton.target = self
        mouseButton.action = #selector(toggleMouse)
        mouseButton.bezelStyle = .rounded
        let stack = NSStackView(views: [heading, foregroundLabel, detailLabel, runtimeLabel, inputLabel, mouseButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ next: ShellCompanionStatus) {
        guard next != status else { return }
        status = next
        foregroundLabel.stringValue = next.foreground
        detailLabel.stringValue = next.detail
        detailLabel.toolTip = next.detail
        runtimeLabel.stringValue = next.runtime
        runtimeLabel.toolTip = next.runtime
        inputLabel.stringValue = next.input
        mouseButton.title = next.mouseCaptureEnabled ? "Release Mouse (⇧⌘M)" : "Capture Mouse (⇧⌘M)"
    }

    func installMenus() {
        let main = NSMenu()
        let app = NSMenu(title: "SwiftXR Shell")
        app.addItem(withTitle: "About SwiftXR Shell", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide SwiftXR Shell", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let quit = app.addItem(withTitle: "Quit SwiftXR Shell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        add(app, to: main)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)
        let mode = NSMenu(title: "Mode")
        item("Connect / Retry Headset", action: .retryConnection, key: "k", in: mode)
        mode.addItem(.separator())
        item("Home", action: .home, key: "1", in: mode)
        item("Video", action: .video, key: "2", in: mode)
        item("Desktop", action: .desktop, key: "3", in: mode)
        item("Browser", action: .browser, key: "4", in: mode)
        mode.addItem(.separator())
        item("Recenter Shell", action: .recenter, key: "r", in: mode)
        item("Stop Launched VR App", action: .stopApp, key: "", in: mode)
        add(mode, to: main)
        let input = NSMenu(title: "Input")
        let capture = item("Capture Mouse in Headset", action: .toggleMouse, key: "m", in: input)
        capture.keyEquivalentModifierMask = [.command, .shift]
        add(input, to: main)
        let windows = NSMenu(title: "Window")
        item("Show Status Window", action: .showWindow, key: "0", in: windows)
        let minimize = windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        minimize.target = window
        add(windows, to: main)
        NSApplication.shared.windowsMenu = windows
        NSApplication.shared.mainMenu = main
    }

    private func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    @discardableResult
    private func item(_ title: String, action: Action, key: String, in menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: #selector(performMenuAction(_:)), keyEquivalent: key)
        item.target = self; item.tag = action.rawValue
        return item
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let action = Action(rawValue: sender.tag) else { return }
        if action == .showWindow { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
        else { onAction?(action) }
    }

    @objc private func toggleMouse() { onAction?(.toggleMouse) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = Action(rawValue: item.tag) else { return true }
        switch action {
        case .home: return status?.canGoHome == true
        case .video, .desktop, .browser: return status?.canSwitchModes == true
        case .stopApp: return status?.canStopApp == true
        case .toggleMouse:
            item.state = status?.mouseCaptureEnabled == true ? .on : .off
            return true
        case .recenter, .showWindow: return true
        case .retryConnection: return status?.canRetryConnection == true
        }
    }
}
