import Foundation

extension SCEndpoint where Response == SCPage<SCFailable<SCPlaylist>> {
    /// Albums and sets come back with the odd unreadable entry, so each item is decoded on its own
    /// and the broken ones are dropped rather than failing the page.
    static func userAlbums(_ id: Int, limit: Int = 30) -> Self {
        .get("/users/\(id)/albums",
             ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    static func userPlaylists(_ id: Int, limit: Int = 30) -> Self {
        .get("/users/\(id)/playlists_without_albums",
             ["limit": "\(limit)", "linked_partitioning": "1"])
    }
}

extension SCEndpoint where Response == SCUser {
    static func user(_ id: Int) -> Self {
        .get("/users/\(id)")
    }
}

extension SCEndpoint where Response == SCPage<SCTrack> {
    static func userTracks(_ id: Int, limit: Int = 30) -> Self {
        .get("/users/\(id)/tracks", ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    static func userTopTracks(_ id: Int, limit: Int = 20) -> Self {
        .get("/users/\(id)/toptracks", ["limit": "\(limit)", "linked_partitioning": "1"])
    }
}

extension SCEndpoint where Response == SCPage<SCUser> {
    /// `/me/followings` is a dead path; the artists you follow live under your own user id.
    static func userFollowings(_ id: Int, limit: Int = 100) -> Self {
        .get("/users/\(id)/followings", ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    /// VERIFIED 08.09.2026: a page of followers with a `next_href`.
    static func userFollowers(_ id: Int, limit: Int = 9) -> Self {
        .get("/users/\(id)/followers",
             ["limit": "\(limit)", "linked_partitioning": "1"],
             verified: "2026-09-08")
    }

    /// "Fans also like". VERIFIED 08.09.2026: users, no `next_href` — the whole set arrives at once.
    static func relatedArtists(_ id: Int, limit: Int = 12) -> Self {
        .get("/users/\(id)/relatedartists", ["limit": "\(limit)"], verified: "2026-09-08")
    }

    static func nextUserPage(_ nextHref: String) -> Self {
        .following(nextHref)
    }
}

extension SCEndpoint where Response == SCStreamPage {
    /// Everything the artist posted, tracks and sets in one timeline — the site's "All" tab.
    /// VERIFIED 07.09.2026: 17 entries on a live profile, 16 tracks and a set, four of them
    /// reposts, with a `next_href`.
    static func userStream(_ id: Int, limit: Int = 30) -> Self {
        .get("/stream/users/\(id)",
             ["limit": "\(limit)", "linked_partitioning": "1"],
             verified: "2026-09-07")
    }

    /// The posts an artist pinned to the top of their page. VERIFIED 07.09.2026 as far as it can
    /// be: it answers with the same shape as the stream, but every profile tried had nothing
    /// pinned, so a populated response has not been seen.
    static func userSpotlight(_ id: Int, limit: Int = 20) -> Self {
        .get("/users/\(id)/spotlight",
             ["limit": "\(limit)", "linked_partitioning": "1"],
             verified: "2026-09-07")
    }

    /// A user's reposts arrive stream-shaped (track/playlist plus reposter).
    static func userReposts(_ id: Int, limit: Int = 30) -> Self {
        .get("/stream/users/\(id)/reposts", ["limit": "\(limit)", "linked_partitioning": "1"])
    }
}

extension SCEndpoint where Response == [SCWebProfile] {
    /// The links an artist listed on their profile. VERIFIED 08.09.2026 — and only in the urn
    /// form: with a bare id the endpoint answers 400, "Could not parse the 'user urn' param".
    static func userWebProfiles(_ id: Int) -> Self {
        .get("/users/soundcloud:users:\(id)/web-profiles", verified: "2026-09-08")
    }
}

extension SCEndpoint where Response == SCPage<SCUserComment> {
    /// Comments this user has left, newest first, each carrying the track it sits on.
    /// VERIFIED 13.09.2026.
    static func userComments(_ id: Int, limit: Int = 5) -> Self {
        .get("/users/\(id)/comments",
             ["limit": "\(limit)", "linked_partitioning": "1"],
             verified: "2026-09-13")
    }
}

extension SCEndpoint where Response == SCLikesPage {
    /// What the artist liked — tracks and sets mixed. VERIFIED 08.09.2026.
    static func userLikes(_ id: Int, limit: Int = 10) -> Self {
        .get("/users/\(id)/likes",
             ["limit": "\(limit)", "linked_partitioning": "1"],
             verified: "2026-09-08")
    }

    static func nextLikesPage(_ nextHref: String) -> Self {
        .following(nextHref)
    }
}

extension SoundCloudAPI {
    func user(id: Int) async throws -> SCUser {
        try await get(.user(id))
    }

    func userTracks(id: Int, limit: Int = 30) async throws -> SCPage<SCTrack> {
        try await get(.userTracks(id, limit: limit))
    }

    func userFollowings(id: Int, limit: Int = 100) async throws -> SCPage<SCUser> {
        try await get(.userFollowings(id, limit: limit))
    }

    func userTopTracks(id: Int, limit: Int = 20) async throws -> SCPage<SCTrack> {
        try await get(.userTopTracks(id, limit: limit))
    }

    func userStream(id: Int, limit: Int = 30) async throws -> SCStreamPage {
        try await get(.userStream(id, limit: limit))
    }

    func userSpotlight(id: Int, limit: Int = 20) async throws -> SCStreamPage {
        try await get(.userSpotlight(id, limit: limit))
    }

    func userReposts(id: Int, limit: Int = 30) async throws -> SCStreamPage {
        try await get(.userReposts(id, limit: limit))
    }

    func userWebProfiles(id: Int) async throws -> [SCWebProfile] {
        try await get(.userWebProfiles(id))
    }

    func userComments(id: Int, limit: Int = 5) async throws -> SCPage<SCUserComment> {
        try await get(.userComments(id, limit: limit))
    }

    func userFollowers(id: Int, limit: Int = 9) async throws -> SCPage<SCUser> {
        try await get(.userFollowers(id, limit: limit))
    }

    func relatedArtists(id: Int, limit: Int = 12) async throws -> SCPage<SCUser> {
        try await get(.relatedArtists(id, limit: limit))
    }

    func userLikes(id: Int, limit: Int = 10) async throws -> SCLikesPage {
        try await get(.userLikes(id, limit: limit))
    }

    func nextUserPage(_ nextHref: String) async throws -> SCPage<SCUser> {
        try await get(.nextUserPage(nextHref))
    }

    func nextLikesPage(_ nextHref: String) async throws -> SCLikesPage {
        try await get(.nextLikesPage(nextHref))
    }

    func allFollowings(id: Int, cap: Int = 5000) async throws -> [SCUser] {
        var page = try await userFollowings(id: id)
        var users = page.collection
        var seen = Set(users.map(\.id))
        while let next = page.nextHref, users.count < cap {
            page = try await nextUserPage(next)
            users.append(contentsOf: page.collection.filter { seen.insert($0.id).inserted })
        }
        return users
    }

    func userAlbums(id: Int, limit: Int = 30) async throws -> [SCPlaylist] {
        try await get(.userAlbums(id, limit: limit)).collection.compactMap(\.value)
    }

    func userPlaylists(id: Int, limit: Int = 30) async throws -> [SCPlaylist] {
        try await get(.userPlaylists(id, limit: limit)).collection.compactMap(\.value)
    }
}
