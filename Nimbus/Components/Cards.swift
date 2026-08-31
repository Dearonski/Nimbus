import NukeUI
import SwiftUI

struct TrackCard: View {
    let track: SCTrack
    let player: PlayerEngine
    var context: [SCTrack] = []

    @Environment(\.metrics) private var metrics
    @State private var hovering = false
    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: play) {
                ZStack {
                    LazyImage(url: track.artworkURL.scArtwork()) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    if hovering || (isCurrent && player.isPlaying) {
                        Color.black.opacity(0.35)
                        Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26)).foregroundStyle(.white)
                    }
                }
                .frame(width: metrics.card, height: metrics.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            NavigationLink(value: track) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain)

            NavigationLink(value: track.user) {
                Text(track.artistLine)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .buttonStyle(.plain)
        }
        .frame(width: metrics.card, alignment: .leading)
        .trackContextMenu(track, player: player)
        .onHover { hovering = $0 }
    }

    private func play() {
        if isCurrent {
            player.togglePlayPause()
        } else {
            Task { await player.play(track, in: context.isEmpty ? [track] : context) }
        }
    }
}

struct PlaylistCard: View {
    let playlist: SCPlaylist
    let model: AppModel

    @Environment(\.metrics) private var metrics
    @State private var hovering = false
    @State private var isStarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: play) {
                ZStack {
                    LazyImage(url: playlist.artworkURL.scArtwork()) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    if hovering || isStarting {
                        Color.black.opacity(0.35)
                        if isStarting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 26)).foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: metrics.card, height: metrics.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink(value: playlist) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(playlist.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
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

struct ArtistCircle: View {
    let artist: SCUser

    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    private var avatarSize: CGFloat { metrics.shelfAvatar }

    var body: some View {
        NavigationLink(value: artist) {
            VStack(spacing: 8) {
                Artwork(url: artist.avatarURL.scArtwork("t300x300"))
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(.tint, lineWidth: 2).opacity(hovering ? 1 : 0) }
                    .scaleEffect(hovering ? 1.04 : 1)

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
