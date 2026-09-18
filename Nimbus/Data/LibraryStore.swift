import Foundation
import Observation
import os

enum LibraryList: CaseIterable {
    case selections, trending, history, likes, stream, playlists, following
}

/// The signed-in user's library: liked tracks and play history (paginated track feeds
/// cached to GRDB for instant FTS5 search) plus playlists from `/me/library/all`.
@MainActor
@Observable
final class LibraryStore {
    private enum TTL {
        static let shelves = Duration.seconds(15 * 60)
        static let chart = Duration.seconds(15 * 60)
        static let feeds = Duration.seconds(5 * 60)
        static let library = Duration.seconds(10 * 60)
        // Following walks every page of the list, so it is asked for least often.
        static let following = Duration.seconds(30 * 60)
    }

    let likes: TrackFeed
    let history: TrackFeed
    let stream: Pager<SCStreamItem>

    private(set) var searchResults: [SCSearchItem] = []
    private(set) var localSearchResults: [SCTrack] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var playlists: [SCPlaylist] = []
    private(set) var playlistsError: String?
    var isLoadingPlaylists: Bool { playlistsFreshness.isLoading }

    var albums: [SCPlaylist] { playlists.filter(\.isAlbum) }
    var userPlaylists: [SCPlaylist] { playlists.filter { !$0.isAlbum && !$0.isSystem } }
    var stations: [SCPlaylist] { playlists.filter { !$0.isAlbum && $0.isSystem } }

    private(set) var selections: [SCMixedSelection] = []
    private var selectionsFreshness = Freshness("shelves", ttl: TTL.shelves)

    private(set) var meUser: SCUser?

    /// Ids of liked tracks: the pages the likes feed has loaded, optimistic toggles, and the whole
    /// collection once `likedIDs()` has walked it. Until that walk, a track that hasn't paged in
    /// yet reads as unliked.
    private(set) var likedTrackIDs: Set<Int> = []
    /// Reposted-track ids. No reposts feed is loaded, so this only reflects reposts made this
    /// session — a previously reposted track reads as not-reposted until you act on it.
    private(set) var repostedTrackIDs: Set<Int> = []
    /// Liked and reposted sets, walked in full the first time a set page asks — unlike tracks,
    /// a set's buttons have no feed of their own to seed them.
    private(set) var likedPlaylistIDs: Set<Int> = []
    private(set) var repostedPlaylistIDs: Set<Int> = []
    private var playlistStateLoaded = false
    private var cachedMeID: Int?

    private(set) var following: [SCUser] = []
    var isLoadingFollowing: Bool { followingFreshness.isLoading }
    private(set) var followingError: String?
    /// Ids of the people you follow, seeded from the Following list.
    private(set) var followedUserIDs: Set<Int> = []
    private var followingFreshness = Freshness("following", ttl: TTL.following)

    private(set) var blockedUserIDs: Set<Int> = []
    private var blockedLoaded = false

    private var likeWrites = PendingWrites()
    private var followWrites = PendingWrites()

    private(set) var trending: [SCTrack] = []
    var isLoadingTrending: Bool { trendingFreshness.isLoading }

    /// The artists behind the current chart, in chart order, deduplicated — a people-shelf for free,
    /// with no extra request.
    var chartArtists: [SCUser] {
        var seen = Set<Int>()
        return trending.map(\.user).filter { seen.insert($0.id).inserted }
    }

    private var trendingFreshness = Freshness("chart", ttl: TTL.chart)
    private var trendingGenre = "all-music"

    let api: SoundCloudAPI
    private let database: AppDatabase?
    private var playlistsFreshness = Freshness("playlists", ttl: TTL.library)
    private var searchTask: Task<Void, Never>?
    private var currentQuery = ""
    /// Bumped by `reset()`. A request in flight was made for the account that just signed out, so
    /// every loader checks the epoch it started in before writing its answer anywhere.
    private var epoch = 0

    init(api: SoundCloudAPI) {
        self.api = api
        let database = try? AppDatabase()
        self.database = database

        let persist: ([SCTrack]) -> Void = { tracks in
            guard let database else { return }
            Task.detached { database.save(tracks) }
        }

        likes = TrackFeed(
            name: "likes",
            ttl: TTL.feeds,
            api: api,
            persist: persist,
            cached: { database?.tracks(ids: database?.collectionIDs("likes") ?? []) ?? [] },
            persistOrder: { tracks in
                guard let database else { return }
                let ids = tracks.map(\.id)
                Task.detached { database.saveCollection("likes", ids: ids) }
            }) {
                try await api.likedTracks(userID: try await api.me().id)
            }
        history = TrackFeed(
            name: "history",
            ttl: TTL.feeds,
            api: api,
            persist: persist,
            cached: { database?.tracks(ids: database?.collectionIDs("history") ?? []) ?? [] },
            persistOrder: { tracks in
                guard let database else { return }
                let ids = tracks.map(\.id)
                Task.detached { database.saveCollection("history", ids: ids) }
            }) {
                try await api.history()
            }
        stream = Pager(
            first: { try await api.stream().page },
            next: { try await api.nextStreamPage($0).page })

        likes.onLoad = { [weak self] tracks in
            self?.likedTrackIDs.formUnion(tracks.map(\.id))
        }
        likes.isSettled = { [weak self] in self?.likeWrites.isSettled ?? true }
        likes.onRefresh = { [weak self] dropped in self?.likesRefreshed(dropping: dropped) }
        likes.source = PlayQueue.Source(
            name: "your likes",
            ids: { [weak self] in await self?.likedIDs() ?? [] },
            resolve: { [weak self] chunk in await self?.tracks(ids: chunk) ?? [] })
    }

    // MARK: - Likes

    func isLiked(_ track: SCTrack) -> Bool { likedTrackIDs.contains(track.id) }

    /// Forgets everything tied to the account, cache included — otherwise the next person to sign
    /// in would be looking at the previous one's library. Each list's freshness goes with it: left
    /// standing, every cleared list would read as fresh and stay empty for the rest of the launch.
    func reset() {
        epoch += 1
        searchTask?.cancel()
        searchTask = nil
        currentQuery = ""
        isSearching = false
        searchResults = []
        searchError = nil
        localSearchResults = []
        playlists = []
        playlistsError = nil
        playlistsFreshness.reset()
        selections = []
        selectionsFreshness.reset()
        meUser = nil
        cachedMeID = nil
        likedTrackIDs = []
        repostedTrackIDs = []
        likedPlaylistIDs = []
        repostedPlaylistIDs = []
        playlistStateLoaded = false
        likedIDCache = []
        following = []
        followedUserIDs = []
        followingError = nil
        followingFreshness.reset()
        blockedUserIDs = []
        blockedLoaded = false
        likeWrites = PendingWrites()
        followWrites = PendingWrites()
        stream.reset()
        trending = []
        trendingFreshness.reset()
        likes.reset()
        history.reset()
        database?.clear()
    }

    func isFollowing(_ user: SCUser) -> Bool { followedUserIDs.contains(user.id) }

    func isBlocked(_ user: SCUser) -> Bool { blockedUserIDs.contains(user.id) }

    /// Fetched once per session, and only where it is asked for: a menu that offers Block has to
    /// know whether it should say Unblock instead.
    func loadBlockedIfNeeded() {
        guard !blockedLoaded else { return }
        blockedLoaded = true
        let epoch = self.epoch
        Task {
            do {
                let ids = try await api.blockedUserIDs()
                guard epoch == self.epoch else { return }
                blockedUserIDs = Set(ids)
            } catch {
                blockedLoaded = false
            }
        }
    }

    /// Blocking also drops the follow, the way the site does it — a blocked artist staying in
    /// Following would keep posting into the feed.
    func toggleBlock(_ user: SCUser) {
        let wasBlocked = blockedUserIDs.contains(user.id)
        let wasFollowing = followedUserIDs.contains(user.id)
        if wasBlocked {
            blockedUserIDs.remove(user.id)
        } else {
            blockedUserIDs.insert(user.id)
            if wasFollowing { setFollowing(user, false) }
        }
        let epoch = self.epoch
        followWrites.begin()
        Task {
            defer { if epoch == self.epoch { followWrites.end() } }
            do {
                if wasBlocked {
                    try await api.unblockUser(id: user.id)
                } else {
                    try await api.blockUser(id: user.id)
                }
            } catch {
                if wasBlocked {
                    blockedUserIDs.insert(user.id)
                } else {
                    blockedUserIDs.remove(user.id)
                    if wasFollowing { setFollowing(user, true) }
                }
            }
        }
    }

    func toggleFollow(_ user: SCUser) {
        let wasFollowing = followedUserIDs.contains(user.id)
        setFollowing(user, !wasFollowing)
        let epoch = self.epoch
        followWrites.begin()
        Task {
            defer { if epoch == self.epoch { followWrites.end() } }
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

    /// Optimistic: flip state immediately, fire the request, roll back on failure.
    func toggleLike(_ track: SCTrack) {
        let wasLiked = likedTrackIDs.contains(track.id)
        setLiked(track, !wasLiked)
        let epoch = self.epoch
        likeWrites.begin()
        Task {
            defer { if epoch == self.epoch { likeWrites.end() } }
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
            // Newest first, matching the order `/me/track_likes/ids` returns and `prepend` renders.
            if !likedIDCache.contains(track.id) { likedIDCache.insert(track.id, at: 0) }
            likes.prepend(track)
        } else {
            likedTrackIDs.remove(track.id)
            likedIDCache.removeAll { $0 == track.id }
            likes.remove(id: track.id)
        }
    }

    func isReposted(_ track: SCTrack) -> Bool { repostedTrackIDs.contains(track.id) }

    func loadPlaylistStateIfNeeded() {
        guard !playlistStateLoaded else { return }
        playlistStateLoaded = true
        let epoch = self.epoch
        Task {
            async let liked = try? await api.likedPlaylistIDs()
            async let reposted = try? await api.repostedPlaylistIDs()
            let (likedIDs, repostedIDs) = await (liked, reposted)
            guard epoch == self.epoch else { return }
            // Union, not assignment: a tap made while the walk was still running must survive it.
            likedPlaylistIDs.formUnion(likedIDs ?? [])
            repostedPlaylistIDs.formUnion(repostedIDs ?? [])
            if likedIDs == nil || repostedIDs == nil { playlistStateLoaded = false }
        }
    }

    /// System mixes carry a urn instead of a numeric id, and can be neither liked nor reposted.
    func isLiked(_ playlist: SCPlaylist) -> Bool {
        Int(playlist.id).map(likedPlaylistIDs.contains) ?? false
    }

    func isReposted(_ playlist: SCPlaylist) -> Bool {
        Int(playlist.id).map(repostedPlaylistIDs.contains) ?? false
    }

    func toggleLike(_ playlist: SCPlaylist) {
        guard let id = Int(playlist.id) else { return }
        let wasLiked = likedPlaylistIDs.contains(id)
        if wasLiked { likedPlaylistIDs.remove(id) } else { likedPlaylistIDs.insert(id) }
        Task {
            do {
                let uid = try await userID()
                if wasLiked {
                    try await api.unlikePlaylist(userID: uid, playlistID: id)
                } else {
                    try await api.likePlaylist(userID: uid, playlistID: id)
                }
            } catch {
                if wasLiked { likedPlaylistIDs.insert(id) } else { likedPlaylistIDs.remove(id) }
            }
        }
    }

    func toggleRepost(_ playlist: SCPlaylist) {
        guard let id = Int(playlist.id) else { return }
        let wasReposted = repostedPlaylistIDs.contains(id)
        if wasReposted { repostedPlaylistIDs.remove(id) } else { repostedPlaylistIDs.insert(id) }
        Task {
            do {
                if wasReposted {
                    try await api.unrepostPlaylist(playlistID: id)
                } else {
                    try await api.repostPlaylist(playlistID: id)
                }
            } catch {
                if wasReposted { repostedPlaylistIDs.insert(id) } else { repostedPlaylistIDs.remove(id) }
            }
        }
    }

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
        let epoch = self.epoch
        let id = try await api.me().id
        // Signed out mid-flight: caching this id would send the next session's likes to the old account.
        guard epoch == self.epoch else { throw CancellationError() }
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
            searchError = nil
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
            do {
                let page = try await api.search(trimmed)
                guard !Task.isCancelled else { return }
                searchResults = page.collection
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                searchResults = []
                searchError = "\(error)"
            }
            isSearching = false
        }
    }

    func retrySearch() {
        search(currentQuery)
    }

    func refreshStale() {
        for list in LibraryList.allCases where isWanted(list) {
            Task { await update(list, force: false) }
        }
    }

    /// ⌘R: these lists regardless of age. False when any of them couldn't be reached.
    func refresh(_ lists: [LibraryList]) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for list in lists {
                group.addTask { await self.update(list, force: true) }
            }
            var reached = true
            for await answered in group where !answered { reached = false }
            return reached
        }
    }

    private func update(_ list: LibraryList, force: Bool) async -> Bool {
        switch list {
        case .selections: await updateSelections(force: force)
        case .trending: await updateTrending(force: force)
        case .history: await history.update(force: force)
        case .likes: await likes.update(force: force)
        case .stream: await updateStream(force: force)
        case .playlists: await updatePlaylists(force: force)
        case .following: await updateFollowing(force: force)
        }
    }

    private func isWanted(_ list: LibraryList) -> Bool {
        switch list {
        case .selections: selectionsFreshness.isWanted
        case .trending: trendingFreshness.isWanted
        case .history: history.wasAsked
        case .likes: likes.wasAsked
        case .stream: stream.hasLoaded || stream.error != nil
        case .playlists: playlistsFreshness.isWanted
        case .following: followingFreshness.isWanted
        }
    }

    private func likesRefreshed(dropping dropped: [Int]) {
        likedTrackIDs.subtract(dropped)
        guard !likedIDCache.isEmpty else { return }
        let walked = Set(likedIDCache)
        // Shuffle-all plays from this walk, and it no longer matches once the head has moved.
        if !dropped.isEmpty || likes.tracks.contains(where: { !walked.contains($0.id) }) {
            likedIDCache = []
        }
    }

    /// Runs in an unstructured Task so it survives the view's `.task` being cancelled while the
    /// window settles on launch (which would otherwise leave playlists empty until you switch tabs).
    func loadPlaylistsIfNeeded(force: Bool = false) {
        Task { await updatePlaylists(force: force) }
    }

    private func updatePlaylists(force: Bool) async -> Bool {
        guard playlistsFreshness.begin(force: force) else { return true }
        let epoch = self.epoch
        do {
            let loaded = try await api.library().collection.compactMap(\.asPlaylist)
            guard epoch == self.epoch else { return true }
            playlists = loaded
            playlistsError = nil
            playlistsFreshness.finish(loaded: true)
            return true
        } catch {
            guard epoch == self.epoch else { return true }
            // A failed refresh keeps the list on screen; only a list that never came has an error to show.
            if !playlistsFreshness.hasLoaded { playlistsError = "\(error)" }
            playlistsFreshness.finish(loaded: false)
            return false
        }
    }

    /// After an edit: the account row and the profile page both read `meUser`, and `loadMe` keeps
    /// whatever it already has.
    func reloadMe() {
        let epoch = self.epoch
        Task {
            guard let user = try? await api.meUser(), epoch == self.epoch else { return }
            meUser = user
        }
    }

    func loadMe() {
        guard meUser == nil else { return }
        let epoch = self.epoch
        Task {
            let user = try? await api.meUser()
            guard epoch == self.epoch else { return }
            meUser = user
        }
    }

    func loadFollowingIfNeeded(force: Bool = false) {
        Task { await updateFollowing(force: force) }
    }

    private func updateFollowing(force: Bool) async -> Bool {
        let isRefresh = followingFreshness.hasLoaded
        guard !isRefresh || followWrites.isSettled, followingFreshness.begin(force: force) else { return true }
        let epoch = self.epoch
        let writes = followWrites.version
        do {
            let id = try await api.me().id
            let users = try await api.allFollowings(id: id)
            guard epoch == self.epoch else { return true }
            if isRefresh {
                // A follow tapped mid-walk is missing from its answer; the next trigger asks again.
                guard followWrites.version == writes else {
                    followingFreshness.finish(loaded: false)
                    return true
                }
                followedUserIDs = Set(users.map(\.id))
            } else {
                followedUserIDs.formUnion(users.map(\.id))
            }
            following = users
            followingError = nil
            followingFreshness.finish(loaded: true)
            return true
        } catch {
            guard epoch == self.epoch else { return true }
            if !followingFreshness.hasLoaded { followingError = "\(error)" }
            followingFreshness.finish(loaded: false)
            return false
        }
    }

    func reloadStream() {
        stream.reset()
        loadStreamIfNeeded()
    }

    func reloadFollowing() {
        loadFollowingIfNeeded(force: true)
    }

    func loadStreamIfNeeded(force: Bool = false) {
        Task { await updateStream(force: force) }
    }

    private func updateStream(force: Bool) async -> Bool {
        if stream.hasLoaded {
            guard Freshness.isDue("feed", fetchedAt: stream.fetchedAt, ttl: TTL.feeds, force: force) else { return true }
            if case .failed = await stream.refresh() { return false }
            return true
        }
        guard !stream.isLoading, Freshness.isDue("feed", fetchedAt: nil, ttl: TTL.feeds, force: force) else { return true }
        await stream.loadMore()
        return stream.hasLoaded
    }

    func loadTrendingIfNeeded(force: Bool = false) {
        Task { await updateTrending(force: force) }
    }

    private func updateTrending(force: Bool) async -> Bool {
        guard trendingFreshness.begin(force: force) else { return true }
        let epoch = self.epoch
        let genre = trendingGenre
        do {
            let tracks = try await fetchTrending(genre: genre)
            guard epoch == self.epoch, trendingGenre == genre else { return true }
            trending = tracks
            persistTracks(tracks)
            trendingFreshness.finish(loaded: true)
            return true
        } catch {
            guard epoch == self.epoch, trendingGenre == genre else { return true }
            trendingFreshness.finish(loaded: false)
            return false
        }
    }

    /// Takes a genre slug ("all-music", "hiphoprap", …). Only all-music still has a real
    /// `/charts` feed; other genres fall back to recent popular tracks by tag.
    private func fetchTrending(genre: String) async throws -> [SCTrack] {
        if genre == "all-music" {
            try await api.charts().collection
        } else {
            try await api.genrePopular(slug: genre).collection
        }
    }

    func reloadTrending(genre: String) {
        guard genre != trendingGenre else { return }
        trendingGenre = genre
        trending = []
        trendingFreshness.reset()
        loadTrendingIfNeeded()
    }

    func loadSelectionsIfNeeded(force: Bool = false) {
        Task { await updateSelections(force: force) }
    }

    private func updateSelections(force: Bool) async -> Bool {
        guard selectionsFreshness.begin(force: force) else { return true }
        let epoch = self.epoch
        do {
            let loaded = try await api.mixedSelections().collection.filter { !$0.items.isEmpty }
            guard epoch == self.epoch else { return true }
            selections = loaded
            selectionsFreshness.finish(loaded: true)
            return true
        } catch {
            guard epoch == self.epoch else { return true }
            selectionsFreshness.finish(loaded: false)
            return false
        }
    }

    private func persistTracks(_ tracks: [SCTrack]) {
        guard let database else { return }
        Task.detached { database.save(tracks) }
    }

    /// Ids of every liked track, cached for the session: the queue is built from these, so shuffle
    /// covers the whole collection rather than the pages the feed has fetched.
    private var likedIDCache: [Int] = []

    func likedIDs() async -> [Int] {
        if !likedIDCache.isEmpty { return likedIDCache }
        let epoch = self.epoch
        let ids = (try? await api.likedTrackIDs()) ?? []
        guard epoch == self.epoch else { return [] }
        likedIDCache = ids
        // Union, not replace: a failed walk yields [] and would otherwise blank every known heart.
        likedTrackIDs.formUnion(ids)
        return ids
    }

    /// Resolves a slice of ids into tracks, caching them for offline browse like every other feed.
    func tracks(ids: [Int]) async -> [SCTrack] {
        let tracks = (try? await api.tracks(ids: ids)) ?? []
        if let database, !tracks.isEmpty { Task.detached { database.save(tracks) } }
        return tracks
    }

    /// Resolves a playlist's stub track IDs into full playable tracks, caching them for search.
    /// Playlists that arrive from `/mixed-selections` carry no track stubs at all, so they are
    /// re-fetched by id first — otherwise the page would open empty.
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
