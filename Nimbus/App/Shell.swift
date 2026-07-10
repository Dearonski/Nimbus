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

    static var browseCases: [LibrarySection] { [.home, .feed] }
    static var libraryCases: [LibrarySection] { [.likes, .playlists, .albums, .stations, .following, .history] }
}

struct LibraryShell: View {
    let model: AppModel
    @State private var section: LibrarySection? = .home
    @State private var searchText = ""
    /// Owned here so the player pill — which lives outside the stack — can push onto it.
    @State private var path = NavigationPath()
    /// Width of the detail column, measured so the pill can float over just the detail (like Music)
    /// instead of stretching across the sidebar. The pill is an overlay on the whole split view —
    /// the only placement that survives a NavigationStack push on macOS.
    @State private var detailWidth: CGFloat = 0

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(LibrarySection.browseCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }

                Section("Library") {
                    ForEach(LibrarySection.libraryCases) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
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
        } detail: {
            NavigationStack(path: $path) {
                DetailContent(model: model, section: $section, searchText: searchText)
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
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: PlayerPill.reservedHeight)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { detailWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in detailWidth = width }
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search SoundCloud")
        .onChange(of: searchText) { _, query in model.library.search(query) }
        .onChange(of: section) { _, _ in path = NavigationPath() }
        .overlay(alignment: .bottomTrailing) {
            PlayerPill(
                player: model.player,
                onOpenTrack: { path.append($0) },
                onOpenArtist: { path.append($0) })
            .frame(width: detailWidth)
        }
        .overlay(alignment: .top) {
            if let error = model.player.lastError {
                PlaybackErrorBanner(message: error) { model.player.dismissError() }
                    .frame(width: detailWidth)
            }
        }
        .animation(.snappy, value: model.player.lastError)
        .environment(model.library)
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

/// Routes the detail column: search results while typing, the genre browser while the search
/// field is focused but empty, otherwise the selected sidebar section.
struct DetailContent: View {
    let model: AppModel
    @Binding var section: LibrarySection?
    let searchText: String

    @Environment(\.isSearching) private var isSearching

    var body: some View {
        if !searchText.isEmpty {
            SearchResultsView(model: model)
        } else if isSearching {
            GenreGridView()
        } else {
            switch section {
            case .home, .none:
                HomeView(model: model)
            case .feed:
                FeedView(model: model)
            case .likes:
                TrackList(feed: model.library.likes, player: model.player)
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
