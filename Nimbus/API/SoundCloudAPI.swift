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

    /// A body-less mutating request (PUT/DELETE like/repost/follow). Uses the web client's auth —
    /// `Authorization` header + `client_id` — and relies on URLSession.shared carrying the
    /// `datadome` cookie synced from the login WebView: api-v2 writes are behind DataDome bot
    /// protection and 403 without it, even though reads aren't gated.
    private func mutate(method: String, path: String) async throws {
        guard let token else { throw SCError.notAuthenticated }
        let clientID = try await clientIDs.clientID()
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "client_id", value: clientID)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw SCError.http(code) }
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
        guard (200..<300).contains(code) else { throw SCError.http(code) }
        return try decoder.decode(T.self, from: data)
    }
}
