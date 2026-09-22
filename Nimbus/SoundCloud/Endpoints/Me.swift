import Foundation

extension SCEndpoint where Response == SCIDPage {
    /// Ids of every liked track, in like order. Verified live: `/me/track_likes/ids` answers 200 and
    /// pages 200 ids at a time behind `next_href` — cheap enough (a couple of KB a page) to walk in
    /// full, which is how the web client can shuffle a whole library instead of one loaded page.
    static func likedTrackIDs() -> Self {
        .get("/me/track_likes/ids", Self.idPaging)
    }

    /// Liked and reposted sets, for the state of a set page's buttons. VERIFIED 13.09.2026: both
    /// answer 200 with `collection` and `next_href`, the same envelope as the track likes above.
    static func likedPlaylistIDs() -> Self {
        .get("/me/playlist_likes/ids", Self.idPaging, verified: "2026-09-13")
    }

    static func repostedPlaylistIDs() -> Self {
        .get("/me/playlist_reposts/ids", Self.idPaging, verified: "2026-09-13")
    }

    /// Who the signed-in user has blocked, as bare ids — the cheap read that tells the artist menu
    /// whether to offer Block or Unblock.
    static func blockedUserIDs() -> Self {
        .get("/me/mutings/users/ids", Self.idPaging)
    }

    static func idPage(after href: String) -> Self {
        .absolute(href)
    }

    private static let idPaging = ["limit": "200", "linked_partitioning": "1"]
}

extension SCEndpoint where Response == SCMe {
    static func me() -> Self {
        .get("/me")
    }
}

extension SCEndpoint where Response == SCUser {
    /// The full signed-in user (avatar, counts, bio) — used for the profile page and account row.
    static func meUser() -> Self {
        .get("/me")
    }
}

extension SCEndpoint where Response == SCEditableProfile {
    /// `/me` again, for the fields only the edit form needs — first and last name among them.
    static func editableProfile() -> Self {
        .get("/me")
    }
}

extension SCEndpoint where Response == SCStreamPage {
    /// The personalized "Following" feed: posts and reposts from users you follow.
    static func stream(_ limit: Int = 30) -> Self {
        .get("/stream", ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    static func nextStreamPage(_ nextHref: String) -> Self {
        .following(nextHref)
    }
}

extension SCEndpoint where Response == SCTrackLikesPage {
    static func likedTracks(_ userID: Int, limit: Int = 24) -> Self {
        .get("/users/\(userID)/track_likes", ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    static func history(_ limit: Int = 25) -> Self {
        .get("/me/play-history/tracks", ["limit": "\(limit)", "linked_partitioning": "1"])
    }

    /// Follows a `next_href` cursor from a paginated collection.
    static func nextPage(_ nextHref: String) -> Self {
        .following(nextHref)
    }
}

extension SCEndpoint where Response == SCLibraryPage {
    static func library() -> Self {
        .get("/me/library/all", ["limit": "100", "linked_partitioning": "1"])
    }
}

extension SoundCloudAPI {
    func me() async throws -> SCMe {
        try await get(.me())
    }

    func meUser() async throws -> SCUser {
        try await get(.meUser())
    }

    func editableProfile() async throws -> SCEditableProfile {
        try await get(.editableProfile())
    }

    func stream(limit: Int = 30) async throws -> SCStreamPage {
        try await get(.stream(limit))
    }

    func nextStreamPage(_ nextHref: String) async throws -> SCStreamPage {
        try await get(.nextStreamPage(nextHref))
    }

    func likedTracks(userID: Int, limit: Int = 24) async throws -> SCTrackLikesPage {
        try await get(.likedTracks(userID, limit: limit))
    }

    func history(limit: Int = 25) async throws -> SCTrackLikesPage {
        try await get(.history(limit))
    }

    func library() async throws -> SCLibraryPage {
        try await get(.library())
    }

    func nextPage(_ nextHref: String) async throws -> SCTrackLikesPage {
        try await get(.nextPage(nextHref))
    }

    func likedTrackIDs(cap: Int = 5000) async throws -> [Int] {
        try await allIDs(.likedTrackIDs(), cap: cap)
    }

    func likedPlaylistIDs() async throws -> [Int] {
        try await allIDs(.likedPlaylistIDs(), cap: 2000)
    }

    func repostedPlaylistIDs() async throws -> [Int] {
        try await allIDs(.repostedPlaylistIDs(), cap: 2000)
    }

    func blockedUserIDs(cap: Int = 1000) async throws -> [Int] {
        try await allIDs(.blockedUserIDs(), cap: cap)
    }
}
