import AVFoundation
import NukeUI
import SwiftUI

// MARK: - Floating player pill (Apple Music style, bottom-centered)

struct PlayerPill: View {
    /// Bottom space the detail content reserves so its last row clears the pill, which floats as an
    /// overlay and takes no layout space of its own.
    static let reservedHeight: CGFloat = 80

    let player: PlayerEngine
    var onOpenTrack: (SCTrack) -> Void = { _ in }
    var onOpenArtist: (SCUser) -> Void = { _ in }
    @Binding var isQueueVisible: Bool

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
            onToggle: { withAnimation(.snappy(duration: 0.18)) { player.togglePlayPause() } },
            onSeek: { player.seek(to: $0) },
            onShuffle: player.toggleShuffle,
            onRepeat: player.cycleRepeat,
            onPrevious: { Task { await player.previous() } },
            onNext: { Task { await player.next() } },
            onLike: { if let track = player.currentTrack { library?.toggleLike(track) } },
            onOpenTrack: onOpenTrack,
            onOpenArtist: onOpenArtist,
            isQueueVisible: $isQueueVisible)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }
}

/// Apple Music-style pill: transport left, an LCD panel center (artwork, two lines of metadata, a
/// progress line hugging the bottom edge), actions right. Hovering the LCD blurs the metadata back
/// and floats the timings over it, the way Music hands the panel over to scrubbing.
struct PlayerPillContent: View {
    private static let artworkSize: CGFloat = 34

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
    var isQueueVisible: Binding<Bool>? = nil
    /// Lets a #Preview render the scrubbing state, which has no pointer to hover it.
    var forceScrubbing = false

    @State private var hoveringScrubber = false
    @State private var dragFraction: Double?

    /// Drag position wins over the engine clock so the line follows the pointer instead of snapping
    /// back between the gesture and the next time update.
    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0, currentTime.isFinite else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private var isScrubbing: Bool { forceScrubbing || hoveringScrubber || dragFraction != nil }

    var body: some View {
        HStack(spacing: 16) {
            transport
            nowPlaying
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous).strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            modeButton("shuffle", isOn: isShuffled, action: onShuffle)
            SkipButton(forward: false, action: onPrevious)
                .disabled(!canPrevious)
            Button(action: onToggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .contentTransition(.symbolEffect(.replace))
                    // play.fill and pause.fill differ in width; a fixed box keeps the row from
                    // shifting every time playback toggles.
                    .frame(width: 28)
            }
            .buttonStyle(PlayerButtonStyle(animatesPress: false))
            .disabled(track == nil)
            SkipButton(forward: true, action: onNext)
                .disabled(!canNext)
            modeButton(repeatMode == .one ? "repeat.1" : "repeat",
                       isOn: repeatMode != .off, action: onRepeat)
        }
        .font(.system(size: 15))
        .buttonStyle(PlayerButtonStyle())
        .foregroundStyle(.primary)
    }

    /// Shuffle and repeat carry a filled disc while on, the way Music badges its active modes.
    private func modeButton(_ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background { if isOn { Circle().fill(.tint.opacity(0.16)) } }
        }
    }

    private var nowPlaying: some View {
        ZStack {
            metadata
                .blur(radius: isScrubbing ? 5 : 0)
                .opacity(isScrubbing ? 0.25 : 1)
            if isScrubbing {
                timings
            }
        }
        .frame(height: Self.artworkSize)
        .frame(maxWidth: .infinity)
        // The line hangs below the row rather than sitting in it, so transport and actions stay
        // centred on the same axis as the artwork and the pill's padding stays symmetric.
        .overlay(alignment: .bottom) {
            ProgressScrubber(
                fraction: fraction,
                duration: duration,
                isExpanded: isScrubbing,
                isHovered: $hoveringScrubber,
                dragFraction: $dragFraction,
                onSeek: onSeek)
            .offset(y: 6.5)
        }
        .animation(.easeOut(duration: 0.15), value: isScrubbing)
    }

    private var metadata: some View {
        HStack(spacing: 10) {
            Button { if let track { onOpenTrack(track) } } label: {
                LazyImage(url: track?.artworkURL.scArtwork("t300x300")) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(track == nil)

            VStack(alignment: .leading, spacing: 1) {
                Button { if let track { onOpenTrack(track) } } label: {
                    Text(track?.title ?? "Not Playing")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .disabled(track == nil)

                Button { if let track { onOpenArtist(track.user) } } label: {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .disabled(track == nil)
            }

            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        guard let track else { return "—" }
        guard let album = track.album, !album.isEmpty else { return track.artistLine }
        return "\(track.artistLine) — \(album)"
    }

    /// Same roll either way, only quicker under the pointer: at playback speed a digit changes once
    /// a second, while a drag fires them far faster and a long roll would trail the cursor.
    private var rollAnimation: Animation {
        dragFraction == nil ? .snappy(duration: 0.25) : .snappy(duration: 0.12)
    }

    private var timings: some View {
        let elapsed = fraction * duration
        let remaining = max(duration - elapsed, 0)
        // Animated on whole seconds: the clock ticks far more often than the digits change, and
        // animating the raw value would restart the roll on every update.
        return HStack(spacing: 8) {
            Text(timeString(elapsed))
                .contentTransition(.numericText(value: elapsed))
                .animation(rollAnimation, value: Int(elapsed))
            Spacer(minLength: 0)
            Text(duration > 0 ? "-\(timeString(remaining))" : "-0:00")
                .contentTransition(.numericText(countsDown: true))
                .animation(rollAnimation, value: Int(remaining))
        }
        .font(.system(size: 13, weight: .medium))
        .monospacedDigit()
        .transition(.opacity)
    }

    private var actions: some View {
        HStack(spacing: 15) {
            Button(action: onLike) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(isLiked ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .disabled(track == nil)

            if let isQueueVisible {
                QueueButton(isVisible: isQueueVisible)
            }
            VolumeButton(volume: $volume)
        }
        .font(.system(size: 15))
        .buttonStyle(PlayerButtonStyle())
        .foregroundStyle(.primary)
    }
}

/// Transport buttons dip and dim on press — plain `.borderless` gives no press feedback at all, and
/// a custom style also has to dim the disabled state itself.
struct PlayerButtonStyle: ButtonStyle {
    /// Play/pause opts out: its symbol replace is already a scale animation, and a second scale on
    /// release reads as the same animation playing twice.
    var animatesPress = true

    func makeBody(configuration: Configuration) -> some View {
        if animatesPress {
            PressableLabel(configuration: configuration)
        } else {
            FlatLabel(configuration: configuration)
        }
    }

    private struct PressableLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        @State private var pressed = false

        var body: some View {
            configuration.label
                .scaleEffect(pressed ? 0.88 : 1)
                .opacity(isEnabled ? (pressed ? 0.55 : 1) : 0.3)
                // Driving an own state instead of `.animation(value: isPressed)` on the label: that
                // modifier re-runs every animation inside it on release.
                .onChange(of: configuration.isPressed) { _, isPressed in
                    withAnimation(.snappy(duration: 0.16)) { pressed = isPressed }
                }
        }
    }

    private struct FlatLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            configuration.label
                .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.3)
        }
    }
}

/// Music's skip buttons: on press the chevrons advance one slot toward the side they point at —
/// the leading one shrinks away as it leaves and a fresh one grows in behind, rather than being
/// clipped off. Three glyphs ride two visible slots, so the phase can snap back unanimated.
struct SkipButton: View {
    let forward: Bool
    let action: () -> Void

    private static let glyphSize: CGFloat = 13
    private static let step: CGFloat = 10
    private static let width: CGFloat = 21

    @State private var phase: CGFloat = 0

    var body: some View {
        Button {
            action()
            withAnimation(.snappy(duration: 0.42, extraBounce: 0.12)) {
                phase = 1
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { phase = 0 }
            }
        } label: {
            ZStack(alignment: .leading) {
                ForEach(0..<3, id: \.self) { slot in
                    Image(systemName: "play.fill")
                        .font(.system(size: Self.glyphSize))
                        .scaleEffect(presence(slot))
                        .opacity(presence(slot))
                        .offset(x: (CGFloat(slot) - 1 + phase) * Self.step)
                }
            }
            .frame(width: Self.width, alignment: .leading)
            // Drawn as a forward button and mirrored for previous, so one set of offsets covers both.
            .scaleEffect(x: forward ? 1 : -1)
        }
        .buttonStyle(PlayerButtonStyle(animatesPress: false))
    }

    /// Slot 0 is the one growing in, slot 2 the one shrinking away; the middle one stays whole.
    private func presence(_ slot: Int) -> CGFloat {
        switch slot {
        case 0: phase
        case 2: 1 - phase
        default: 1
        }
    }
}

/// Progress line pinned to the bottom of the pill: thin at rest, thick while hovered or dragged,
/// with a knob only during an actual drag — the timings live just above it.
struct ProgressScrubber: View {
    let fraction: Double
    let duration: Double
    let isExpanded: Bool
    /// Hover is detected here, not on the whole panel: Music hands over to scrubbing only when the
    /// pointer is actually on the line. The pill owns the resulting state.
    @Binding var isHovered: Bool
    @Binding var dragFraction: Double?
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(.secondary.opacity(0.28))
                // A square-ended fill clipped by the track: rounding the played end makes the head
                // drift away from the true position and look wrong at low progress.
                Rectangle().fill(.tint).frame(width: width * fraction)
            }
            .clipShape(Capsule())
            .frame(height: isExpanded ? 8 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // Offset, not padding: the line rises on hover but its hit area stays where it is,
            // so the pointer can't fall out of the zone the moment it expands.
            .offset(y: isExpanded ? -4.5 : 0)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        dragFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        defer { dragFraction = nil }
                        guard duration > 0, width > 0 else { return }
                        onSeek(min(max(value.location.x / width, 0), 1) * duration)
                    })
        }
        // Grows upward once active (the row is bottom-anchored), so the pointer keeps a wide band
        // to travel in — a 10pt strip is far too easy to slip out of mid-scrub.
        .frame(height: isExpanded ? 24 : 10)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isExpanded)
    }
}

struct VolumeButton: View {
    @Binding var volume: Double
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .popover(isPresented: $showPopover) {
            Slider(value: $volume, in: 0...1).frame(width: 120).padding()
        }
    }
}
