import AVFoundation
import NukeUI
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

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
                AccountRow(model: model, section: $section)
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

// MARK: - Floating player pill (Apple Music style, bottom-centered)

struct PlayerPill: View {
    /// Bottom space the detail content reserves so its last row clears the pill, which floats as an
    /// overlay and takes no layout space of its own.
    static let reservedHeight: CGFloat = 72

    let player: PlayerEngine
    var onOpenTrack: (SCTrack) -> Void = { _ in }
    var onOpenArtist: (SCUser) -> Void = { _ in }

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
            onToggle: { player.togglePlayPause() },
            onSeek: { player.seek(to: $0) },
            onShuffle: player.toggleShuffle,
            onRepeat: player.cycleRepeat,
            onPrevious: { Task { await player.previous() } },
            onNext: { Task { await player.next() } },
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
    let onToggle: () -> Void
    let onSeek: (Double) -> Void
    var onShuffle: () -> Void = {}
    var onRepeat: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
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

struct QueueButton: View {
    let player: PlayerEngine
    @State private var showQueue = false

    var body: some View {
        Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }
            .buttonStyle(.borderless)
            .popover(isPresented: $showQueue, arrowEdge: .bottom) {
                QueueView(player: player)
            }
    }
}

struct QueueView: View {
    let player: PlayerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Playing Next")
                .font(.headline)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            List {
                ForEach(player.queue) { track in
                    QueueItemView(track: track, isCurrent: track.id == player.currentTrack?.id) {
                        if let index = player.queue.firstIndex(where: { $0.id == track.id }) {
                            Task { await player.jump(to: index) }
                        }
                    }
                }
                .onMove { player.moveInQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(atOffsets: $0) }
            }
            .listStyle(.inset)
        }
        .frame(width: 360, height: 460)
    }
}

struct QueueItemView: View {
    let track: SCTrack
    let isCurrent: Bool
    let onJump: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Click the artwork to jump; the rest of the row stays free for drag-to-reorder.
            Button(action: onJump) {
                ZStack {
                    LazyImage(url: track.artworkURL.flatMap(URL.init)) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    if hovering {
                        Color.black.opacity(0.4)
                        Image(systemName: "play.fill").foregroundStyle(.white).font(.system(size: 14))
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text(track.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.tint)
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
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

// MARK: - Track lists

struct TrackTable: View {
    let tracks: [SCTrack]
    let player: PlayerEngine
    var isLoading = false
    var onReachEnd: () async -> Void = {}

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(tracks) { track in
                    TrackRow(track: track, player: player, queueContext: tracks)
                        .onAppear {
                            if track.id == tracks.last?.id { Task { await onReachEnd() } }
                        }
                }
                if isLoading {
                    ProgressView().controlSize(.small).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct TrackList: View {
    let feed: TrackFeed
    let player: PlayerEngine

    var body: some View {
        TrackTable(
            tracks: feed.tracks, player: player, isLoading: feed.isLoading,
            onReachEnd: { await feed.loadMore() })
        .overlay {
            if let error = feed.error, feed.tracks.isEmpty {
                ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            }
        }
        .task { feed.loadInitialIfNeeded() }
    }
}

enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case tracks = "Tracks"
    case artists = "Artists"
    case playlists = "Playlists"

    var id: String { rawValue }
}

enum SearchSort: String, CaseIterable, Identifiable {
    case relevance = "Relevance"
    case popular = "Most popular"
    case plays = "Most played"
    case likes = "Most liked"
    case duration = "Longest"
    case followers = "Most followers"
    case trackCount = "Most tracks"

    var id: String { rawValue }
}

struct SearchResultsView: View {
    let model: AppModel
    @State private var scope: SearchScope = .all
    @State private var sort: SearchSort = .relevance

    private static let previewLimit = 4

    private var results: [SCSearchItem] { model.library.searchResults }

    private var rawUsers: [SCUser] {
        results.compactMap { if case .user(let u) = $0 { u } else { nil } }
    }
    private var rawPlaylists: [SCPlaylist] {
        results.compactMap { if case .playlist(let p) = $0 { p } else { nil } }
    }
    private var rawTracks: [SCTrack] {
        results.compactMap { if case .track(let t) = $0 { t } else { nil } }
    }

    /// Instant FTS5 hits from the local GRDB cache, minus whatever the network already returned.
    private var libraryTracks: [SCTrack] {
        let networkIDs = Set(rawTracks.map(\.id))
        return model.library.localSearchResults.filter { !networkIDs.contains($0.id) }
    }

    private var tracks: [SCTrack] {
        switch sort {
        case .plays, .popular: rawTracks.sorted { ($0.playbackCount ?? 0) > ($1.playbackCount ?? 0) }
        case .likes: rawTracks.sorted { ($0.likesCount ?? 0) > ($1.likesCount ?? 0) }
        case .duration: rawTracks.sorted { $0.duration > $1.duration }
        default: rawTracks
        }
    }
    private var users: [SCUser] {
        switch sort {
        case .followers, .popular: rawUsers.sorted { ($0.followersCount ?? 0) > ($1.followersCount ?? 0) }
        default: rawUsers
        }
    }
    private var playlists: [SCPlaylist] {
        switch sort {
        case .trackCount, .popular: rawPlaylists.sorted { $0.trackCount > $1.trackCount }
        default: rawPlaylists
        }
    }

    private var sortOptions: [SearchSort] {
        switch scope {
        case .all: [.relevance, .popular]
        case .tracks: [.relevance, .plays, .likes, .duration]
        case .artists: [.relevance, .followers]
        case .playlists: [.relevance, .trackCount]
        }
    }

    var body: some View {
        if results.isEmpty && libraryTracks.isEmpty {
            Group {
                if model.library.isSearching {
                    ProgressView()
                } else {
                    ContentUnavailableView.search
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                header
                list
            }
            .onChange(of: scope) { _, _ in
                if !sortOptions.contains(sort) { sort = .relevance }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $scope) {
                ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !sortOptions.isEmpty {
                sortMenu
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        List {
            switch scope {
            case .all: allSections
            case .tracks: scopeSection(tracks, empty: "No tracks") { trackRow($0) }
            case .artists: scopeSection(users, empty: "No artists") { artistRow($0) }
            case .playlists: scopeSection(playlists, empty: "No playlists") { playlistRow($0) }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var allSections: some View {
        if !libraryTracks.isEmpty {
            Section("From your library") {
                ForEach(libraryTracks.prefix(Self.previewLimit)) { track in
                    TrackRow(track: track, player: model.player, queueContext: libraryTracks)
                }
            }
        }
        if !users.isEmpty {
            previewSection("Artists", users, scope: .artists) { artistRow($0) }
        }
        if !tracks.isEmpty {
            previewSection("Tracks", tracks, scope: .tracks) { trackRow($0) }
        }
        if !playlists.isEmpty {
            previewSection("Playlists", playlists, scope: .playlists) { playlistRow($0) }
        }
    }

    @ViewBuilder
    private func previewSection<Item: Identifiable, RowContent: View>(
        _ title: String, _ items: [Item], scope target: SearchScope,
        @ViewBuilder row: @escaping (Item) -> RowContent
    ) -> some View {
        Section {
            ForEach(items.prefix(Self.previewLimit)) { row($0) }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if items.count > Self.previewLimit {
                    Button("See all") { scope = target }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .textCase(nil)
                }
            }
        }
    }

    @ViewBuilder
    private func scopeSection<Item: Identifiable, RowContent: View>(
        _ items: [Item], empty: String, @ViewBuilder row: @escaping (Item) -> RowContent
    ) -> some View {
        if items.isEmpty {
            Text(empty)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
                .listRowSeparator(.hidden)
        } else {
            ForEach(items) { row($0) }
        }
    }

    private func trackRow(_ track: SCTrack) -> some View {
        TrackRow(track: track, player: model.player, queueContext: tracks)
    }
    private func artistRow(_ user: SCUser) -> some View {
        NavigationLink(value: user) { UserRow(user: user) }
    }
    private func playlistRow(_ playlist: SCPlaylist) -> some View {
        NavigationLink(value: playlist) { PlaylistRow(playlist: playlist) }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(sortOptions) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Account row (sidebar) & Home

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

struct StreamItemView: View {
    let item: SCStreamItem
    let model: AppModel
    let context: [SCTrack]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let reposter = item.reposter {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.2.squarepath").foregroundStyle(.tint)
                    Text("\(reposter.username) reposted")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            }
            switch item.content {
            case .track(let track):
                TrackRow(track: track, player: model.player, queueContext: context)
            case .playlist(let playlist):
                NavigationLink(value: playlist) { PlaylistRow(playlist: playlist) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

// MARK: - Home/Profile building blocks

/// A titled horizontal shelf of cards with an optional "See all" action.
struct HomeCarousel<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    var seeAll: (() -> Void)? = nil
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2).bold()
                Spacer()
                if let seeAll {
                    Button("See all", action: seeAll)
                        .buttonStyle(.plain).foregroundStyle(.tint).font(.subheadline)
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct TrackCard: View {
    let track: SCTrack
    let player: PlayerEngine
    var context: [SCTrack] = []

    @State private var hovering = false
    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: play) {
                ZStack {
                    LazyImage(url: track.artworkURL.scArtwork()) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    if hovering || (isCurrent && player.isPlaying) {
                        Color.black.opacity(0.35)
                        Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26)).foregroundStyle(.white)
                    }
                }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            NavigationLink(value: track) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain)

            NavigationLink(value: track.user) {
                Text(track.artistLine)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 160, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private func play() {
        if isCurrent {
            player.togglePlayPause()
        } else {
            Task { await player.play(track, in: context.isEmpty ? [track] : context) }
        }
    }
}

struct PlaylistCard: View {
    let playlist: SCPlaylist
    let model: AppModel

    @State private var hovering = false
    @State private var isStarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: play) {
                ZStack {
                    LazyImage(url: playlist.artworkURL.scArtwork()) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    if hovering || isStarting {
                        Color.black.opacity(0.35)
                        if isStarting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 26)).foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink(value: playlist) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(playlist.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 160, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 160, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private func play() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            await model.play(playlist)
        }
    }
}

// MARK: - Profile

struct ProfileView: View {
    let model: AppModel
    @Binding var section: LibrarySection?

    @State private var uploads: [SCTrack] = []

    private var likes: [SCTrack] { model.library.likes.tracks }
    private var playlists: [SCPlaylist] { model.library.playlists }

    var body: some View {
        ScrollView {
            if let me = model.library.meUser {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ProfileHeader(user: me)

                    if !likes.isEmpty {
                        HomeCarousel(title: "Likes", items: Array(likes.prefix(20)),
                                     seeAll: { section = .likes }) { track in
                            TrackCard(track: track, player: model.player, context: likes)
                        }
                    }
                    if !playlists.isEmpty {
                        HomeCarousel(title: "Playlists", items: Array(playlists.prefix(20)),
                                     seeAll: { section = .playlists }) { playlist in
                            PlaylistCard(playlist: playlist, model: model)
                        }
                    }
                    if !uploads.isEmpty {
                        HomeCarousel(title: "Tracks", items: uploads) { track in
                            TrackCard(track: track, player: model.player, context: uploads)
                        }
                    }
                }
                .padding(.vertical, 16)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .navigationTitle("Profile")
        .task {
            model.library.loadMe()
            model.library.likes.loadInitialIfNeeded()
            model.library.loadPlaylistsIfNeeded()
        }
        .task(id: model.library.meUser?.id) {
            guard let me = model.library.meUser, uploads.isEmpty else { return }
            uploads = (try? await model.api.userTracks(id: me.id))?.collection ?? []
        }
    }
}

struct ProfileHeader: View {
    let user: SCUser

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            LazyImage(url: user.avatarURL.scArtwork()) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 128, height: 128)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(user.username).font(.largeTitle).bold().lineLimit(1)
                    if user.verified == true {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint)
                    }
                }
                HStack(spacing: 28) {
                    stat(user.followersCount ?? 0, "Followers")
                    stat(user.followingsCount ?? 0, "Following")
                    stat(user.trackCount ?? 0, "Tracks")
                }
                if let city = user.city, !city.isEmpty {
                    Label(city, systemImage: "mappin.and.ellipse")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(countString(value)).font(.headline).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct UserRow: View {
    let user: SCUser

    var body: some View {
        HStack(spacing: 10) {
            LazyImage(url: user.avatarURL.flatMap(URL.init)) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(user.username).lineLimit(1)
                    if user.verified == true {
                        Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.tint)
                    }
                }
                Text("Artist · \(countString(user.followersCount ?? 0)) followers")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct PlaylistRow: View {
    let playlist: SCPlaylist

    var body: some View {
        HStack(spacing: 10) {
            LazyImage(url: playlist.artworkURL.flatMap(URL.init)) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).lineLimit(1)
                Text("\(playlist.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PlaylistTracksView: View {
    let playlist: SCPlaylist
    let library: LibraryStore
    let player: PlayerEngine

    @State private var tracks: [SCTrack] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                PlaylistHeader(playlist: playlist, tracks: tracks, player: player)
                    .padding(.bottom, 16)

                ForEach(tracks) { track in
                    TrackRow(track: track, player: player, queueContext: tracks)
                }
                if isLoading {
                    ProgressView().controlSize(.small).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle(playlist.title)
        .task {
            tracks = await library.tracks(for: playlist)
            isLoading = false
        }
    }
}

struct PlaylistHeader: View {
    let playlist: SCPlaylist
    let tracks: [SCTrack]
    let player: PlayerEngine

    private var kindLabel: String {
        playlist.isAlbum ? "Album" : playlist.isSystem ? "Mix" : "Playlist"
    }

    private var summary: String {
        let count = tracks.isEmpty ? playlist.trackCount : tracks.count
        let ms = tracks.isEmpty ? (playlist.duration ?? 0) : tracks.reduce(0) { $0 + $1.duration }
        var parts = ["\(count) tracks"]
        if ms > 0 { parts.append(longDurationString(ms: ms)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            LazyImage(url: playlist.artworkURL.scArtwork()) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(kindLabel.uppercased())
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                Text(playlist.title).font(.largeTitle).bold().lineLimit(2)
                if let user = playlist.user {
                    NavigationLink(value: user) {
                        Text(user.username).font(.subheadline).foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
                Text(summary).font(.caption).foregroundStyle(.secondary)
                if let description = playlist.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button {
                        guard let first = tracks.first else { return }
                        Task { await player.play(first, in: tracks) }
                    } label: {
                        Label("Play", systemImage: "play.fill").frame(minWidth: 76)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { await player.playShuffled(tracks) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(minWidth: 76)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(tracks.isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

// MARK: - Artist page

enum ArtistTab: String, CaseIterable, Identifiable {
    case popular = "Popular"
    case tracks = "Tracks"
    case albums = "Albums"
    case playlists = "Playlists"
    case reposts = "Reposts"

    var id: String { rawValue }
}

struct ArtistView: View {
    let user: SCUser
    let model: AppModel

    @State private var tab: ArtistTab = .popular
    @State private var popular: [SCTrack] = []
    @State private var tracks: [SCTrack] = []
    @State private var tracksNextHref: String?
    @State private var albums: [SCPlaylist] = []
    @State private var playlists: [SCPlaylist] = []
    @State private var reposts: [SCStreamItem] = []
    @State private var loadedTabs: Set<ArtistTab> = []
    @State private var isLoading = false

    private var repostTracks: [SCTrack] {
        reposts.compactMap { if case .track(let t) = $0.content { t } else { nil } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if let banner = user.bannerURL.flatMap(URL.init) {
                    LazyImage(url: banner) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.1)
                        }
                    }
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 4)
                }

                ArtistHeader(user: user)
                    .padding(.bottom, 8)

                Picker("", selection: $tab) {
                    ForEach(ArtistTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.bottom, 10)

                tabContent

                if isLoading {
                    ProgressView().controlSize(.small).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle(user.username)
        .task(id: tab) { await load(tab) }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .popular:
            trackRows(popular, empty: "No tracks yet")
        case .tracks:
            ForEach(tracks) { track in
                TrackRow(track: track, player: model.player, queueContext: tracks)
                    .onAppear {
                        if track.id == tracks.last?.id { Task { await loadMoreTracks() } }
                    }
            }
            emptyNote(show: tracks.isEmpty, "No tracks yet")
        case .albums:
            playlistRows(albums, empty: "No albums yet")
        case .playlists:
            playlistRows(playlists, empty: "No playlists yet")
        case .reposts:
            ForEach(reposts) { item in
                StreamItemView(item: item, model: model, context: repostTracks)
            }
            emptyNote(show: reposts.isEmpty, "No reposts yet")
        }
    }

    @ViewBuilder
    private func trackRows(_ items: [SCTrack], empty: String) -> some View {
        ForEach(items) { track in
            TrackRow(track: track, player: model.player, queueContext: items)
        }
        emptyNote(show: items.isEmpty, empty)
    }

    @ViewBuilder
    private func playlistRows(_ items: [SCPlaylist], empty: String) -> some View {
        ForEach(items) { playlist in
            NavigationLink(value: playlist) { PlaylistRow(playlist: playlist) }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        emptyNote(show: items.isEmpty, empty)
    }

    @ViewBuilder
    private func emptyNote(show: Bool, _ text: String) -> some View {
        if show && !isLoading && loadedTabs.contains(tab) {
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
        }
    }

    private func load(_ tab: ArtistTab) async {
        guard !loadedTabs.contains(tab) else { return }
        isLoading = true
        defer {
            isLoading = false
            loadedTabs.insert(tab)
        }
        switch tab {
        case .popular:
            popular = (try? await model.api.userTopTracks(id: user.id))?.collection ?? []
        case .tracks:
            let page = try? await model.api.userTracks(id: user.id)
            tracks = page?.collection ?? []
            tracksNextHref = page?.nextHref
        case .albums:
            albums = (try? await model.api.userAlbums(id: user.id)) ?? []
        case .playlists:
            playlists = (try? await model.api.userPlaylists(id: user.id)) ?? []
        case .reposts:
            reposts = (try? await model.api.userReposts(id: user.id))?.collection ?? []
        }
    }

    private func loadMoreTracks() async {
        guard let href = tracksNextHref else { return }
        tracksNextHref = nil
        let page = try? await model.api.nextTrackPage(href)
        tracks.append(contentsOf: page?.collection ?? [])
        tracksNextHref = page?.nextHref
    }
}

struct ArtistHeader: View {
    let user: SCUser

    var body: some View {
        HStack(spacing: 16) {
            LazyImage(url: user.avatarURL.scArtwork()) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(user.username).font(.title2).bold().lineLimit(1)
                    if user.verified == true {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint)
                    }
                }
                HStack(spacing: 12) {
                    Label(countString(user.followersCount ?? 0), systemImage: "person.2.fill")
                    Label("\(user.trackCount ?? 0) tracks", systemImage: "music.note")
                    if let city = user.city, !city.isEmpty {
                        Label(city, systemImage: "mappin.and.ellipse")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let description = user.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer()
        }
        .padding(12)
    }
}

// MARK: - Track detail page

struct TrackDetailView: View {
    let track: SCTrack
    let model: AppModel

    @State private var waveform = WaveformLoader()

    private var isCurrent: Bool { track.id == model.player.currentTrack?.id }
    private var progress: Double {
        guard isCurrent, model.player.duration > 0 else { return 0 }
        return model.player.currentTime / model.player.duration
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 20) {
                    LazyImage(url: track.artworkURL.scArtwork()) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 8, y: 4)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(track.title).font(.largeTitle).bold().lineLimit(3)
                        NavigationLink(value: track.user) {
                            HStack(spacing: 6) {
                                Text(track.artistLine).font(.title3)
                                if track.user.verified == true {
                                    Image(systemName: "checkmark.seal.fill").imageScale(.small)
                                }
                            }
                            .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 10) {
                            if let genre = track.genre, !genre.isEmpty { GenreBadge(text: genre) }
                            if let album = track.album, !album.isEmpty {
                                Label(album, systemImage: "square.stack").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(timeString(Double(track.duration) / 1000))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Button(action: play) {
                            Label(isCurrent && model.player.isPlaying ? "Pause" : "Play",
                                  systemImage: isCurrent && model.player.isPlaying ? "pause.fill" : "play.fill")
                                .frame(minWidth: 100)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    Spacer(minLength: 0)
                }

                WaveformView(waveform: waveform.waveform, progress: progress)
                    .frame(height: 64)

                detailStats
            }
            .padding(24)
        }
        .navigationTitle(track.title)
        .task(id: track.id) { waveform.load(track.waveformURL) }
    }

    private var detailStats: some View {
        HStack(spacing: 28) {
            statColumn("Plays", "play.fill", track.playbackCount)
            statColumn("Likes", "heart.fill", track.likesCount)
            statColumn("Comments", "text.bubble.fill", track.commentCount)
            statColumn("Reposts", "arrow.2.squarepath", track.repostsCount)
            Spacer()
        }
    }

    @ViewBuilder
    private func statColumn(_ label: String, _ symbol: String, _ count: Int?) -> some View {
        if let count, count > 0 {
            VStack(spacing: 4) {
                Label(countString(count), systemImage: symbol).font(.headline).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func play() {
        if isCurrent {
            model.player.togglePlayPause()
        } else {
            Task { await model.player.play(track) }
        }
    }
}

struct TrackRow: View {
    let track: SCTrack
    let player: PlayerEngine
    var queueContext: [SCTrack] = []

    @State private var hovering = false

    private var isCurrent: Bool { track.id == player.currentTrack?.id }

    var body: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 3) {
                NavigationLink(value: track) {
                    Text(track.title)
                        .font(.system(size: 15))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
                NavigationLink(value: track.user) {
                    Text(track.artistLine)
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            stats

            Text(timeString(Double(track.duration) / 1000))
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
                .opacity(hovering ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { play() }
        .trackContextMenu(track, player: player)
    }

    private var artwork: some View {
        Button(action: artworkTapped) {
            ZStack {
                LazyImage(url: track.artworkURL.flatMap(URL.init)) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
                if hovering {
                    Color.black.opacity(0.4)
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(.white).font(.system(size: 18))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var stats: some View {
        HStack(spacing: 16) {
            stat("play.fill", track.playbackCount)
            stat("heart.fill", track.likesCount)
            stat("text.bubble.fill", track.commentCount)
            stat("arrow.2.squarepath", track.repostsCount)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func stat(_ symbol: String, _ count: Int?) -> some View {
        if let count, count > 0 {
            HStack(spacing: 4) {
                Image(systemName: symbol).imageScale(.small)
                Text(countString(count)).monospacedDigit()
            }
        }
    }

    private func artworkTapped() {
        if isCurrent { player.togglePlayPause() } else { play() }
    }

    private func play() {
        Task { await player.play(track, in: queueContext.isEmpty ? [track] : queueContext) }
    }
}

struct GenreBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - Genre browsing

struct SCGenre: Identifiable, Hashable {
    let name: String
    let slug: String

    var id: String { slug }
    var urn: String { "soundcloud:genres:\(slug)" }

    static let all = SCGenre(name: "All genres", slug: "all-music")
    static let browse: [SCGenre] = [
        SCGenre(name: "Hip-hop & Rap", slug: "hiphoprap"),
        SCGenre(name: "Electronic", slug: "electronic"),
        SCGenre(name: "Dance & EDM", slug: "danceedm"),
        SCGenre(name: "Pop", slug: "pop"),
        SCGenre(name: "R&B & Soul", slug: "rbsoul"),
        SCGenre(name: "Rock", slug: "rock"),
        SCGenre(name: "Indie", slug: "indie"),
        SCGenre(name: "House", slug: "house"),
        SCGenre(name: "Deep House", slug: "deephouse"),
        SCGenre(name: "Techno", slug: "techno"),
        SCGenre(name: "Trance", slug: "trance"),
        SCGenre(name: "Drum & Bass", slug: "drumbass"),
        SCGenre(name: "Dubstep", slug: "dubstep"),
        SCGenre(name: "Trap", slug: "trap"),
        SCGenre(name: "Trip-hop", slug: "triphop"),
        SCGenre(name: "Ambient", slug: "ambient"),
        SCGenre(name: "Classical", slug: "classical"),
        SCGenre(name: "Jazz & Blues", slug: "jazzblues"),
        SCGenre(name: "Metal", slug: "metal"),
        SCGenre(name: "Country", slug: "country"),
        SCGenre(name: "Folk", slug: "folksingersongwriter"),
        SCGenre(name: "Latin", slug: "latin"),
        SCGenre(name: "Reggae", slug: "reggae"),
        SCGenre(name: "Reggaeton", slug: "reggaeton"),
        SCGenre(name: "Disco", slug: "disco"),
        SCGenre(name: "Piano", slug: "piano"),
        SCGenre(name: "Soundtrack", slug: "soundtrack"),
        SCGenre(name: "World", slug: "world"),
    ]
}

/// Shown while the search field is focused but empty: browse the top chart per genre.
struct GenreGridView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Browse").font(.title2).bold()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(Array(SCGenre.browse.enumerated()), id: \.element) { index, genre in
                        NavigationLink(value: genre) {
                            GenreTile(genre: genre, index: index)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
    }
}

struct GenreTile: View {
    let genre: SCGenre
    let index: Int

    var body: some View {
        let hue = Double(index) / Double(max(SCGenre.browse.count, 1))
        RoundedRectangle(cornerRadius: 10)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.85),
                        Color(hue: hue, saturation: 0.75, brightness: 0.5),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(height: 72)
            .overlay(alignment: .bottomLeading) {
                Text(genre.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
            }
    }
}

struct GenreChartView: View {
    let genre: SCGenre
    let model: AppModel

    @State private var tracks: [SCTrack] = []
    @State private var nextHref: String?
    @State private var isLoading = true

    var body: some View {
        TrackTable(tracks: tracks, player: model.player, isLoading: isLoading, onReachEnd: loadMore)
            .navigationTitle(genre.name)
            .task {
                guard tracks.isEmpty else { return }
                let page = try? await model.api.genrePopular(slug: genre.slug)
                tracks = page?.collection ?? []
                nextHref = page?.nextHref
                isLoading = false
            }
    }

    private func loadMore() async {
        guard let href = nextHref else { return }
        nextHref = nil
        let page = try? await model.api.nextGenrePopularPage(href)
        tracks.append(contentsOf: page?.collection ?? [])
        nextHref = page?.nextHref
    }
}

func countString(_ n: Int) -> String {
    let value: Double
    let suffix: String
    if n >= 1_000_000 { value = Double(n) / 1_000_000; suffix = "M" }
    else if n >= 1_000 { value = Double(n) / 1_000; suffix = "K" }
    else { return "\(n)" }
    return (value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)) + suffix
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

func longDurationString(ms: Int) -> String {
    let minutes = ms / 60_000
    guard minutes >= 60 else { return "\(minutes) min" }
    return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
}

#Preview {
    ContentView()
}
