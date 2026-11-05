import Foundation

/// A universal-search result item, dispatched on the object's `kind`.
nonisolated enum SCSearchItem: Decodable, Sendable, Identifiable {
    case track(SCTrack)
    case user(SCUser)
    case playlist(SCPlaylist)

    var id: String {
        switch self {
        case .track(let t): "t\(t.id)"
        case .user(let u): "u\(u.id)"
        case .playlist(let p): "p\(p.id)"
        }
    }

    private enum KindKey: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: KindKey.self).decode(String.self, forKey: .kind)
        switch kind {
        case "track": self = .track(try SCTrack(from: decoder))
        case "user": self = .user(try SCUser(from: decoder))
        case "playlist", "playlist-like": self = .playlist(try SCPlaylist(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown kind \(kind)"))
        }
    }
}

// One page of a typed search (`/search/tracks`, `users`, `albums`, `playlists_without_albums`), decoded leniently.
nonisolated struct SCSearchResults<Item: Decodable & Sendable>: Decodable, Sendable {
    let collection: [Item]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextHref = try c.decodeIfPresent(String.self, forKey: .nextHref)
        collection = try c.decode([SCFailable<Item>].self, forKey: .collection).compactMap(\.value)
    }
}

typealias SCTrackSearchPage = SCSearchResults<SCTrack>

// `/search/queries`: the completions the site's own field offers while you type.
nonisolated struct SCSearchSuggestions: Decodable, Sendable {
    struct Suggestion: Decodable, Sendable {
        let query: String
    }

    let collection: [Suggestion]
}
