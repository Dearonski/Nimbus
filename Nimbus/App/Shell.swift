import NukeUI
import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.isAuthenticated {
                LibraryShell(model: model)
            } else {
                LoginWebView { _ in model.didAuthenticate() }
            }
        }
        .frame(minWidth: 1040, minHeight: 620)
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
}

struct LibraryShell: View {
    let model: AppModel
    @AppStorage("librarySection") private var storedSection: String = LibrarySection.home.rawValue
    @State private var section: LibrarySection? = .home
    /// Owned here so the player pill — which lives outside the stack — can push onto it.
    @State private var path = NavigationPath()
    /// Frame of the detail column inside the split view. The pill has to be an overlay on the whole
    /// split view — the only placement that survives a NavigationStack push on macOS — so it needs
    /// both the width and the origin to sit over the detail alone, and it tracks the column as the
    /// sidebar or the queue inspector resize it.
    @State private var detailFrame: CGRect = .zero
    @State private var showQueue = false

    private static let shellSpace = "shell"

    var body: some View {
        // The column can only ever grow: the minimum is the default width, which also keeps the
        // collapse gesture from squeezing it away. No columnVisibility binding — driving one from
        // here made the split view re-lay itself out on every pass.
        NavigationSplitView {
            SidebarNav(section: $section)
                .navigationSplitViewColumnWidth(min: 212, ideal: 212, max: 320)
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
            .task {
                section = LibrarySection(rawValue: storedSection) ?? .home
                await model.restoreSession()
            }
        } detail: {
            NavigationStack(path: $path) {
                DetailContent(model: model, section: $section)
                    .navigationDestination(for: SCUser.self) { user in
                        ArtistView(user: user, model: model)
                    }
                    .navigationDestination(for: SCTrack.self) { track in
                        TrackDetailView(track: track, model: model)
                    }
                    .navigationDestination(for: SCPlaylist.self) { playlist in
                        PlaylistTracksView(playlist: playlist, library: model.library, player: model.player)
                    }
                    .navigationDestination(for: SCGenre.self) { genre in
                        GenreChartView(genre: genre, model: model)
                    }
            }
            .adaptiveMetrics()
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: PlayerPill.reservedHeight)
            }
            // onGeometryChange rather than onChange inside a GeometryReader: writing state from
            // the latter re-runs layout in the same frame, which SwiftUI flags as updating multiple
            // times per frame.
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.shellSpace))
            } action: { frame in
                detailFrame = frame
            }
        }
        // Attached to the split view, not to the detail's NavigationStack: inside the stack the
        // inspector shares a layer with the pushed page, which then covers it.
        .inspector(isPresented: $showQueue) {
            QueuePanel(player: model.player) { showQueue = false }
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
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
            path = NavigationPath()
            if let new { storedSection = new.rawValue }
        }
        // Space only reaches here when no text field has focus, which is the gate that keeps it
        // from stealing typing in the search box.
        .onKeyPress(.space) {
            model.player.togglePlayPause()
            return .handled
        }
        .overlay(alignment: .bottomLeading) {
            PlayerPill(
                player: model.player,
                onOpenTrack: { path.append($0) },
                onOpenArtist: { path.append($0) },
                isQueueVisible: $showQueue)
            .frame(width: detailFrame.width)
            .offset(x: detailFrame.minX)
        }
        .overlay(alignment: .topLeading) {
            if let error = model.player.lastError {
                PlaybackErrorBanner(message: error) { model.player.dismissError() }
                    .frame(width: detailFrame.width)
                    .offset(x: detailFrame.minX)
            }
        }
        .animation(.snappy, value: model.player.lastError)
        .animation(.snappy, value: showQueue)
        .environment(model.library)
    }
}

/// A plain stack rather than a List: `.listStyle(.sidebar)` layers its own horizontal insets on top
/// of the row's, so the highlight never lines up with the column edges. Eight fixed destinations
/// need none of what List provides.
struct SidebarNav: View {
    @Binding var section: LibrarySection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(LibrarySection.browseCases) { item in
                    SidebarRow(item: item, selection: $section)
                }

                Text("Library")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 14)
                    .padding(.bottom, 2)

                ForEach(LibrarySection.libraryCases) { item in
                    SidebarRow(item: item, selection: $section)
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
            .onTapGesture { selection = item }
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1))
        }
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
            ProfileView(model: model, section: $section)
        }
    }
}

struct AccountRow: View {
    let model: AppModel
    @Binding var section: LibrarySection?

    private var me: SCUser? { model.library.meUser }

    var body: some View {
        HStack(spacing: 8) {
            LazyImage(url: me?.avatarURL.flatMap(URL.init)) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
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

#Preview {
    ContentView(model: AppModel())
}
