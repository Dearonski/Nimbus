import Foundation

extension SCEndpoint where Response == [SCTrack] {
    /// Full tracks by id, at most 50 per call — what turns the `{id}` stubs inside a playlist into
    /// something playable.
    static func tracks(ids: some Sequence<Int>) -> Self {
        .get("/tracks", ["ids": ids.map(String.init).joined(separator: ",")])
    }
}

extension SCEndpoint where Response == SCPage<SCTrack> {
    static func relatedTracks(_ id: Int, limit: Int = 20) -> Self {
        .get("/tracks/\(id)/related", ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    static func nextTrackPage(_ nextHref: String) -> Self {
        .following(nextHref)
    }
}

extension SCEndpoint where Response == SCPage<SCPlaylist> {
    /// Sets this track appears on. VERIFIED 09.09.2026.
    static func trackAlbums(_ id: Int, limit: Int = 5) -> Self {
        .get("/tracks/\(id)/albums",
             ["limit": "\(limit)", "linked_partitioning": "1"],
             verified: "2026-09-09")
    }

    static func trackPlaylists(_ id: Int, limit: Int = 6) -> Self {
        .get("/tracks/\(id)/playlists_without_albums",
             ["limit": "\(limit)", "linked_partitioning": "1"])
    }
}

extension SCEndpoint where Response == SCStreamURL {
    /// Resolves a transcoding into a freshly signed playlist URL (valid ~5 min) plus, for
    /// encrypted streams, the `licenseAuthToken` used against the FairPlay endpoint.
    static func resolve(for transcoding: SCTranscoding, trackAuthorization: String) -> Self {
        .absolute(transcoding.url, ["track_authorization": trackAuthorization])
    }
}

extension SoundCloudAPI {
    func relatedTracks(id: Int, limit: Int = 20) async throws -> SCPage<SCTrack> {
        try await get(.relatedTracks(id, limit: limit))
    }

    func trackAlbums(id: Int, limit: Int = 5) async throws -> SCPage<SCPlaylist> {
        try await get(.trackAlbums(id, limit: limit))
    }

    func trackPlaylists(id: Int, limit: Int = 6) async throws -> SCPage<SCPlaylist> {
        try await get(.trackPlaylists(id, limit: limit))
    }

    func nextTrackPage(_ nextHref: String) async throws -> SCPage<SCTrack> {
        try await get(.nextTrackPage(nextHref))
    }

    func resolve(for transcoding: SCTranscoding, trackAuthorization: String) async throws -> SCStreamURL {
        try await get(.resolve(for: transcoding, trackAuthorization: trackAuthorization))
    }

    /// Resolves `{id}` track stubs (as found in playlists) into full playable tracks,
    /// batched by 50 and returned in the requested order.
    func tracks(ids: [Int]) async throws -> [SCTrack] {
        guard !ids.isEmpty else { return [] }
        var resolved: [SCTrack] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = ids[start..<min(start + 50, ids.count)]
            resolved.append(contentsOf: try await get(.tracks(ids: chunk)))
        }
        let byID = Dictionary(resolved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    func streamURL(for transcoding: SCTranscoding, trackAuthorization: String) async throws -> URL {
        let stream = try await resolve(for: transcoding, trackAuthorization: trackAuthorization)
        guard let url = URL(string: stream.url) else { throw SCError.badResponse }
        return url
    }
}
