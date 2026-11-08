import SwiftUI

/// "Steam (Windows)" on Home: the Windows games in macOS Steam's library.
@MainActor
struct SteamGamesSection: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var library: SteamGameLibrary

    private let columns = [
        GridItem(.adaptive(minimum: 172, maximum: 200), spacing: 18)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("Steam (Windows)")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            if library.loadState == .loaded {
                Text(countText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            HStack(spacing: 0) {
                filterButton("VR", selected: library.showsVROnly) {
                    library.showsVROnly = true
                }
                filterButton("All", selected: !library.showsVROnly) {
                    library.showsVROnly = false
                }
            }
            .background(Capsule().fill(.white.opacity(0.08)))

            Button {
                library.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(library.loadState == .loading)
        }
    }

    private var countText: String {
        let shown = library.visibleGames
        let installed = shown.filter(\.isInstalled).count
        return "\(shown.count) \(library.showsVROnly ? "VR " : "")game\(shown.count == 1 ? "" : "s"), "
            + "\(installed) installed"
    }

    private func filterButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(selected ? Color.cyan.opacity(0.85) : .clear))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if case let .failed(error) = library.loadState {
            message(error, systemImage: "exclamationmark.triangle.fill")
        }

        if library.games.isEmpty {
            if library.loadState == .idle || library.loadState == .loading {
                message("Reading macOS Steam's library…", systemImage: "hourglass")
            }
        } else {
            if library.visibleGames.isEmpty {
                message(
                    library.showsVROnly
                        ? "No Windows VR games in your Steam library"
                        : "No Windows games in your Steam library",
                    systemImage: "gamecontroller"
                )
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(library.visibleGames) { game in
                        SteamGameTile(
                            game: game,
                            install: library.installs[game.appID],
                            installError: library.installErrors[game.appID],
                            activity: model.externalActivity(for: game),
                            canLaunch: model.externalApplicationsEnabled
                                && model.externalActivity == nil,
                            canInstall: !library.isInstalling,
                            onPlay: { model.launch(game) },
                            onStop: { model.stopExternalApplication() },
                            onInstall: { library.install(game) },
                            onCancelInstall: { library.cancelInstall(game.appID) },
                            onDismissError: { library.dismissInstallError(game.appID) }
                        )
                    }
                }
            }
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.vertical, 10)
    }
}

@MainActor
private struct SteamGameTile: View {
    let game: SteamGame
    let install: SteamInstallProgress?
    let installError: String?
    let activity: ShellExternalActivity?
    let canLaunch: Bool
    let canInstall: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    let onInstall: () -> Void
    let onCancelInstall: () -> Void
    let onDismissError: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(shape)
                .overlay(alignment: .topLeading) { badges }
                .opacity(game.isInstalled || install != nil ? 1 : 0.6)

            Text(game.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2, reservesSpace: true)

            controls
                .frame(minHeight: 52, alignment: .top)
        }
        .padding(10)
        .background(shape.fill(.white.opacity(0.06)))
        .overlay(shape.stroke(.white.opacity(activity != nil ? 0.5 : 0.12), lineWidth: 1.5))
    }

    @ViewBuilder
    private var cover: some View {
        if let image = (game.coverPath ?? game.heroPath)
            .flatMap(SteamCoverImageCache.image(atPath:)) {
            Color.clear.overlay(
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            )
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.16, blue: 0.26), Color(red: 0.05, green: 0.08, blue: 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(spacing: 10) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.cyan.opacity(0.7))
                    Text(game.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
            }
        }
    }

    private var badges: some View {
        HStack(spacing: 5) {
            if game.isVR {
                badge("VR", color: .cyan)
            }
            if game.isInstalled {
                badge("Installed", color: .green)
            }
        }
        .padding(7)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.9)))
            .foregroundStyle(.black)
    }

    @ViewBuilder
    private var controls: some View {
        if let activity {
            HStack {
                Label(
                    activity.phase == .stopping ? "Stopping…"
                        : activity.phase == .running ? "Running" : "Starting…",
                    systemImage: "hourglass"
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Button("Stop", role: .destructive, action: onStop)
                    .buttonStyle(.bordered)
                    .disabled(activity.phase == .stopping)
            }
        } else if let install {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView(value: min(max(install.percent / 100, 0), 1))
                        .tint(.cyan)
                    Button("Cancel", action: onCancelInstall)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(install.isCancelling)
                }
                Text(installStatus(install))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        } else if let installError {
            VStack(alignment: .leading, spacing: 6) {
                Text(installError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                HStack {
                    Button("Retry", action: onInstall)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canInstall)
                    Button("Dismiss", action: onDismissError)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        } else if game.isInstalled {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(!canLaunch)
            .help(canLaunch ? "Launch \(game.name)" : "Launch requires Monado runtime control and no other app starting or running")
        } else {
            Button(action: onInstall) {
                Label("Install", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canInstall)
        }
    }

    private func installStatus(_ install: SteamInstallProgress) -> String {
        if install.isCancelling {
            return "Cancelling…"
        }
        guard let state = install.state else {
            return "Preparing…"
        }
        var text = "\(state.prefix(1).uppercased())\(state.dropFirst()) \(Int(install.percent))%"
        if install.totalBytes > 0 {
            let done = ByteCountFormatter.string(fromByteCount: install.doneBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: install.totalBytes, countStyle: .file)
            text += " · \(done) / \(total)"
        }
        return text
    }
}
