import AppKit
import Nuke
import SwiftUI

/// The window's topmost view, so it keeps the rounded corners and the traffic lights stay above it.
@MainActor
@Observable
final class FullPlayerPresenter {
    private(set) var isOpen = false
    /// The view runs its own way in and out off this; it stays in the window until the way out has played.
    private(set) var isShown = false
    /// The pill's cover; the sleeve flies out of it and back.
    @ObservationIgnored weak var pillArtwork: NSView?
    /// That cover in the player's own top-down space, read off AppKit when opening and closing.
    private(set) var origin: CGRect?
    /// The window's close light in the player's own top-down space; the player's close button mirrors it.
    private(set) var closeLight: CGRect?

    /// Long enough for the record to go back in and the sleeve to land in the pill.
    private static let leaving: Duration = .milliseconds(620)

    @ObservationIgnored private var host: NSView?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private let chrome = TitlebarChrome()
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
            // No notification says a window refused full screen; opening in place beats leaving `isOpen` stuck.
            Task { [weak self, weak window] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.pending != nil else { return }
                self.tookFullScreen = window?.styleMask.contains(.fullScreen) ?? false
                self.enteredFullScreen()
            }
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
        origin = pillArtworkInHost()
        isShown = false
        Task {
            // Back with the page, as the backdrop starts to go — not over a player still on screen.
            try? await Task.sleep(for: .milliseconds(260))
            chrome.show()
            try? await Task.sleep(for: Self.leaving - .milliseconds(260))
            tearDown()
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
        chrome.hide(in: window)
        locateCloseLight()

        // Left by the green button or the system's own shortcut: nothing for closing to undo.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tookFullScreen = false
                self?.locateCloseLight()
            }
        })

        isShown = true
    }

    /// Read when the flight starts rather than when the view is made, once both ends are laid out.
    func locatePill() {
        origin = pillArtworkInHost()
    }

    /// Through the screen: in full screen the lights live in a window of their own, above this one.
    private func locateCloseLight() {
        guard let host, let hostWindow = host.window,
              let light = window?.standardWindowButton(.closeButton), let lightWindow = light.window,
              lightWindow.isVisible else {
            closeLight = nil
            return
        }
        let lit = lightWindow.convertToScreen(light.convert(light.bounds, to: nil))
        let area = hostWindow.convertToScreen(host.convert(host.bounds, to: nil))
        let rect = CGRect(x: lit.minX - area.minX, y: area.maxY - lit.maxY, width: lit.width, height: lit.height)
        // A full-screen bar tucked away above the screen leaves the lights nowhere to line up with.
        closeLight = rect.minY >= 0 && rect.maxY <= area.height ? rect : nil
    }

    /// Through the window: SwiftUI's spaces differ between the shell's hosting view and this one.
    private func pillArtworkInHost() -> CGRect? {
        guard let pillArtwork, let host, pillArtwork.window != nil else { return nil }
        // The host is flipped, so the rect comes back top-down like SwiftUI's.
        return host.convert(pillArtwork.convert(pillArtwork.bounds, to: nil), from: nil)
    }


    private func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        chrome.show()
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
    /// A preview's one frame comes before any way in has run; this starts it already open.
    var startsOpen = false

    @Environment(FullPlayerPresenter.self) private var presenter
    @State private var controlsVisible = true
    @State private var idle: Task<Void, Never>?
    @State private var showingSpeed = false
    @State private var draggingVolume = false
    @State private var hoveringColumn = false
    @State private var comments = WaveformCommentsLoader()
    @State private var ticker = CommentTicker()

    // The way in and out, each step its own flag so each runs on its own curve.
    @State private var backdrop = false
    @State private var landed = false
    @State private var recordOut = false
    @State private var columnStep = 0
    @State private var sleeveFrame: CGRect = .zero
    @State private var sequence: Task<Void, Never>?

    /// What the sleeve, title and backdrop show; it trails the player so the old record and sleeve can leave first.
    @State private var shown: SCTrack?
    /// The sleeve's sideways travel during a change, in sleeve widths; it leaves and arrives in the direction of play.
    @State private var swap: CGFloat = 0
    @State private var swapOpacity = 1.0
    @State private var lastIndex: Int?

    /// The scratch in progress: degrees turned by hand, where it started, and whether to play on after.
    @State private var hold: Double?
    @State private var grabbedAt: Double = 0
    @State private var playedBeforeGrab = false
    @State private var lastHandAngle: Double?

    private var player: PlayerEngine { model.player }
    private var track: SCTrack? { player.currentTrack }
    private var face: SCTrack? { shown ?? track }

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
            // Measured from the window's top, where the lights are, not from under the titlebar's safe area.
            .overlay {
                Color.clear
                    .overlay(alignment: .topTrailing) { closeButton.opacity(controlsVisible && backdrop ? 1 : 0) }
                    .ignoresSafeArea()
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(.scOrange)
        .onChange(of: presenter.isShown, initial: true) { _, isShown in
            if isShown { enter() } else { leave() }
        }
        .onChange(of: track?.id) { _, _ in changeTrack() }
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
                GeometryReader { proxy in
                    // Blurred at thumbnail size and scaled up as a picture: the same look, not a window-sized blur per frame.
                    Artwork(face, size: .mid)
                        .frame(width: 40, height: 40)
                        .blur(radius: 3, opaque: true)
                        .drawingGroup()
                        .scaleEffect(max(proxy.size.width, proxy.size.height) / 40 * 1.4)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(0.75)
                        .id(face?.id)
                        .transition(.opacity)
                }
            }
            .overlay { Color.black.opacity(0.35) }
            .clipped()
            .ignoresSafeArea()
            .opacity(backdrop ? 1 : 0)
    }

    private func sleeve(_ metrics: FullPlayerMetrics) -> some View {
        let side = metrics.side
        return ZStack(alignment: .leading) {
            // A 12-inch disc in a 12.4-inch jacket, so the two read as one object.
            SpinningVinyl(track: face, playhead: player.playhead, hold: hold)
                .frame(width: side * 0.965, height: side * 0.965)
                // Cast by a still disc underneath: on the turning one the shadow was redrawn every frame.
                .background {
                    Circle().fill(.black).shadow(color: .black.opacity(0.55), radius: side * 0.05, y: side * 0.02)
                }
                // Tucked all the way into the sleeve until it slides out.
                .offset(x: side * (recordOut ? FullPlayerMetrics.peek : 0) + side * 0.0175)
            ZStack {
                // The pill's own size is already cached, so the sleeve is never empty while the upload loads.
                Artwork(face, size: .mid)
                Artwork(face, size: .original, placeholderOpacity: 0)
            }
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
        .offset(x: swap * side * 0.4)
        .opacity(swapOpacity)
        .modifier(FlyFromPill(origin: presenter.origin, destination: sleeveFrame, side: side, landed: landed))
        // Measured on a still frame under it: on itself the flight's own transform came back as the destination.
        .frame(width: metrics.group, height: side, alignment: .leading)
        .background {
            // Global, not this view's own space: that one starts under the titlebar, the pill's rect at the window's top.
            Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sleeveFrame = $0 }
        }
        // Stopping the disc by hand: the record answers by winding down or spinning up, so it needs no other feedback.
        .overlay(alignment: .topLeading) {
            if hold != nil {
                Text(timeString(scratchTarget))
                    .font(.system(size: 15 * metrics.scale, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10 * metrics.scale)
                    .padding(.vertical, 5 * metrics.scale)
                    .background(.black.opacity(0.55), in: Capsule())
                    // Over the record's centre, above its rim.
                    .position(x: recordCentre(side).x, y: side * 0.06)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.18)) { player.togglePlayPause() } }
        .gesture(scratch(side: side))
        .pointerStyle(.link)
        .help(player.isPlaying ? "Pause" : "Play")
    }

    private func column(_ metrics: FullPlayerMetrics) -> some View {
        let scale = metrics.scale
        return VStack(alignment: .leading, spacing: 26 * scale) {
            VStack(alignment: .leading, spacing: 6 * scale) {
                Button { open(face) } label: {
                    Text(face?.title ?? "Not Playing")
                        .font(.system(size: 40 * scale, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Button { open(face?.user) } label: {
                    Text(subtitle)
                        .font(.system(size: 22 * scale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .id(face?.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10 * scale)), removal: .opacity))
            .modifier(Arrival(step: 1, current: columnStep, scale: scale))

            waveform(scale)
                .modifier(Arrival(step: 2, current: columnStep, scale: scale))
            // Folded, not faded: a transparent row kept its height and pushed the title off the sleeve's centre line.
            if controlsVisible {
                VStack(spacing: 18 * scale) {
                    transport(scale)
                    volume(scale)
                }
                .modifier(Arrival(step: 3, current: columnStep, scale: scale))
                .transition(.opacity)
            }
        }
        .frame(width: metrics.column, alignment: .leading)
        // Over the column, not in it, so the title and the wave keep the sleeve's centre line.
        .overlay(alignment: .topLeading) {
            FullPlayerComments(shown: ticker.shown, scale: scale)
                .alignmentGuide(.top) { $0[.bottom] + 22 * scale }
                .opacity(columnStep > 0 ? 1 : 0)
        }
        .onHover { hoveringColumn = $0 }
    }

    private var subtitle: String {
        guard let face else { return "" }
        guard let album = face.album, !album.isEmpty else { return face.artistLine }
        return "\(face.artistLine) — \(album)"
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

    /// Music's row under the transport: the quiet end, the bar, the loud end.
    private func volume(_ scale: CGFloat) -> some View {
        HStack(spacing: 12 * scale) {
            Image(systemName: "speaker.fill")
            VolumeBar(volume: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }),
                      dragging: $draggingVolume, thickness: 5 * scale)
                .frame(height: 24 * scale)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 12 * scale))
        .foregroundStyle(.white.opacity(0.7))
    }

    private var closeButton: some View {
        Button { presenter.close() } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: Self.closeSide, height: Self.closeSide)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close Full Screen Player")
        // The corner opposite the traffic lights: centred on their line, as far in from the side as from the top.
        .padding([.top, .trailing], presenter.closeLight.map { $0.midY - Self.closeSide / 2 } ?? 14)
    }

    private static let closeSide: CGFloat = 32

    private func open(_ object: (any Hashable)?) {
        guard let object else { return }
        presenter.close()
        onOpen(AnyHashable(object))
    }

    /// The sleeve flies out of the pill with the record still inside; the record slides out once it has landed.
    private func enter() {
        shown = track
        lastIndex = player.currentIndex
        warmNext()
        if startsOpen {
            (backdrop, landed, recordOut, columnStep) = (true, true, true, 3)
            return
        }
        sequence?.cancel()
        sequence = Task {
            // The flight needs the sleeve's place, which the first layout pass hands over.
            for _ in 0..<10 where sleeveFrame == .zero {
                try? await Task.sleep(for: .milliseconds(16))
            }
            presenter.locatePill()
            withAnimation(.easeOut(duration: 0.3)) { backdrop = true }
            withAnimation(.spring(duration: 0.5, bounce: 0.12)) { landed = true }
            try? await Task.sleep(for: .milliseconds(480))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.5, bounce: 0.22)) { recordOut = true }
            for step in 1...3 {
                withAnimation(.easeOut(duration: 0.35)) { columnStep = step }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    /// Record home, sleeve out against the direction of play, the next one in from the other side, its record out.
    private func changeTrack() {
        let index = player.currentIndex
        defer { lastIndex = index }
        // Before the player is up there is nothing to animate; it just shows the new track when it is.
        guard presenter.isShown, landed, shown != nil else {
            shown = track
            return
        }
        let direction: CGFloat = index >= (lastIndex ?? index) ? 1 : -1
        let incoming = track
        // Fetched and decoded while the old sleeve leaves: decoded on arrival, the cover stalled the swap for 100 ms.
        let warming = Task { await Self.warm(incoming) }
        warmNext()
        sequence?.cancel()
        sequence = Task {
            withAnimation(.easeIn(duration: 0.18)) { recordOut = false }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                swap = -direction
                swapOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            // A slow network doesn't get to hold the sleeve off screen for long.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await warming.value }
                group.addTask { try? await Task.sleep(for: .milliseconds(400)) }
                await group.next()
                group.cancelAll()
            }
            guard !Task.isCancelled else { return }
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) { swap = direction }
            withAnimation(.easeOut(duration: 0.3)) { shown = track }
            withAnimation(.spring(duration: 0.45, bounce: 0.1)) {
                swap = 0
                swapOpacity = 1
            }
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.5, bounce: 0.22)) { recordOut = true }
        }
    }

    // MARK: - Scratch

    /// One turn of the record moves the track this far: a real one is 1.8 s, which would take a hundred turns to cross a song.
    private static let secondsPerTurn = 10.0

    private func recordCentre(_ side: CGFloat) -> CGPoint {
        CGPoint(x: side * (FullPlayerMetrics.peek + 0.0175 + 0.965 / 2), y: side / 2)
    }

    private var scratchTarget: Double {
        let duration = player.duration > 0 ? player.duration : Double(face?.duration ?? 0) / 1000
        return min(max(grabbedAt + (hold ?? 0) / 360 * Self.secondsPerTurn, 0), max(duration - 1, 0))
    }

    /// A grab stops the sound, clockwise is forward, and letting go seeks there, a flick carrying it a little further.
    private func scratch(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let centre = recordCentre(side)
                // Only the record: a drag that starts on the sleeve is no scratch.
                guard recordOut, value.startLocation.x > side * 0.98 || hold != nil else { return }
                let angle = atan2(value.location.y - centre.y, value.location.x - centre.x) * 180 / .pi
                if hold == nil {
                    grabbedAt = player.currentTime
                    playedBeforeGrab = player.isPlaying
                    if player.isPlaying { player.togglePlayPause(forcePause: true) }
                    lastHandAngle = angle
                    withAnimation(.easeOut(duration: 0.12)) { hold = 0 }
                    return
                }
                guard let last = lastHandAngle else { return }
                var step = angle - last
                // Across the ±180° seam the raw difference jumps by a whole turn.
                if step > 180 { step -= 360 } else if step < -180 { step += 360 }
                hold = (hold ?? 0) + step
                lastHandAngle = angle
            }
            .onEnded { value in
                guard hold != nil, let last = lastHandAngle else { return }
                let centre = recordCentre(side)
                let flung = atan2(value.predictedEndLocation.y - centre.y, value.predictedEndLocation.x - centre.x) * 180 / .pi
                var carry = flung - last
                if carry > 180 { carry -= 360 } else if carry < -180 { carry += 360 }
                hold = (hold ?? 0) + carry * 0.5
                player.seek(to: scratchTarget)
                if playedBeforeGrab { player.togglePlayPause(forcePlay: true) }
                withAnimation(.easeOut(duration: 0.2)) { hold = nil }
                lastHandAngle = nil
            }
    }

    /// The next track in the queue, so a skip finds its covers already decoded.
    private func warmNext() {
        let queue = player.queue
        let next = player.currentIndex + 1
        guard queue.indices.contains(next) else { return }
        let track = queue[next]
        Task { await Self.warm(track) }
    }

    private static func warm(_ track: SCTrack?) async {
        let urls = [ArtworkSize.mid, .hero, .original].compactMap { track?.coverURL.liveArtwork.scArtwork($0) }
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { _ = try? await ImagePipeline.shared.image(for: url) }
            }
        }
    }

    /// The way in backwards: the record is all the way home before the sleeve takes off with it.
    private func leave() {
        sequence?.cancel()
        // A track change cut short would otherwise fly home a sleeve that is halfway off.
        withAnimation(.easeOut(duration: 0.15)) {
            swap = 0
            swapOpacity = 1
        }
        sequence = Task {
            withAnimation(.easeIn(duration: 0.15)) { columnStep = 0 }
            withAnimation(.easeIn(duration: 0.2)) { recordOut = false }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.36, bounce: 0)) { landed = false }
            withAnimation(.easeIn(duration: 0.3).delay(0.06)) { backdrop = false }
        }
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

/// The sleeve on the pill's cover until it lands; values in one branch, as if/else gave SwiftUI two views to swap.
private struct FlyFromPill: ViewModifier {
    let origin: CGRect?
    let destination: CGRect
    let side: CGFloat
    let landed: Bool

    func body(content: Content) -> some View {
        let flying = !landed && destination != .zero
        let from = flying ? origin : nil
        content
            // With no pill to come from it grows in where it stands.
            .scaleEffect(from.map { $0.width / side } ?? (landed ? 1 : 0.92), anchor: .topLeading)
            .offset(x: from.map { $0.minX - destination.minX } ?? 0, y: from.map { $0.minY - destination.minY } ?? 0)
            .opacity(landed || origin != nil ? 1 : 0)
    }
}

/// One line of the column coming in: up from a little below, out of nothing.
private struct Arrival: ViewModifier {
    let step: Int
    let current: Int
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(current >= step ? 1 : 0)
            .offset(y: current >= step ? 0 : 12 * scale)
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
    return FullPlayerView(model: model, onOpen: { _ in }, startsOpen: true)
        .environment(FullPlayerPresenter.shownForPreview())
        .environment(model.library)
        .frame(width: 1280, height: 800)
}
#endif
