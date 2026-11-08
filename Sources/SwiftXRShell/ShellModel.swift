import Foundation
import SwiftUI

@MainActor
enum ShellCommand {
    case launch(ShellApplication)
    case stopExternalApplication
    case settings
}

struct ShellApplication: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case videoPlayer
        case virtualDesktop
        case browser
        case browserViz
        case resumeObservedExternal
        case external(ExternalOpenXRApplication)
    }

    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let kind: Kind

    static let videoPlayer = ShellApplication(
        id: "swiftxr.video",
        title: "Video",
        subtitle: "VR180, 360, EAC and flat video",
        systemImage: "play.rectangle.fill",
        kind: .videoPlayer
    )

    static let virtualDesktop = ShellApplication(
        id: "swiftxr.desktop",
        title: "Desktop",
        subtitle: "View and control your Mac",
        systemImage: "desktopcomputer",
        kind: .virtualDesktop
    )

    static let browser = ShellApplication(
        id: "swiftxr.browser",
        title: "Browser",
        subtitle: "Chromium, WebXR and the web",
        systemImage: "globe",
        kind: .browser
    )

    static let browserViz = ShellApplication(
        id: "swiftxr.browser-viz",
        title: "Browser (Viz)",
        subtitle: "Compare offscreen Chromium · GPU surface",
        systemImage: "rectangle.on.rectangle",
        kind: .browserViz
    )

    static func resumeObservedExternal(title: String) -> ShellApplication {
        ShellApplication(
            id: "swiftxr.resume-external",
            title: "Resume \(title)",
            subtitle: "Return to the active immersive OpenXR session",
            systemImage: "play.circle.fill",
            kind: .resumeObservedExternal
        )
    }
}

struct ExternalOpenXRApplication: Hashable, Sendable {
    let executableURL: URL
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var openXRApplicationName: String?
    /// How long to wait for the app's Monado client before giving up.
    var openXRClientTimeout: TimeInterval = 30
    /// How long Stop waits after SIGTERM before SIGKILL.
    var stopGracePeriod: TimeInterval = 2
    /// Keep Home on screen (with Stop) until the app's client takes the HMD,
    /// instead of an empty view for the whole start-up.
    var showsHomeWhileStarting = false
}

/// The external app the launcher is handling, as shown in Home.
struct ShellExternalActivity: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case starting
        case running
        case stopping
    }

    let applicationID: String
    let title: String
    var phase: Phase
}

@MainActor
final class ShellModel: ObservableObject {
    @Published var usesTrackedControllers = false
    @Published var launchError: String?
    @Published private(set) var applications: [ShellApplication] = [
        .videoPlayer,
        .virtualDesktop,
        .browser,
        .browserViz,
    ]
    @Published private(set) var externalApplicationsEnabled = false
    /// The external app being started, running or stopped, if any.
    @Published var externalActivity: ShellExternalActivity?

    /// Windows games from macOS Steam's library (macos-wine-xr's steam_games.py).
    let steamLibrary: SteamGameLibrary

    var commandHandler: ((ShellCommand) -> Void)?

    init(steamLibrary: SteamGameLibrary = SteamGameLibrary(configuration: .default)) {
        self.steamLibrary = steamLibrary
    }

    private var externalApplications: [ShellApplication] = []
    private var resumeApplication: ShellApplication?

    func launch(_ application: ShellApplication) {
        guard isLaunchEnabled(application) else { return }
        launchError = nil
        commandHandler?(.launch(application))
    }

    func isLaunchEnabled(_ application: ShellApplication) -> Bool {
        // Home stays on screen while some apps start; nothing else launches then.
        guard externalActivity == nil else { return false }
        if case .external = application.kind {
            return externalApplicationsEnabled
        }
        return true
    }

    func launch(_ game: SteamGame) {
        guard game.isInstalled else { return }
        launch(steamLibrary.configuration.application(for: game))
    }

    func stopExternalApplication() {
        commandHandler?(.stopExternalApplication)
    }

    func externalActivity(for game: SteamGame) -> ShellExternalActivity? {
        guard let externalActivity,
              externalActivity.applicationID == steamLibrary.configuration
              .application(for: game).id
        else { return nil }
        return externalActivity
    }

    func setExternalApplicationsEnabled(_ enabled: Bool) {
        externalApplicationsEnabled = enabled
    }

    func openSettings() {
        commandHandler?(.settings)
    }

    func replaceExternalApplications(_ external: [ShellApplication]) {
        externalApplications = external
        rebuildApplications()
    }

    func showResumeObservedExternal(title: String) {
        resumeApplication = .resumeObservedExternal(title: title)
        rebuildApplications()
    }

    func clearResumeObservedExternal() {
        guard resumeApplication != nil else { return }
        resumeApplication = nil
        rebuildApplications()
    }

    private func rebuildApplications() {
        var result: [ShellApplication] = []
        if let resumeApplication {
            result.append(resumeApplication)
        }
        result.append(.videoPlayer)
        result.append(.virtualDesktop)
        result.append(.browser)
        result.append(.browserViz)
        result.append(contentsOf: externalApplications)
        applications = result
    }
}
