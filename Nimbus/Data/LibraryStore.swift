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

    /// Seeded by loaded pages, then the full walk signing in starts, so an old like shows its heart anywhere.
    let likedTracks: OptimisticSet
    let repostedTracks: OptimisticSet
    /// A set's buttons have no feed of their own to seed them, so these are walked when a set page first asks.
    let likedPlaylists: OptimisticSet
    let repostedPlaylists: OptimisticSet
    private let account: AccountID

    private(set) var following: [SCUser] = []
    var isLoadingFollowing: Bool { followingFreshness.isLoading }
    private(set) var followingError: String?
    /// The people you follow, seeded from the Following list.
    let followed: OptimisticSet
    private var followingFreshness = Freshness("following", ttl: TTL.following)

    let blocked: OptimisticSet

    private var lastPlayAt: ContinuousClock.Instant?

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
        let account = AccountID(api: api)
        self.account = account

        likedTracks = OptimisticSet { id, on in
            let user = try await account.id()
            if on { try await api.likeTrack(userID: user, trackID: id) } else { try await api.unlikeTrack(userID: user, trackID: id) }
        }
        repostedTracks = OptimisticSet(walk: { try await api.repostedTrackIDs() }) { id, on in
            if on { try await api.repostTrack(trackID: id) } else { try await api.unrepostTrack(trackID: id) }
        }
        likedPlaylists = OptimisticSet(walk: { try await api.likedPlaylistIDs() }) { id, on in
            let user = try await account.id()
            if on {
                try await api.likePlaylist(userID: user, playlistID: id)
            } else {
                try await api.unlikePlaylist(userID: user, playlistID: id)
            }
        }
        repostedPlaylists = OptimisticSet(walk: { try await api.repostedPlaylistIDs() }) { id, on in
            if on { try await api.repostPlaylist(playlistID: id) } else { try await api.unrepostPlaylist(playlistID: id) }
        }
        followed = OptimisticSet { id, on in
            if on { try await api.followUser(id: id) } else { try await api.unfollowUser(id: id) }
        }
        blocked = OptimisticSet(walk: { try await api.blockedUserIDs() }) { id, on in
            if on { try await api.blockUser(id: id) } else { try await api.unblockUser(id: id) }
        }

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
                try await api.likedTracks(userID: try await account.id())
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
            self?.likedTracks.seed(tracks.map(\.id))
        }
        likes.isSettled = { [weak self] in self?.likedTracks.pending.isSettled ?? true }
        likes.onRefresh = { [weak self] dropped in self?.likesRefreshed(dropping: dropped) }
        // Until the events batch has landed, the server's history would drop a play shown locally.
        history.isSettled = { [weak self] in self?.lastPlayAt.map { .now - $0 > .seconds(30) } ?? true }
        history.context = .history
        likes.source = PlayQueue.Source(
            name: "your likes",
            ids: { [weak self] in await self?.likedIDs() ?? [] },
            resolve: { [weak self] chunk in await self?.tracks(ids: chunk) ?? [] })
    }

    // MARK: - Likes

    func isLiked(_ track: SCTrack) -> Bool { likedTracks.contains(track.id) }

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
        account.reset()
        for set in [likedTracks, repostedTracks, likedPlaylists, repostedPlaylists, followed, blocked] { set.reset() }
        likedIDCache = nil
        likedWalk?.cancel()
        likedWalk = nil
        following = []
        followingError = nil
        followingFreshness.reset()
        lastPlayAt = nil
        stream.reset()
        trending = []
        trendingFreshness.reset()
        likes.reset()
        history.reset()
        database?.clear()
    }

    func isFollowing(_ user: SCUser) -> Bool { followed.contains(user.id) }

    func isBlocked(_ user: SCUser) -> Bool { blocked.contains(user.id) }

    /// Fetched once per session, and only where it is asked for: a menu that offers Block has to
    /// know whether it should say Unblock instead.
    func loadBlockedIfNeeded() {
        blocked.loadIfNeeded()
    }

    /// Blocking also drops the follow, the way the site does it — a blocked artist staying in
    /// Following would keep posting into the feed.
    func toggleBlock(_ user: SCUser) {
        let wasFollowing = followed.contains(user.id)
        blocked.toggle(user.id) { [weak self] isBlocked in
            guard wasFollowing, let self else { return }
            followed.assume(user.id, !isBlocked)
            showFollowing(user, !isBlocked)
        }
    }

    func toggleFollow(_ user: SCUser) {
        followed.toggle(user.id) { [weak self] isFollowing in self?.showFollowing(user, isFollowing) }
    }

    private func showFollowing(_ user: SCUser, _ isNow: Bool) {
        if isNow {
            if !following.contains(where: { $0.id == user.id }) { following.insert(user, at: 0) }
        } else {
            following.removeAll { $0.id == user.id }
        }
    }

    func toggleLike(_ track: SCTrack) {
        likedTracks.toggle(track.id) { [weak self] liked in self?.showLiked(track, liked) }
    }

    /// The Likes list and the ids a likes queue is built from follow the heart.
    private func showLiked(_ track: SCTrack, _ liked: Bool) {
        if liked {
            // Newest first, matching the order `/me/track_likes/ids` returns and `prepend` renders.
            if likedIDCache?.contains(track.id) == false { likedIDCache?.insert(track.id, at: 0) }
            likes.prepend(track)
        } else {
            likedIDCache?.removeAll { $0 == track.id }
            likes.remove(id: track.id)
        }
    }

    func isReposted(_ track: SCTrack) -> Bool { repostedTracks.contains(track.id) }

    func loadPlaylistStateIfNeeded() {
        likedPlaylists.loadIfNeeded()
        repostedPlaylists.loadIfNeeded()
    }

    /// System mixes carry a urn instead of a numeric id, and can be neither liked nor reposted.
    func isLiked(_ playlist: SCPlaylist) -> Bool {
        Int(playlist.id).map(likedPlaylists.contains) ?? false
    }

    func isReposted(_ playlist: SCPlaylist) -> Bool {
        Int(playlist.id).map(repostedPlaylists.contains) ?? false
    }

    func toggleLike(_ playlist: SCPlaylist) {
        guard let id = Int(playlist.id) else { return }
        likedPlaylists.toggle(id)
    }

    func toggleRepost(_ playlist: SCPlaylist) {
        guard let id = Int(playlist.id) else { return }
        repostedPlaylists.toggle(id)
    }

    func toggleRepost(_ track: SCTrack) {
        repostedTracks.toggle(track.id)
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
                searchError = error.surfaced()
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
        likedTracks.drop(dropped)
        guard let likedIDCache else { return }
        let walked = Set(likedIDCache)
        // Shuffle-all plays from this walk, and it no longer matches once the head has moved.
        if !dropped.isEmpty || likes.tracks.contains(where: { !walked.contains($0.id) }) {
            self.likedIDCache = nil
        }
    }

    /// The server writes history from the player's events a few seconds on; Recently played shows it now.
    func recordPlay(_ track: SCTrack, context: PlayContext?) {
        lastPlayAt = .now
        // Moving the row while playing through history would reshuffle the list being played.
        guard context != .history, history.pagesLoaded > 0 else { return }
        history.moveToTop(track)
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
            let loaded = try await api.libraryPlaylists()
            guard epoch == self.epoch else { return true }
            playlists = loaded
            playlistsError = nil
            playlistsFreshness.finish(loaded: true)
            return true
        } catch {
            guard epoch == self.epoch else { return true }
            // A failed refresh keeps the list on screen; only a list that never came has an error to show.
            if !playlistsFreshness.hasLoaded { playlistsError = error.surfaced() }
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
        guard !isRefresh || followed.pending.isSettled, followingFreshness.begin(force: force) else { return true }
        let epoch = self.epoch
        let mark = followed.mark
        do {
            let users = try await api.allFollowings(id: try await account.id())
            guard epoch == self.epoch else { return true }
            // A follow tapped while the list was walked is missing from it, an unfollow still in it.
            followed.adopt(users.map(\.id), since: mark)
            let walked = Set(users.map(\.id))
            following = following.filter { !walked.contains($0.id) && followed.contains($0.id) }
                + users.filter { followed.contains($0.id) }
            followingError = nil
            followingFreshness.finish(loaded: true)
            return true
        } catch {
            guard epoch == self.epoch else { return true }
            if !followingFreshness.hasLoaded { followingError = error.surfaced() }
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
    private var likedIDCache: [Int]?
    private var likedWalk: Task<[Int]?, Never>?

    func likedIDs() async -> [Int] {
        if let likedIDCache { return likedIDCache }
        return await (likedWalk ?? walkLikedIDs()).value ?? []
    }

    func loadTrackStateIfNeeded() {
        if likedIDCache == nil, likedWalk == nil { _ = walkLikedIDs() }
        repostedTracks.loadIfNeeded()
    }

    private static let likesWalkCap = 5000

    private func walkLikedIDs() -> Task<[Int]?, Never> {
        let epoch = self.epoch
        let mark = likedTracks.mark
        let walk = Task { () -> [Int]? in
            defer { if epoch == self.epoch { likedWalk = nil } }
            guard let walked = try? await api.likedTrackIDs(cap: Self.likesWalkCap), epoch == self.epoch else { return nil }
            // A walk cut short by the cap doesn't know the older likes, so it can only add.
            if walked.count < Self.likesWalkCap {
                likedTracks.adopt(walked, since: mark)
            } else {
                likedTracks.seed(walked)
            }
            // Liked while the walk ran: the newest, so first, as `/me/track_likes/ids` orders them.
            let listed = Set(walked)
            let ids = likedTracks.ids.filter { !listed.contains($0) } + walked.filter(likedTracks.contains)
            likedIDCache = ids
            return ids
        }
        likedWalk = walk
        return walk
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

/// The signed-in account's id, asked for once per session rather than before every write and list.
@MainActor
private final class AccountID {
    private let api: SoundCloudAPI
    private var cached: Int?
    private var generation = 0

    init(api: SoundCloudAPI) {
        self.api = api
    }

    func id() async throws -> Int {
        if let cached { return cached }
        let generation = self.generation
        let id = try await api.me().id
        // Signed out mid-flight: caching this id would send the next session's likes to the old account.
        guard generation == self.generation else { throw CancellationError() }
        cached = id
        return id
    }

    func reset() {
        generation += 1
        cached = nil
    }
}
