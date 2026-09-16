import SwiftUI

@MainActor
struct ShellHomeView: View {
    @ObservedObject var model: ShellModel

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 22)
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.04, blue: 0.08),
                    Color(red: 0.055, green: 0.10, blue: 0.17),
                    Color(red: 0.025, green: 0.04, blue: 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "viewfinder.circle.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.cyan)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SwiftXR Shell")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                        Text("OpenXR on macOS")
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.62))
                    }

                    Spacer()

                    Button {
                        model.recenter()
                    } label: {
                        Label("Recenter", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        model.openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(model.applications) { application in
                            Button {
                                model.launch(application)
                            } label: {
                                ShellApplicationTile(application: application)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Label("Move mouse to point • click to select • Esc to exit", systemImage: "cursorarrow.motionlines")
                    Spacer()
                    Text("SwiftXR")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
            }
            .padding(42)
        }
        .foregroundStyle(.white)
        .frame(width: 1280, height: 720)
    }
}

@MainActor
private struct ShellApplicationTile: View {
    let application: ShellApplication

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: application.systemImage)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.cyan)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer(minLength: 12)

            Text(application.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text(application.subtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
