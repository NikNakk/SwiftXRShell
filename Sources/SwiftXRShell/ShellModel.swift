import Foundation

@MainActor
enum ShellCommand {
    case launch(ShellApplication)
    case settings
}

struct ShellApplication: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case videoPlayer
        case virtualDesktop
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
}

struct ExternalOpenXRApplication: Hashable, Sendable {
    let executableURL: URL
    var arguments: [String] = []
    var environment: [String: String] = [:]
}

@MainActor
final class ShellModel: ObservableObject {
    @Published private(set) var applications: [ShellApplication] = [
        .videoPlayer,
        .virtualDesktop,
    ]

    var commandHandler: ((ShellCommand) -> Void)?

    func launch(_ application: ShellApplication) {
        commandHandler?(.launch(application))
    }

    func openSettings() {
        commandHandler?(.settings)
    }

    func replaceExternalApplications(_ external: [ShellApplication]) {
        applications = [.videoPlayer, .virtualDesktop] + external
    }
}
