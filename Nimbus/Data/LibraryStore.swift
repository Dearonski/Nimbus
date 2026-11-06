import Foundation
import Observation
import os

enum LibraryList: CaseIterable {
    case selections, trending, history, likes, stream, playlists, following, activity
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

    let search: SearchModel
    let activity: ActivityStore

    let playlistList = FreshList<SCPlaylist>("playlists", ttl: TTL.library)
    var playlists: [SCPlaylist] { playlistList.items }

    var albums: [SCPlaylist] { playlists.filter(\.isAlbum) }
    // By the site's own test: a "Related tracks" mix made for you lists under Playlists, only a station under Stations.
    var userPlaylists: [SCPlaylist] { playlists.filter { !$0.isAlbum && !$0.isStation }.map(patched) }
    var stations: [SCPlaylist] { playlists.filter { !$0.isAlbum && $0.isStation } }

    let selectionList = FreshList<SCMixedSelection>("shelves", ttl: TTL.shelves)
    var selections: [SCMixedSelection] { selectionList.items }

    private(set) var meUser: SCUser?

    /// Seeded by loaded pages, then the full walk signing in starts, so an old like shows its heart anywhere.
    let likedTracks: OptimisticSet<Int>
    let repostedTracks: OptimisticSet<Int>
    /// A set's buttons have no feed of their own to seed them, so these are walked when a set page first asks.
    let likedPlaylists: OptimisticSet<Int>
    let repostedPlaylists: OptimisticSet<Int>
    /// Mixes and stations go by urn, with a like list of their own; they can't be reposted.
    let likedSystemPlaylists: OptimisticSet<String>
    private let account: AccountID

    let followingList = FreshList<SCUser>("following", ttl: TTL.following)
    var following: [SCUser] { followingList.items }
    /// The people you follow, seeded from the Following list.
    let followed: OptimisticSet<Int>

    let blocked: OptimisticSet<Int>

    private var lastPlayAt: ContinuousClock.Instant?

    let trendingList = FreshList<SCTrack>("trending", ttl: TTL.chart)
    var trending: [SCTrack] { trendingList.items }
    var isLoadingTrending: Bool { trendingList.isLoading }

    /// The artists behind the current chart, in chart order, deduplicated — a people-shelf for free,
    /// with no extra request.
    var chartArtists: [SCUser] {
        var seen = Set<Int>()
        return trending.map(\.user).filter { seen.insert($0.id).inserted }
    }

    private var trendingGenre = SCGenre.charts[0]

    let api: SoundCloudAPI
    private let cache: TrackCache
    /// Bumped by `reset()`. A request in flight was made for the account that just signed out, so
    /// every loader checks the epoch it started in before writing its answer anywhere.
    private var epoch = 0

    init(api: SoundCloudAPI) {
        self.api = api
        let cache = TrackCache()
        self.cache = cache
        let account = AccountID(api: api)
        self.account = account
        search = SearchModel(api: api, database: cache.database)
        activity = ActivityStore(api: api)

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
        likedSystemPlaylists = OptimisticSet(walk: { try await api.likedSystemPlaylistURNs() }) { urn, on in
            let user = try await account.id()
            if on { try await api.likeSystemPlaylist(userID: user, urn: urn) } else { try await api.unlikeSystemPlaylist(userID: user, urn: urn) }
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

        likes = TrackFeed(
            name: "likes",
            ttl: TTL.feeds,
            api: api,
            persist: { cache.save($0) },
            cached: { await cache.rows(of: "likes") },
            persistOrder: { cache.saveOrder("likes", ids: $0.map(\.id)) }) {
                try await api.likedTracks(userID: try await account.id())
            }
        history = TrackFeed(
            name: "history",
            ttl: TTL.feeds,
            api: api,
            persist: { cache.save($0) },
            cached: { await cache.rows(of: "history") },
            persistOrder: { cache.saveOrder("history", ids: $0.map(\.id)) }) {
                try await api.history()
            }
        stream = Pager(
            first: { try await api.stream().page },
            next: { try await api.page(after: $0, as: SCStreamPage.self).page })

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

        playlistList.fetch = { try await Self.withCovers(api.libraryPlaylists(), api: api) }
        selectionList.fetch = { try await api.mixedSelections().collection.filter { !$0.items.isEmpty } }
        trendingList.fetch = { [weak self] in
            guard let self else { return [] }
            let chart = try await api.systemPlaylist(urn: trendingGenre.chartURN)
            return try await tracks(for: chart)
        }
        followingList.isSettled = { [weak self] in self?.followed.pending.isSettled ?? true }
        followingList.fetch = { [weak self] in try await self?.walkFollowing() ?? [] }
    }

    // MARK: - Likes

    func isLiked(_ track: SCTrack) -> Bool { likedTracks.contains(track.id) }

    /// Forgets everything tied to the account, cache included — otherwise the next person to sign
    /// in would be looking at the previous one's library. Each list's freshness goes with it: left
    /// standing, every cleared list would read as fresh and stay empty for the rest of the launch.
    func reset() {
        epoch += 1
        search.reset()
        playlistList.reset()
        selectionList.reset()
        followingList.reset()
        trendingList.reset()
        activity.reset()
        meUser = nil
        account.reset()
        for set in [likedTracks, repostedTracks, likedPlaylists, repostedPlaylists, followed, blocked] { set.reset() }
        likedSystemPlaylists.reset()
        likedIDCache = nil
        likedWalk?.cancel()
        likedWalk = nil
        lastPlayAt = nil
        stream.reset()
        likes.reset()
        history.reset()
        cache.clear()
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
        followingList.edit { following in
            if isNow {
                if !following.contains(where: { $0.id == user.id }) { following.insert(user, at: 0) }
            } else {
                following.removeAll { $0.id == user.id }
            }
        }
    }

    func toggleLike(_ track: SCTrack) {
        likedTracks.toggle(track.id, counted: track.likesCount ?? 0) { [weak self] liked in self?.showLiked(track, liked) }
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

    // A count arrives with the track or set and isn't fetched again; your own tap moves it, as on the site.
    func likesCount(_ track: SCTrack) -> Int? { likedTracks.count(track.id, sent: track.likesCount) }

    func repostsCount(_ track: SCTrack) -> Int? { repostedTracks.count(track.id, sent: track.repostsCount) }

    func likesCount(_ playlist: SCPlaylist) -> Int? {
        if let id = Int(playlist.id) { return likedPlaylists.count(id, sent: playlist.likesCount) }
        return likedSystemPlaylists.count(playlist.id, sent: playlist.likesCount)
    }

    func repostsCount(_ playlist: SCPlaylist) -> Int? {
        Int(playlist.id).map { repostedPlaylists.count($0, sent: playlist.repostsCount) } ?? playlist.repostsCount
    }

    func loadPlaylistStateIfNeeded() {
        likedPlaylists.loadIfNeeded()
        repostedPlaylists.loadIfNeeded()
        likedSystemPlaylists.loadIfNeeded()
    }

    func isLiked(_ playlist: SCPlaylist) -> Bool {
        Int(playlist.id).map(likedPlaylists.contains) ?? likedSystemPlaylists.contains(playlist.id)
    }

    func isReposted(_ playlist: SCPlaylist) -> Bool {
        Int(playlist.id).map(repostedPlaylists.contains) ?? false
    }

    func toggleLike(_ playlist: SCPlaylist) {
        let count = playlist.likesCount ?? 0
        if let id = Int(playlist.id) {
            likedPlaylists.toggle(id, counted: count)
        } else {
            likedSystemPlaylists.toggle(playlist.id, counted: count)
        }
    }

    func toggleRepost(_ playlist: SCPlaylist) {
        guard let id = Int(playlist.id) else { return }
        repostedPlaylists.toggle(id, counted: playlist.repostsCount ?? 0)
    }

    func toggleRepost(_ track: SCTrack) {
        repostedTracks.toggle(track.id, counted: track.repostsCount ?? 0)
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
        case .selections: await selectionList.update(force: force)
        case .trending: await trendingList.update(force: force)
        case .history: await history.update(force: force)
        case .likes: await likes.update(force: force)
        case .stream: await updateStream(force: force)
        case .playlists: await playlistList.update(force: force)
        case .following: await followingList.update(force: force)
        case .activity: await activity.update(force: force)
        }
    }

    private func isWanted(_ list: LibraryList) -> Bool {
        switch list {
        case .selections: selectionList.isWanted
        case .trending: trendingList.isWanted
        case .history: history.wasAsked
        case .likes: likes.wasAsked
        case .stream: stream.hasLoaded || stream.error != nil
        case .playlists: playlistList.isWanted
        case .following: followingList.isWanted
        case .activity: activity.list.isWanted
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
        playlistList.loadIfNeeded(force: force)
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
        followingList.loadIfNeeded(force: force)
    }

    /// A follow tapped while the list was walked is missing from it, an unfollow still in it.
    private func walkFollowing() async throws -> [SCUser] {
        let epoch = self.epoch
        let mark = followed.mark
        let users = try await api.allFollowings(id: try await account.id())
        guard epoch == self.epoch else { throw CancellationError() }
        followed.adopt(users.map(\.id), since: mark)
        let walked = Set(users.map(\.id))
        return following.filter { !walked.contains($0.id) && followed.contains($0.id) }
            + users.filter { followed.contains($0.id) }
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
        trendingList.loadIfNeeded(force: force)
    }

    func reloadTrending(genre: SCGenre) {
        guard genre != trendingGenre else { return }
        trendingGenre = genre
        trendingList.reset()
        trendingList.loadIfNeeded()
    }

    func loadSelectionsIfNeeded(force: Bool = false) {
        selectionList.loadIfNeeded(force: force)
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

    func tracks(ids: [Int]) async -> [SCTrack] {
        (try? await api.tracks(ids: ids)) ?? []
    }

    // The library can list a set with no cover at all, own or computed, while the set itself still has its tracks.
    private static func withCovers(_ playlists: [SCPlaylist], api: SoundCloudAPI) async -> [SCPlaylist] {
        let bare = playlists.filter {
            !$0.isSystem && $0.artworkURL == nil && $0.firstTrackArtworkURL == nil && $0.trackCount > 0
        }
        guard !bare.isEmpty else { return playlists }
        var covers: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for playlist in bare.prefix(12) {
                guard let id = Int(playlist.id) else { continue }
                group.addTask {
                    let full = try? await api.playlist(id: id)
                    return (playlist.id, full?.artworkURL ?? full?.firstTrackArtworkURL)
                }
            }
            for await (id, cover) in group {
                if let cover { covers[id] = cover }
            }
        }
        return playlists.map { playlist in
            guard let cover = covers[playlist.id] else { return playlist }
            var copy = playlist
            copy.firstTrackArtworkURL = cover
            return copy
        }
    }

    // MARK: - Own playlists

    // The library lists playlists the user only follows alongside the ones they made.
    var ownPlaylists: [SCPlaylist] {
        guard let me = meUser else { return [] }
        return userPlaylists.filter { !$0.isSystem && $0.user?.id == me.id }
    }

    // Bumped per playlist on every change made here, so an open page knows to show it again.
    private(set) var playlistEdits: [String: Int] = [:]

    // What Nimbus last wrote to each playlist, shown at once and until SoundCloud's own reads catch up.
    private var written: [String: Written] = [:]
    // Tracks put into or listed in an own playlist here: its page and cover need nothing more about them.
    private(set) var addedTracks: [Int: SCTrack] = [:]
    private static let readsSettle: TimeInterval = 120

    private struct Written {
        var trackIDs: [Int]?
        var title: String?
        var description: String?
        var sharing: String?
        var at = Date.now
    }

    func owns(_ playlist: SCPlaylist) -> Bool {
        !playlist.isSystem && meUser != nil && playlist.user?.id == meUser?.id
    }

    private func recent(_ id: String) -> Written? {
        guard let entry = written[id], Date.now.timeIntervalSince(entry.at) < Self.readsSettle else { return nil }
        return entry
    }

    func writtenTrackIDs(for id: String) -> [Int]? { recent(id)?.trackIDs }

    func remember(_ tracks: [SCTrack], in playlist: SCPlaylist) {
        guard owns(playlist) else { return }
        for track in tracks where addedTracks[track.id] == nil { addedTracks[track.id] = track }
    }

    func patched(_ playlist: SCPlaylist) -> SCPlaylist {
        guard let entry = recent(playlist.id) else { return playlist }
        var copy = playlist
        if let title = entry.title { copy.title = title }
        if let description = entry.description { copy.description = description }
        if let sharing = entry.sharing { copy.sharing = sharing }
        if let ids = entry.trackIDs {
            copy.trackIDs = ids
            copy.trackCount = ids.count
            // SoundCloud covers a set with its first track, and recomputes that well after the write.
            let first = ids.first.flatMap { addedTracks[$0] }
            if !copy.hasOwnArtwork, ids.isEmpty || first != nil {
                copy.artworkURL = first?.artworkURL
                copy.firstTrackArtworkURL = first?.artworkURL
            }
        }
        return copy
    }

    private func record(_ id: String, _ change: (inout Written) -> Void) {
        var entry = recent(id) ?? Written()
        change(&entry)
        entry.at = .now
        written[id] = entry
        playlistEdits[id, default: 0] += 1
    }

    // Read fresh before writing the whole list back: a stale one would undo changes made on the site since.
    private func currentTrackIDs(_ id: Int, _ key: String) async throws -> [Int] {
        if let ids = writtenTrackIDs(for: key) { return ids }
        return try await api.playlist(id: id, fresh: true).trackIDs
    }

    @discardableResult
    func add(_ track: SCTrack, to playlist: SCPlaylist) async throws -> Bool {
        guard let id = Int(playlist.id) else { return false }
        let before = try await currentTrackIDs(id, playlist.id)
        guard !before.contains(track.id) else { return false }
        addedTracks[track.id] = track
        try await write(playlist.id, from: before, to: before + [track.id]) {
            try await api.setPlaylistTracks(id: id, trackIDs: before + [track.id])
        }
        return true
    }

    func remove(_ track: SCTrack, from playlist: SCPlaylist) async throws {
        guard let id = Int(playlist.id) else { return }
        let before = try await currentTrackIDs(id, playlist.id)
        guard let index = before.firstIndex(of: track.id) else { return }
        var after = before
        after.remove(at: index)
        try await write(playlist.id, from: before, to: after) {
            try await api.setPlaylistTracks(id: id, trackIDs: after)
        }
    }

    // Shown before SoundCloud answers, and put back if it refuses.
    private func write(_ key: String, from before: [Int], to after: [Int],
                       _ send: () async throws -> Void) async throws {
        record(key) { $0.trackIDs = after }
        do {
            try await send()
        } catch {
            record(key) { $0.trackIDs = before }
            throw error
        }
        _ = await playlistList.update(force: true)
    }

    func createPlaylist(title: String, isPrivate: Bool, with tracks: [SCTrack]) async throws -> SCPlaylist {
        let made = try await api.createPlaylist(title: title, isPrivate: isPrivate, trackIDs: tracks.map(\.id))
        tracks.forEach { addedTracks[$0.id] = $0 }
        record(made.id) { $0.trackIDs = tracks.map(\.id) }
        _ = await playlistList.update(force: true)
        return made
    }

    func save(_ playlist: SCPlaylist, title: String, description: String, isPrivate: Bool,
              trackIDs: [Int]) async throws {
        guard let id = Int(playlist.id) else { return }
        try await api.editPlaylist(id: id, title: title, description: description, isPrivate: isPrivate,
                                   trackIDs: trackIDs)
        record(playlist.id) {
            $0.trackIDs = trackIDs
            $0.title = title
            $0.description = description
            $0.sharing = isPrivate ? "private" : "public"
        }
        _ = await playlistList.update(force: true)
    }

    func delete(_ playlist: SCPlaylist) async throws {
        guard let id = Int(playlist.id) else { return }
        try await api.deletePlaylist(id: id)
        playlistList.edit { $0.removeAll { $0.id == playlist.id } }
        written[playlist.id] = nil
        playlistEdits[playlist.id, default: 0] += 1
    }

    /// Resolves a playlist's stub track IDs into full playable tracks.
    /// Playlists that arrive from `/mixed-selections` carry no track stubs at all, so they are
    /// re-fetched by id first — otherwise the page would open empty.
    /// Throws rather than returning `[]`: a failed resolve and an empty playlist looked identical
    /// to callers, which is what made a broken quick-play card a dead click.
    func tracks(for playlist: SCPlaylist) async throws -> [SCTrack] {
        var ids = playlist.trackIDs
        if ids.isEmpty, let numericID = Int(playlist.id) {
            ids = try await api.playlist(id: numericID).trackIDs
        }
        return try await api.tracks(ids: ids)
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
