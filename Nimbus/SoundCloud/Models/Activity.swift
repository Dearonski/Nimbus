import Foundation

nonisolated struct SCActivity: Decodable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case follow = "affiliation"
        case trackLike = "track-like"
        case trackRepost = "track-repost"
        case playlistLike = "playlist-like"
        case playlistRepost = "playlist-repost"
        case comment
        case mention
    }

    let id: String
    let kind: Kind
    let createdAt: String
    let user: SCUser
    let track: SCTrack?
    let playlist: SCPlaylist?
    let comment: SCUserComment?

    // VERIFIED 06.11.2026 on follows only; the other kinds' keys are the web client's (the type up to its dash).
    private enum CodingKeys: String, CodingKey {
        case uuid, type, user, track, playlist, comment
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: type) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown activity \(type)")
        }
        self.kind = kind
        id = try c.decode(String.self, forKey: .uuid)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        user = try c.decode(SCUser.self, forKey: .user)
        track = try c.decodeIfPresent(SCTrack.self, forKey: .track)
        playlist = try c.decodeIfPresent(SCPlaylist.self, forKey: .playlist)
        comment = try c.decodeIfPresent(SCUserComment.self, forKey: .comment)
    }

    var date: Date? { SCTrack.parseDate(createdAt) }
    var ageLabel: String? { SCTrack.ageLabel(of: createdAt) }

    var action: String {
        switch kind {
        case .follow: "followed you"
        case .trackLike: "liked your track"
        case .trackRepost: "reposted your track"
        case .playlistLike: playlist?.isAlbum == true ? "liked your album" : "liked your playlist"
        case .playlistRepost: playlist?.isAlbum == true ? "reposted your album" : "reposted your playlist"
        case .comment: "commented on"
        case .mention: "mentioned you on"
        }
    }

    var subjectTrack: SCTrack? { track ?? comment?.track }

    var subjectTitle: String? { subjectTrack?.title ?? playlist?.title }

    var target: AnyHashable {
        if let track = subjectTrack { return track }
        if let playlist { return playlist }
        return user
    }
}
