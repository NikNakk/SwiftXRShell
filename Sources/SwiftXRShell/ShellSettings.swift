import Foundation

enum ShellOverlayButton: String, Codable, Sendable {
    case home
    case menu
    case options
}

struct ShellSettings: Sendable {
    var systemOverlayButton: ShellOverlayButton = .home
    var steamGames: SteamGamesConfiguration = .default

    private struct Document: Codable {
        var systemOverlayButton: ShellOverlayButton?
        /// macos-wine-xr's tools/steam_games/steam_games.py.
        var steamGamesTool: String?
        /// The rig's run-windows-game.zsh.
        var windowsGameRunner: String?
    }

    static var settingsURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return base
            .appendingPathComponent("SwiftXRShell", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func load() throws -> ShellSettings {
        let url = settingsURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: url.path) {
            let data = try JSONEncoder.prettyPrinted.encode(
                Document(systemOverlayButton: .home)
            )
            try data.write(to: url, options: .atomic)
            return ShellSettings()
        }

        let document = try JSONDecoder().decode(
            Document.self,
            from: Data(contentsOf: url)
        )
        var steamGames = SteamGamesConfiguration.default
        if let path = document.steamGamesTool, !path.isEmpty {
            steamGames.toolURL = expandedFileURL(path)
        }
        if let path = document.windowsGameRunner, !path.isEmpty {
            steamGames.runnerURL = expandedFileURL(path)
        }
        return ShellSettings(
            systemOverlayButton: document.systemOverlayButton ?? .home,
            steamGames: steamGames
        )
    }

    private static func expandedFileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
