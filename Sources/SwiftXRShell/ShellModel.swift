import Foundation
import SwiftUI

@MainActor
enum ShellCommand {
    case launch(ShellApplication)
    case settings
}

struct ShellApplication: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case videoPlayer
        case virtualDesktop
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
}

@MainActor
final class ShellModel: ObservableObject {
    @Published private(set) var applications: [ShellApplication] = [
        .videoPlayer,
        .virtualDesktop,
    ]

    var commandHandler: ((ShellCommand) -> Void)?

    private var externalApplications: [ShellApplication] = []
    private var resumeApplication: ShellApplication?

    func launch(_ application: ShellApplication) {
        commandHandler?(.launch(application))
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
        result.append(contentsOf: externalApplications)
        applications = result
    }
}
