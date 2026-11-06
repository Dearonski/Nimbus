import Foundation

// The site's own search tabs, one kind each.
nonisolated enum SCSearchKind: String, Sendable {
    case tracks, users, albums
    case playlists = "playlists_without_albums"
}

extension SCEndpoint {
    // VERIFIED 05.11.2026 against soundcloud.com/search: 20 a page, `next_href` walks on by offset.
    static func search<Item>(_ kind: SCSearchKind, _ query: String, limit: Int = 20) -> Self
    where Response == SCSearchResults<Item> {
        .get("/search/\(kind.rawValue)", ["q": query, "limit": "\(limit)", "linked_partitioning": "1"],
             verified: "2026-11-05")
    }
}

extension SCEndpoint where Response == SCSearchSuggestions {
    // VERIFIED 05.11.2026 against soundcloud.com's search field: ten at most, each `{output, query}`, no paging.
    static func searchSuggestions(_ query: String, limit: Int = 10) -> Self {
        .get("/search/queries", ["q": query, "limit": "\(limit)", "linked_partitioning": "1"], verified: "2026-11-05")
    }
}

extension SCEndpoint where Response == SCSearchItem {
    /// VERIFIED 26.10.2026: a profile (its subpages such as `/likes` too), a track (query string
    /// and all) and a set or album come back as the object itself, `kind` saying which; 404 otherwise.
    static func resolve(_ url: URL) -> Self {
        .get("/resolve", ["url": url.absoluteString], verified: "2026-10-26")
    }
}

extension SCEndpoint where Response == SCTrackSearchPage {
    /// The closest live equivalent of the removed per-genre charts: recent popular tracks
    /// filtered by genre tag.
    static func genrePopular(_ slug: String, limit: Int = 30) -> Self {
        .get("/search/tracks",
             [ "q": "", "filter.genre_or_tag": slug, "sort": "popular", "filter.created_at": "last_month", "limit": "\(limit)", "linked_partitioning": "1", ])
    }
}

extension SoundCloudAPI {
    func resolve(url: URL) async throws -> SCSearchItem {
        try await get(.resolve(url))
    }

    func search<Item>(_ kind: SCSearchKind, _ query: String, limit: Int = 20) async throws -> SCSearchResults<Item> {
        try await get(.search(kind, query, limit: limit))
    }

    func searchSuggestions(_ query: String) async throws -> SCSearchSuggestions {
        try await get(.searchSuggestions(query))
    }

    func genrePopular(slug: String, limit: Int = 30) async throws -> SCTrackSearchPage {
        try await get(.genrePopular(slug, limit: limit))
    }
}
