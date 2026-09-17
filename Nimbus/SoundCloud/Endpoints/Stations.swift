import Foundation

extension SCEndpoint where Response == SCPage<SCTrack> {
    /// The artist's own station — what the site's Station button starts. VERIFIED 08.09.2026 on
    /// the short urn; `station_urn` on the user object spells the longer system-playlist form,
    /// which this endpoint does not take.
    static func artistStationTracks(_ userID: Int, limit: Int = 50) -> Self {
        .get("/stations/soundcloud:artist-stations:\(userID)/tracks",
             ["limit": "\(limit)"],
             verified: "2026-09-08")
    }
}

extension SCEndpoint where Response == SCPlaylist {
    /// A mix by its urn, in full — the lists that link to one don't always carry its description
    /// or who it was made for. VERIFIED 13.09.2026 on a personalised "Related tracks" mix.
    static func systemPlaylist(_ urn: String) -> Self {
        .get("/system-playlists/\(urn)", verified: "2026-09-13")
    }

    /// The station as a set, so it can be opened as a page like any other system mix.
    /// VERIFIED 08.09.2026: `playlist_type` ARTIST_STATION, titled after the artist.
    static func artistStation(_ userID: Int) -> Self {
        .get("/system-playlists/soundcloud:system-playlists:artist-stations:\(userID)",
             verified: "2026-09-08")
    }
}

extension SCEndpoint where Response == SCMixedSelectionsPage {
    /// Personalized home shelves: "Daily Drops", "Mixed for you", charts mixes, etc.
    static func mixedSelections(_ limit: Int = 12) -> Self {
        .get("/mixed-selections", ["limit": "\(limit)", "linked_partitioning": "1"])
    }
}

extension SoundCloudAPI {
    func artistStationTracks(userID: Int, limit: Int = 50) async throws -> SCPage<SCTrack> {
        try await get(.artistStationTracks(userID, limit: limit))
    }

    func systemPlaylist(urn: String) async throws -> SCPlaylist {
        try await get(.systemPlaylist(urn))
    }

    func artistStation(userID: Int) async throws -> SCPlaylist {
        try await get(.artistStation(userID))
    }

    func mixedSelections(limit: Int = 12) async throws -> SCMixedSelectionsPage {
        try await get(.mixedSelections(limit))
    }
}
