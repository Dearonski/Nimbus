import AppKit
import SwiftUI

/// The block a set's page opens with, on the same frame as `TrackHero`: play, title and byline top
/// left, artwork on the right, actions along the bottom. The middle follows the site — the track
/// count and length while nothing from the set plays, and the waveform of the track that does
/// once one starts.
struct PlaylistHero: View {
    let page: PlaylistPageModel
    let model: AppModel

    @Environment(\.metrics) private var metrics
    @Environment(PageRoom.self) private var room: PageRoom?
    @Environment(\.openURL) private var openURL

    @State private var comments = WaveformCommentsLoader()

    private var playlist: SCPlaylist { page.playlist }
    private var player: PlayerEngine { model.player }

    /// The track from this set that is on air. Membership, not queue identity: the same album
    /// started from the artist page is still this album playing.
    private var current: SCTrack? {
        guard let now = player.currentTrack else { return nil }
        return page.tracks.first { $0.id == now.id }
    }

    private var currentNumber: Int? {
        guard let current else { return nil }
        return page.tracks.firstIndex { $0.id == current.id }.map { $0 + 1 }
    }

    private var isPlaying: Bool { current != nil && player.isPlaying }

    private var progress: Double {
        guard current != nil, player.duration > 0 else { return 0 }
        return min(max(player.currentTime / player.duration, 0), 1)
    }

    private var artworkSize: CGFloat {
        TrackDetailView.showsRail(in: room, usable: metrics.usable) ? TrackDetailView.railWidth : 240
    }

    /// The track hero's ratio, so the strip lands at the same height on both pages.
    private var middleHeight: CGFloat { artworkSize * 0.39 }

    private var permalink: URL? { playlist.permalinkURL.flatMap(URL.init) }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 0) {
                headline
                Spacer(minLength: 12)
                middle
                    .frame(height: middleHeight)
                    // The hovered comment's line can reach the action row; it has to stay on top.
                    .zIndex(1)
                Spacer(minLength: 12)
                bottomBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Artwork(playlist, size: .hero)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opensArtwork(playlist.coverURL, preview: .hero, title: playlist.title)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
        .padding(TrackHero.contentInset)
        .frame(minHeight: artworkSize + TrackHero.contentInset * 2)
        .background {
            // Cropped before the blur: a filled square cover would otherwise be blurred whole.
            Artwork(playlist, size: .hero)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 60, opaque: true)
                .overlay(Color.black.opacity(0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.snappy, value: artworkSize)
        .task(id: current?.id) {
            guard let current else { return }
            await comments.load(current, api: model.api)
        }
    }

    private var headline: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                PlayFAB(size: 56, isPlaying: isPlaying)
            }
            .buttonStyle(PlayerButtonStyle())
            .disabled(page.tracks.isEmpty)

            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.title)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let user = page.author ?? playlist.user, !playlist.isSystem {
                        NavButton(value: user) {
                            HStack(spacing: 5) {
                                Text(user.username)
                                if user.verified == true {
                                    Image(systemName: "checkmark.seal.fill").font(.system(size: 11))
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Text("·")
                    }
                    if playlist.isSystem, let madeFor = playlist.madeFor {
                        Text("Made for \(madeFor.username)")
                    } else {
                        Text(playlist.kindLabel)
                    }
                    if let genre = playlist.genre, !genre.isEmpty {
                        Text("· \(genre)")
                    }
                    if let age = playlist.ageLabel {
                        Text("· \(age)")
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var middle: some View {
        if let current {
            WaveformStrip(track: current,
                          progress: progress,
                          currentTime: player.currentTime,
                          isCurrent: true,
                          comments: comments.comments,
                          style: .hero) { ratio in
                player.seek(to: ratio * player.duration)
            }
            .overlay(alignment: .topLeading) {
                if let currentNumber {
                    // Which of the set's tracks the strip belongs to — without it the waveform
                    // reads as the album's own.
                    Text("\(currentNumber) · \(current.title)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .frame(maxWidth: 360, alignment: .leading)
                }
            }
        } else {
            TracksSummary(count: page.trackCount, milliseconds: page.duration)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
            }
            .glassButton()
            .disabled(page.tracks.isEmpty)

            if !playlist.isSystem {
                let isLiked = model.library.isLiked(playlist)
                Button { model.library.toggleLike(playlist) } label: {
                    Label(countString(playlist.likesCount ?? 0), systemImage: isLiked ? "heart.fill" : "heart")
                }
                .glassButton(isLiked ? .prominent : .neutral)

                let isReposted = model.library.isReposted(playlist)
                Button { model.library.toggleRepost(playlist) } label: {
                    Label(countString(playlist.repostsCount ?? 0), systemImage: "arrow.2.squarepath")
                }
                .glassButton(isReposted ? .prominent : .neutral)
            }

            if let permalink {
                ShareLink(item: permalink) { Image(systemName: "square.and.arrow.up") }
                    .glassButton(.icon)
            }

            Menu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    enqueue(next: true)
                }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    enqueue(next: false)
                }
                if let permalink {
                    Divider()
                    Button("Copy Link", systemImage: "link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(permalink.absoluteString, forType: .string)
                    }
                    Button("Open in SoundCloud", systemImage: "safari") { openURL(permalink) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .glassButton(.icon)
            .fixedSize()
            .disabled(page.tracks.isEmpty)

            Spacer(minLength: 0)
        }
        .controlSize(.large)
        .glassButtonRow()
    }

    private func play() {
        if current != nil {
            player.togglePlayPause()
        } else if !page.tracks.isEmpty {
            Task { await PlayQueue.exactly(page.tracks).start(on: player) }
        }
    }

    private func shuffle() {
        guard !page.tracks.isEmpty else { return }
        Task { await PlayQueue.exactly(page.tracks).start(shuffled: true, on: player) }
    }

    private func enqueue(next: Bool) {
        guard !page.tracks.isEmpty else { return }
        // With nothing on air, each call would start playback of its own before a queue exists.
        guard player.currentTrack != nil else {
            play()
            return
        }
        if next {
            page.tracks.reversed().forEach(player.playNext)
        } else {
            page.tracks.forEach(player.playLater)
        }
    }
}

/// The site's circle in the hero's lower left while nothing from the set plays: how many tracks,
/// and how long it runs.
private struct TracksSummary: View {
    let count: Int
    let milliseconds: Int

    private var length: String {
        let seconds = milliseconds / 1000
        guard seconds >= 3600 else { return timeString(Double(seconds)) }
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    var body: some View {
        VStack(spacing: 1) {
            Text("\(count)")
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
            Text(count == 1 ? "TRACK" : "TRACKS")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
            if milliseconds > 0 {
                Text(length)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 96, height: 96)
        .background(Color.black.opacity(0.6), in: Circle())
    }
}

#if DEBUG
#Preview("Playlist hero") {
    let model = AppModel()
    let playlist = try! JSONDecoder().decode(SCPlaylist.self, from: Data("""
    {"id":1891647005,"title":"LOVESONGS","kind":"playlist","set_type":"album","is_album":true,
     "genre":"Pop","track_count":16,"duration":2611618,"likes_count":585,"reposts_count":9,
     "created_at":"2024-10-17T22:43:08Z","release_date":"2024-10-18T00:00:00Z",
     "permalink_url":"https://soundcloud.com/x/sets/lovesongs",
     "user":{"id":9,"username":"Дора","verified":true},"tracks":[]}
    """.utf8))
    let page = PlaylistPageModel(playlist: playlist, api: model.api, library: model.library)
    page.seedForPreview(tracks: [previewStripTrack(comments: 0)])
    return PlaylistHero(page: page, model: model)
        .padding(24)
        .environment(model.library)
        .frame(width: 1100, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.scOrange)
}
#endif
