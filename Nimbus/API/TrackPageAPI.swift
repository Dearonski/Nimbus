import Foundation

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

extension SoundCloudAPI {
    private static let commentFields = """
    urn body createdAt trackTime
    replies { total }
    reactions { userReaction reactionCounts { reactionTypeValueUrn count } }
    user { urn username avatarUrl verified permalinkUrl followersCount tracksCount city country }
    """

    /// VERIFIED 09.09.2026. `options` takes `sort` (NEWEST / OLDEST / TIMESTAMP), `first` and
    /// `after`; a `limit` or `sortBy` is rejected by the schema, which is how those three were found.
    func trackComments(trackURN: String, sort: SCCommentSort = .newest,
                       first: Int = 20, after: String? = nil) async throws -> SCCommentsPage {
        struct Payload: Decodable, Sendable { let trackComments: SCCommentsPage }
        let query = """
        query NimbusTrackComments($urn: ID!, $first: Int, $after: String) {
          trackComments(trackUrn: $urn, options: {sort: \(sort.rawValue), first: $first, after: $after}) {
            comments { \(Self.commentFields) }
            pageInfo { endCursor hasNextPage }
          }
        }
        """
        let payload: Payload = try await graphQL(query, operation: "NimbusTrackComments", variables: [
            "urn": .string(trackURN),
            "first": .int(first),
            "after": after.map(SCJSON.string) ?? .null,
        ])
        return payload.trackComments
    }

    func commentReplies(trackURN: String, commentURN: String, first: Int = 20) async throws -> SCCommentsPage {
        struct Payload: Decodable, Sendable { let trackCommentReplies: SCCommentsPage }
        let query = """
        query NimbusCommentReplies($trackUrn: ID!, $commentUrn: ID!, $first: Int) {
          trackCommentReplies(trackUrn: $trackUrn, commentUrn: $commentUrn, options: {first: $first}) {
            comments { \(Self.commentFields) }
            pageInfo { endCursor hasNextPage }
          }
        }
        """
        let payload: Payload = try await graphQL(query, operation: "NimbusCommentReplies", variables: [
            "trackUrn": .string(trackURN),
            "commentUrn": .string(commentURN),
            "first": .int(first),
        ])
        return payload.trackCommentReplies
    }

    func topFans(trackURN: String) async throws -> SCTopFans {
        struct Board: Decodable, Sendable {
            struct Entry: Decodable, Sendable {
                let fan: SCUser
                let totalPlays: Int?
            }
            let fans: [SCFailable<Entry>]?
        }
        struct Payload: Decodable, Sendable {
            struct TopFans: Decodable, Sendable {
                let firstPeriodDays: Int?
                let allTime: Board?
                let firstPeriod: Board?
            }
            let topFans: TopFans?
        }
        let query = """
        query NimbusTopFans($trackUrn: ID!) {
          topFans(input: {trackUrn: $trackUrn}) {
            firstPeriodDays
            allTime { fans { fan { \(Self.fanFields) } totalPlays } }
            firstPeriod { fans { fan { \(Self.fanFields) } totalPlays } }
          }
        }
        """
        let payload: Payload = try await graphQL(query, operation: "NimbusTopFans",
                                                 variables: ["trackUrn": .string(trackURN)])
        func board(_ board: Board?) -> [SCTopFans.Fan] {
            (board?.fans ?? []).compactMap(\.value).map { .init(user: $0.fan, plays: $0.totalPlays ?? 0) }
        }
        return SCTopFans(firstPeriodDays: payload.topFans?.firstPeriodDays ?? 7,
                         allTime: board(payload.topFans?.allTime),
                         firstPeriod: board(payload.topFans?.firstPeriod))
    }

    private static let fanFields = "urn username avatarUrl verified permalinkUrl followersCount tracksCount"

    /// A freshly posted comment comes back as `UserTrackComment`, which has no `replies` — asking
    /// for it fails the whole mutation before anything is written.
    private static let postedCommentFields = """
    urn body createdAt trackTime
    reactions { userReaction reactionCounts { reactionTypeValueUrn count } }
    user { urn username avatarUrl verified permalinkUrl followersCount tracksCount city country }
    """

    /// Posts a comment at a position in the track. VERIFIED 09.09.2026 by probing the schema:
    /// `trackUrn`, `body` and `timestamp` are all required — and the position is spelled
    /// `timestamp` on the way in while it comes back as `trackTime`.
    func postComment(trackURN: String, body: String, trackTime: Int) async throws -> SCComment {
        struct Payload: Decodable, Sendable {
            struct Result: Decodable, Sendable { let comment: SCComment? }
            let createTrackComment: Result?
        }
        let query = """
        mutation NimbusCreateComment($input: CreateTrackCommentInput!) {
          createTrackComment(input: $input) { comment { \(Self.postedCommentFields) } }
        }
        """
        let payload: Payload = try await graphQL(query, operation: "NimbusCreateComment", variables: [
            "input": .object([
                "trackUrn": .string(trackURN),
                "body": .string(body),
                "timestamp": .int(trackTime),
            ]),
        ])
        guard let comment = payload.createTrackComment?.comment else {
            throw GraphQLFailure(messages: ["comment was not returned"])
        }
        return comment
    }

    /// VERIFIED 09.09.2026: the input takes just `commentUrn`.
    func reportComment(commentURN: String) async throws {
        struct Payload: Decodable, Sendable { let reportTrackComment: Bool? }
        let query = """
        mutation NimbusReportComment($input: ReportTrackCommentInput!) {
          reportTrackComment(input: $input)
        }
        """
        let _: Payload = try await graphQL(query, operation: "NimbusReportComment", variables: [
            "input": .object(["commentUrn": .string(commentURN)]),
        ])
    }

    func deleteComment(commentURN: String) async throws {
        struct Payload: Decodable, Sendable { let deleteTrackComment: Bool? }
        let query = """
        mutation NimbusDeleteComment($input: DeleteTrackCommentInput!) {
          deleteTrackComment(input: $input)
        }
        """
        let _: Payload = try await graphQL(query, operation: "NimbusDeleteComment", variables: [
            "input": .object(["commentUrn": .string(commentURN)]),
        ])
    }

    /// A comment like is a generic "interaction" here, not a like endpoint of its own. VERIFIED
    /// 09.09.2026 from a plain URLSession — the gateway takes mutations without the web page, so
    /// these do not need `WebWriteBridge` the way api-v2 writes do. Reads of the reaction lag the
    /// write by a few seconds, which is why the UI keeps its own optimistic state.
    func setCommentLike(_ liked: Bool, commentURN: String, trackURN: String) async throws {
        struct Payload: Decodable, Sendable {
            struct Typed: Decodable, Sendable { let __typename: String? }
            let upsertInteraction: Typed?
            /// `removeInteraction` answers a bare Boolean and rejects a selection set.
            let removeInteraction: Bool?
        }
        let query = liked ? """
        mutation NimbusLikeComment($commentUrn: String!, $trackUrn: String!) {
          upsertInteraction(input: {targetUrn: $commentUrn, parentUrn: $trackUrn,
            interactionTypeUrn: "sc:interactiontype:reaction",
            interactionTypeValueUrn: "sc:interactiontypevalue:like"}) { __typename }
        }
        """ : """
        mutation NimbusUnlikeComment($commentUrn: String!, $trackUrn: String!) {
          removeInteraction(input: {targetUrn: $commentUrn, parentUrn: $trackUrn,
            interactionTypeUrn: "sc:interactiontype:reaction",
            interactionTypeValueUrn: "sc:interactiontypevalue:like"})
        }
        """
        let _: Payload = try await graphQL(query,
                                           operation: liked ? "NimbusLikeComment" : "NimbusUnlikeComment",
                                           variables: [
            "commentUrn": .string(commentURN),
            "trackUrn": .string(trackURN),
        ])
    }
}
