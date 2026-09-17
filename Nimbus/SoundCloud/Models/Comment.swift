import Foundation

/// A comment as `/users/{id}/comments` returns it. The whole track rides along, so the profile
/// block can name what was commented on and open it without a second request. VERIFIED 13.09.2026.
nonisolated struct SCUserComment: Decodable, Sendable, Identifiable {
    let id: Int
    let body: String
    let createdAt: String?
    /// Where in the track the comment sits, in milliseconds.
    let timestamp: Int?
    let track: SCTrack?

    enum CodingKeys: String, CodingKey {
        case id, body, timestamp, track
        case createdAt = "created_at"
    }

    var ageLabel: String? {
        guard let createdAt, let date = SCTrack.parseDate(createdAt) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// A comment as the GraphQL gateway hands it over: a urn instead of an id, the position in the
/// track in milliseconds, its reactions and how many replies hang off it.
nonisolated struct SCComment: Decodable, Sendable, Identifiable, Hashable {
    let urn: String
    let body: String
    let createdAt: String?
    let trackTime: Int
    let user: SCUser
    let likes: Int
    let likedByMe: Bool
    let replyCount: Int

    var id: String { urn }

    var ageLabel: String? {
        guard let createdAt, let date = SCTrack.parseDate(createdAt) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private enum CodingKeys: String, CodingKey {
        case urn, body, createdAt, trackTime, user, reactions, replies
    }

    private struct Reactions: Decodable {
        struct Count: Decodable {
            let reactionTypeValueUrn: String?
            let count: Int?
        }
        let userReaction: String?
        let reactionCounts: [Count]?
    }

    private struct Replies: Decodable {
        let total: Int?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urn = try c.decode(String.self, forKey: .urn)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        trackTime = try c.decodeIfPresent(Int.self, forKey: .trackTime) ?? 0
        user = try c.decode(SCUser.self, forKey: .user)
        let reactions = try c.decodeIfPresent(Reactions.self, forKey: .reactions)
        likes = reactions?.reactionCounts?.reduce(0) { $0 + ($1.count ?? 0) } ?? 0
        likedByMe = reactions?.userReaction != nil
        replyCount = try c.decodeIfPresent(Replies.self, forKey: .replies)?.total ?? 0
    }
}

nonisolated struct SCCommentsPage: Decodable, Sendable {
    let comments: [SCComment]
    let endCursor: String?
    let hasNextPage: Bool

    private enum CodingKeys: String, CodingKey { case comments, pageInfo }
    private struct PageInfo: Decodable {
        let endCursor: String?
        let hasNextPage: Bool?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        comments = try c.decode([SCFailable<SCComment>].self, forKey: .comments).compactMap(\.value)
        let info = try c.decodeIfPresent(PageInfo.self, forKey: .pageInfo)
        endCursor = info?.endCursor
        hasNextPage = info?.hasNextPage ?? false
    }
}

/// Who has played this track the most — the leaderboard the web client shows as "Fans". There is
/// no api-v2 equivalent: `/tracks/{id}/fans`, `/top_listeners` and `/listeners` all answer 404.
nonisolated struct SCTopFans: Sendable {
    struct Fan: Sendable, Identifiable {
        let user: SCUser
        let plays: Int
        var id: Int { user.id }
    }

    /// How long the "first days" board covers — the gateway decides, currently 7.
    let firstPeriodDays: Int
    let allTime: [Fan]
    let firstPeriod: [Fan]

    var isEmpty: Bool { allTime.isEmpty && firstPeriod.isEmpty }
}

nonisolated struct SCCommentSort: Sendable, Hashable {
    let rawValue: String
    static let newest = SCCommentSort(rawValue: "NEWEST")
    static let oldest = SCCommentSort(rawValue: "OLDEST")
    /// Ordered by position in the track rather than by time posted.
    static let timestamp = SCCommentSort(rawValue: "TIMESTAMP")
}
