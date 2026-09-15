import Foundation
import SwiftUI

@MainActor
enum VideoControlCommand {
    case togglePlayback
    case seekBy(Double)
    case seekTo(Double)
    case setVolume(Float)
    case recenter
    case setProjection(VideoProjectionMode)
    case setStereoLayout(VideoStereoLayout)
    case showFiles
    case showYouTube
    case home
}

@MainActor
final class VideoControlsModel: ObservableObject {
    @Published var title: String
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 1
    @Published var projectionMode: VideoProjectionMode
    @Published var stereoLayout: VideoStereoLayout
    @Published var spatialAudioEnabled = false
    @Published var isScrubbing = false

    var commandHandler: ((VideoControlCommand) -> Void)?

    init(title: String, projectionMode: VideoProjectionMode, stereoLayout: VideoStereoLayout = .mono) {
        self.title = title
        self.projectionMode = projectionMode
        self.stereoLayout = stereoLayout
    }

    func update(
        isPlaying: Bool,
        currentTime: Double,
        duration: Double,
        volume: Float,
        projectionMode: VideoProjectionMode,
        stereoLayout: VideoStereoLayout,
        spatialAudioEnabled: Bool
    ) -> Bool {
        var changed = false
        if self.isPlaying != isPlaying { self.isPlaying = isPlaying; changed = true }
        if !isScrubbing, abs(self.currentTime - currentTime) >= 0.20 {
            self.currentTime = currentTime; changed = true
        }
        if abs(self.duration - duration) >= 0.01 { self.duration = duration; changed = true }
        let newVolume = Double(volume)
        if abs(self.volume - newVolume) >= 0.005 { self.volume = newVolume; changed = true }
        if self.projectionMode != projectionMode { self.projectionMode = projectionMode; changed = true }
        if self.stereoLayout != stereoLayout { self.stereoLayout = stereoLayout; changed = true }
        if self.spatialAudioEnabled != spatialAudioEnabled {
            self.spatialAudioEnabled = spatialAudioEnabled; changed = true
        }
        return changed
    }

    func send(_ command: VideoControlCommand) { commandHandler?(command) }
}

@MainActor
struct VideoControlsView: View {
    @ObservedObject var model: VideoControlsModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.black.opacity(0.88))
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1.5)

            VStack(spacing: 13) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title)
                            .font(.system(size: 18, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(model.projectionMode.description)
                            Text("•")
                            Text(model.stereoLayout.description)
                            if model.spatialAudioEnabled {
                                Label("Spatial", systemImage: "spatialaudio")
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    Button { model.send(.home) } label: {
                        Label("Home", systemImage: "house.fill")
                    }
                    Button { model.send(.showFiles) } label: {
                        Label("Files", systemImage: "folder.fill")
                    }
                    Button { model.send(.showYouTube) } label: {
                        Label("YouTube", systemImage: "play.rectangle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { model.send(.recenter) } label: {
                        Label("Recenter", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    Text(Self.timeString(model.currentTime)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    Slider(
                        value: Binding(get: { model.currentTime }, set: { model.currentTime = $0 }),
                        in: 0...max(model.duration, 0.001),
                        onEditingChanged: { editing in
                            model.isScrubbing = editing
                            if !editing { model.send(.seekTo(model.currentTime)) }
                        }
                    )
                    Text(Self.timeString(model.duration)).monospacedDigit().frame(width: 52, alignment: .leading)
                }

                HStack(spacing: 14) {
                    Button { model.send(.seekBy(-15)) } label: { Label("15", systemImage: "gobackward.15") }
                    Button { model.send(.togglePlayback) } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { model.send(.seekBy(15)) } label: { Label("15", systemImage: "goforward.15") }
                    Spacer()
                    Image(systemName: "speaker.fill")
                    Slider(
                        value: Binding(
                            get: { model.volume },
                            set: { value in
                                model.volume = value
                                model.send(.setVolume(Float(value)))
                            }
                        ),
                        in: 0...1
                    )
                    .frame(width: 125)
                    Text("\(Int(model.volume * 100))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                .buttonStyle(.bordered)

                HStack(spacing: 8) {
                    Text("Projection").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.65)).frame(width: 72, alignment: .leading)
                    projectionButton("Flat", .flat)
                    projectionButton("VR180", .vr180Equirect)
                    projectionButton("Fisheye", .vr180Fisheye)
                    projectionButton("EAC360", .eac360)
                }

                HStack(spacing: 8) {
                    Text("Stereo").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.65)).frame(width: 72, alignment: .leading)
                    stereoButton(.mono)
                    stereoButton(.sideBySide)
                    stereoButton(.topBottom)
                    Spacer()
                }
            }
            .foregroundStyle(.white)
            .controlSize(.regular)
            .padding(22)
        }
        .frame(width: 900, height: 325)
        .padding(6)
    }

    @ViewBuilder
    private func projectionButton(_ title: String, _ mode: VideoProjectionMode) -> some View {
        Button(title) {
            model.projectionMode = mode
            model.send(.setProjection(mode))
        }
        .buttonStyle(model.projectionMode == mode ? .borderedProminent : .bordered)
    }

    @ViewBuilder
    private func stereoButton(_ layout: VideoStereoLayout) -> some View {
        Button(layout.shortLabel) {
            model.stereoLayout = layout
            model.send(.setStereoLayout(layout))
        }
        .buttonStyle(model.stereoLayout == layout ? .borderedProminent : .bordered)
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
