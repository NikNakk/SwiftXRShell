import AppKit
import Darwin
import Foundation

/// Where the macos-wine-xr Steam tools live. Overridable in settings.json
/// (`steamGamesTool`, `windowsGameRunner`).
struct SteamGamesConfiguration: Sendable {
    /// `tools/steam_games/steam_games.py` in macos-wine-xr.
    var toolURL: URL
    /// The rig's `run-windows-game.zsh APPID`; SIGTERM closes the game.
    var runnerURL: URL

    /// A Windows game starts Wine, the Steam stand-in and its prefix before it
    /// creates an OpenXR client, which takes far longer than a native app.
    static let openXRClientTimeout: TimeInterval = 120
    /// The runner restores OpenVR path files and stops the prefix's wineserver
    /// on SIGTERM; give it time before a SIGKILL.
    static let stopGracePeriod: TimeInterval = 30

    static var `default`: SteamGamesConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SteamGamesConfiguration(
            toolURL: home.appendingPathComponent(
                "Code/macos-wine-xr/tools/steam_games/steam_games.py"
            ),
            runnerURL: home.appendingPathComponent("Windows/run-windows-game.zsh")
        )
    }

    func application(for game: SteamGame) -> ShellApplication {
        ShellApplication(
            id: "steam.\(game.appID)",
            title: game.name,
            subtitle: "Steam (Windows)",
            systemImage: "gamecontroller.fill",
            kind: .external(
                ExternalOpenXRApplication(
                    executableURL: runnerURL,
                    arguments: [String(game.appID)],
                    openXRApplicationName: game.name,
                    openXRClientTimeout: Self.openXRClientTimeout,
                    stopGracePeriod: Self.stopGracePeriod,
                    showsHomeWhileStarting: true
                )
            )
        )
    }
}

struct SteamInstallProgress: Equatable, Sendable {
    /// SteamCMD's state ("downloading", "verifying install", ...), or nil before
    /// the first progress line (app info lookup and sign-in).
    var state: String?
    var percent: Double = 0
    var doneBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var isCancelling = false
}

@MainActor
final class SteamGameLibrary: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var games: [SteamGame] = []
    @Published private(set) var loadState: LoadState = .idle
    @Published var showsVROnly = true
    @Published private(set) var installs: [Int: SteamInstallProgress] = [:]
    @Published private(set) var installErrors: [Int: String] = [:]

    let configuration: SteamGamesConfiguration

    private var installProcesses: [Int: Process] = [:]
    private var installTasks: [Int: Task<Void, Never>] = [:]

    init(configuration: SteamGamesConfiguration) {
        self.configuration = configuration
    }

    var visibleGames: [SteamGame] {
        showsVROnly ? games.filter(\.isVR) : games
    }

    var vrGameCount: Int {
        games.lazy.filter(\.isVR).count
    }

    /// SteamCMD shares one login and one install folder tree; run one install at a time.
    var isInstalling: Bool {
        !installs.isEmpty
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: configuration.toolURL.path)
    }

    // MARK: Library

    func reload() {
        guard loadState != .loading else { return }
        guard isAvailable else {
            loadState = .failed("steam_games.py not found at \(configuration.toolURL.path)")
            return
        }

        loadState = .loading
        let arguments = toolArguments(["library", "--all", "--json"])
        Task { @MainActor [weak self] in
            do {
                let output = try await ChildProcess.run(arguments)
                guard let self else { return }
                guard output.status == 0 else {
                    self.loadState = .failed(
                        output.errorSummary ?? "steam_games.py library exited with \(output.status)"
                    )
                    return
                }
                self.games = try SteamGame.decodeLibrary(output.stdout)
                self.loadState = .loaded
                print("[steam] \(self.games.count) Windows game(s), \(self.vrGameCount) VR")
            } catch {
                self?.loadState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Install

    func install(_ game: SteamGame) {
        let appID = game.appID
        guard !isInstalling, !game.isInstalled, isAvailable else { return }

        let process = Process()
        let arguments = toolArguments(["install", String(appID), "--progress"])
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let exit = ChildProcess.ExitWaiter(process)

        do {
            try process.run()
        } catch {
            installErrors[appID] = error.localizedDescription
            return
        }

        print("[steam] installing \(game.name) (\(appID))")
        installErrors[appID] = nil
        installs[appID] = SteamInstallProgress()
        installProcesses[appID] = process

        let stderrText = ChildProcess.readToEnd(stderr.fileHandleForReading)
        installTasks[appID] = Task { @MainActor [weak self] in
            var result: (succeeded: Bool, message: String)?
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    guard let event = SteamInstallEvent.parse(line: line) else { continue }
                    switch event {
                    case .start:
                        break
                    case let .progress(state, percent, done, total):
                        self?.updateInstall(appID) {
                            $0.state = state
                            $0.percent = percent
                            $0.doneBytes = done
                            $0.totalBytes = total
                        }
                    case let .result(succeeded, message):
                        result = (succeeded, message)
                    }
                }
            } catch {
                // The pipe closes when the process exits; fall through to its status.
            }

            let status = await exit.status()
            let errors = await stderrText.value
            self?.finishInstall(
                appID: appID,
                name: game.name,
                status: status,
                result: result,
                stderr: errors
            )
        }
    }

    func cancelInstall(_ appID: Int) {
        guard let process = installProcesses[appID], installs[appID] != nil else { return }
        updateInstall(appID) { $0.isCancelling = true }
        // Process puts the child in its own process group; signal the group so
        // SteamCMD, which the script starts as a child, stops too.
        let pid = process.processIdentifier
        if killpg(pid, SIGTERM) != 0 {
            process.terminate()
        }
        print("[steam] cancelling install of \(appID)")
    }

    func dismissInstallError(_ appID: Int) {
        installErrors[appID] = nil
    }

    /// Stop installs when the Shell quits; SteamCMD would otherwise keep running.
    func shutdown() {
        for (_, process) in installProcesses where process.isRunning {
            killpg(process.processIdentifier, SIGTERM)
        }
        installTasks.values.forEach { $0.cancel() }
    }

    private func updateInstall(_ appID: Int, _ change: (inout SteamInstallProgress) -> Void) {
        guard var progress = installs[appID] else { return }
        change(&progress)
        installs[appID] = progress
    }

    private func finishInstall(
        appID: Int,
        name: String,
        status: Int32,
        result: (succeeded: Bool, message: String)?,
        stderr: String
    ) {
        let wasCancelled = installs[appID]?.isCancelling ?? false
        installs[appID] = nil
        installProcesses[appID] = nil
        installTasks[appID] = nil

        if wasCancelled {
            print("[steam] install of \(name) cancelled")
        } else if result?.succeeded == true, status == 0 {
            print("[steam] installed \(name)")
        } else {
            let message = [result?.message, ChildProcess.lastLine(of: stderr)]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .first ?? "Install exited with status \(status)"
            installErrors[appID] = message
            print("[steam] install of \(name) failed: \(message)")
        }

        // Refresh installed state (a cancelled install may have left a folder,
        // but the library only counts games with an app manifest).
        reload()
    }

    private func toolArguments(_ arguments: [String]) -> [String] {
        ["/usr/bin/env", "python3", configuration.toolURL.path] + arguments
    }
}

/// Small helpers around Foundation's Process for the Steam tools.
enum ChildProcess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: String

        var errorSummary: String? {
            ChildProcess.lastLine(of: stderr)
        }
    }

    /// Runs `arguments[0]` with the remaining arguments and collects its output.
    static func run(_ arguments: [String]) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let exit = ExitWaiter(process)
        try process.run()

        // Read both pipes while the process runs; the library JSON is larger
        // than a pipe buffer.
        let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
        let err = readToEnd(stderr.fileHandleForReading)
        let data = await out.value
        let errors = await err.value
        let status = await exit.status()
        return Output(status: status, stdout: data, stderr: errors)
    }

    static func readToEnd(_ handle: FileHandle) -> Task<String, Never> {
        Task.detached {
            String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        }
    }

    static func lastLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Delivers a process's exit status to async code. Create it before `run()`.
    final class ExitWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var exitStatus: Int32?
        private var waiters: [CheckedContinuation<Int32, Never>] = []

        init(_ process: Process) {
            process.terminationHandler = { [self] process in
                let status = process.terminationStatus
                lock.lock()
                exitStatus = status
                let pending = waiters
                waiters.removeAll()
                lock.unlock()
                pending.forEach { $0.resume(returning: status) }
            }
        }

        func status() async -> Int32 {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let exitStatus {
                    lock.unlock()
                    continuation.resume(returning: exitStatus)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }
}

/// Downsampled Steam cover art, loaded on demand.
@MainActor
enum SteamCoverImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(atPath path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 360,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }

        let image = NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        )
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
