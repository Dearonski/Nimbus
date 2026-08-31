import NukeUI
import SwiftUI

/// A liked track the way SoundCloud lists it: cover, uploader and title, the waveform across the
/// full width, and the like/repost row underneath — not a table line.
struct LikeCard: View {
    let track: SCTrack
    let player: PlayerEngine
    var context: [SCTrack] = []
    /// Overrides how playback starts, so a page backed by a paginated collection can queue the whole
    /// thing instead of the rows it has loaded.
    var onPlay: ((SCTrack) -> Void)? = nil

    @Environment(\.metrics) private var metrics
    @Environment(LibraryStore.self) private var library: LibraryStore?

    @State private var waveform = WaveformLoader()
    @State private var hovering = false
    @State private var waveformWidth: CGFloat = 1
    @State private var hoverX: CGFloat?

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
        .onHover { hovering = $0 }
        .task(id: track.id) { waveform.load(track.waveformURL) }
    }

    private var artwork: some View {
        NavigationLink(value: track) {
            LazyImage(url: track.artworkURL.scArtwork()) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: metrics.listArtwork, height: metrics.listArtwork)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: play) {
                ZStack {
                    Circle().fill(.tint)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(PlayerButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                NavigationLink(value: track.user) {
                    Text(track.artistLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                NavigationLink(value: track) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
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
        WaveformView(waveform: waveform.waveform,
                     progress: progress,
                     hoverProgress: hoverProgress)
            .frame(height: Self.waveHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                if isCurrent {
                    timeBadge(timeString(player.currentTime), accent: true)
                        .padding(.bottom, Self.reflectionZone)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                timeBadge(timeString(Double(track.duration) / 1000), accent: false)
                    .padding(.bottom, Self.reflectionZone)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                waveformWidth = max(width, 1)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = min(max(point.x, 0), waveformWidth)
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in scrub(toX: value.location.x) })
    }

    private var hoverProgress: Double {
        guard let hoverX else { return 0 }
        return min(max(hoverX / waveformWidth, 0), 1)
    }

    /// Height of the reflection plus the centre gap — the badges sit on the upright half, clear of
    /// the mirrored bars below it.
    private static let waveHeight: CGFloat = 48
    private static let reflectionZone: CGFloat = (waveHeight - 2) * 0.32 + 2

    private func timeBadge(_ text: String, accent: Bool) -> some View {
        Text(text)
            .font(.system(size: 10)).monospacedDigit()
            .foregroundStyle(accent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
    }

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
        } else if let onPlay {
            onPlay(track)
        } else {
            Task { await player.play(track, in: context.isEmpty ? [track] : context) }
        }
    }

    /// Clicking the waveform seeks the playing track, and starts this one otherwise — SoundCloud
    /// treats the strip as the track's own scrubber either way.
    private func scrub(toX x: CGFloat) {
        guard isCurrent else {
            play()
            return
        }
        player.seek(to: min(max(x / waveformWidth, 0), 1) * player.duration)
    }
}
