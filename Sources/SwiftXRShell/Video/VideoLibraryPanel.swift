import AppKit
import Foundation
import SwiftUI

@MainActor
enum VideoPanelMode: Equatable {
    case files
    case youtube
    case loading
    case controls
}

struct VideoFileEntry: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    var id: String { path }
}

@MainActor
final class VideoLibraryModel: ObservableObject {
    @Published var mode: VideoPanelMode = .files
    @Published var currentDirectory = ""
    @Published var entries: [VideoFileEntry] = []
    @Published var selectionIndex = 0
    @Published var pageOffset = 0
    @Published var loadingText = "Opening media…"
    @Published var errorText: String?
    @Published var youtubeSnapshot: NSImage?
    @Published var youtubeStatus = "Loading YouTube VR…"

    let pageSize = 6
    var openMedia: ((String) -> Void)?
    var openYouTube: (() -> Void)?
    var requestHome: (() -> Void)?

    var visibleEntries: [VideoFileEntry] {
        guard !entries.isEmpty else { return [] }
        let start = min(max(pageOffset, 0), max(entries.count - 1, 0))
        let end = min(start + pageSize, entries.count)
        return Array(entries[start..<end])
    }

    func openInitialDirectory() {
        let fm = FileManager.default
        var start = fm.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: start.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            start = fm.homeDirectoryForCurrentUser
        }
        loadDirectory(start.path)
        mode = .files
    }

    func showFiles() {
        if currentDirectory.isEmpty { openInitialDirectory() }
        else { mode = .files; errorText = nil }
    }

    func showYouTube() {
        errorText = nil
        mode = .youtube
        openYouTube?()
    }

    func showLoading(_ text: String) { loadingText = text; errorText = nil; mode = .loading }
    func showControls() { errorText = nil; mode = .controls }
    func showError(_ message: String) { errorText = message; mode = .files }
    func setYouTubeSnapshot(_ image: NSImage?) { youtubeSnapshot = image }
    func setYouTubeStatus(_ value: String) { youtubeStatus = value }

    func loadDirectory(_ path: String) {
        let fm = FileManager.default
        let expanded = NSString(string: path).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            showError("Folder is not available: \(expanded)")
            return
        }

        do {
            let names = try fm.contentsOfDirectory(atPath: expanded)
            var directories: [VideoFileEntry] = []
            var files: [VideoFileEntry] = []

            for name in names where !name.hasPrefix(".") {
                let fullPath = URL(fileURLWithPath: expanded).appendingPathComponent(name).path
                var childIsDirectory: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &childIsDirectory) else { continue }

                if childIsDirectory.boolValue {
                    directories.append(.init(path: fullPath, name: name, isDirectory: true))
                } else {
                    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                    if ["mp4", "m4v", "mov"].contains(ext) {
                        files.append(.init(path: fullPath, name: name, isDirectory: false))
                    }
                }
            }

            let comparison: (VideoFileEntry, VideoFileEntry) -> Bool = {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            directories.sort(by: comparison)
            files.sort(by: comparison)

            var result: [VideoFileEntry] = []
            let url = URL(fileURLWithPath: expanded)
            let parent = url.deletingLastPathComponent().path
            if parent != expanded && !parent.isEmpty {
                result.append(.init(path: parent, name: "..", isDirectory: true))
            }
            result.append(contentsOf: directories)
            result.append(contentsOf: files)

            currentDirectory = expanded
            entries = result
            selectionIndex = 0
            pageOffset = 0
            errorText = nil
        } catch {
            showError("Could not read \(expanded): \(error.localizedDescription)")
        }
    }

    func activate(_ entry: VideoFileEntry) {
        if entry.isDirectory { loadDirectory(entry.path) }
        else { openMedia?(entry.path) }
    }

    func activateSelection() {
        guard entries.indices.contains(selectionIndex) else { return }
        activate(entries[selectionIndex])
    }

    func select(_ entry: VideoFileEntry) {
        if let index = entries.firstIndex(of: entry) {
            selectionIndex = index
            ensureSelectionVisible()
        }
    }

    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectionIndex = min(max(selectionIndex + delta, 0), entries.count - 1)
        ensureSelectionVisible()
    }

    func page(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectionIndex = min(max(selectionIndex + delta * pageSize, 0), entries.count - 1)
        ensureSelectionVisible()
    }

    func openDrives() { loadDirectory("/Volumes") }

    private func ensureSelectionVisible() {
        if selectionIndex < pageOffset { pageOffset = selectionIndex }
        else if selectionIndex >= pageOffset + pageSize {
            pageOffset = max(selectionIndex - pageSize + 1, 0)
        }
    }
}

@MainActor
struct VideoPlayerRootView: View {
    @ObservedObject var library: VideoLibraryModel
    @ObservedObject var controls: VideoControlsModel

    var body: some View {
        Group {
            switch library.mode {
            case .files: VideoFileBrowserView(model: library)
            case .youtube: VideoYouTubeBrowserView(model: library)
            case .loading: VideoLoadingView(model: library)
            case .controls: VideoControlsView(model: controls)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

@MainActor
private struct VideoFileBrowserView: View {
    @ObservedObject var model: VideoLibraryModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.black.opacity(0.90))
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1.5)

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button { model.requestHome?() } label: {
                        Label("Home", systemImage: "house.fill")
                    }
                    .buttonStyle(.bordered)
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Text(URL(fileURLWithPath: model.currentDirectory).lastPathComponent.isEmpty
                         ? model.currentDirectory
                         : URL(fileURLWithPath: model.currentDirectory).lastPathComponent)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(model.currentDirectory)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .frame(maxWidth: 460, alignment: .trailing)
                }

                if let errorText = model.errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 6) {
                    ForEach(model.visibleEntries) { entry in
                        let selected = model.entries.indices.contains(model.selectionIndex)
                            && model.entries[model.selectionIndex] == entry
                        Button {
                            model.select(entry)
                            model.activate(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.isDirectory
                                      ? (entry.name == ".." ? "arrow.uturn.left" : "folder.fill")
                                      : "film.fill")
                                    .frame(width: 28)
                                Text(entry.name).lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 20, weight: .medium))
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selected ? Color.accentColor.opacity(0.75) : .white.opacity(0.07))
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in if hovering { model.select(entry) } }
                    }

                    if model.visibleEntries.isEmpty {
                        Text("No supported videos in this folder")
                            .foregroundStyle(.white.opacity(0.65))
                            .font(.system(size: 20, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }

                HStack(spacing: 10) {
                    Button { model.page(-1) } label: { Label("Page up", systemImage: "chevron.up") }
                    Button { model.page(1) } label: { Label("Page down", systemImage: "chevron.down") }
                    Button { model.openDrives() } label: { Label("Drives", systemImage: "externaldrive.fill") }
                    Spacer()
                    Button { model.showYouTube() } label: { Label("YouTube", systemImage: "play.rectangle.fill") }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .padding(6)
    }
}

@MainActor
private struct VideoYouTubeBrowserView: View {
    @ObservedObject var model: VideoLibraryModel

    var body: some View {
        ZStack {
            Color.black
            if let snapshot = model.youtubeSnapshot {
                Image(nsImage: snapshot).resizable().aspectRatio(contentMode: .fill).clipped()
            } else {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text(model.youtubeStatus).font(.system(size: 26, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            VStack {
                HStack(spacing: 8) {
                    Text("Files / Back")
                    Spacer()
                    Text("SwiftXR Shell Video")
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(.black.opacity(0.72))
                Spacer()
                Text("Mouse/left stick: cursor   Click/Cross: select   Right stick/scroll: page   Circle: back")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 18)
                    .frame(height: 42)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.76))
            }
            .foregroundStyle(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1.5)
        )
    }
}

@MainActor
private struct VideoLoadingView: View {
    @ObservedObject var model: VideoLibraryModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.black.opacity(0.92))
            VStack(spacing: 18) {
                ProgressView().controlSize(.large)
                Text(model.loadingText).font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("The headset remains live while media is resolved and prepared.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .foregroundStyle(.white)
        }
        .padding(6)
    }
}
