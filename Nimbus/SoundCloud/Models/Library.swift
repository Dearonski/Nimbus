import Foundation

/// One page of a `linked_partitioning` collection of liked tracks.
nonisolated struct SCTrackLikesPage: Codable, Sendable {
    struct Item: Codable, Sendable {
        let track: SCTrack
    }

    let collection: [Item]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }
}

/// One entry of `/users/{id}/likes`: a track or a set, the way the site's own likes column mixes
/// them. `SCTrackLikesPage` cannot stand in — it insists on a `track` and throws on a liked set.
nonisolated struct SCLikeItem: Decodable, Sendable, Identifiable {
    enum Content: Sendable {
        case track(SCTrack)
        case playlist(SCPlaylist)
    }

    let content: Content
    let createdAt: String?

    var id: String {
        switch content {
        case .track(let t): "t\(t.id)"
        case .playlist(let p): "p\(p.id)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case track, playlist
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        if let track = try c.decodeIfPresent(SCTrack.self, forKey: .track) {
            content = .track(track)
        } else if let playlist = try c.decodeIfPresent(SCPlaylist.self, forKey: .playlist) {
            content = .playlist(playlist)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .track, in: c,
                                                   debugDescription: "like has neither track nor playlist")
        }
    }
}

nonisolated struct SCLikesPage: Decodable, Sendable {
    let collection: [SCLikeItem]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextHref = try c.decodeIfPresent(String.self, forKey: .nextHref)
        collection = try c.decode([SCFailable<SCLikeItem>].self, forKey: .collection).compactMap(\.value)
    }
}

/// `/me/library/all` aggregates likes/reposts/playlists; we keep the playlist-shaped items.
nonisolated struct SCLibraryPage: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let playlist: SCPlaylist?
        let systemPlaylist: SCPlaylist?

        enum CodingKeys: String, CodingKey {
            case playlist
            case systemPlaylist = "system_playlist"
        }

        var asPlaylist: SCPlaylist? { playlist ?? systemPlaylist }
    }

    let collection: [Item]
}
