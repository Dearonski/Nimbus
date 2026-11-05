import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case tracks = "Tracks"
    case artists = "Artists"
    case albums = "Albums"
    case playlists = "Playlists"

    var id: String { rawValue }
}

enum SearchSort: String, Identifiable {
    case relevance = "Relevance"
    case popular = "Most popular"
    case plays = "Most played"
    case likes = "Most liked"
    case duration = "Longest"
    case followers = "Most followers"
    case trackCount = "Most tracks"

    var id: String { rawValue }

    static func options(in scope: SearchScope) -> [SearchSort] {
        switch scope {
        case .all: [.relevance, .popular]
        case .tracks: [.relevance, .plays, .likes, .duration]
        case .artists: [.relevance, .followers]
        case .albums, .playlists: [.relevance, .trackCount]
        }
    }
}

// Shared by the page, the sidebar's field and the window's toolbar, which holds the scope and the sort.
@MainActor
@Observable
final class SearchControls {
    var query = ""
    var scope: SearchScope = .all {
        didSet { if !sortOptions.contains(sort) { sort = .relevance } }
    }
    var sort: SearchSort = .relevance
    // Return in the field; a pasted link opens on it.
    private(set) var submits = 0

    private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []

    var sortOptions: [SearchSort] { SearchSort.options(in: scope) }
    var isBlank: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static let recentsKey = "search.recents"
    private static let recentsKept = 8

    func submit() {
        submits += 1
        remember(query)
    }

    // A search counts once it is acted on — Return, a suggestion, a result opened — not at every keystroke.
    func remember(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, SoundCloudLink.url(in: query) == nil else { return }
        var list = recents.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        list.insert(query, at: 0)
        recents = Array(list.prefix(Self.recentsKept))
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }
}

struct SearchResultsView: View {
    let model: AppModel

    @State private var width: CGFloat = 0
    @Environment(\.metrics) private var metrics

    private static let spacing: CGFloat = 12

    private var controls: SearchControls { model.searchControls }
    private var search: SearchModel { model.library.search }

    /// Instant FTS5 hits from the local GRDB cache, minus whatever the network already returned.
    private var libraryTracks: [SCTrack] {
        let networkIDs = Set((search.tracks?.items ?? []).map(\.id))
        return search.localResults.filter { !networkIDs.contains($0.id) }
    }

    private var tracks: [SCTrack] {
        let tracks = search.tracks?.items ?? []
        return switch controls.sort {
        case .plays, .popular: tracks.sorted { ($0.playbackCount ?? 0) > ($1.playbackCount ?? 0) }
        case .likes: tracks.sorted { ($0.likesCount ?? 0) > ($1.likesCount ?? 0) }
        case .duration: tracks.sorted { $0.duration > $1.duration }
        default: tracks
        }
    }
    private var users: [SCUser] {
        let users = search.users?.items ?? []
        return switch controls.sort {
        case .followers, .popular: users.sorted { ($0.followersCount ?? 0) > ($1.followersCount ?? 0) }
        default: users
        }
    }
    private func sets(_ pager: Pager<SCPlaylist>?) -> [SCPlaylist] {
        let sets = pager?.items ?? []
        return switch controls.sort {
        case .trackCount, .popular: sets.sorted { $0.trackCount > $1.trackCount }
        default: sets
        }
    }

    // As many columns as the width takes, so a preview is whole rows instead of a ragged last one.
    private var columns: Int {
        let usable = width - gutter * 2 + Self.spacing
        return max(1, Int(usable / (metrics.rowGrid + Self.spacing)))
    }

    var body: some View {
        if search.isEmpty && libraryTracks.isEmpty {
            if search.isSearching {
                ScrollView { TrackRowsSkeleton().padding(.vertical, 8) }
            } else if let error = search.error {
                LoadFailure(title: "Couldn't search", message: error) { search.retry() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                // Lazy, so a scope's footer only asks for the next page once it is scrolled to.
                LazyVStack(alignment: .leading, spacing: 30) {
                    switch controls.scope {
                    case .all: allSections
                    case .tracks: trackGrid
                    case .artists: artistGrid
                    case .albums: setGrid(search.albums, empty: "No albums")
                    case .playlists: setGrid(search.playlists, empty: "No playlists")
                    }
                }
                .padding(.vertical, 16)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    @ViewBuilder
    private var allSections: some View {
        // Sorted once a pass: read inside each row, the whole result set was sorted again for every row.
        let tracks = tracks
        let library = libraryTracks
        let preview = columns * 3
        if !library.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                heading("From Your Library")
                pills(Array(library.prefix(columns * 2)), queue: .exactly(library))
            }
        }
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                heading("Tracks", more: .tracks)
                pills(Array(tracks.prefix(preview)), queue: .exactly(tracks))
            }
        }
        if !users.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                heading("Artists", more: .artists)
                Shelf(spacing: 20) { ForEach(users) { ArtistCircle(artist: $0) } }
            }
        }
        shelf("Albums", sets(search.albums), more: .albums)
        shelf("Playlists", sets(search.playlists), more: .playlists)
    }

    @ViewBuilder
    private func shelf(_ title: String, _ sets: [SCPlaylist], more scope: SearchScope) -> some View {
        if !sets.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                heading(title, more: scope)
                Shelf { ForEach(sets) { PlaylistCard(playlist: $0, model: model) } }
            }
        }
    }

    private func heading(_ title: String, more scope: SearchScope? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .bold))
            Spacer()
            if let scope {
                Button("See All") { controls.scope = scope }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, gutter)
    }

    private func pills(_ shown: [SCTrack], queue: PlayQueue) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns),
                  spacing: Self.spacing) {
            ForEach(shown) { RecentPill(track: $0, player: model.player, queue: queue) }
        }
        .padding(.horizontal, gutter)
    }

    @ViewBuilder
    private var trackGrid: some View {
        let tracks = tracks
        if tracks.isEmpty {
            emptyScope("No tracks", pager: search.tracks)
        } else {
            pills(tracks, queue: .exactly(tracks))
            footer(search.tracks)
        }
    }

    @ViewBuilder
    private var artistGrid: some View {
        let users = users
        if users.isEmpty {
            emptyScope("No artists", pager: search.users)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.shelfAvatar + 20), spacing: 20)], spacing: 24) {
                ForEach(users) { ArtistCircle(artist: $0) }
            }
            .padding(.horizontal, gutter)
            footer(search.users)
        }
    }

    @ViewBuilder
    private func setGrid(_ pager: Pager<SCPlaylist>?, empty: String) -> some View {
        let sets = sets(pager)
        if sets.isEmpty {
            emptyScope(empty, pager: pager)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.card), spacing: 18)], spacing: 22) {
                ForEach(sets) { PlaylistCard(playlist: $0, model: model) }
            }
            .padding(.horizontal, gutter)
            footer(pager)
        }
    }

    // Always a row of its own: an idle footer draws nothing, and a lazy stack never shows an empty row to its task.
    @ViewBuilder
    private func footer<Item: Identifiable>(_ pager: Pager<Item>?) -> some View {
        if let pager, !pager.isComplete {
            ZStack {
                Color.clear
                FeedFooter(isLoading: pager.isLoading, error: pager.nextPageError) { await pager.loadMore() }
            }
            .frame(maxWidth: .infinity)
            .frame(height: FeedFooter.height())
            .task(id: pager.pagesLoaded) { await pager.loadMore() }
        }
    }

    @ViewBuilder
    private func emptyScope<Item: Identifiable>(_ text: String, pager: Pager<Item>?) -> some View {
        if pager?.isLoading ?? true {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }
}
