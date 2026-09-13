import SwiftUI

struct TrackCard: View {
    let track: SCTrack
    let player: PlayerEngine
    let queue: PlayQueue

    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        MediaCard(isPlaying: isCurrent && player.isPlaying, play: play) {
            Artwork(track, size: .hero)
        } caption: {
            // Two targets rather than one: the title opens the track, the line under it the artist.
            VStack(alignment: .leading, spacing: 2) {
                NavButton(value: track) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                NavButton(value: track.user) {
                    Text(track.artistLine)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
        .trackContextMenu(track, player: player)
    }

    private func play() {
        if isCurrent {
            player.togglePlayPause()
        } else {
            Task { await queue.start(track, on: player) }
        }
    }
}

struct PlaylistCard: View {
    let playlist: SCPlaylist
    let model: AppModel
    /// A profile lists the owner's own sets, where the byline would only repeat their name.
    var subtitle: String?

    @State private var isStarting = false

    var body: some View {
        MediaCard(isBusy: isStarting, play: play) {
            Artwork(playlist, size: .hero)
        } caption: {
            NavButton(value: playlist) {
                CardCaption(title: playlist.title, subtitle: subtitle ?? playlist.byline)
            }
            .buttonStyle(.plain)
        }
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

struct ArtistCircle: View {
    let artist: SCUser
    /// Lets a #Preview show the hover state, which has no pointer to produce it.
    var forceHover = false

    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    private var lit: Bool { hovering || forceHover }

    private var avatarSize: CGFloat { metrics.shelfAvatar }

    var body: some View {
        NavButton(value: artist) {
            VStack(spacing: 8) {
                Artwork(artist, size: .mid)
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(.tint, lineWidth: 2).opacity(lit ? 1 : 0) }
                    .scaleEffect(lit ? 1.04 : 1)

                VStack(spacing: 2) {
                    Text(artist.username)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(countString(artist.followersCount ?? 0))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: avatarSize + 8)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
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

            PlayFAB(size: 36, isStarting: isStarting)
                .scaleEffect(hovering || isStarting ? 1 : 0.88)
                .opacity(hovering || isStarting ? 1 : 0)
                .padding(12)
                .frame(width: metrics.wideCard.width, height: metrics.wideCard.height, alignment: .bottomTrailing)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: hovering || isStarting)
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
