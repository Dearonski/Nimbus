import SwiftUI

/// An album or playlist the way the site posts one: cover, title, the opening tracks numbered
/// underneath, and a way into the rest. On SoundCloud a set is a post in the timeline, not a table
/// row — which is why the artist page listed albums in a line that said almost nothing about them.
struct SetCard: View {
    let playlist: SCPlaylist
    let model: AppModel
    /// Same as on a track card: a repost is written into the byline, not announced above it.
    var reposter: SCUser?

    /// The site shows five and hides the rest behind a link. Enough to recognise a record by its
    /// opening, short enough that a long album does not swallow the page.
    private static let listed = 5

    /// What `CardCollection` measures by: only the number of listed tracks changes a set's height.
    static func heightVariant(of playlist: SCPlaylist) -> AnyHashable {
        ["set", min(playlist.hydratedTracks.count, listed)] as [AnyHashable]
    }

    @Environment(\.metrics) private var metrics
    @State private var isStarting = false

    private var shown: [SCTrack] { Array(playlist.hydratedTracks.prefix(Self.listed)) }
    private var isCurrentSet: Bool {
        guard let current = model.player.currentTrack else { return false }
        return playlist.trackIDs.contains(current.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            NavButton(value: playlist) {
                Artwork(playlist, size: .mid)
                    .frame(width: metrics.listArtwork, height: metrics.listArtwork)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 10) {
                titleRow
                if !shown.isEmpty { trackList }
                footer
            }
        }
        .padding(.vertical, 4)
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: play) {
                PlayFAB(size: 34, isStarting: isStarting)
            }
            .buttonStyle(PlayerButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let author = playlist.user {
                        NavButton(value: author) {
                            Text(author.username)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
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
                NavButton(value: playlist) {
                    HStack(spacing: 6) {
                        Text(playlist.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isCurrentSet ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        Text(playlist.isAlbum ? "Album" : "Playlist")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            if let age = playlist.ageLabel {
                Text(age)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, track in
                SetTrackLine(number: index + 1, track: track, player: model.player,
                             queue: .exactly(playlist.hydratedTracks))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if playlist.trackCount > shown.count {
                NavButton(value: playlist) {
                    Text("View all \(playlist.trackCount) tracks")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            stat("heart", playlist.likesCount)
            stat("arrow.2.squarepath", playlist.repostsCount)
            stat("music.note.list", playlist.trackCount)
            if let duration = playlist.duration, duration > 0 {
                Text(longDurationString(ms: duration))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func stat(_ symbol: String, _ value: Int?) -> some View {
        if let value, value > 0 {
            Label(countString(value), systemImage: symbol)
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.secondary)
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

/// One line of a set's track list: rank, title, plays — the shape the site uses inside an album
/// post, where a full row would repeat the cover and artist on every line.
private struct SetTrackLine: View {
    let number: Int
    let track: SCTrack
    let player: PlayerEngine
    let queue: PlayQueue

    @State private var hovering = false

    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)

            Artwork(track, size: .thumb)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Text(track.title)
                .font(.system(size: 13))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .lineLimit(1)

            Spacer(minLength: 12)

            if let plays = track.playbackCount {
                Label(countString(plays), systemImage: "play.fill")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.06))
                .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { Task { await queue.start(track, on: player) } }
        .trackContextMenu(track, player: player)
    }
}
