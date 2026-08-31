import Foundation
import Observation

/// The signed-in user's library: liked tracks and play history (paginated track feeds
/// cached to GRDB for instant FTS5 search) plus playlists from `/me/library/all`.
@MainActor
@Observable
final class LibraryStore {
    let likes: TrackFeed
    let history: TrackFeed

    private(set) var searchResults: [SCSearchItem] = []
    private(set) var localSearchResults: [SCTrack] = []
    private(set) var isSearching = false
    private(set) var playlists: [SCPlaylist] = []
    private(set) var playlistsError: String?
    private(set) var isLoadingPlaylists = false

    var albums: [SCPlaylist] { playlists.filter(\.isAlbum) }
    var userPlaylists: [SCPlaylist] { playlists.filter { !$0.isAlbum && !$0.isSystem } }
    var stations: [SCPlaylist] { playlists.filter { !$0.isAlbum && $0.isSystem } }

    private(set) var selections: [SCMixedSelection] = []
    private var selectionsLoaded = false

    private(set) var meUser: SCUser?

    /// Ids of liked tracks, seeded from the likes feed as it pages in and toggled optimistically.
    /// Only knows tracks the likes feed has actually loaded, so a like on a track that hasn't paged
    /// in yet reads as unliked until you scroll far enough in Likes.
    private(set) var likedTrackIDs: Set<Int> = []
    /// Reposted-track ids. No reposts feed is loaded, so this only reflects reposts made this
    /// session — a previously reposted track reads as not-reposted until you act on it.
    private(set) var repostedTrackIDs: Set<Int> = []
    private var cachedMeID: Int?

    private(set) var following: [SCUser] = []
    private(set) var isLoadingFollowing = false
    private(set) var followingError: String?
    /// Ids of the people you follow, seeded from the Following list.
    private(set) var followedUserIDs: Set<Int> = []
    private var followingLoaded = false

    private(set) var stream: [SCStreamItem] = []
    private(set) var isLoadingStream = false
    private(set) var streamError: String?
    private var streamNextHref: String?
    private var streamLoaded = false

    private(set) var trending: [SCTrack] = []
    private(set) var isLoadingTrending = false

    /// The artists behind the current chart, in chart order, deduplicated — a people-shelf for free,
    /// with no extra request.
    var chartArtists: [SCUser] {
        var seen = Set<Int>()
        return trending.map(\.user).filter { seen.insert($0.id).inserted }
    }

    private var trendingNextHref: String?
    private var trendingLoaded = false
    private var trendingGenre = "all-music"

    let api: SoundCloudAPI
    private let database: AppDatabase?
    private var playlistsLoaded = false
    private var searchTask: Task<Void, Never>?
    private var currentQuery = ""

    init(api: SoundCloudAPI) {
        self.api = api
        let database = try? AppDatabase()
        self.database = database

        let persist: ([SCTrack]) -> Void = { tracks in
            guard let database else { return }
            Task.detached { database.save(tracks) }
        }

        likes = TrackFeed(api: api, persist: persist) {
            try await api.likedTracks(userID: try await api.me().id)
        }
        history = TrackFeed(api: api, persist: persist) {
            try await api.history()
        }

        likes.onLoad = { [weak self] tracks in
            self?.likedTrackIDs.formUnion(tracks.map(\.id))
        }
    }

    // MARK: - Likes

    func isLiked(_ track: SCTrack) -> Bool { likedTrackIDs.contains(track.id) }

    /// Optimistic: flip state immediately, fire the request, roll back on failure.
    func isFollowing(_ user: SCUser) -> Bool { followedUserIDs.contains(user.id) }

    func toggleFollow(_ user: SCUser) {
        let wasFollowing = followedUserIDs.contains(user.id)
        setFollowing(user, !wasFollowing)
        Task {
            do {
                if wasFollowing {
                    try await api.unfollowUser(id: user.id)
                } else {
                    try await api.followUser(id: user.id)
                }
            } catch {
                setFollowing(user, wasFollowing)
            }
        }
    }

    private func setFollowing(_ user: SCUser, _ isNow: Bool) {
        if isNow {
            followedUserIDs.insert(user.id)
            if !self.following.contains(where: { $0.id == user.id }) {
                self.following.insert(user, at: 0)
            }
        } else {
            followedUserIDs.remove(user.id)
            self.following.removeAll { $0.id == user.id }
        }
    }

    func toggleLike(_ track: SCTrack) {
        let wasLiked = likedTrackIDs.contains(track.id)
        setLiked(track, !wasLiked)
        Task {
            do {
                let uid = try await userID()
                if wasLiked {
                    try await api.unlikeTrack(userID: uid, trackID: track.id)
                } else {
                    try await api.likeTrack(userID: uid, trackID: track.id)
                }
            } catch {
                setLiked(track, wasLiked)
            }
        }
    }

    /// Keeps the heart state (`likedTrackIDs`) and the Likes list itself in sync.
    private func setLiked(_ track: SCTrack, _ liked: Bool) {
        if liked {
            likedTrackIDs.insert(track.id)
            likes.prepend(track)
        } else {
            likedTrackIDs.remove(track.id)
            likes.remove(id: track.id)
        }
    }

    func isReposted(_ track: SCTrack) -> Bool { repostedTrackIDs.contains(track.id) }

    func toggleRepost(_ track: SCTrack) {
        let wasReposted = repostedTrackIDs.contains(track.id)
        if wasReposted { repostedTrackIDs.remove(track.id) } else { repostedTrackIDs.insert(track.id) }
        Task {
            do {
                if wasReposted {
                    try await api.unrepostTrack(trackID: track.id)
                } else {
                    try await api.repostTrack(trackID: track.id)
                }
            } catch {
                if wasReposted { repostedTrackIDs.insert(track.id) } else { repostedTrackIDs.remove(track.id) }
            }
        }
    }

    private func userID() async throws -> Int {
        if let cachedMeID { return cachedMeID }
        let id = try await api.me().id
        cachedMeID = id
        return id
    }

    /// Debounced online search across the whole SoundCloud catalogue (tracks/users/playlists).
    /// Local FTS5 results from the GRDB cache land instantly, without the debounce.
    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentQuery = trimmed
        guard !trimmed.isEmpty else {
            searchResults = []
            localSearchResults = []
            isSearching = false
            return
        }
        isSearching = true
        if let database {
            Task.detached {
                let local = database.search(trimmed, limit: 50)
                await MainActor.run {
                    guard self.currentQuery == trimmed else { return }
                    self.localSearchResults = local
                }
            }
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let page = try? await api.search(trimmed)
            guard !Task.isCancelled else { return }
            searchResults = page?.collection ?? []
            isSearching = false
        }
    }

    /// Runs in an unstructured Task so it survives the view's `.task` being cancelled while the
    /// window settles on launch (which would otherwise leave playlists empty until you switch tabs).
    func loadPlaylistsIfNeeded() {
        guard !playlistsLoaded else { return }
        playlistsLoaded = true
        isLoadingPlaylists = true
        Task {
            defer { isLoadingPlaylists = false }
            do {
                playlists = try await api.library().collection.compactMap(\.asPlaylist)
                playlistsError = nil
            } catch {
                playlistsLoaded = false
                playlistsError = "\(error)"
            }
        }
    }

    func loadMe() {
        guard meUser == nil else { return }
        Task { meUser = try? await api.meUser() }
    }

    func loadFollowingIfNeeded() {
        guard !followingLoaded else { return }
        followingLoaded = true
        isLoadingFollowing = true
        Task {
            defer { isLoadingFollowing = false }
            do {
                let id = try await api.me().id
                following = try await api.userFollowings(id: id).collection
                followedUserIDs.formUnion(following.map(\.id))
                followingError = nil
            } catch {
                followingLoaded = false
                followingError = "\(error)"
            }
        }
    }

    func reloadStream() {
        streamLoaded = false
        loadStreamIfNeeded()
    }

    func reloadFollowing() {
        followingLoaded = false
        loadFollowingIfNeeded()
    }

    func loadStreamIfNeeded() {
        guard !streamLoaded else { return }
        streamLoaded = true
        isLoadingStream = true
        Task {
            defer { isLoadingStream = false }
            do {
                let page = try await api.stream()
                stream = page.collection
                streamNextHref = page.nextHref
                streamError = nil
            } catch {
                streamLoaded = false
                streamError = "\(error)"
            }
        }
    }

    func loadMoreStream() async {
        guard let href = streamNextHref, !isLoadingStream else { return }
        isLoadingStream = true
        defer { isLoadingStream = false }
        streamNextHref = nil
        guard let page = try? await api.nextStreamPage(href) else { return }
        stream.append(contentsOf: page.collection)
        streamNextHref = page.nextHref
    }

    func loadTrendingIfNeeded() {
        guard !trendingLoaded else { return }
        trendingLoaded = true
        isLoadingTrending = true
        let genre = trendingGenre
        Task {
            do {
                let (tracks, nextHref) = try await fetchTrending(genre: genre, nextHref: nil)
                guard trendingGenre == genre else { return }
                trending = tracks
                trendingNextHref = nextHref
                persistTracks(tracks)
            } catch {
                if trendingGenre == genre { trendingLoaded = false }
            }
            if trendingGenre == genre { isLoadingTrending = false }
        }
    }

    /// Takes a genre slug ("all-music", "hiphoprap", …). Only all-music still has a real
    /// `/charts` feed; other genres fall back to recent popular tracks by tag.
    private func fetchTrending(genre: String, nextHref: String?) async throws -> ([SCTrack], String?) {
        if genre == "all-music" {
            let page: SCChartPage
            if let nextHref {
                page = try await api.nextChartPage(nextHref)
            } else {
                page = try await api.charts()
            }
            return (page.collection, page.nextHref)
        } else {
            let page: SCTrackSearchPage
            if let nextHref {
                page = try await api.nextGenrePopularPage(nextHref)
            } else {
                page = try await api.genrePopular(slug: genre)
            }
            return (page.collection, page.nextHref)
        }
    }

    func reloadTrending(genre: String) {
        guard genre != trendingGenre else { return }
        trendingGenre = genre
        trending = []
        trendingNextHref = nil
        trendingLoaded = false
        loadTrendingIfNeeded()
    }

    func loadSelectionsIfNeeded() {
        guard !selectionsLoaded else { return }
        selectionsLoaded = true
        Task {
            do {
                selections = try await api.mixedSelections().collection.filter { !$0.items.isEmpty }
            } catch {
                selectionsLoaded = false
            }
        }
    }

    func loadMoreTrending() async {
        guard let href = trendingNextHref, !isLoadingTrending else { return }
        isLoadingTrending = true
        defer { isLoadingTrending = false }
        trendingNextHref = nil
        let genre = trendingGenre
        guard let (tracks, nextHref) = try? await fetchTrending(genre: genre, nextHref: href),
              trendingGenre == genre else { return }
        trending.append(contentsOf: tracks)
        trendingNextHref = nextHref
        persistTracks(tracks)
    }

    private func persistTracks(_ tracks: [SCTrack]) {
        guard let database else { return }
        Task.detached { database.save(tracks) }
    }

    /// Resolves a playlist's stub track IDs into full playable tracks, caching them for search.
    /// Playlists that arrive from `/mixed-selections` carry no track stubs at all, so they are
    /// re-fetched by id first — otherwise the page would open empty.
/// Ids of every liked track, cached for the session: the queue is built from these, so shuffle
    /// covers the whole collection rather than the pages the feed has fetched.
    private var likedIDCache: [Int] = []

    func likedIDs() async -> [Int] {
        if !likedIDCache.isEmpty { return likedIDCache }
        likedIDCache = (try? await api.likedTrackIDs()) ?? []
        return likedIDCache
    }

    /// Resolves a slice of ids into tracks, caching them for offline browse like every other feed.
    func tracks(ids: [Int]) async -> [SCTrack] {
        let tracks = (try? await api.tracks(ids: ids)) ?? []
        if let database, !tracks.isEmpty { Task.detached { database.save(tracks) } }
        return tracks
    }

        /// Throws rather than returning `[]`: a failed resolve and an empty playlist looked identical
    /// to callers, which is what made a broken quick-play card a dead click.
    func tracks(for playlist: SCPlaylist) async throws -> [SCTrack] {
        var ids = playlist.trackIDs
        if ids.isEmpty, let numericID = Int(playlist.id) {
            ids = try await api.playlist(id: numericID).trackIDs
        }
        let tracks = try await api.tracks(ids: ids)
        if let database { Task.detached { database.save(tracks) } }
        return tracks
    }
}
