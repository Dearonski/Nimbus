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

/// Mirrors SoundCloud's own navigation: discovery and the social feed are separate destinations,
/// and the library splits the things `/me/library/all` already distinguishes.
enum LibrarySection: String, CaseIterable, Identifiable {
    case search = "Search"
    case home = "Home"
    case feed = "Feed"
    case likes = "Likes"
    case playlists = "Playlists"
    case albums = "Albums"
    case stations = "Stations"
    case following = "Following"
    case history = "History"
    case profile = "Profile"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house"
        case .feed: "newspaper"
        case .likes: "heart"
        case .playlists: "music.note.list"
        case .albums: "square.stack"
        case .stations: "dot.radiowaves.left.and.right"
        case .following: "person.2"
        case .history: "clock"
        case .profile: "person.crop.circle"
        }
    }

    static var browseCases: [LibrarySection] { [.search, .home, .feed] }
    static var libraryCases: [LibrarySection] { [.likes, .playlists, .albums, .stations, .following, .history] }

    static let storageKey = "librarySection"
}

struct LibraryShell: View {
    let model: AppModel
    @State private var section: LibrarySection?
    /// Owned here so the player pill — which lives outside the stack — can push onto it.
    @State private var path = NavigationPath()
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

    /// Every press of a sidebar row goes back to that section's root: pressing the section you are
    /// already in is how a pushed page is left, and a selection binding says nothing when it repeats.
    private func select(_ item: LibrarySection) {
        if !path.isEmpty { path = NavigationPath() }
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
            NavigationStack(path: $path) {
                // Every destination measures for itself: environment set on the NavigationStack
                // does not reach a pushed view, so without this they fell back to the default
                // width and drew covers and cards a size adrift from the rest of the app.
                DetailContent(model: model, section: $section)
                    .navigationDestination(for: SCUser.self) { user in
                        ArtistView(user: user, model: model).adaptiveMetrics()
                    }
                    .navigationDestination(for: SCTrack.self) { track in
                        TrackDetailView(track: track, model: model).adaptiveMetrics()
                    }
                    .navigationDestination(for: SCPlaylist.self) { playlist in
                        PlaylistPage(playlist: playlist, model: model).adaptiveMetrics()
                    }
                    .navigationDestination(for: SCGenre.self) { genre in
                        GenreChartView(genre: genre, model: model).adaptiveMetrics()
                    }
                    .navigationDestination(for: ProfileList.self) { list in
                        ProfileListView(list: list, model: model).adaptiveMetrics()
                    }
            }
            .adaptiveMetrics()
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: PlayerPill.reservedHeight)
            }
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
        .environment(\.navigator, Navigator { path.append($0) })
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if room.shellWidth != width { room.shellWidth = width }
        }
        .coordinateSpace(.named(Self.shellSpace))
        // A window with no toolbar item at all loses its titlebar area: the sidebar then starts
        // below it and the window buttons sit outside the column instead of over it. A zero-sized
        // status item keeps the chrome without putting anything in the bar.
        .toolbar {
            ToolbarItem(placement: .status) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onChange(of: section) { _, new in
            // Only when there is something to pop: assigning a fresh path anyway rewrites
            // navigation state inside the same update that changed the section, which is what
            // SwiftUI reports as updating multiple times per frame.
            if !path.isEmpty { path = NavigationPath() }
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
                    onOpenTrack: { path.append($0) },
                    onOpenArtist: { path.append($0) },
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

/// A plain stack rather than a List: `.listStyle(.sidebar)` layers its own horizontal insets on top
/// of the row's, so the highlight never lines up with the column edges. Nine fixed destinations
/// need none of what List provides.
struct SidebarNav: View {
    @Binding var section: LibrarySection?
    var onSelect: (LibrarySection) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(LibrarySection.browseCases) { item in
                    SidebarRow(item: item, selection: $section, onSelect: onSelect)
                }

                Text("Library")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 14)
                    .padding(.bottom, 2)

                ForEach(LibrarySection.libraryCases) { item in
                    SidebarRow(item: item, selection: $section, onSelect: onSelect)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
        }
        .scrollContentBackground(.hidden)
    }
}

/// Rows draw their own selection: List's built-in highlight paints with the system accent colour
/// (blue by default), which no tint can override.
struct SidebarRow: View {
    let item: LibrarySection
    @Binding var selection: LibrarySection?
    var onSelect: (LibrarySection) -> Void = { _ in }

    @State private var hovering = false

    private var isActive: Bool { selection == item }
    private var tint: AnyShapeStyle { isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary) }

    var body: some View {
        // Hand-built rather than a Label: Music sets the icon 18pt in from the pill edge and 10pt
        // clear of the title, and Label exposes neither gap. The fixed icon box also keeps titles
        // aligned, since the symbols differ in width.
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(item.rawValue)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .background {
                // Music tints only the label and keeps the pill itself neutral grey; an accent-filled
                // row reads as a button rather than a selection.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.075 : (hovering ? 0.04 : 0)))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selection = item
                onSelect(item)
            }
            .onHover { hovering = $0 }
    }
}

/// Surfaces a failed track (geo/Go+ block, dropped connection) instead of leaving the queue looking
/// like it silently stalled — the engine keeps skipping, this just says why.
struct PlaybackErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
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

struct AccountRow: View {
    let model: AppModel
    @Binding var section: LibrarySection?

    private var me: SCUser? { model.library.meUser }

    var body: some View {
        HStack(spacing: 8) {
            Artwork(me, size: .thumb, placeholderOpacity: 0.2)
                .frame(width: 26, height: 26)
                .clipShape(Circle())

            Text(me?.username ?? "Account")
                .font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(.primary)

            Spacer()

            Menu {
                Button { section = .profile } label: {
                    Label("My Profile", systemImage: "person.crop.circle")
                }
                Divider()
                Button(role: .destructive) { model.signOut() } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

#if DEBUG
#Preview {
    ContentView(model: AppModel())
}
#endif
