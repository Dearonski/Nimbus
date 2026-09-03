import Foundation

enum SCError: Error {
    case notAuthenticated
    case clientIDNotFound
    case noHLSTranscoding
    case http(Int)
    case badResponse
}

/// Thin async wrapper over SoundCloud's internal api-v2.
/// Auth is a harvested `oauth_token`; on 401/403 we refresh the client_id once and retry.
actor SoundCloudAPI {
    static let tokenAccount = "oauth_token"
    /// Writes go out on a jar-less session on purpose — see `mutate`.
    private static let writeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()
    private static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Asked for a fresh token when the current one stops being accepted; returns nil when the web
    /// session is gone too, which is the app's cue to show the login screen.
    private var refreshToken: (@Sendable () async -> String?)?
    private var onSessionExpired: (@Sendable () async -> Void)?

    func setRefreshToken(_ handler: @escaping @Sendable () async -> String?) {
        refreshToken = handler
    }

    func setOnSessionExpired(_ handler: @escaping @Sendable () async -> Void) {
        onSessionExpired = handler
    }

    private let base = URL(string: "https://api-v2.soundcloud.com")!
    private let clientIDs = ClientIDResolver()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private var token: String? { Keychain.get(SoundCloudAPI.tokenAccount) }

    func resolveTrack(url: String) async throws -> SCTrack {
        try await getDecoded(path: "/resolve", query: ["url": url])
    }

    func me() async throws -> SCMe {
        try await getDecoded(path: "/me", query: [:])
    }

    /// The full signed-in user (avatar, counts, bio) — used for the profile page and account row.
    func meUser() async throws -> SCUser {
        try await getDecoded(path: "/me", query: [:])
    }

    /// The personalized "Following" feed: posts and reposts from users you follow.
    func stream(limit: Int = 30) async throws -> SCStreamPage {
        try await getDecoded(
            path: "/stream",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    func nextStreamPage(_ nextHref: String) async throws -> SCStreamPage {
        try await getDecoded(absolute: nextHref, query: [:])
    }

    /// Trending chart. Since ~2026 `/charts` only serves `all-music`; per-genre charts 404 —
    /// use `genrePopular` for everything else.
    func charts(kind: String = "trending",
                genre: String = "soundcloud:genres:all-music",
                limit: Int = 30) async throws -> SCChartPage {
        try await getDecoded(
            path: "/charts",
            query: ["kind": kind, "genre": genre, "limit": "\(limit)", "linked_partitioning": "1"])
    }

    func nextChartPage(_ nextHref: String) async throws -> SCChartPage {
        try await getDecoded(absolute: nextHref, query: [:])
    }

    /// The closest live equivalent of the removed per-genre charts: recent popular tracks
    /// filtered by genre tag.
    func genrePopular(slug: String, limit: Int = 30) async throws -> SCTrackSearchPage {
        try await getDecoded(
            path: "/search/tracks",
            query: [
                "q": "",
                "filter.genre_or_tag": slug,
                "sort": "popular",
                "filter.created_at": "last_month",
                "limit": "\(limit)",
                "linked_partitioning": "1",
            ])
    }

    func nextGenrePopularPage(_ nextHref: String) async throws -> SCTrackSearchPage {
        try await getDecoded(absolute: nextHref, query: [:])
    }

    func likedTracks(userID: Int, limit: Int = 24) async throws -> SCTrackLikesPage {
        try await getDecoded(
            path: "/users/\(userID)/track_likes",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    func history(limit: Int = 25) async throws -> SCTrackLikesPage {
        try await getDecoded(
            path: "/me/play-history/tracks",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    func library() async throws -> SCLibraryPage {
        try await getDecoded(path: "/me/library/all", query: ["limit": "100", "linked_partitioning": "1"])
    }

    /// Playlists inside `/mixed-selections` arrive without their `tracks` array — fetching the
    /// playlist by id is the only way to learn which tracks it holds.
    func playlist(id: Int) async throws -> SCPlaylist {
        try await getDecoded(path: "/playlists/\(id)", query: [:])
    }

    func relatedTracks(id: Int, limit: Int = 20) async throws -> SCPage<SCTrack> {
        try await getDecoded(
            path: "/tracks/\(id)/related",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    /// Resolves `{id}` track stubs (as found in playlists) into full playable tracks,
    /// batched by 50 and returned in the requested order.
/// Ids of every liked track, in like order. Verified live: `/me/track_likes/ids` answers 200 and
    /// pages 200 ids at a time behind `next_href` — cheap enough (a couple of KB a page) to walk in
    /// full, which is how the web client can shuffle a whole library instead of one loaded page.
    func likedTrackIDs(cap: Int = 5000) async throws -> [Int] {
        struct Page: Decodable {
            let collection: [Int]
            let nextHref: String?
            enum CodingKeys: String, CodingKey {
                case collection
                case nextHref = "next_href"
            }
        }

        var ids: [Int] = []
        var page: Page = try await getDecoded(
            path: "/me/track_likes/ids", query: ["limit": "200", "linked_partitioning": "1"])
        ids.append(contentsOf: page.collection)

        while let next = page.nextHref, ids.count < cap {
            page = try await getDecoded(absolute: next, query: [:])
            ids.append(contentsOf: page.collection)
        }
        return Array(ids.prefix(cap))
    }

        func tracks(ids: [Int]) async throws -> [SCTrack] {
        guard !ids.isEmpty else { return [] }
        var resolved: [SCTrack] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = ids[start..<min(start + 50, ids.count)]
            let batch: [SCTrack] = try await getDecoded(
                path: "/tracks", query: ["ids": chunk.map(String.init).joined(separator: ",")])
            resolved.append(contentsOf: batch)
        }
        let byID = Dictionary(resolved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Follows a `next_href` cursor from a paginated collection.
    func nextPage(_ nextHref: String) async throws -> SCTrackLikesPage {
        try await getDecoded(absolute: nextHref, query: [:])
    }

    func search(_ query: String, limit: Int = 30) async throws -> SCSearchPage {
        try await getDecoded(
            path: "/search",
            query: ["q": query, "limit": "\(limit)", "linked_partitioning": "1"])
    }

    func nextSearchPage(_ nextHref: String) async throws -> SCSearchPage {
        try await getDecoded(absolute: nextHref, query: [:])
    }

    func user(id: Int) async throws -> SCUser {
        try await getDecoded(path: "/users/\(id)", query: [:])
    }

    func userTracks(id: Int, limit: Int = 30) async throws -> SCPage<SCTrack> {
        try await getDecoded(
            path: "/users/\(id)/tracks",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    /// `/me/followings` is a dead path; the artists you follow live under your own user id.
    func userFollowings(id: Int, limit: Int = 100) async throws -> SCPage<SCUser> {
        try await getDecoded(
            path: "/users/\(id)/followings",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    func userTopTracks(id: Int, limit: Int = 20) async throws -> SCPage<SCTrack> {
        try await getDecoded(
            path: "/users/\(id)/toptracks",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    func userAlbums(id: Int, limit: Int = 30) async throws -> [SCPlaylist] {
        let page: SCPage<SCFailable<SCPlaylist>> = try await getDecoded(
            path: "/users/\(id)/albums",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
        return page.collection.compactMap(\.value)
    }

    func userPlaylists(id: Int, limit: Int = 30) async throws -> [SCPlaylist] {
        let page: SCPage<SCFailable<SCPlaylist>> = try await getDecoded(
            path: "/users/\(id)/playlists_without_albums",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
        return page.collection.compactMap(\.value)
    }

    /// A user's reposts arrive stream-shaped (track/playlist plus reposter).
    func userReposts(id: Int, limit: Int = 30) async throws -> SCStreamPage {
        try await getDecoded(
            path: "/stream/users/\(id)/reposts",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    /// Personalized home shelves: "Daily Drops", "Mixed for you", charts mixes, etc.
    func mixedSelections(limit: Int = 12) async throws -> SCMixedSelectionsPage {
        try await getDecoded(
            path: "/mixed-selections",
            query: ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    func nextTrackPage(_ nextHref: String) async throws -> SCPage<SCTrack> {
        try await getDecoded(absolute: nextHref, query: [:])
    }

    /// Resolves a transcoding into a freshly signed playlist URL (valid ~5 min) plus, for
    /// encrypted streams, the `licenseAuthToken` used against the FairPlay endpoint.
    func resolve(for transcoding: SCTranscoding, trackAuthorization: String) async throws -> SCStreamURL {
        try await getDecoded(
            absolute: transcoding.url,
            query: ["track_authorization": trackAuthorization])
    }

    func streamURL(for transcoding: SCTranscoding, trackAuthorization: String) async throws -> URL {
        let stream = try await resolve(for: transcoding, trackAuthorization: trackAuthorization)
        guard let url = URL(string: stream.url) else { throw SCError.badResponse }
        return url
    }

    // MARK: - Mutations

    /// Path taken from SoundCloud's own web bundle, where the API map lists `myFollowingsCreate`
    /// and `myFollowingsDelete` against `me/followings/:id`. The verbs are minified there; PUT was
    /// ruled out by a live 404, leaving POST for create and DELETE for remove.
    func followUser(id: Int) async throws {
        try await mutate(method: "POST", path: "/me/followings/\(id)")
    }

    func unfollowUser(id: Int) async throws {
        try await mutate(method: "DELETE", path: "/me/followings/\(id)")
    }

    func likeTrack(userID: Int, trackID: Int) async throws {
        try await mutate(method: "PUT", path: "/users/\(userID)/track_likes/\(trackID)")
    }

    func unlikeTrack(userID: Int, trackID: Int) async throws {
        try await mutate(method: "DELETE", path: "/users/\(userID)/track_likes/\(trackID)")
    }

    func likePlaylist(userID: Int, playlistID: Int) async throws {
        try await mutate(method: "PUT", path: "/users/\(userID)/playlist_likes/\(playlistID)")
    }

    func unlikePlaylist(userID: Int, playlistID: Int) async throws {
        try await mutate(method: "DELETE", path: "/users/\(userID)/playlist_likes/\(playlistID)")
    }

    func repostTrack(trackID: Int) async throws {
        try await mutate(method: "PUT", path: "/me/track_reposts/\(trackID)")
    }

    func unrepostTrack(trackID: Int) async throws {
        try await mutate(method: "DELETE", path: "/me/track_reposts/\(trackID)")
    }

    func repostPlaylist(playlistID: Int) async throws {
        try await mutate(method: "PUT", path: "/me/playlist_reposts/\(playlistID)")
    }

    func unrepostPlaylist(playlistID: Int) async throws {
        try await mutate(method: "DELETE", path: "/me/playlist_reposts/\(playlistID)")
    }

    // MARK: - Request plumbing

    /// A body-less mutating request (PUT/DELETE like/repost/follow).
    ///
    /// Two things get this past DataDome, both measured 03.09.2026. The `Origin`/`Referer` pair is
    /// required — without it every attempt answers 403 with a `geo.captcha-delivery.com` redirect.
    /// And the request must carry NO cookies: the harvested `datadome` cookie marks the caller as a
    /// flagged session, which is why a like could be removed but never added while writes rode
    /// `URLSession.shared`. Hence `writeSession` below. `User-Agent`, `client_id` and the body make
    /// no difference either way.
    private func mutate(method: String, path: String) async throws {
        guard let token else { throw SCError.notAuthenticated }
        let clientID = try await clientIDs.clientID()
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "client_id", value: clientID)]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        if method != "DELETE" {
            req.httpBody = Data()
            req.setValue("0", forHTTPHeaderField: "Content-Length")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // The gate. Everything else below is belt and braces; these two are load-bearing.
        req.setValue("https://soundcloud.com", forHTTPHeaderField: "Origin")
        req.setValue("https://soundcloud.com/", forHTTPHeaderField: "Referer")
        req.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.writeSession.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let body = String(decoding: data.prefix(160), as: UTF8.self)
            print("[api-v2] \(method) \(path) -> \(code) \(body)")
            throw SCError.http(code)
        }
    }

    private func getDecoded<T: Decodable>(
        path: String? = nil,
        absolute: String? = nil,
        query: [String: String]
    ) async throws -> T {
        guard let token else { throw SCError.notAuthenticated }

        func makeURL(clientID: String) -> URL {
            let baseURL = absolute.flatMap { URL(string: $0) } ?? base.appendingPathComponent(path ?? "")
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            var items = (comps.queryItems ?? []) + query.map { URLQueryItem(name: $0.key, value: $0.value) }
            items.append(URLQueryItem(name: "client_id", value: clientID))
            comps.queryItems = items
            return comps.url!
        }

        func request(clientID: String) async throws -> (Data, Int) {
            var req = URLRequest(url: makeURL(clientID: clientID))
            req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (data, code)
        }

        var clientID = try await clientIDs.clientID()
        var (data, code) = try await request(clientID: clientID)

        if code == 401 || code == 403 {
            await clientIDs.invalidate()
            clientID = try await clientIDs.clientID(forceRefresh: true)
            (data, code) = try await request(clientID: clientID)
        }
        // A rotated client_id doesn't help a stale token, so try the web session's own before
        // giving up on it.
        if code == 401, let refreshed = await refreshToken?(), refreshed != token {
            Keychain.set(refreshed, for: Self.tokenAccount)
            (data, code) = try await request(clientID: clientID)
        }
        if code == 401 {
            await onSessionExpired?()
        }
        guard (200..<300).contains(code) else { throw SCError.http(code) }
        return try decoder.decode(T.self, from: data)
    }
}
