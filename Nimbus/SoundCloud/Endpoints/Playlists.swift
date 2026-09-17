import Foundation

extension SCEndpoint where Response == SCPlaylist {
    /// Playlists inside `/mixed-selections` arrive without their `tracks` array — fetching the
    /// playlist by id is the only way to learn which tracks it holds.
    static func playlist(_ id: Int) -> Self {
        .get("/playlists/\(id)")
    }
}

extension SCEndpoint where Response == SCPage<SCUser> {
    /// Who liked and who reposted a set. VERIFIED 13.09.2026 — both a user collection with
    /// `next_href`.
    static func playlistLikers(_ id: Int, limit: Int = 12) -> Self {
        .get("/playlists/\(id)/likers",
             ["limit": "\(limit)", "linked_partitioning": "1"],
             verified: "2026-09-13")
    }

    static func playlistReposters(_ id: Int, limit: Int = 12) -> Self {
        .get("/playlists/\(id)/reposters", ["limit": "\(limit)", "linked_partitioning": "1"])
    }
}

extension SoundCloudAPI {
    func playlist(id: Int) async throws -> SCPlaylist {
        try await get(.playlist(id))
    }

    func playlistLikers(id: Int, limit: Int = 12) async throws -> SCPage<SCUser> {
        try await get(.playlistLikers(id, limit: limit))
    }

    func playlistReposters(id: Int, limit: Int = 12) async throws -> SCPage<SCUser> {
        try await get(.playlistReposters(id, limit: limit))
    }
}
