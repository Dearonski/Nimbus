import AVFoundation
import NukeUI
import SwiftUI

// MARK: - Floating player pill (Apple Music style, bottom-centered)

struct PlayerPill: View {
    /// Bottom space the detail content reserves so its last row clears the pill, which floats as an
    /// overlay and takes no layout space of its own.
    static let reservedHeight: CGFloat = 72

    let player: PlayerEngine
    var onOpenTrack: (SCTrack) -> Void = { _ in }
    var onOpenArtist: (SCUser) -> Void = { _ in }

    @Environment(LibraryStore.self) private var library: LibraryStore?

    var body: some View {
        PlayerPillContent(
            track: player.currentTrack,
            isPlaying: player.isPlaying,
            currentTime: player.currentTime,
            duration: player.duration,
            isShuffled: player.isShuffled,
            repeatMode: player.repeatMode,
            canPrevious: player.canGoPrevious,
            canNext: player.canGoNext,
            volume: Binding(
                get: { Double(player.player.volume) },
                set: { player.player.volume = Float($0) }),
            isLiked: player.currentTrack.map { library?.isLiked($0) ?? false } ?? false,
            onToggle: { player.togglePlayPause() },
            onSeek: { player.seek(to: $0) },
            onShuffle: player.toggleShuffle,
            onRepeat: player.cycleRepeat,
            onPrevious: { Task { await player.previous() } },
            onNext: { Task { await player.next() } },
            onLike: { if let track = player.currentTrack { library?.toggleLike(track) } },
            onOpenTrack: onOpenTrack,
            onOpenArtist: onOpenArtist,
            player: player)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// Apple Music-style pill: transport left, now-playing + thin progress center, actions right.
struct PlayerPillContent: View {
    let track: SCTrack?
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    var isShuffled = false
    var repeatMode: RepeatMode = .off
    var canPrevious = false
    var canNext = false
    @Binding var volume: Double
    var isLiked = false
    let onToggle: () -> Void
    let onSeek: (Double) -> Void
    var onShuffle: () -> Void = {}
    var onRepeat: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var onLike: () -> Void = {}
    var onOpenTrack: (SCTrack) -> Void = { _ in }
    var onOpenArtist: (SCUser) -> Void = { _ in }
    var player: PlayerEngine? = nil

    var body: some View {
        HStack(spacing: 16) {
            transport
            nowPlaying.frame(maxWidth: .infinity)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 3)
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button(action: onShuffle) { Image(systemName: "shuffle") }
                .foregroundStyle(isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Button(action: onPrevious) { Image(systemName: "backward.fill") }
                .disabled(!canPrevious)
            Button(action: onToggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20))
            }
            .disabled(track == nil)
            Button(action: onNext) { Image(systemName: "forward.fill") }
                .disabled(!canNext)
            Button(action: onRepeat) {
                Image(systemName: repeatMode == .one ? "repeat.1" : "repeat")
            }
            .foregroundStyle(repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .font(.system(size: 13))
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }

    private var nowPlaying: some View {
        HStack(spacing: 8) {
            Button { if let track { onOpenTrack(track) } } label: {
                LazyImage(url: track?.artworkURL.scArtwork("t300x300")) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(track == nil)

            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Button { if let track { onOpenTrack(track) } } label: {
                        Text(track?.title ?? "Not Playing")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(track == nil)

                    if let track {
                        Text("·").font(.system(size: 12)).foregroundStyle(.tertiary)
                        Button { onOpenArtist(track.user) } label: {
                            Text(track.artistLine)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ProgressScrubber(currentTime: currentTime, duration: duration, onSeek: onSeek)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Button(action: onLike) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
            }
            .foregroundStyle(isLiked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .disabled(track == nil)

            if let player {
                QueueButton(player: player)
            }
            VolumeButton(volume: $volume)
        }
        .font(.system(size: 13))
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

/// Thin, knob-less progress line (tint-filled) with tap/drag to seek — Apple Music style.
struct ProgressScrubber: View {
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.3))
                Capsule().fill(.tint).frame(width: geo.size.width * fraction)
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    guard duration > 0 else { return }
                    let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                    onSeek(fraction * duration)
                })
        }
        .frame(height: 12)
    }
}

struct VolumeButton: View {
    @Binding var volume: Double
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showPopover) {
            Slider(value: $volume, in: 0...1).frame(width: 120).padding()
        }
    }
}
