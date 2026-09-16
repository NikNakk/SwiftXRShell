import Foundation

struct ResolvedMediaInput: Sendable {
    let url: URL
    let youtubeEACHint: Bool
    let ambisonicURL: URL?
    let originalInput: String
}

typealias MediaInputProgressHandler = @Sendable (String) -> Void

enum MediaInputError: Error, CustomStringConvertible {
    case noInput
    case fileDoesNotExist(String)
    case cacheDirectory(String)
    case commandLaunch(String, String)
    case commandFailed(String, Int32)
    case noDownloadedFile

    var description: String {
        switch self {
        case .noInput: return "No media input supplied"
        case let .fileDoesNotExist(path): return "Media file does not exist: \(path)"
        case let .cacheDirectory(message): return "Could not create YouTube cache directory: \(message)"
        case let .commandLaunch(command, message): return "Could not launch \(command): \(message)"
        case let .commandFailed(command, status): return "\(command) exited with status \(status)"
        case .noDownloadedFile: return "yt-dlp did not produce a playable local file"
        }
    }
}

enum MediaInputResolver {
    static func resolve(
        _ input: String,
        progress: MediaInputProgressHandler? = nil
    ) throws -> ResolvedMediaInput {
        guard !input.isEmpty else { throw MediaInputError.noInput }

        if !isHTTPURL(input) {
            let expanded = NSString(string: input).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw MediaInputError.fileDoesNotExist(expanded)
            }
            return ResolvedMediaInput(
                url: URL(fileURLWithPath: expanded),
                youtubeEACHint: filenameSuggestsEAC(expanded),
                ambisonicURL: localAmbisonicOverride(),
                originalInput: input
            )
        }
        return try resolveYouTube(input, progress: progress)
    }

    private static func isHTTPURL(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://")
    }

    private static func youtubeVideoID(_ value: String) -> String? {
        guard let components = URLComponents(string: value) else { return nil }
        let host = components.host?.lowercased() ?? ""
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            return components.path.split(separator: "/").first.map(String.init)
        }
        if let value = components.queryItems?.first(where: { $0.name == "v" })?.value,
           !value.isEmpty {
            return value
        }
        let parts = components.path.split(separator: "/").map(String.init)
        for index in 0..<(max(parts.count - 1, 0)) {
            if ["shorts", "embed", "live"].contains(parts[index].lowercased()) {
                return parts[index + 1]
            }
        }
        return nil
    }

    static func filenameSuggestsEAC(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.uppercased()
        return name.contains("EAC360") || (name.contains("360") && !name.contains("180"))
    }

    private static func cacheDirectory() throws -> URL {
        let fm = FileManager.default
        let url = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/GAVPSVR2/YouTube", isDirectory: true)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw MediaInputError.cacheDirectory(error.localizedDescription)
        }
        return url
    }

    private static func localAmbisonicOverride() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["SWIFTXR_AMBISONIC_AUDIO"]
            ?? environment["GAV_AMBISONIC_AUDIO"],
            !raw.isEmpty,
            raw.lowercased() != "off"
        else { return nil }
        let path = NSString(string: raw).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            fputs("[audio] Ambisonic override does not exist: \(path)\n", stderr)
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func findCachedYouTubeFile(cache: URL, videoID: String?) -> URL? {
        guard let videoID, !videoID.isEmpty else { return nil }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cache,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let needle = "[\(videoID)]"
        var fallback: URL?
        for entry in entries where entry.pathExtension.lowercased() == "mp4" {
            guard entry.lastPathComponent.contains(needle) else { continue }
            if filenameSuggestsEAC(entry.path) { return entry }
            fallback = entry
        }
        return fallback
    }

    private static func audioChannelCount(_ url: URL) -> Int? {
        guard let result = try? run(
            "ffprobe",
            [
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream=channels",
                "-of", "default=noprint_wrappers=1:nokey=1",
                url.path,
            ],
            suppressStderr: true
        ), result.status == 0 else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func findCachedAmbisonicFile(cache: URL, videoID: String?) -> URL? {
        if let override = localAmbisonicOverride() { return override }
        guard let videoID, !videoID.isEmpty else { return nil }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cache,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let extensions = Set(["webm", "mka", "opus", "ogg", "m4a", "mp4"])
        let needle = "[\(videoID)]"
        let candidates = entries.filter {
            $0.lastPathComponent.contains(needle) && extensions.contains($0.pathExtension.lowercased())
        }

        let explicitMarker = "\(needle) ambisonic.".lowercased()
        for candidate in candidates where candidate.lastPathComponent.lowercased().contains(explicitMarker) {
            if let channels = audioChannelCount(candidate), channels > 2 { return candidate }
            if audioChannelCount(candidate) == nil { return candidate }
        }
        for candidate in candidates {
            if let channels = audioChannelCount(candidate), channels > 2 { return candidate }
        }
        return nil
    }

    private static func discoverMultichannelFormatID(
        _ input: String,
        progress: MediaInputProgressHandler?
    ) -> String? {
        progress?("Checking spatial audio…")
        guard let result = try? run(
            "yt-dlp",
            [
                "-J",
                "--no-playlist",
                "--no-warnings",
                "--extractor-args", "youtube:player_client=default,web_embedded",
                input,
            ],
            suppressStderr: true
        ), result.status == 0,
        let data = result.stdout.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let formats = json["formats"] as? [[String: Any]]
        else { return nil }

        var bestID: String?
        var bestChannels = 0
        var bestBitrate = -1.0

        for format in formats {
            guard (format["vcodec"] as? String) == "none",
                  let channels = format["audio_channels"] as? Int,
                  channels > 2,
                  let formatID = format["format_id"] as? String
            else { continue }

            let bitrate = (format["abr"] as? Double) ?? (format["tbr"] as? Double) ?? -1
            if channels > bestChannels || (channels == bestChannels && bitrate > bestBitrate) {
                bestID = formatID
                bestChannels = channels
                bestBitrate = bitrate
            }
        }

        if let bestID {
            print("[audio] YouTube spatial format \(bestID): \(bestChannels) channels")
        }
        return bestID
    }

    private static func downloadAmbisonicFile(
        cache: URL,
        input: String,
        videoID: String?,
        progress: MediaInputProgressHandler?
    ) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if (environment["SWIFTXR_AMBISONIC_AUDIO"] ?? environment["GAV_AMBISONIC_AUDIO"])?
            .lowercased() == "off" {
            return nil
        }
        guard let formatID = discoverMultichannelFormatID(input, progress: progress) else { return nil }

        progress?("Starting spatial-audio download…")
        let template = cache
            .appendingPathComponent("%(title)s [YT] [%(id)s] ambisonic.%(ext)s")
            .path
        guard let result = try? run(
            "yt-dlp",
            [
                "--no-playlist",
                "--no-warnings",
                "--extractor-args", "youtube:player_client=default,web_embedded",
                "--format", formatID,
                "--output", template,
                "--print", "after_move:filepath",
                "--progress",
                "--newline",
                "--progress-delta", "0.25",
                "--progress-template", "download:SWIFTXR_PROGRESS|%(progress._default_template)s",
                input,
            ],
            suppressStderr: false,
            progressStage: "Spatial audio",
            progress: progress
        ), result.status == 0 else { return nil }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        if let channels = audioChannelCount(url), channels > 2 {
            print("[audio] downloaded \(channels)-channel sidecar: \(path)")
            return url
        }
        return nil
    }

    private static func resolveYouTube(
        _ input: String,
        progress: MediaInputProgressHandler?
    ) throws -> ResolvedMediaInput {
        let cache = try cacheDirectory()
        let videoID = youtubeVideoID(input)

        var ambisonic = findCachedAmbisonicFile(cache: cache, videoID: videoID)
        if ambisonic == nil {
            ambisonic = downloadAmbisonicFile(
                cache: cache,
                input: input,
                videoID: videoID,
                progress: progress
            )
        }

        progress?("Checking YouTube cache…")
        if let cached = findCachedYouTubeFile(cache: cache, videoID: videoID) {
            let eac = filenameSuggestsEAC(cached.path)
            print("[youtube] cache hit: \(cached.path)\(eac ? " (EAC360)" : "")")
            progress?("Using cached YouTube video…")
            return ResolvedMediaInput(
                url: cached,
                youtubeEACHint: eac,
                ambisonicURL: ambisonic,
                originalInput: input
            )
        }

        print("[youtube] downloading media with yt-dlp…")
        progress?("Starting video download…")
        let template = cache
            .appendingPathComponent("%(title)s [YT] [%(id)s] [%(width)sx%(height)s].%(ext)s")
            .path
        let result = try run(
            "yt-dlp",
            [
                "--no-playlist",
                "--no-warnings",
                "--format", "bv*[ext=mp4][vcodec^=av01]+ba[ext=m4a]/bv*[ext=mp4][vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4]",
                "--merge-output-format", "mp4",
                "--write-info-json",
                "--output", template,
                "--print", "after_move:filepath",
                "--progress",
                "--newline",
                "--progress-delta", "0.25",
                "--progress-template", "download:SWIFTXR_PROGRESS|%(progress._default_template)s",
                input,
            ],
            suppressStderr: false,
            progressStage: "Video",
            progress: progress
        )
        guard result.status == 0 else {
            throw MediaInputError.commandFailed("yt-dlp", result.status)
        }

        progress?("Preparing downloaded video…")
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw MediaInputError.noDownloadedFile
        }
        let url = URL(fileURLWithPath: path)
        let eac = filenameSuggestsEAC(path)
        return ResolvedMediaInput(
            url: url,
            youtubeEACHint: eac,
            ambisonicURL: ambisonic,
            originalInput: input
        )
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
    }

    private static func run(
        _ executable: String,
        _ arguments: [String],
        suppressStderr: Bool,
        progressStage: String? = nil,
        progress: MediaInputProgressHandler? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments

        let output = Pipe()
        process.standardOutput = output

        let progressPipe: Pipe?
        if progress != nil, progressStage != nil {
            let pipe = Pipe()
            process.standardError = pipe
            progressPipe = pipe
        } else {
            process.standardError = suppressStderr ? FileHandle.nullDevice : FileHandle.standardError
            progressPipe = nil
        }

        do {
            try process.run()
        } catch {
            throw MediaInputError.commandLaunch(executable, error.localizedDescription)
        }

        if let progressPipe, let progressStage {
            progressPipe.fileHandleForWriting.closeFile()
            var pending = ""
            while true {
                let data = progressPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending += String(decoding: data, as: UTF8.self)

                while let newline = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                    pending.removeSubrange(...newline)
                    handleStderrLine(
                        line,
                        suppressStderr: suppressStderr,
                        progressStage: progressStage,
                        progress: progress
                    )
                }
            }
            let finalLine = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalLine.isEmpty {
                handleStderrLine(
                    finalLine,
                    suppressStderr: suppressStderr,
                    progressStage: progressStage,
                    progress: progress
                )
            }
        }

        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private static func handleStderrLine(
        _ line: String,
        suppressStderr: Bool,
        progressStage: String,
        progress: MediaInputProgressHandler?
    ) {
        let marker = "SWIFTXR_PROGRESS|"
        if line.hasPrefix(marker) {
            let detail = String(line.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty {
                progress?("\(progressStage) • \(detail)")
            }
        } else if !suppressStderr, !line.isEmpty {
            fputs("\(line)\n", stderr)
        }
    }
}
