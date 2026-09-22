import SwiftUI

/// A liked track the way SoundCloud lists it: cover, uploader and title, the waveform across the
/// full width, and the like/repost row underneath — not a table line.
struct LikeCard: View {
    let track: SCTrack
    let player: PlayerEngine
    let queue: PlayQueue
    /// Set when the post is someone's repost. The site writes it into the byline — "author ↻
    /// reposter" — rather than stacking a separate line above the card.
    var reposter: SCUser?

    @Environment(\.metrics) private var metrics
    @Environment(LibraryStore.self) private var library: LibraryStore?

    @State private var comments = WaveformCommentsLoader()

    /// What `CardCollection` measures by: the age and genre stacked are the one thing taller than
    /// the title block. Anything else that changes a card's height has to be added here. Asked for
    /// every row of a list, so it reads fields and formats nothing.
    static func heightVariant(of track: SCTrack) -> AnyHashable {
        track.createdAt != nil && track.genre?.isEmpty == false
    }

    static func warm(_ tracks: [SCTrack]) {
        ArtworkPrefetcher.warm(tracks.map(\.coverURL), size: .mid)
        WaveformLoader.warm(tracks.map(\.waveformURL))
    }

    private var isCurrent: Bool { track.id == player.currentTrack?.id }
    private var isPlaying: Bool { isCurrent && player.isPlaying }
    private var progress: Double {
        guard isCurrent, player.duration > 0 else { return 0 }
        return min(max(player.currentTime / player.duration, 0), 1)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            artwork
            VStack(alignment: .leading, spacing: 10) {
                titleRow
                waveformStrip
                actionRow
            }
        }
        .padding(.vertical, 4)
        .trackContextMenu(track, player: player)
        .task(id: track.id) {
            guard let library else { return }
            await comments.load(track, api: library.api)
        }
    }

    private var artwork: some View {
        NavButton(value: track) {
            Artwork(track, size: .mid)
            .frame(width: metrics.listArtwork, height: metrics.listArtwork)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .lockedLook(track)
        }
        .buttonStyle(.plain)
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: play) {
                PlayFAB(size: 34, isPlaying: isPlaying)
            }
            .buttonStyle(PlayerButtonStyle())
            .disabled(!track.isPlayable)
            .lockedLook(track)
            .help(track.lockNote ?? "")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    NavButton(value: track.user) {
                        Text(track.artistLine)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)

                    if let reposter {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.system(size: 10))
                            .foregroundStyle(.tint)
                        NavButton(value: reposter) {
                            Text(reposter.username)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 6) {
                    NavButton(value: track) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .lockedLook(track)
                    AvailabilityBadge(track: track)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                if let age = track.ageLabel {
                    Text(age).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let genre = track.genre, !genre.isEmpty {
                    Text("#\(genre)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .lineLimit(1)
                }
            }
        }
    }

    private var waveformStrip: some View {
        WaveformStrip(track: track,
                      progress: progress,
                      currentTime: isCurrent ? player.currentTime : 0,
                      isCurrent: isCurrent,
                      comments: comments.comments(for: track),
                      onScrub: scrub)
            .frame(height: Self.waveHeight)
            .lockedLook(track)
            .allowsHitTesting(track.isPlayable)
    }

    private static let waveHeight: CGFloat = 48

    private var actionRow: some View {
        HStack(spacing: 8) {
            statButton(
                symbol: isLiked ? "heart.fill" : "heart",
                count: track.likesCount,
                isOn: isLiked) { library?.toggleLike(track) }

            statButton(
                symbol: "arrow.2.squarepath",
                count: track.repostsCount,
                isOn: isReposted) { library?.toggleRepost(track) }

            Spacer(minLength: 8)

            if let plays = track.playbackCount {
                stat("play.fill", plays)
            }
            if let comments = track.commentCount {
                stat("text.bubble", comments)
            }
        }
        .font(.system(size: 11))
    }

    private var isLiked: Bool { library?.isLiked(track) ?? false }
    private var isReposted: Bool { library?.isReposted(track) ?? false }

    private func statButton(symbol: String, count: Int?, isOn: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                if let count, count > 0 { Text(countString(count)).monospacedDigit() }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(PlayerButtonStyle())
        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }

    private func stat(_ symbol: String, _ count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(countString(count)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    private func play() {
        if isCurrent {
            player.togglePlayPause()
        } else {
            Task { await queue.start(track, on: player) }
        }
    }

    /// Clicking the waveform seeks the playing track, and starts this one otherwise — SoundCloud
    /// treats the strip as the track's own scrubber either way.
    private func scrub(to ratio: Double) {
        guard isCurrent else {
            play()
            return
        }
        player.seek(to: ratio * player.duration)
    }
}

#if DEBUG
#Preview("Like card") {
    let model = AppModel()
    let track = previewStripTrack(comments: 5)
    WaveformCommentsLoader.seedCache(track.urn, [
        sampleComment(1, "Кирилл Мельников", "легенда", 6955, likes: 3),
        sampleComment(2, "FAX UT", "лучший трек года, серьёзно", 39650),
        sampleComment(3, "DJ 7up", "только мы вдвоем", 105993, likes: 12),
        sampleComment(4, "darinkas", "🔥", 148000),
        sampleComment(5, "wmelon", "пацы, кто фит??? пишите мне в комы под трэками", 168000),
    ])
    return VStack(spacing: 0) {
        LikeCard(track: track, player: model.player, queue: .exactly([track]))
            .padding(20)
    }
    .frame(width: 760)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(model.library)
    .tint(.scOrange)
}
#endif
