import AppKit
import SwiftUI

/// The window's topmost view, so it keeps the rounded corners and the traffic lights stay above it.
@MainActor
@Observable
final class FullPlayerPresenter {
    private(set) var isOpen = false
    /// Drives the fade; the view stays in the window until the fade-out has run.
    private(set) var isShown = false

    @ObservationIgnored private var host: NSView?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Titlebar views this hid, to show again on the way out.
    @ObservationIgnored private var hiddenChrome: [NSView] = []
    /// Set when opening took the window into full screen, so closing brings it back out.
    @ObservationIgnored private var tookFullScreen = false
    @ObservationIgnored private var pending: (() -> AnyView)?
    @ObservationIgnored private var fullScreenWait: (any NSObjectProtocol)?

    func toggle(fullScreen: Bool, content: @escaping () -> AnyView) {
        if isOpen { close() } else { open(fullScreen: fullScreen, content: content) }
    }

    func open(fullScreen: Bool, content: @escaping () -> AnyView) {
        guard !isOpen, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        isOpen = true
        self.window = window
        if fullScreen && !window.styleMask.contains(.fullScreen) {
            tookFullScreen = true
            pending = content
            // Shown once the window has settled, so it doesn't fade in over the zoom animation.
            fullScreenWait = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteredFullScreen() }
            }
            window.toggleFullScreen(nil)
        } else {
            present(content())
        }
    }

    private func enteredFullScreen() {
        if let fullScreenWait { NotificationCenter.default.removeObserver(fullScreenWait) }
        fullScreenWait = nil
        if let pending { present(pending()) }
        pending = nil
    }

    func close() {
        guard isOpen, isShown else { return }
        showChrome()
        withAnimation(.easeIn(duration: 0.2)) {
            isShown = false
        } completion: {
            self.tearDown()
        }
    }

    private func present(_ content: AnyView) {
        guard isOpen, let window, let contentView = window.contentView, let frame = contentView.superview else { return }
        let host = NSHostingView(rootView: content.environment(self))
        host.sizingOptions = []
        // Always dark: AppKit colours in it (the mode buttons' grey) follow the view's appearance, not SwiftUI's scheme.
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = contentView.frame
        host.autoresizingMask = [.width, .height]
        // A sibling of the content (SwiftUI's root view takes no subviews), so still under the titlebar.
        frame.addSubview(host, positioned: .above, relativeTo: contentView)
        self.host = host
        hideChrome(of: window)

        // Left by the green button or the system's own shortcut: nothing for closing to undo.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tookFullScreen = false }
        })

        withAnimation(.easeOut(duration: 0.3)) { isShown = true }
    }

    /// Everything in the titlebar but the window buttons; turning the toolbar off would re-lay the whole window.
    private func hideChrome(of window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard var titlebar = buttons.first?.superview else { return }
        while let parent = titlebar.superview, parent !== window.contentView?.superview { titlebar = parent }

        func hide(in view: NSView) {
            for subview in view.subviews where !buttons.contains(where: { $0 === subview }) {
                if buttons.contains(where: { $0.isDescendant(of: subview) }) {
                    hide(in: subview)
                } else if !subview.isHidden {
                    subview.isHidden = true
                    hiddenChrome.append(subview)
                }
            }
        }
        hide(in: titlebar)
    }

    private func showChrome() {
        for view in hiddenChrome { view.isHidden = false }
        hiddenChrome = []
    }

    private func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        showChrome()
        host?.removeFromSuperview()
        host = nil
        isOpen = false
        NSCursor.setHiddenUntilMouseMoves(false)
        if tookFullScreen, let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        tookFullScreen = false
    }
}

/// Everything scales from the sleeve, drawn at 450, so any window keeps the same proportions.
private struct FullPlayerMetrics {
    static let peek: CGFloat = 0.55

    let side: CGFloat
    var scale: CGFloat { side / 450 }
    var group: CGFloat { side * (1 + Self.peek) }
    var gap: CGFloat { 56 * scale }
    var column: CGFloat { 420 * scale }

    init(_ size: CGSize) {
        let across = 1 + Self.peek + (56 + 420) / 450
        side = max(min(size.height * 0.56, size.width * 0.9 / across), 200)
    }
}

struct FullPlayerView: View {
    let model: AppModel
    let onOpen: (AnyHashable) -> Void

    @Environment(FullPlayerPresenter.self) private var presenter
    @State private var controlsVisible = true
    @State private var idle: Task<Void, Never>?
    @State private var showingSpeed = false
    @State private var hoveringColumn = false
    @State private var comments = WaveformCommentsLoader()
    @State private var ticker = CommentTicker()

    private var player: PlayerEngine { model.player }
    private var track: SCTrack? { player.currentTrack }

    var body: some View {
        GeometryReader { proxy in
            let metrics = FullPlayerMetrics(proxy.size)
            ZStack {
                background
                HStack(spacing: metrics.gap) {
                    sleeve(metrics)
                    column(metrics)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The titlebar is under the player now; this band is what the window is dragged by.
            .overlay(alignment: .top) {
                Color.clear.frame(height: 52).contentShape(Rectangle()).gesture(WindowDragGesture())
            }
            .overlay(alignment: .topTrailing) { closeButton.opacity(controlsVisible ? 1 : 0) }
        }
        .environment(\.colorScheme, .dark)
        .tint(.scOrange)
        .opacity(presenter.isShown ? 1 : 0)
        .onContinuousHover { _ in wake() }
        .onAppear { wake() }
        .onDisappear { idle?.cancel() }
        .task(id: track?.id) {
            // 100 is all one request gives; the newest spread across the whole track.
            if let track { await comments.load(track, api: model.api, first: 100) }
        }
        .onChange(of: player.currentTime) { _, time in
            ticker.advance(track: track, time: time, comments: track.map(comments.comments(for:)) ?? [])
        }
        .animation(.easeInOut(duration: 0.35), value: controlsVisible)
    }

    private var background: some View {
        // An overlay: a square cover filling a wide screen asks to be taller, and stretched the layout off centre.
        Color.black
            .overlay {
                Artwork(track, size: .hero)
                    .scaleEffect(1.4)
                    .blur(radius: 120)
                    .opacity(0.75)
            }
            .overlay { Color.black.opacity(0.35) }
            .clipped()
            .ignoresSafeArea()
    }

    private func sleeve(_ metrics: FullPlayerMetrics) -> some View {
        let side = metrics.side
        return ZStack(alignment: .leading) {
            // A 12-inch disc in a 12.4-inch jacket, so the two read as one object.
            SpinningVinyl(track: track, playhead: player.playhead)
                .frame(width: side * 0.965, height: side * 0.965)
                .shadow(color: .black.opacity(0.55), radius: side * 0.05, y: side * 0.02)
                .offset(x: side * FullPlayerMetrics.peek + side * 0.0175)
            Artwork(track, size: .original)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 4 * metrics.scale))
                // The jacket's edge catches the light where the record slides out from behind it.
                .overlay(alignment: .trailing) {
                    LinearGradient(colors: [.clear, .white.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 6 * metrics.scale)
                }
                .shadow(color: .black.opacity(0.55), radius: 26 * metrics.scale, x: 10 * metrics.scale, y: 14 * metrics.scale)
        }
        .frame(width: metrics.group, height: side, alignment: .leading)
        // Stopping the disc by hand: the record answers by winding down or spinning up, so it needs no other feedback.
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.18)) { player.togglePlayPause() } }
        .pointerStyle(.link)
        .help(player.isPlaying ? "Pause" : "Play")
    }

    private func column(_ metrics: FullPlayerMetrics) -> some View {
        let scale = metrics.scale
        return VStack(alignment: .leading, spacing: 26 * scale) {
            VStack(alignment: .leading, spacing: 6 * scale) {
                Button { open(track) } label: {
                    Text(track?.title ?? "Not Playing")
                        .font(.system(size: 40 * scale, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Button { open(track?.user) } label: {
                    Text(subtitle)
                        .font(.system(size: 22 * scale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            waveform(scale)
            // Folded, not faded: a transparent row kept its height and pushed the title off the sleeve's centre line.
            if controlsVisible {
                transport(scale).transition(.opacity)
            }
        }
        .frame(width: metrics.column, alignment: .leading)
        // Over the column, not in it, so the title and the wave keep the sleeve's centre line.
        .overlay(alignment: .topLeading) {
            FullPlayerComments(shown: ticker.shown, scale: scale)
                .alignmentGuide(.top) { $0[.bottom] + 22 * scale }
        }
        .onHover { hoveringColumn = $0 }
    }

    private var subtitle: String {
        guard let track else { return "" }
        guard let album = track.album, !album.isEmpty else { return track.artistLine }
        return "\(track.artistLine) — \(album)"
    }

    @ViewBuilder
    private func waveform(_ scale: CGFloat) -> some View {
        if let track {
            HStack(spacing: 12 * scale) {
                Text(timeString(player.currentTime))
                WaveformStrip(track: track, playhead: player.playhead, currentTime: player.currentTime,
                              isCurrent: true, style: .fullScreen) { ratio in
                    player.seek(to: ratio * player.duration)
                }
                .frame(height: 34 * scale)
                Text(timeString(player.duration > 0 ? player.duration : Double(track.duration) / 1000))
            }
            .font(.system(size: 12 * scale, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// Music's order, centred under the wave; the like and the speed at the ends don't pull it off centre.
    private func transport(_ scale: CGFloat) -> some View {
        let isLiked = track.map { model.library.isLiked($0) } ?? false
        return HStack(spacing: 22 * scale) {
            PlayerModeButton(isOn: player.isShuffled, action: player.toggleShuffle, size: 32 * scale) {
                Image(systemName: "shuffle").font(.system(size: 18 * scale))
            }
            SkipButton(forward: false) { Task { await player.previous() } }
                .disabled(!player.canGoPrevious)
                .scaleEffect(1.6 * scale)
            Button { withAnimation(.snappy(duration: 0.18)) { player.togglePlayPause() } } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38 * scale))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44 * scale)
            }
            .buttonStyle(PlayerButtonStyle(animatesPress: false))
            .disabled(track == nil)
            SkipButton(forward: true) { Task { await player.next() } }
                .disabled(!player.canGoNext)
                .scaleEffect(1.6 * scale)
            PlayerModeButton(isOn: player.repeatMode != .off, action: player.cycleRepeat, size: 32 * scale) {
                RepeatGlyph(one: player.repeatMode == .one).scaleEffect(1.05 * scale)
            }
        }
        .buttonStyle(PlayerButtonStyle())
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            Button { if let track { model.library.toggleLike(track) } } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 18 * scale))
                    .foregroundStyle(isLiked ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PlayerButtonStyle())
        }
        .overlay(alignment: .trailing) {
            SpeedBadge(speed: player.speed, keepsPitch: player.keepsPitch, isRevealed: true) { showingSpeed = true }
                .popover(isPresented: $showingSpeed, arrowEdge: .bottom) {
                    SpeedPanel(speed: player.speed, keepsPitch: player.keepsPitch,
                               onSpeed: { player.speed = $0 }, onKeepsPitch: { player.keepsPitch = $0 })
                }
        }
        .foregroundStyle(.white)
    }

    private var closeButton: some View {
        Button { presenter.close() } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close Full Screen Player")
        // The corner opposite the traffic lights.
        .padding(.top, 14)
        .padding(.trailing, 18)
    }

    private func open(_ object: (any Hashable)?) {
        guard let object else { return }
        presenter.close()
        onOpen(AnyHashable(object))
    }

    /// The record, the title and the wave stay; the buttons, the close button and the pointer go after a few still seconds.
    private func wake() {
        if !controlsVisible { controlsVisible = true }
        idle?.cancel()
        idle = Task {
            try? await Task.sleep(for: .seconds(3))
            // Not from under a pointer aiming at a button, nor with the speed panel open.
            guard !Task.isCancelled, !showingSpeed, !hoveringColumn else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

#if DEBUG
extension FullPlayerPresenter {
    /// A preview has no window to lay a panel over; this one just reads as open.
    static func shownForPreview() -> FullPlayerPresenter {
        let presenter = FullPlayerPresenter()
        presenter.isOpen = true
        presenter.isShown = true
        return presenter
    }
}

#Preview("Full screen player") {
    let json = """
    {"id":7,"title":"Midnight City","duration":243000,"permalink_url":"x","artwork_url":null,\
    "user":{"id":100,"username":"M83"},"media":{"transcodings":[]},"track_authorization":"",\
    "publisher_metadata":{"album_title":"Hurry Up, We're Dreaming"}}
    """
    let track = try! JSONDecoder().decode(SCTrack.self, from: Data(json.utf8))
    let model = AppModel()
    model.player.seedForPreview([track])
    return FullPlayerView(model: model) { _ in }
        .environment(FullPlayerPresenter.shownForPreview())
        .environment(model.library)
        .frame(width: 1280, height: 800)
}
#endif
