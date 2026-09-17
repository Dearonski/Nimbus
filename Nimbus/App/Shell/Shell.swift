import AppKit
import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.isAuthenticated {
                LibraryShell(model: model)
                    .frame(minWidth: 1040, maxWidth: .infinity,
                           minHeight: 620, maxHeight: .infinity)
            } else {
                // A definite size, not a minimum: with `.windowResizability(.contentSize)` this is
                // what the window becomes, and the welcome screen stops inheriting the shell's frame.
                WelcomeView(model: model)
                    .frame(width: 560, height: 640)
            }
        }
        .tint(.scOrange)
    }
}

struct LibraryShell: View {
    let model: AppModel
    @State private var section: LibrarySection?
    /// Owned here so the player pill — which lives outside the stack — can push onto it.
    @State private var pageController: HistoryPageController?
    /// What the column shows right now — the page controller reports it, gesture or button alike.
    @State private var shown: AnyHashable = LibrarySection.home
    @State private var canGoBack = false
    /// Frame of the detail column inside the split view. The pill has to be an overlay on the whole
    /// split view — the only placement that survives a NavigationStack push on macOS — so it needs
    /// both the width and the origin to sit over the detail alone, and it tracks the column as the
    /// sidebar or the queue inspector resize it.
    @State private var detailFrame = DetailColumnFrame()
    @State private var room = PageRoom()
    @State private var showQueue = false
    @State private var spaceMonitor: Any?
    @State private var viewer = ArtworkViewer()

    nonisolated private static let shellSpace = "shell"

    /// Seeded here rather than corrected in a `.task`: landing on Home for one runloop still runs
    /// its three loaders, and they spawn unstructured Tasks that tearing the view down can't cancel.
    init(model: AppModel) {
        self.model = model
        let stored = UserDefaults.standard.string(forKey: LibrarySection.storageKey)
        _section = State(initialValue: stored.flatMap(LibrarySection.init(rawValue:)) ?? .home)
    }

    /// Space toggles playback from anywhere in the window, so it is watched at the event level
    /// rather than with `onKeyPress`: SwiftUI routes key events into the view tree only while
    /// something inside it holds focus, and once a text field handed focus back, nothing did —
    /// Space stopped arriving at all on any page that has a field.
    private func startSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Bare Space only: ⌘Space and friends belong to the system.
            let bare = event.modifierFlags
                .intersection([.command, .option, .control, .shift]).isEmpty
            // With a picture open, Esc and Space close it — Space the way it closes Quick Look —
            // instead of reaching the page or the player behind it.
            if bare, event.keyCode == 53 || event.keyCode == 49 {
                let closed = MainActor.assumeIsolated { () -> Bool in
                    guard viewer.viewing != nil else { return false }
                    viewer.dismiss()
                    return true
                }
                if closed { return nil }
            }
            let isCommandF = event.charactersIgnoringModifiers == "f"
                && event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command]
            guard event.keyCode == 49 && bare || isCommandF else { return event }
            // Only a Bool crosses back out of the actor: NSEvent is not Sendable.
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                if isCommandF {
                    // Sections without a field send you to Search, which is where ⌘F is expected
                    // to land anyway.
                    if section != .likes { section = .search }
                    model.focusFieldRequest += 1
                    return true
                }
                guard !model.isTypingInField else { return false }
                model.player.togglePlayPause()
                return true
            }
            return swallowed ? nil : event
        }
    }

    /// The titlebar names the page — but only where the page does not name itself. Likes, the
    /// profile, an artist, a track and a set all carry their own heading, and saying it twice was
    /// the whole complaint; everything else had nothing up there at all.
    private func title(of object: AnyHashable) -> String {
        switch object {
        case let genre as SCGenre: genre.name
        case let list as ProfileList: list.title
        case let section as LibrarySection:
            // The profile still names itself — the big line beside the avatar is the user's own
            // name, not a section label.
            section == .profile ? "" : section.rawValue
        default: ""
        }
    }

    /// A page for whatever the history holds. Everything the page needs is applied here: a hosting
    /// controller starts a fresh environment, so nothing set on the shell reaches inside it.
    private func destination(_ object: AnyHashable) -> AnyView {
        let page: AnyView = switch object {
        case let user as SCUser: AnyView(ArtistView(user: user, model: model))
        case let track as SCTrack: AnyView(TrackDetailView(track: track, model: model))
        case let playlist as SCPlaylist: AnyView(PlaylistPage(playlist: playlist, model: model))
        case let genre as SCGenre: AnyView(GenreChartView(genre: genre, model: model))
        case let list as ProfileList: AnyView(ProfileListView(list: list, model: model))
        default: AnyView(DetailContent(model: model, section: $section))
        }
        return AnyView(
            page
                // Inside the page, not around the controller: a safe-area inset on an AppKit view
                // takes the strip away from it instead of letting the content scroll under it.
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: PlayerPill.reservedHeight)
                }
                .adaptiveMetrics()
                .environment(\.navigator, Navigator { pageController?.open(AnyHashable($0)) })
                .environment(viewer)
                .environment(room)
                .environment(model.library)
                .coordinateSpace(.named(Self.shellSpace))
        )
    }

    /// Every press of a sidebar row goes back to that section's root: pressing the section you are
    /// already in is how a pushed page is left, and a selection binding says nothing when it repeats.
    private func select(_ item: LibrarySection) {
        section = item
    }

    private func stopSpaceMonitor() {
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        spaceMonitor = nil
    }

    var body: some View {
        // The column can only ever grow: the minimum is the default width, which also keeps the
        // collapse gesture from squeezing it away. No columnVisibility binding — driving one from
        // here made the split view re-lay itself out on every pass.
        NavigationSplitView {
            SidebarNav(section: $section, onSelect: select)
                .background { SidebarPin().frame(width: 0, height: 0) }
                .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    AccountRow(model: model, section: $section)
                    Link("Powered by SoundCloud", destination: URL(string: "https://soundcloud.com")!)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            }
            .task { model.library.loadMe() }
            .task { await model.restoreSession() }
            // After `toolbar(removing:)`, which swallows it: set before, the column kept AppKit's
            // own 140 minimum and no maximum at all, and the sidebar dragged out to any width.
            .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 270)
        } detail: {
            NavigationPages(root: section ?? .home,
                            page: { destination($0) },
                            onShow: { object, back in
                                shown = object
                                withAnimation(.snappy(duration: 0.2)) { canGoBack = back }
                            },
                            controller: $pageController)
            // onGeometryChange rather than onChange inside a GeometryReader: writing state from
            // the latter re-runs layout in the same frame, which SwiftUI flags as updating multiple
            // times per frame. Horizontal only: mid-resize the titlebar is re-measured and the
            // column's top flickers 52 -> 34 -> 52 within a frame, which SwiftUI flags as cycling.
            .onGeometryChange(for: ColumnSpan.self) { proxy in
                let frame = proxy.frame(in: .named(Self.shellSpace))
                return ColumnSpan(minX: frame.minX, width: frame.width)
            } action: { span in
                detailFrame.span = span
                if room.detailMinX != span.minX { room.detailMinX = span.minX }
            }
        }
        // Attached to the split view, not to the detail's NavigationStack: inside the stack the
        // inspector shares a layer with the pushed page, which then covers it.
        .inspector(isPresented: $showQueue) {
            QueuePanel(player: model.player) { showQueue = false }
                // Full width from the slide's first frame: what the queue will take, known before it takes it.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if room.queueWidth != width { room.queueWidth = width }
                }
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .environment(\.navigator, Navigator { pageController?.open(AnyHashable($0)) })
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if room.shellWidth != width { room.shellWidth = width }
        }
        .coordinateSpace(.named(Self.shellSpace))
        .navigationTitle(title(of: shown))
        // Apple Music's shape: the bar carries no fill of its own, the page runs under it and shows
        // through — so a page with nothing to say up there has no empty strip either.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The bar is AppKit's from here on, the one way the Back button animates in and out.
        .background(WindowToolbar(canGoBack: canGoBack) { pageController?.navigateBack(nil) })

        .onChange(of: section) { _, new in
            if let new { UserDefaults.standard.set(new.rawValue, forKey: LibrarySection.storageKey) }
        }
        .onChange(of: showQueue) { _, open in
            withAnimation(.snappy) { room.isQueueOpen = open }
        }
        .onAppear { startSpaceMonitor() }
        .onDisappear { stopSpaceMonitor() }
        .overlay(alignment: .bottomLeading) {
            OverDetailColumn(frame: detailFrame) {
                PlayerPill(
                    player: model.player,
                    onOpenTrack: { pageController?.open($0) },
                    onOpenArtist: { pageController?.open($0) },
                    isQueueVisible: $showQueue)
            }
        }
        .overlay(alignment: .topLeading) {
            if let error = model.player.lastError {
                OverDetailColumn(frame: detailFrame) {
                    PlaybackErrorBanner(message: error) { model.player.dismissError() }
                }
            }
        }
        .animation(.snappy, value: model.player.lastError)
        .animation(.snappy, value: showQueue)
        .environment(viewer)
        .environment(room)
        .environment(model.library)
    }
}

/// Holds the sidebar open. AppKit collapses a split item dragged under its minimum, and with the
/// toggle removed from the toolbar a collapsed sidebar had no way back — it stayed shut across
/// launches, since the split view remembers where the divider was left.
private struct SidebarPin: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Pin() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Pin)?.pin() }

    private final class Pin: NSView {
        private var watch: NSKeyValueObservation?
        private var tries = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            pin()
        }

        func pin() {
            guard let item = splitItem else {
                // The split view isn't assembled on the first passes, and until the ban lands the
                // divider reports no minimum at all — which is also why the cursor stays two-way.
                guard tries < 10 else { return }
                tries += 1
                DispatchQueue.main.async { [weak self] in self?.pin() }
                return
            }
            tries = 0
            if item.isCollapsed { item.isCollapsed = false }
            item.canCollapse = false
            guard watch == nil else { return }
            // The ban alone doesn't hold: AppKit puts `canCollapse` back after every expand.
            watch = item.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
                guard change.newValue == true else { return }
                MainActor.assumeIsolated { self?.pin() }
            }
        }

        private var splitItem: NSSplitViewItem? {
            var view: NSView? = superview
            while let current = view {
                if let split = current as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
                    return controller.splitViewItems.first { isDescendant(of: $0.viewController.view) }
                }
                view = current.superview
            }
            return nil
        }
    }
}

// A reference the shell never reads: the column resizes every frame while the inspector slides in.
@Observable
private final class DetailColumnFrame {
    var span = ColumnSpan()
}

private nonisolated struct ColumnSpan: Equatable {
    var minX: CGFloat = 0
    var width: CGFloat = 0
}

private struct OverDetailColumn<Content: View>: View {
    let frame: DetailColumnFrame
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: frame.span.width)
            .offset(x: frame.span.minX)
    }
}

/// Routes the detail column to the selected sidebar section.
struct DetailContent: View {
    let model: AppModel
    @Binding var section: LibrarySection?

    var body: some View {
        switch section {
        case .search:
            SearchPage(model: model)
        case .home, .none:
            HomeView(model: model)
        case .feed:
            FeedView(model: model)
        case .likes:
            LikesView(model: model)
        case .history:
            TrackList(feed: model.library.history, player: model.player)
        case .playlists:
            PlaylistCollection(section: .playlists, library: model.library)
        case .albums:
            PlaylistCollection(section: .albums, library: model.library)
        case .stations:
            PlaylistCollection(section: .stations, library: model.library)
        case .following:
            FollowingView(model: model)
        case .profile:
            MyProfileView(model: model)
        }
    }
}

#if DEBUG
#Preview {
    ContentView(model: AppModel())
}
#endif
