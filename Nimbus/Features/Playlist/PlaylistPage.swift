import SwiftUI

/// A set's page, laid out like the track page: the hero across the top, the tracklist beside a
/// rail. Same widths as `TrackDetailView`, so going from a track to the album it sits on keeps
/// every edge where it was.
struct PlaylistPage: View {
    let playlist: SCPlaylist
    let model: AppModel

    @Environment(\.metrics) private var metrics
    @Environment(PageRoom.self) private var room: PageRoom?

    @State private var page: PlaylistPageModel?

    private var showsRail: Bool { TrackDetailView.showsRail(in: room, usable: metrics.usable) }

    /// The tracklist starts on the hero card's own left edge, the way the site lines a set's tracks
    /// up with its hero block; the right side keeps the card's inset, which is what puts the rail
    /// under the artwork.
    static let columnInsets = EdgeInsets(top: 0, leading: gutter, bottom: 0,
                                         trailing: gutter + ContentMetrics.heroInset)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let page {
                    PlaylistHero(page: page, model: model)
                        .padding(.horizontal, gutter)
                        .padding(.top, 10)

                    // AnyLayout, not if/else: crossing the threshold rebuilt the tracklist and rail.
                    let layout = showsRail
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
                    layout {
                        PlaylistTracklist(page: page, model: model)
                        PlaylistRail(page: page, model: model)
                            .frame(width: showsRail ? TrackDetailView.railWidth : nil,
                                   alignment: .leading)
                    }
                    .padding(Self.columnInsets)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                    .animation(.snappy, value: showsRail)
                }
            }
        }
        .overlay {
            if let page, let failure = page.loadError, page.tracks.isEmpty {
                LoadFailure(message: failure) { Task { await page.load() } }
            }
        }
        .task(id: playlist.id) {
            let pageModel = PlaylistPageModel(playlist: playlist, api: model.api, library: model.library)
            page = pageModel
            model.library.loadPlaylistStateIfNeeded()
            await pageModel.load()
        }
    }
}

/// The column under the hero: release date and description, then the numbered tracks. The rows
/// bleed their hover highlight past the column edge, so the covers sit on that edge with the text
/// above them, instead of a row-inset in.
struct PlaylistTracklist: View {
    let page: PlaylistPageModel
    let model: AppModel

    var body: some View {
        let indexWidth = TrackRow.indexWidth(for: page.tracks.count)
        LazyVStack(alignment: .leading, spacing: 2) {
            details(page.playlist)
            // By position, not by track id: a playlist can hold the same track twice.
            ForEach(Array(page.tracks.enumerated()), id: \.offset) { offset, track in
                TrackRow(track: track, player: model.player, queue: .exactly(page.tracks),
                         index: offset + 1, indexWidth: indexWidth)
                    .padding(.horizontal, -TrackRow.inset)
            }
            FeedFooter(isLoading: page.isLoading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func details(_ playlist: SCPlaylist) -> some View {
        // A mix's description ("Based on …") sits at the top of its rail instead, as on the site.
        let text = playlist.isSystem ? ""
            : playlist.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty || playlist.releaseLabel != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let released = playlist.releaseLabel {
                    Text("Released \(released)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if !text.isEmpty {
                    ArtistBio(text: text)
                        .frame(maxWidth: 680, alignment: .leading)
                }
            }
            .padding(.bottom, 14)
        }
    }
}

/// Everything a set's page shows besides the set itself. The tracks decide whether there is
/// anything to play; the author and the people who liked or reposted only fill the rail, and a
/// failure there simply leaves a block out.
@Observable
final class PlaylistPageModel {
    /// The set as the list that opened the page had it, until the full one arrives. A card in a
    /// feed or a library row carries enough to draw a cover and a title, but not necessarily the
    /// description, the release date or what kind of set it is.
    var playlist: SCPlaylist { full ?? opened }

    private let opened: SCPlaylist
    private var full: SCPlaylist?
    private let api: SoundCloudAPI
    private let library: LibraryStore

    private(set) var tracks: [SCTrack] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    /// The nested user on a set carries a name and an avatar; the rail's card needs counts.
    private(set) var author: SCUser?
    private(set) var likers: [SCUser] = []
    private(set) var reposters: [SCUser] = []
    /// A mix has no author to put in the rail, so the site lists who is on it instead: the first
    /// three uploaders in track order, each once.
    private(set) var featuredArtists: [SCUser] = []

    init(playlist: SCPlaylist, api: SoundCloudAPI, library: LibraryStore) {
        self.opened = playlist
        self.api = api
        self.library = library
    }

    var trackCount: Int { tracks.isEmpty ? playlist.trackCount : tracks.count }

    var duration: Int {
        tracks.isEmpty ? (playlist.duration ?? 0) : tracks.reduce(0) { $0 + $1.duration }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        async let people: Void = loadPeople()
        async let details: Void = loadFullSet()
        do {
            tracks = try await library.tracks(for: opened)
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
        await people
        await details
        if opened.isSystem { await loadFeaturedArtists() }
    }

    private func loadFullSet() async {
        if opened.isSystem {
            full = try? await api.systemPlaylist(urn: opened.id)
        } else if let id = Int(opened.id) {
            full = try? await api.playlist(id: id)
        }
    }

    /// The user nested in a track has a follower count but no track count, and the row shows both
    /// — so each of the three is fetched in full, the way the site does it.
    private func loadFeaturedArtists() async {
        var seen = Set<Int>()
        let uploaders = tracks.map(\.user).filter { seen.insert($0.id).inserted }.prefix(3)
        featuredArtists = Array(uploaders)
        var full: [Int: SCUser] = [:]
        await withTaskGroup(of: SCUser?.self) { group in
            for artist in uploaders {
                group.addTask { [api] in try? await api.user(id: artist.id) }
            }
            for await user in group {
                if let user { full[user.id] = user }
            }
        }
        featuredArtists = uploaders.map { full[$0.id] ?? $0 }
    }

    private func loadPeople() async {
        // A system mix is identified by a urn and has neither an owner page nor likers.
        guard let id = Int(opened.id), !opened.isSystem else { return }
        async let liked = try? await api.playlistLikers(id: id)
        async let reposted = try? await api.playlistReposters(id: id)
        if let ownerID = opened.user?.id {
            author = try? await api.user(id: ownerID)
        }
        likers = await liked?.collection ?? []
        reposters = await reposted?.collection ?? []
    }
}

#if DEBUG
extension PlaylistPageModel {
    func seedForPreview(tracks: [SCTrack], likers: [SCUser] = []) {
        self.tracks = tracks
        self.likers = likers
        isLoading = false
    }
}
#endif

#if DEBUG
#Preview("Playlist tracklist") {
    let model = AppModel()
    let playlist = try! JSONDecoder().decode(SCPlaylist.self, from: Data("""
    {"id":1,"title":"LOVESONGS","kind":"playlist","set_type":"album","is_album":true,"track_count":12,
     "release_date":"2024-10-18T00:00:00Z","description":"Второй альбом. Записан летом у моря.",
     "user":{"id":9,"username":"Дора"},"tracks":[]}
    """.utf8))
    let tracks = (1...12).map { index in
        try! JSONDecoder().decode(SCTrack.self, from: Data("""
        {"id":\(index),"title":"Track \(index)","duration":214000,"permalink_url":"x","artwork_url":null,
         "user":{"id":9,"username":"Дора"},"media":{"transcodings":[]},"track_authorization":"",
         "playback_count":\(index * 4321)}
        """.utf8))
    }
    let page = PlaylistPageModel(playlist: playlist, api: model.api, library: model.library)
    page.seedForPreview(tracks: tracks)
    // With the page's own insets, so the covers can be checked against the hero card's edge.
    return VStack(alignment: .leading, spacing: 22) {
        PlaylistHero(page: page, model: model)
            .padding(.horizontal, gutter)
        PlaylistTracklist(page: page, model: model)
            .padding(PlaylistPage.columnInsets)
    }
    .padding(.vertical, 16)
    .frame(width: 1000, height: 820, alignment: .top)
    .environment(model.library)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}
#endif
