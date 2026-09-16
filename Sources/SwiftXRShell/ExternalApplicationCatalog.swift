import Foundation

struct ExternalApplicationCatalogEntry: Codable, Sendable {
    let id: String
    let title: String
    var subtitle: String?
    var systemImage: String?
    let path: String
    var arguments: [String]?
    var environment: [String: String]?
    var openXRApplicationName: String?
}

enum ExternalApplicationCatalogError: Error, LocalizedError {
    case duplicateID(String)
    case emptyID
    case emptyTitle(String)
    case emptyPath(String)

    var errorDescription: String? {
        switch self {
        case let .duplicateID(id):
            return "External application catalog contains duplicate id '\(id)'"
        case .emptyID:
            return "External application catalog contains an empty id"
        case let .emptyTitle(id):
            return "External application '\(id)' has an empty title"
        case let .emptyPath(id):
            return "External application '\(id)' has an empty path"
        }
    }
}

enum ExternalApplicationCatalog {
    static var catalogURL: URL {
        if let override = ProcessInfo.processInfo.environment["SWIFTXR_SHELL_APPS"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }

        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return base
            .appendingPathComponent("SwiftXRShell", isDirectory: true)
            .appendingPathComponent("apps.json", isDirectory: false)
    }

    static func loadApplications() throws -> [ShellApplication] {
        let url = catalogURL
        try createEmptyCatalogIfNeeded(at: url)

        let data = try Data(contentsOf: url)
        let entries = try JSONDecoder().decode([ExternalApplicationCatalogEntry].self, from: data)

        var seenIDs = Set<String>()
        return try entries.map { entry in
            let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw ExternalApplicationCatalogError.emptyID
            }
            guard seenIDs.insert(id).inserted else {
                throw ExternalApplicationCatalogError.duplicateID(id)
            }

            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw ExternalApplicationCatalogError.emptyTitle(id)
            }

            let path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw ExternalApplicationCatalogError.emptyPath(id)
            }

            let executableURL = URL(
                fileURLWithPath: (path as NSString).expandingTildeInPath
            ).standardizedFileURL

            return ShellApplication(
                id: id,
                title: title,
                subtitle: entry.subtitle ?? "OpenXR application",
                systemImage: entry.systemImage ?? "arkit",
                kind: .external(
                    ExternalOpenXRApplication(
                        executableURL: executableURL,
                        arguments: entry.arguments ?? [],
                        environment: entry.environment ?? [:],
                        openXRApplicationName: entry.openXRApplicationName
                    )
                )
            )
        }
    }

    private static func createEmptyCatalogIfNeeded(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("[]\n".utf8).write(to: url, options: .atomic)
        print("[shell] created external app catalog at \(url.path)")
    }
}
