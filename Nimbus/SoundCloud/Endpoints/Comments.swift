import Foundation

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
            comments { \(Self.flatCommentFields) }
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

    /// Everything a comment carries except `replies`. Neither a reply (`TrackCommentReply`) nor a
    /// freshly posted comment (`UserTrackComment`) has that field, and asking for it fails the whole
    /// query before anything is read or written.
    private static let flatCommentFields = """
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
          createTrackComment(input: $input) { comment { \(Self.flatCommentFields) } }
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
