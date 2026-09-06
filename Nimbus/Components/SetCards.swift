import SwiftUI

/// Resolving a playlist's tracks takes a request, so the button reports that it is working
/// instead of looking dead for a second.
private struct PlayFAB: View {
    let size: CGFloat
    let isStarting: Bool

    var body: some View {
        Circle()
            .fill(.tint)
            .frame(width: size, height: size)
            .overlay {
                if isStarting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: size * 0.38))
                        .foregroundStyle(.white)
                }
            }
    }
}

/// Artwork plays, the caption opens the page — the split `TrackCard` already uses. Wrapping the
/// whole card in a NavigationLink swallowed the play button's click, so the button was a lie.
struct SquareSetCard: View {
    let playlist: SCPlaylist
    let model: AppModel

    @State private var hovering = false
    @State private var isStarting = false

    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: play) {
                ZStack {
                    Artwork(playlist, size: .hero)
                        .frame(width: metrics.card, height: metrics.card)
                    if hovering || isStarting {
                        Color.black.opacity(0.3)
                        PlayFAB(size: 40, isStarting: isStarting)
                    }
                }
                .frame(width: metrics.card, height: metrics.card)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavButton(value: playlist) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(playlist.byline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: metrics.card, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: metrics.card, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private func play() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            await model.play(playlist)
        }
    }
}

/// The title overlays the artwork here, so the card plays and only the title text navigates.
struct WideSetCard: View {
    let playlist: SCPlaylist
    let model: AppModel

    @State private var hovering = false
    @State private var isStarting = false

    @Environment(\.metrics) private var metrics

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Button(action: play) {
                ZStack {
                    Artwork(playlist, size: .hero)
                        .frame(width: metrics.wideCard.width, height: metrics.wideCard.height)

                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0), location: 0.25),
                            .init(color: .black.opacity(0.55), location: 0.6),
                            .init(color: .black.opacity(0.9), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom)
                }
                .frame(width: metrics.wideCard.width, height: metrics.wideCard.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                NavButton(value: playlist) {
                    Text(playlist.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                Text("\(playlist.trackCount) tracks")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(12)

            if hovering || isStarting {
                PlayFAB(size: 36, isStarting: isStarting)
                    .padding(12)
                    .frame(width: metrics.wideCard.width, height: metrics.wideCard.height, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: metrics.wideCard.width, height: metrics.wideCard.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
    }

    private func play() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            await model.play(playlist)
        }
    }
}
