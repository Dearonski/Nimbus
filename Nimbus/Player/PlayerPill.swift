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
                get: { Double(player.volume) },
                set: { player.volume = Float($0) }),
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
    var forceVolumeExpanded = false

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
        HStack(spacing: 8) {
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
        HStack(spacing: PlayerButtonStyle.actionSpacing) {
            Button(action: onLike) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(isLiked ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .disabled(track == nil)

            if let isQueueVisible {
                QueueButton(isVisible: isQueueVisible)
            }
            VolumeButton(volume: $volume, forceExpanded: forceVolumeExpanded)
        }
        .font(.system(size: 17))
        .buttonStyle(PlayerButtonStyle())
        .foregroundStyle(.primary)
    }
}

/// Transport buttons dip and dim on press — plain `.borderless` gives no press feedback at all, and
/// a custom style also has to dim the disabled state itself. It also sets the hit target: a bare
/// glyph is only clickable on its own strokes, which at 15pt is a target a few points wide.
struct PlayerButtonStyle: ButtonStyle {
    static let hitTarget: CGFloat = 32
    /// Gap between buttons in the actions row; the volume panel measures itself against it.
    static let actionSpacing: CGFloat = 4

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
                .frame(minWidth: PlayerButtonStyle.hitTarget, minHeight: PlayerButtonStyle.hitTarget)
                .contentShape(Rectangle())
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
                .frame(minWidth: PlayerButtonStyle.hitTarget, minHeight: PlayerButtonStyle.hitTarget)
                .contentShape(Rectangle())
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

/// Music's volume control: the first click slides a panel out over the buttons to its left, the
/// next one mutes.
///
/// The panel is a sibling of the icon, not its background: nested, every rebuild of the button —
/// and the glyph rebuilds whenever the level crosses a wave threshold — tore up the panel with it
/// and cancelled a drag in progress. Both sit in a fixed-size container instead, so the row's
/// layout never moves and the two cannot disturb each other.
struct VolumeButton: View {
    @Binding var volume: Double
    /// A preview has no pointer, so the panel needs a way to be shown for a render.
    var forceExpanded = false
    /// Where to come back to on unmute — a mute that forgot the level would be a reset, not a mute.
    @State private var premute: Double = 1
    @State private var isOpen = false
    @State private var overIcon = false
    @State private var overPanel = false
    @State private var dragging = false
    @State private var closeTask: Task<Void, Never>?

    private static let inset: CGFloat = 16
    /// How far the capsule reaches past the slots at each end, so it doesn't stop flush with the
    /// icons it covers.
    private static let overhang: CGFloat = 8
    /// A little past the buttons it covers, into the metadata — enough to make the bar worth
    /// dragging without the capsule swallowing the track title.
    private static let reach: CGFloat = 8
    private static let panelWidth = PlayerButtonStyle.hitTarget * 3
        + PlayerButtonStyle.actionSpacing * 2 + overhang * 2 + reach
    private static let panelHeight: CGFloat = 40

    private var expanded: Bool { isOpen || forceExpanded }

    var body: some View {
        Color.clear
            .frame(width: PlayerButtonStyle.hitTarget, height: PlayerButtonStyle.hitTarget)
            .overlay(alignment: .trailing) {
                if expanded {
                    panel.offset(x: Self.overhang).transition(.opacity)
                }
            }
            .overlay(alignment: .trailing) { icon }
            // A drag that ends with the pointer already outside gets no further hover event, so the
            // panel has to be given its chance to close when the drag itself finishes.
            .onChange(of: dragging) { _, isDragging in
                if !isDragging { closeIfAway() }
            }
            .animation(.snappy(duration: 0.22), value: expanded)
    }

    private var icon: some View {
        Button {
            if expanded { toggleMute() } else { isOpen = true }
        } label: {
            VolumeGlyph(volume: volume)
        }
        .buttonStyle(PlayerButtonStyle(animatesPress: false))
        .help(expanded ? (volume > 0 ? "Mute" : "Unmute") : "Volume")
        // `onContinuousHover` reports an explicit `.ended`; `onHover` can simply never deliver its
        // false, which left the panel open with no way to dismiss it.
        .onContinuousHover { phase in
            overIcon = isActive(phase)
            closeIfAway()
        }
    }

    private var panel: some View {
        HStack(spacing: 0) {
            VolumeBar(volume: $volume, dragging: $dragging)
                .padding(.leading, Self.inset)
                .padding(.trailing, 8)
            // The icon is drawn over this; leave it its slot plus the margin past it.
            Color.clear.frame(width: PlayerButtonStyle.hitTarget + Self.overhang)
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .background {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay { Capsule(style: .continuous).strokeBorder(.primary.opacity(0.08)) }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
        .contentShape(Capsule(style: .continuous))
        .onContinuousHover { phase in
            overPanel = isActive(phase)
            closeIfAway()
        }
    }

    private func isActive(_ phase: HoverPhase) -> Bool {
        if case .active = phase { return true }
        return false
    }

    /// Deferred, because the two hover regions hand over rather than overlap: crossing from the
    /// icon to the panel reports the icon as left before the panel reports as entered, and closing
    /// on that instant snaps the panel shut just as the pointer reaches for the bar.
    private func closeIfAway() {
        closeTask?.cancel()
        guard !overIcon, !overPanel, !dragging else { return }
        closeTask = Task {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, !overIcon, !overPanel, !dragging else { return }
            isOpen = false
        }
    }

    private func toggleMute() {
        if volume > 0 {
            premute = volume
            volume = 0
        } else {
            volume = premute > 0 ? premute : 1
        }
    }
}

/// A knob-less capsule, the way Music draws volume and the way the pill already draws progress.
private struct VolumeBar: View {
    @Binding var volume: Double
    @Binding var dragging: Bool
    var thickness: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.22))
                // Square-ended and clipped by the track, the same way the scrubber draws its played
                // part: a rounded head sits short of the level it is meant to mark.
                Rectangle().fill(.primary).frame(width: width * volume)
            }
            .clipShape(Capsule())
            .frame(height: thickness)
            // The line is 7pt but the target is the whole height of the panel: aiming at the line
            // itself is the same trap the scrubber's 10pt strip was.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        volume = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { _ in dragging = false })
        }
    }
}

/// The speaker, its waves and the mute stroke.
///
/// Two things are settled by measurement rather than by the API. `.symbolEffect(.replace.magic)`
/// refuses this pair and falls back to scaling the whole glyph away and back, which — frame by
/// frame against a recording of Music — is the one thing the system's own control never does. And
/// Music does not use `speaker.slash.fill` at all: its stroke runs from the bottom left up to the
/// right, where the system symbol's runs the other way. So the waves are system symbols and the
/// stroke is ours.
///
/// The symbols are laid out against the leading edge on purpose. Rendered at 64pt, `speaker.fill`
/// and every `speaker.wave.N.fill` place the body at the same offset from that edge, so swapping
/// between them leaves the body still; centring them instead made it jump, since the glyphs are
/// 64 to 103pt wide.
private struct VolumeGlyph: View {
    let volume: Double

    /// The glyph's own size. Measured against Music, whose volume symbol takes about 0.29 of the
    /// pill's height where ours took 0.20; matching it exactly would need 21pt and tower over the
    /// like and queue icons beside it, so the whole row moved up together instead.
    private static let font: CGFloat = 17
    /// Wide enough for three waves plus the stroke's overshoot.
    private static let box: CGFloat = 22
    /// The speaker on its own, which is what the stroke is centred on.
    private static let bodyBox: CGFloat = 17

    /// Layout widths at 64pt, measured off the rendered symbols. The body sits at the same offset
    /// from the leading edge in all of them, so the difference in width is the whole story of where
    /// a centred glyph puts its body.
    private static let widths: [String: CGFloat] = [
        "speaker.fill": 64, "speaker.wave.1.fill": 75,
        "speaker.wave.2.fill": 89, "speaker.wave.3.fill": 103,
    ]

    private var muted: Bool { volume <= 0.001 }
    private var target: String { Self.symbol(for: volume) }

    private static func symbol(for volume: Double) -> String {
        switch volume {
        case ..<0.001: "speaker.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    /// Where the body has to sit to land exactly on the one inside the wave symbol beneath it.
    private var bodyOffset: CGFloat {
        let width = Self.widths[shown] ?? 64
        return (64 - width) * Self.font / 128
    }

    /// Mirrored into state and driven by an explicit `withAnimation`: `.animation(_:value:)` on a
    /// view that a button rebuilds around it never ran, which is why the waves simply appeared.
    /// Seeded from the level so the first appearance is not itself a transition.
    @State private var shown: String
    @State private var slash: CGFloat

    init(volume: Double) {
        self.volume = volume
        _shown = State(initialValue: Self.symbol(for: volume))
        _slash = State(initialValue: volume <= 0.001 ? 1 : 0)
    }

    var body: some View {
        ZStack {
            // The waves. Its own body is hidden by the layer above, so scaling and fading this one
            // never touches the speaker.
            Image(systemName: shown)
                .id(shown)
                // Scaled from the leading edge, where the body sits, so the wave grows outward from
                // the speaker. Measured on Music: adding a wave widens the glyph over several
                // frames rather than fading it in at full size.
                .transition(.scale(scale: 0.88, anchor: .leading).combined(with: .opacity))

            // The speaker, drawn opaque on top and given nothing but a position: the body is asked
            // to move as the glyph recentres and to do nothing else.
            Image(systemName: "speaker.fill")
                .offset(x: bodyOffset)
        }
        .font(.system(size: Self.font, weight: .semibold))
        .frame(width: Self.box, height: Self.box)
        // Punched through rather than painted in the background colour: the panel is a material,
        // so there is no flat colour to fake the gap with.
        .overlay { stroke(width: 2.2).blendMode(.destinationOut) }
        .compositingGroup()
        // Thinner and greyer than the glyph it crosses: measured, Music draws the stroke at about
        // four fifths of the body's brightness and half the thickness ours had.
        .overlay { stroke(width: 1.0).opacity(0.8) }
        .onChange(of: target, initial: true) { _, new in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) { shown = new }
        }
        .onChange(of: muted, initial: true) { _, isMuted in
            // Music lets the waves settle before retracting the stroke; muting draws it at once.
            withAnimation(.smooth(duration: 0.24).delay(isMuted ? 0 : 0.05)) {
                slash = isMuted ? 1 : 0
            }
        }
    }

    private func stroke(width: CGFloat) -> some View {
        MuteStroke()
            .trim(from: 0, to: slash)
            .stroke(style: StrokeStyle(lineWidth: width, lineCap: .round))
            .frame(width: Self.bodyBox, height: Self.bodyBox)
    }
}

/// Bottom left to top right — the direction Music draws it, which is the opposite of the one
/// `speaker.slash.fill` uses.
private struct MuteStroke: Shape {
    func path(in rect: CGRect) -> Path {
        // Measured against Music, the stroke runs about 2.1 times the width of the speaker body.
        // Across this box that lands at a small inset rather than a large one.
        let inset = rect.width * 0.07
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        return path
    }
}
