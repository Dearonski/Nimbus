import Foundation
import Observation

/// Everything an artist's page shows: the full profile, each tab's posts and the rail beside them.
/// Each tab loads the first time it is opened, and the rail's blocks each stay empty when theirs fails.
@Observable
final class ArtistPageModel {
    let id: Int
    let isMe: Bool
    private let api: SoundCloudAPI

    /// A page is opened from a track, whose nested user carries only id, name and avatar — no
    /// description, no visuals, no counts. The header needs the full profile.
    private(set) var profile: SCUser?

    let allPages: Pager<SCStreamItem>
    private(set) var spotlight: [SCStreamItem] = []
    private(set) var popular: [SCTrack] = []
    let trackPages: Pager<SCTrack>
    private(set) var albums: [SCPlaylist] = []
    private(set) var playlists: [SCPlaylist] = []
    private(set) var reposts: [SCStreamItem] = []
    private(set) var loadedTabs: Set<ArtistTab> = []
    private(set) var loadingTabs: Set<ArtistTab> = []
    private(set) var tabErrors: [ArtistTab: String] = [:]

    private(set) var likes: [SCLikeItem] = []
    private(set) var related: [SCUser] = []
    private(set) var followers: [SCUser] = []
    private(set) var comments: [SCUserComment] = []
    private(set) var links: [SCWebProfile] = []
    @ObservationIgnored private var railLoaded = false
    @ObservationIgnored private var tabLoads: [ArtistTab: Task<Void, Never>] = [:]

    /// What is happening to the header right now — "Uploading…", "Removing…" — or nil when idle.
    private(set) var headerActivity: String?

    init(user: SCUser, isMe: Bool, api: SoundCloudAPI) {
        id = user.id
        self.isMe = isMe
        self.api = api
        let id = user.id
        allPages = Pager(first: { try await api.userStream(id: id).page },
                         next: { try await api.nextStreamPage($0).page })
        trackPages = Pager(first: { try await api.userTracks(id: id).page },
                           next: { try await api.nextTrackPage($0).page })
    }

    func loadProfile() async {
        guard profile == nil else { return }
        profile = try? await api.user(id: id)
    }

    /// Through `/me` on your own page: a public profile fetched right after an edit can still come
    /// back as it was a moment ago, and a save that shows the old values reads as one that failed.
    func reloadProfile() async {
        guard let fresh = isMe ? try? await api.meUser() : try? await api.user(id: id) else { return }
        profile = fresh
    }

    func uploadHeader(_ file: URL) async throws {
        headerActivity = "Uploading…"
        defer { headerActivity = nil }
        try await api.uploadProfileHeader(file)
        await reloadProfile()
    }

    func removeHeader() async throws {
        headerActivity = "Removing…"
        defer { headerActivity = nil }
        try await api.removeProfileHeader()
        await reloadProfile()
    }

    func loadMore(_ tab: ArtistTab) async {
        // An empty list is already "near its end": paging it first made `load` see a page in flight and call the tab empty.
        guard loadedTabs.contains(tab) else { return }
        switch tab {
        case .all: await allPages.loadMore()
        case .tracks: await trackPages.loadMore()
        default: break
        }
    }

    /// One load a tab, finished even if the tab is left: a second caller waited for nothing and called it empty.
    func load(_ tab: ArtistTab) async {
        guard !loadedTabs.contains(tab) else { return }
        if let running = tabLoads[tab] { return await running.value }
        let load = Task { await fetch(tab) }
        tabLoads[tab] = load
        await load.value
        tabLoads[tab] = nil
    }

    private func fetch(_ tab: ArtistTab) async {
        loadingTabs.insert(tab)
        defer { loadingTabs.remove(tab) }
        tabErrors[tab] = nil
        let api = api, id = id
        var failure: String?
        do {
            switch tab {
            case .all:
                // Spotlight is what the artist pinned; the stream is everything they posted, tracks
                // and sets in one timeline. Most profiles pin nothing, so an empty one just vanishes.
                async let pinned = try? await api.userSpotlight(id: id)
                await allPages.loadMore()
                spotlight = (await pinned)?.collection ?? []
                failure = allPages.firstPageError
            case .popular:
                popular = try await api.userTopTracks(id: id).collection
            case .tracks:
                await trackPages.loadMore()
                failure = trackPages.firstPageError
            case .albums:
                albums = try await api.userAlbums(id: id)
            case .playlists:
                playlists = try await api.userPlaylists(id: id)
            case .reposts:
                reposts = try await api.userReposts(id: id).collection
            }
        } catch {
            failure = error.surfaced()
        }
        if let failure {
            tabErrors[tab] = failure
        } else {
            loadedTabs.insert(tab)
        }
    }

    /// Your own page swaps the last two blocks: who you follow comes from the library, and what you
    /// have been saying on other people's tracks replaces fans and followers.
    func loadRail() async {
        guard !railLoaded else { return }
        let api = api, id = id
        async let liked = try? await api.userLikes(id: id, limit: 6)
        async let listed = loadLinks()
        if isMe {
            async let said = try? await api.userComments(id: id)
            likes = await liked?.collection ?? []
            comments = await said?.collection ?? []
        } else {
            async let fans = try? await api.relatedArtists(id: id)
            async let crowd = try? await api.userFollowers(id: id, limit: 15)
            likes = await liked?.collection ?? []
            // The artist is in their own related list often enough to look like a bug.
            related = await fans?.collection.filter { $0.id != id } ?? []
            followers = await crowd?.collection ?? []
        }
        links = await listed
        if !Task.isCancelled { railLoaded = true }
    }

    private func loadLinks() async -> [SCWebProfile] {
        (try? await api.userWebProfiles(id: id)) ?? []
    }
}
