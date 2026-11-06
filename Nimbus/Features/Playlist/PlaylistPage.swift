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

    private var edits: Int { model.library.playlistEdits[playlist.id] ?? 0 }

    private var showsRail: Bool { DetailLayout.showsRail(in: room, usable: metrics.usable) }

    var body: some View {
        ZStack {
            if let page {
                PlaylistList(page: page, model: model, showsRail: showsRail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .listStatus(page.map { ListPhase(isEmpty: $0.tracks.isEmpty, isLoading: $0.isLoading,
                                         error: $0.loadError, wasAsked: $0.hasLoaded) } ?? .loading,
                    retry: { Task { await page?.load() } })
        .task(id: "\(playlist.id)#\(edits)") {
            // A kept page runs this again every time it is shown; a new model threw away what it had.
            if page?.playlist.id != playlist.id {
                page = model.pages.model(for: .playlist(playlist.id)) {
                    PlaylistPageModel(playlist: playlist, api: model.api, library: model.library)
                }
            }
            guard let page else { return }
            guard page.hasLoaded else {
                page.shownEdit = edits
                model.library.loadPlaylistStateIfNeeded()
                model.library.loadTrackStateIfNeeded()
                await page.load()
                return
            }
            guard page.shownEdit != edits else { return }
            page.shownEdit = edits
            await page.reload()
        }
        .sheet(isPresented: Binding(get: { page?.isEditing ?? false }, set: { page?.isEditing = $0 })) {
            if let page {
                PlaylistEditor(page: page, library: model.library)
            }
        }
    }
}

/// The hero across the top, then the numbered tracks beside the rail. The tracklist starts on the
/// hero card's own left edge, the way the site lines a set's tracks up with its hero block; the
/// right side keeps the card's inset, which is what puts the rail under the artwork. The rows bleed
/// their hover highlight past the column edge, so the covers sit on that edge.
struct PlaylistList: View {
    let page: PlaylistPageModel
    let model: AppModel
    let showsRail: Bool

    @Environment(\.onTitleCollapse) private var onTitleCollapse


    // By position, not by track id: a playlist can hold the same track twice.
    private struct Entry: Identifiable {
        let id: Int
        let track: SCTrack
    }

    private var removal: PlaylistTrackRemoval? {
        let playlist = page.playlist
        let library = model.library
        let player = model.player
        let page = page
        guard library.owns(playlist) else { return nil }
        return PlaylistTrackRemoval { track in
            page.hide(track)
            Task {
                do {
                    try await library.remove(track, from: playlist)
                } catch {
                    player.report("Couldn't remove “\(track.title)”: \(error.surfaced())")
                    await page.reload()
                }
            }
        }
    }

    var body: some View {
        let indexWidth = TrackRow.indexWidth(for: page.tracks.count)
        let queue = PlayQueue.exactly(page.tracks, context: .set(urn: page.playlist.urn))
        let entries = page.tracks.enumerated().map { Entry(id: $0.offset, track: $0.element) }
        CardCollection(items: entries,
                       rows: .measured(by: { _ in 0 }),
                       insets: NSEdgeInsets(top: 22, left: gutter, bottom: 8,
                                            right: gutter + ContentMetrics.heroInset),
                       spacing: 2,
                       bottomReserve: PlayerPill.reservedHeight,
                       paging: ListPaging(isLoading: page.isLoading),
                       chrome: CardCollectionChrome(
                           header: AnyView(PlaylistHero(page: page, model: model)
                               .padding(.horizontal, gutter)
                               .padding(.top, 10)),
                           lead: AnyView(PlaylistDetails(playlist: page.playlist)),
                           side: CardCollectionSide(width: DetailLayout.railWidth, spacing: 28,
                                                    isBeside: showsRail,
                                                    content: AnyView(PlaylistRail(page: page, model: model))),
                           titleEdge: DetailLayout.titleEdge,
                           onTitleCollapse: { onTitleCollapse($0) }),
                       rowOutset: TrackRow.inset,
                       onPrefetch: { ArtworkPrefetcher.warm($0.map(\.track.coverURL), size: .thumb) }) { entry in
            TrackRow(track: entry.track, player: model.player, queue: queue,
                     index: entry.id + 1, indexWidth: indexWidth)
        }
        .environment(\.playlistTrackRemoval, removal)
        .ignoresSafeArea()
    }
}

/// Release date and description, above the tracks.
struct PlaylistDetails: View {
    let playlist: SCPlaylist

    var body: some View {
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
                    ArtistBio(text: text, animatesItself: false)
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
    var playlist: SCPlaylist { library.patched(full ?? opened) }

    private let opened: SCPlaylist
    private var full: SCPlaylist?
    private let api: SoundCloudAPI
    private let library: LibraryStore

    private(set) var tracks: [SCTrack] = []
    var isEditing = false
    // The library's edit count this page last showed; a change made from another page shows on return.
    var shownEdit = 0
    private(set) var isLoading = true
    /// Set only by a load that ran to the end: one cut short by leaving the page runs again on return.
    private(set) var hasLoaded = false
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

    // Once listed, the tracks are the count: a set emptied here still reports its old one for a while.
    private var listsTracks: Bool { hasLoaded || !tracks.isEmpty }

    var trackCount: Int { listsTracks ? tracks.count : playlist.trackCount }

    var duration: Int {
        listsTracks ? tracks.reduce(0) { $0 + $1.duration } : (playlist.duration ?? 0)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        async let people: Void = loadPeople()
        async let details: Void = loadFullSet()
        do {
            if let ids = library.writtenTrackIDs(for: opened.id) {
                tracks = try await resolve(ids)
            } else {
                tracks = try await library.tracks(for: opened)
            }
            loadError = nil
        } catch {
            // Leaving mid-load cancels the request; that is no failure to put on screen.
            if !Task.isCancelled { loadError = error.surfaced() }
        }
        await people
        await details
        library.remember(tracks, in: playlist)
        if opened.isSystem { await loadFeaturedArtists() }
        if !Task.isCancelled { hasLoaded = true }
    }

    // After an edit: the order Nimbus wrote goes up at once, since SoundCloud's reads trail it for a while.
    func reload() async {
        if let ids = library.writtenTrackIDs(for: opened.id) {
            tracks = known(ids)
            if let resolved = try? await resolve(ids) { tracks = resolved }
        }
        guard let id = Int(opened.id), let fresh = try? await api.playlist(id: id, fresh: true) else { return }
        full = fresh
        guard library.writtenTrackIDs(for: opened.id) == nil,
              let resolved = try? await library.tracks(for: fresh) else { return }
        tracks = resolved
    }

    // Gone from the list before the write even starts; a refused one brings it back on reload.
    func hide(_ track: SCTrack) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) { tracks.remove(at: index) }
    }

    private func known(_ ids: [Int]) -> [SCTrack] {
        var byID = library.addedTracks
        for track in tracks { byID[track.id] = track }
        return ids.compactMap { byID[$0] }
    }

    private func resolve(_ ids: [Int]) async throws -> [SCTrack] {
        let have = Set(known(ids).map(\.id))
        let missing = ids.filter { !have.contains($0) }
        let fetched = try await api.tracks(ids: missing)
        var byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for track in known(ids) { byID[track.id] = track }
        return ids.compactMap { byID[$0] }
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
    return PlaylistList(page: page, model: model, showsRail: true)
    .frame(width: 1000, height: 820, alignment: .top)
    .environment(model.library)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}
#endif
