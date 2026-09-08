import SwiftUI

/// One confident answer to "what should I play?" — the page opens with a mix, not a chart.
struct FeaturedMix: View {
    let playlist: SCPlaylist?
    let eyebrow: String?
    let model: AppModel

    @State private var isStarting = false

    @Environment(\.metrics) private var metrics

    var body: some View {
        Group {
            if let playlist {
                card(playlist)
            } else {
                FeaturedMixSkeleton()
            }
        }
        .padding(.horizontal, gutter)
    }

    private func card(_ playlist: SCPlaylist) -> some View {
        HStack(alignment: .top, spacing: 22) {
            NavButton(value: playlist) {
                Artwork(playlist, size: .hero)
                    .frame(width: metrics.hero - 40, height: metrics.hero - 40)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text((eyebrow ?? "Featured").uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.tint)

                Text(playlist.title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)

                if let description = playlist.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let author = playlist.user?.username {
                    Text(author).font(.system(size: 14)).foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                HStack(spacing: 12) {
                    Button { start(playlist, shuffled: false) } label: {
                        Label("Play", systemImage: "play.fill").frame(minWidth: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button { start(playlist, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if isStarting { FaderLoader(size: 20) }

                    Text("\(playlist.trackCount) tracks")
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        // Same metric as the artwork inside it, which is inset by this padding on both sides.
        .frame(height: metrics.hero)
        .background {
            Artwork(playlist, size: .hero)
                .blur(radius: 52, opaque: true)
                .overlay(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.07))
        }
    }

    private func start(_ playlist: SCPlaylist, shuffled: Bool) {
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            await model.play(playlist, shuffled: shuffled)
        }
    }
}
