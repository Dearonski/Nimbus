import Foundation

extension SCEndpoint where Response == SCSearchPage {
    static func search(_ query: String, limit: Int = 30) -> Self {
        .get("/search", ["q": query, "limit": "\(limit)", "linked_partitioning": "1"])
    }
}

extension SCEndpoint where Response == SCChartPage {
    /// Trending chart. Since ~2026 `/charts` only serves `all-music`; per-genre charts 404 —
    /// use `genrePopular` for everything else.
    static func charts(_ kind: String = "trending", genre: String = "soundcloud:genres:all-music", limit: Int = 30) -> Self {
        .get("/charts",
             ["kind": kind, "genre": genre, "limit": "\(limit)", "linked_partitioning": "1"])
    }
}

extension SCEndpoint where Response == SCTrackSearchPage {
    /// The closest live equivalent of the removed per-genre charts: recent popular tracks
    /// filtered by genre tag.
    static func genrePopular(_ slug: String, limit: Int = 30) -> Self {
        .get("/search/tracks",
             [ "q": "", "filter.genre_or_tag": slug, "sort": "popular", "filter.created_at": "last_month", "limit": "\(limit)", "linked_partitioning": "1", ])
    }

    static func nextGenrePopularPage(_ nextHref: String) -> Self {
        .following(nextHref)
    }
}

extension SoundCloudAPI {
    func search(_ query: String, limit: Int = 30) async throws -> SCSearchPage {
        try await get(.search(query, limit: limit))
    }

    func charts(kind: String = "trending", genre: String = "soundcloud:genres:all-music", limit: Int = 30) async throws -> SCChartPage {
        try await get(.charts(kind, genre: genre, limit: limit))
    }

    func genrePopular(slug: String, limit: Int = 30) async throws -> SCTrackSearchPage {
        try await get(.genrePopular(slug, limit: limit))
    }

    func nextGenrePopularPage(_ nextHref: String) async throws -> SCTrackSearchPage {
        try await get(.nextGenrePopularPage(nextHref))
    }
}
