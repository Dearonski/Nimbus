import Foundation

/// One api-v2 request as a value: where it goes, what it carries, what it decodes into, and when
/// it was last seen working. Endpoints live in `Endpoints/` as static factories, so a path or a
/// parameter that SoundCloud changes is edited in one line instead of inside a method body.
nonisolated struct SCEndpoint<Response: Decodable & Sendable>: Sendable {
    enum Target: Sendable {
        /// Relative to `https://api-v2.soundcloud.com`.
        case path(String)
        /// A whole URL the API handed us — a `next_href` cursor or a transcoding link.
        case absolute(String)
    }

    let target: Target
    let query: [String: String]
    /// Date this endpoint was last confirmed against the live API, `yyyy-MM-dd`.
    let verified: String?

    static func get(_ path: String,
                    _ query: [String: String] = [:],
                    verified: String? = nil) -> Self {
        Self(target: .path(path), query: query, verified: verified)
    }

    static func absolute(_ url: String,
                         _ query: [String: String] = [:],
                         verified: String? = nil) -> Self {
        Self(target: .absolute(url), query: query, verified: verified)
    }

    /// A `next_href` asked for a page this long. The first page stays small so a list opens fast;
    /// after it, 24 rows at a quarter of a second each could not keep up with a fast flick.
    static func following(_ nextHref: String, limit: Int = 100) -> Self {
        .absolute(nextHref, ["limit": "\(limit)"])
    }

    /// What the logs and the smoke test call this request — the path with its ids left in place.
    var label: String {
        switch target {
        case .path(let path): path
        case .absolute(let url): URL(string: url)?.path ?? url
        }
    }
}

/// A write, kept apart from reads because it travels differently: api-v2 mutations go through the
/// login WebView to satisfy DataDome, and none of them answer with a body worth decoding.
nonisolated struct SCWrite: Sendable {
    let method: String
    let path: String
    let json: String?
    let verified: String?

    init(_ method: String, _ path: String, json: String? = nil, verified: String? = nil) {
        self.method = method
        self.path = path
        self.json = json
        self.verified = verified
    }

    static func put(_ path: String, json: String? = nil, verified: String? = nil) -> Self {
        Self("PUT", path, json: json, verified: verified)
    }

    static func post(_ path: String, json: String? = nil, verified: String? = nil) -> Self {
        Self("POST", path, json: json, verified: verified)
    }

    static func delete(_ path: String, verified: String? = nil) -> Self {
        Self("DELETE", path, verified: verified)
    }
}
