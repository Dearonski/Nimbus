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

    /// Follows a `next_href` cursor from a paginated collection.
    func nextPage(_ nextHref: String) async throws -> SCTrackLikesPage {
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

    // MARK: - Request plumbing

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
