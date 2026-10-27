import Foundation
import Testing
@testable import SwiftXRShell

@Suite("steam_games.py library --json")
struct SteamLibraryDecodingTests {
    @Test func decodesInstalledAndNotInstalledGames() throws {
        // Shape as printed by steam_games.py library --all --json (2026-10-27).
        let json = """
        [
         {
          "appid": 244210,
          "name": "Assetto Corsa",
          "vr": true,
          "installed": true,
          "library": "rig-prefix",
          "folder": "/Users/me/Windows/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/assettocorsa",
          "cover": "/Users/me/Library/Application Support/Steam/appcache/librarycache/244210/library_600x900.jpg",
          "hero": "/Users/me/Library/Application Support/Steam/appcache/librarycache/244210/library_hero.jpg",
          "native_macos": false
         },
         {
          "appid": 2667980,
          "name": "Genotype",
          "vr": true,
          "installed": false,
          "library": null,
          "folder": null,
          "cover": null,
          "hero": "/Users/me/Library/Application Support/Steam/appcache/librarycache/2667980/library_hero.jpg",
          "native_macos": true
         }
        ]
        """

        let games = try SteamGame.decodeLibrary(Data(json.utf8))
        #expect(games.count == 2)

        let corsa = games[0]
        #expect(corsa.appID == 244210)
        #expect(corsa.id == 244210)
        #expect(corsa.name == "Assetto Corsa")
        #expect(corsa.isVR)
        #expect(corsa.isInstalled)
        #expect(corsa.library == "rig-prefix")
        #expect(corsa.folder?.hasSuffix("common/assettocorsa") == true)
        #expect(corsa.coverPath?.hasSuffix("244210/library_600x900.jpg") == true)
        #expect(!corsa.hasNativeMacOSBuild)

        let genotype = games[1]
        #expect(!genotype.isInstalled)
        #expect(genotype.library == nil)
        #expect(genotype.folder == nil)
        #expect(genotype.coverPath == nil)
        #expect(genotype.heroPath != nil)
        #expect(genotype.hasNativeMacOSBuild)
    }

    @Test func toleratesMissingOptionalFields() throws {
        let games = try SteamGame.decodeLibrary(Data(#"[{"appid": 620}]"#.utf8))
        #expect(games == [SteamGame(appID: 620, name: "620")])
    }

    @Test func decodesEmptyLibrary() throws {
        #expect(try SteamGame.decodeLibrary(Data("[]\n".utf8)).isEmpty)
    }

    @Test func rejectsEntryWithoutAppID() {
        #expect(throws: DecodingError.self) {
            try SteamGame.decodeLibrary(Data(#"[{"name": "No ID"}]"#.utf8))
        }
    }

    @Test func rejectsNonArray() {
        #expect(throws: DecodingError.self) {
            try SteamGame.decodeLibrary(Data(#"{"appid": 1}"#.utf8))
        }
    }
}

@Suite("steam_games.py install --progress")
struct SteamInstallEventDecodingTests {
    @Test func decodesStart() {
        let line = #"{"appid": 1256230, "event": "start", "name": "Hyperbolica", "folder": "/Users/me/Windows/library/steamapps/common/Hyperbolica"}"#
        #expect(
            SteamInstallEvent.parse(line: line)
                == .start(name: "Hyperbolica", folder: "/Users/me/Windows/library/steamapps/common/Hyperbolica")
        )
    }

    @Test func decodesProgress() {
        let line = #"{"appid": 1256230, "event": "progress", "state": "downloading", "percent": 42.17, "done": 1234567890, "total": 5000000000}"#
        #expect(
            SteamInstallEvent.parse(line: line)
                == .progress(state: "downloading", percent: 42.17, doneBytes: 1_234_567_890, totalBytes: 5_000_000_000)
        )
    }

    @Test func decodesIntegerPercentAndTrailingNewline() {
        let line = #"{"appid": 1, "event": "progress", "state": "verifying install", "percent": 100, "done": 10, "total": 10}"# + "\n"
        #expect(
            SteamInstallEvent.parse(line: line)
                == .progress(state: "verifying install", percent: 100, doneBytes: 10, totalBytes: 10)
        )
    }

    @Test func decodesSuccessfulResult() {
        let line = #"{"appid": 1, "event": "result", "result": "ok", "message": "Success! App '1' fully installed."}"#
        #expect(
            SteamInstallEvent.parse(line: line)
                == .result(succeeded: true, message: "Success! App '1' fully installed.")
        )
    }

    @Test func decodesFailedResult() {
        let line = #"{"appid": 1, "event": "result", "result": "error", "message": "ERROR! Failed to install app '1' (No subscription)"}"#
        #expect(
            SteamInstallEvent.parse(line: line)
                == .result(succeeded: false, message: "ERROR! Failed to install app '1' (No subscription)")
        )
    }

    @Test func ignoresLinesThatAreNotEvents() {
        #expect(SteamInstallEvent.parse(line: "") == nil)
        #expect(SteamInstallEvent.parse(line: "Installing Hyperbolica (1256230) into /tmp") == nil)
        #expect(SteamInstallEvent.parse(line: "{not json") == nil)
        #expect(SteamInstallEvent.parse(line: #"{"appid": 1}"#) == nil)
        #expect(SteamInstallEvent.parse(line: #"{"appid": 1, "event": "something-new"}"#) == nil)
    }
}

@Suite("Steam game launch")
struct SteamGameLaunchTests {
    @Test @MainActor func launchUsesRunnerWithLongerClientTimeout() throws {
        let configuration = SteamGamesConfiguration(
            toolURL: URL(fileURLWithPath: "/tools/steam_games.py"),
            runnerURL: URL(fileURLWithPath: "/rig/run-windows-game.zsh")
        )
        let application = configuration.application(
            for: SteamGame(appID: 1256230, name: "Hyperbolica", isVR: true, isInstalled: true)
        )

        #expect(application.id == "steam.1256230")
        guard case let .external(external) = application.kind else {
            Issue.record("expected an external application")
            return
        }
        #expect(external.executableURL.path == "/rig/run-windows-game.zsh")
        #expect(external.arguments == ["1256230"])
        #expect(external.openXRClientTimeout == 120)
        #expect(external.stopGracePeriod > 2)
        #expect(external.showsHomeWhileStarting)
    }
}
