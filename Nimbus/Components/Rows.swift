import NukeUI
import SwiftUI

struct TrackRow: View {
    let track: SCTrack
    let player: PlayerEngine
    var queueContext: [SCTrack] = []

    @State private var hovering = false

    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 3) {
                NavigationLink(value: track) {
                    Text(track.title)
                        .font(.system(size: 15))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
                NavigationLink(value: track.user) {
                    Text(track.artistLine)
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            stats

            Text(timeString(Double(track.duration) / 1000))
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
                .opacity(hovering ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { play() }
        .trackContextMenu(track, player: player)
    }

    private var artwork: some View {
        Button(action: artworkTapped) {
            ZStack {
                LazyImage(url: track.artworkURL.flatMap(URL.init)) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
                if hovering {
                    Color.black.opacity(0.4)
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(.white).font(.system(size: 18))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var stats: some View {
        HStack(spacing: 16) {
            stat("play.fill", track.playbackCount)
            stat("heart.fill", track.likesCount)
            stat("text.bubble.fill", track.commentCount)
            stat("arrow.2.squarepath", track.repostsCount)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func stat(_ symbol: String, _ count: Int?) -> some View {
        if let count, count > 0 {
            HStack(spacing: 4) {
                Image(systemName: symbol).imageScale(.small)
                Text(countString(count)).monospacedDigit()
            }
        }
    }

    private func artworkTapped() {
        if isCurrent { player.togglePlayPause() } else { play() }
    }

    private func play() {
        Task { await player.play(track, in: queueContext.isEmpty ? [track] : queueContext) }
    }
}

struct UserRow: View {
    let user: SCUser

    var body: some View {
        HStack(spacing: 10) {
            LazyImage(url: user.avatarURL.flatMap(URL.init)) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(user.username).lineLimit(1)
                    if user.verified == true {
                        Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.tint)
                    }
                }
                Text("Artist · \(countString(user.followersCount ?? 0)) followers")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct PlaylistRow: View {
    let playlist: SCPlaylist

    var body: some View {
        HStack(spacing: 10) {
            LazyImage(url: playlist.artworkURL.flatMap(URL.init)) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).lineLimit(1)
                Text("\(playlist.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct StreamItemView: View {
    let item: SCStreamItem
    let model: AppModel
    let context: [SCTrack]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let reposter = item.reposter {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.2.squarepath").foregroundStyle(.tint)
                    Text("\(reposter.username) reposted")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            }
            switch item.content {
            case .track(let track):
                TrackRow(track: track, player: model.player, queueContext: context)
            case .playlist(let playlist):
                NavigationLink(value: playlist) { PlaylistRow(playlist: playlist) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}
