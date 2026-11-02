import Foundation

/// A shelf item: SoundCloud itself signals whether a shelf holds sets or people.
nonisolated enum SCSelectionItem: Decodable, Sendable, Identifiable {
    case playlist(SCPlaylist)
    case user(SCUser)

    var id: String {
        switch self {
        case .playlist(let p): "p\(p.id)"
        case .user(let u): "u\(u.id)"
        }
    }

    private enum KindKey: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: KindKey.self).decode(String.self, forKey: .kind)
        switch kind {
        case "playlist", "system-playlist": self = .playlist(try SCPlaylist(from: decoder))
        case "user": self = .user(try SCUser(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown selection kind \(kind)"))
        }
    }
}

/// One `/mixed-selections` shelf — this endpoint *is* soundcloud.com/discover: "More of what you
/// like", "Recently played", "Trending by genre", "Artists to watch out for", "Curated by SoundCloud".
nonisolated struct SCMixedSelection: Decodable, Sendable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let items: [SCSelectionItem]

    var playlists: [SCPlaylist] {
        items.compactMap { if case .playlist(let p) = $0 { p } else { nil } }
    }
    var users: [SCUser] {
        items.compactMap { if case .user(let u) = $0 { u } else { nil } }
    }
    var isPeopleShelf: Bool { !users.isEmpty && playlists.isEmpty }

    private enum CodingKeys: String, CodingKey { case urn, title, description, items }
    private struct Items: Decodable { let collection: [SCFailable<SCSelectionItem>] }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "For you"
        id = try c.decodeIfPresent(String.self, forKey: .urn) ?? title
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        items = (try c.decodeIfPresent(Items.self, forKey: .items))?.collection.compactMap(\.value) ?? []
    }
}

nonisolated struct SCMixedSelectionsPage: Decodable, Sendable {
    let collection: [SCMixedSelection]

    private enum CodingKeys: String, CodingKey { case collection }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode([SCFailable<SCMixedSelection>].self, forKey: .collection).compactMap(\.value)
    }
}

/// One entry of the personalized `/stream` feed: a track or playlist that someone you follow
/// posted or reposted. Reposts carry the reposter so the UI can show "Reposted by …".
nonisolated struct SCStreamItem: Decodable, Sendable, Identifiable {
    enum Content: Sendable {
        case track(SCTrack)
        case playlist(SCPlaylist)
    }

    let content: Content
    let reposter: SCUser?
    let createdAt: String?

    var id: String {
        let base: String = switch content {
        case .track(let t): "t\(t.id)"
        case .playlist(let p): "p\(p.id)"
        }
        return "\(createdAt ?? "")-\(reposter?.id ?? 0)-\(base)"
    }

    private enum CodingKeys: String, CodingKey {
        case type, kind, user, track, playlist
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        // `/users/{id}/spotlight` returns the bare pinned track or playlist, not a stream wrapper.
        guard let type = try c.decodeIfPresent(String.self, forKey: .type) else {
            reposter = nil
            switch try c.decode(String.self, forKey: .kind) {
            case "track": content = .track(try SCTrack(from: decoder))
            case "playlist": content = .playlist(try SCPlaylist(from: decoder))
            case let kind:
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unknown spotlight kind \(kind)"))
            }
            return
        }
        reposter = type.contains("repost") ? try c.decodeIfPresent(SCUser.self, forKey: .user) : nil
        if type.hasPrefix("track") {
            content = .track(try c.decode(SCTrack.self, forKey: .track))
        } else if type.hasPrefix("playlist") {
            content = .playlist(try c.decode(SCPlaylist.self, forKey: .playlist))
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown stream type \(type)"))
        }
    }
}

nonisolated struct SCStreamPage: Decodable, Sendable {
    let collection: [SCStreamItem]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextHref = try c.decodeIfPresent(String.self, forKey: .nextHref)
        collection = try c.decode([SCFailable<SCStreamItem>].self, forKey: .collection).compactMap(\.value)
    }
}
