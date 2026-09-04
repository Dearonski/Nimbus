import SwiftUI

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
        NavButton(value: user) { UserRow(user: user) }
    }
    private func playlistRow(_ playlist: SCPlaylist) -> some View {
        NavButton(value: playlist) { PlaylistRow(playlist: playlist) }
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
