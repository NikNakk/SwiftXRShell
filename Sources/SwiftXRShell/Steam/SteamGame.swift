import Foundation

/// One entry of `steam_games.py library --json` (macos-wine-xr, docs/steam-games.md).
struct SteamGame: Decodable, Identifiable, Hashable, Sendable {
    let appID: Int
    let name: String
    let isVR: Bool
    let isInstalled: Bool
    /// `shared` (~/Windows/library) or `rig-prefix`, when installed.
    let library: String?
    let folder: String?
    /// Steam's `library_600x900.jpg`, when macOS Steam has cached it.
    let coverPath: String?
    let heroPath: String?
    let hasNativeMacOSBuild: Bool

    var id: Int { appID }

    private enum CodingKeys: String, CodingKey {
        case appID = "appid"
        case name
        case isVR = "vr"
        case isInstalled = "installed"
        case library
        case folder
        case coverPath = "cover"
        case heroPath = "hero"
        case hasNativeMacOSBuild = "native_macos"
    }

    init(
        appID: Int,
        name: String,
        isVR: Bool = false,
        isInstalled: Bool = false,
        library: String? = nil,
        folder: String? = nil,
        coverPath: String? = nil,
        heroPath: String? = nil,
        hasNativeMacOSBuild: Bool = false
    ) {
        self.appID = appID
        self.name = name
        self.isVR = isVR
        self.isInstalled = isInstalled
        self.library = library
        self.folder = folder
        self.coverPath = coverPath
        self.heroPath = heroPath
        self.hasNativeMacOSBuild = hasNativeMacOSBuild
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appID = try container.decode(Int.self, forKey: .appID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? String(appID)
        isVR = try container.decodeIfPresent(Bool.self, forKey: .isVR) ?? false
        isInstalled = try container.decodeIfPresent(Bool.self, forKey: .isInstalled) ?? false
        library = try container.decodeIfPresent(String.self, forKey: .library)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        coverPath = try container.decodeIfPresent(String.self, forKey: .coverPath)
        heroPath = try container.decodeIfPresent(String.self, forKey: .heroPath)
        hasNativeMacOSBuild = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasNativeMacOSBuild
        ) ?? false
    }

    static func decodeLibrary(_ data: Data) throws -> [SteamGame] {
        try JSONDecoder().decode([SteamGame].self, from: data)
    }
}

/// One line of `steam_games.py install APPID --progress`.
enum SteamInstallEvent: Equatable, Sendable {
    case start(name: String, folder: String)
    /// `state` is SteamCMD's own wording, such as "downloading" or "verifying install".
    case progress(state: String, percent: Double, doneBytes: Int64, totalBytes: Int64)
    case result(succeeded: Bool, message: String)

    /// Returns nil for lines that are not install events (SteamCMD chatter, unknown events).
    static func parse(line: String) -> SteamInstallEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let line = try? JSONDecoder().decode(Line.self, from: Data(trimmed.utf8))
        else { return nil }

        switch line.event {
        case "start":
            return .start(name: line.name ?? String(line.appid ?? 0), folder: line.folder ?? "")
        case "progress":
            return .progress(
                state: line.state ?? "",
                percent: line.percent ?? 0,
                doneBytes: line.done ?? 0,
                totalBytes: line.total ?? 0
            )
        case "result":
            return .result(succeeded: line.result == "ok", message: line.message ?? "")
        default:
            return nil
        }
    }

    private struct Line: Decodable {
        let event: String
        let appid: Int?
        let name: String?
        let folder: String?
        let state: String?
        let percent: Double?
        let done: Int64?
        let total: Int64?
        let result: String?
        let message: String?
    }
}
