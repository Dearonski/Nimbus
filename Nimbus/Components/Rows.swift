import SwiftUI

struct TrackRow: View {
    let track: SCTrack
    let player: PlayerEngine
    let queue: PlayQueue
    /// Position in a set's tracklist. Numbered the way the site numbers an album, so the order the
    /// artist chose stays readable while the rows are scanned — and placed after the cover, as the
    /// site places it: in front of it, the number column pushed every cover off the edge the page
    /// hero's play button stands on.
    var index: Int?
    /// As wide as the tracklist's longest number: right-aligned digits, with no blank column in
    /// front of a nine-track album's single digits.
    var indexWidth: CGFloat = TrackRow.indexWidth(for: 99)

    /// The row's own inset inside its hover highlight; a list that wants the content on its
    /// margin bleeds the highlight out by this much.
    static let inset: CGFloat = 10

    static func indexWidth(for count: Int) -> CGFloat {
        CGFloat(String(max(count, 1)).count) * 8 + 1
    }

    @Environment(LibraryStore.self) private var library: LibraryStore?
    @State private var hovering = false

    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        HStack(spacing: 12) {
            artwork

            if let index {
                Text("\(index)")
                    .font(.system(size: 13)).monospacedDigit()
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: indexWidth, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 3) {
                NavButton(value: track) {
                    Text(track.title)
                        .font(.system(size: 15))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
                NavButton(value: track.user) {
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
        .padding(.horizontal, Self.inset)
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
                Artwork(track, size: .thumb)
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
            likeStat
            stat("text.bubble.fill", track.commentCount)
            repostStat
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private var likeStat: some View {
        if let library {
            let liked = library.isLiked(track)
            Button { library.toggleLike(track) } label: {
                HStack(spacing: 4) {
                    Image(systemName: liked ? "heart.fill" : "heart").imageScale(.small)
                    if let count = track.likesCount, count > 0 {
                        Text(countString(count)).monospacedDigit()
                    }
                }
                .foregroundStyle(liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
        } else {
            stat("heart.fill", track.likesCount)
        }
    }

    @ViewBuilder
    private var repostStat: some View {
        if let library {
            let reposted = library.isReposted(track)
            Button { library.toggleRepost(track) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath").imageScale(.small)
                    if let count = track.repostsCount, count > 0 {
                        Text(countString(count)).monospacedDigit()
                    }
                }
                .foregroundStyle(reposted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
        } else {
            stat("arrow.2.squarepath", track.repostsCount)
        }
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
        Task { await queue.start(track, on: player) }
    }
}

struct UserRow: View {
    let user: SCUser

    var body: some View {
        HStack(spacing: 10) {
            Artwork(user, size: .thumb)
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
            Artwork(playlist, size: .thumb)
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
    let queue: PlayQueue

    var body: some View {
        // A post is the same card wherever it appears — the feed, an artist's All tab, their
        // reposts. A repost is not a different shape with a banner over it: the reposter goes
        // into the byline beside the author, which is how the site reads.
        Group {
            switch item.content {
            case .track(let track):
                LikeCard(track: track, player: model.player, queue: queue,
                         reposter: item.reposter)
            case .playlist(let playlist):
                SetCard(playlist: playlist, model: model, reposter: item.reposter)
            }
        }
        .padding(.vertical, 4)
    }
}
