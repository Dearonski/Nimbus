import Foundation

/// SoundCloud's newer web client talks to a GraphQL gateway instead of api-v2, and that gateway
/// accepts the same harvested `oauth_token`. Everything the track page needs beyond api-v2 —
/// comments with replies and reactions, the fan leaderboard — lives only here.
///
/// Verified 09.09.2026 from a plain URLSession: 200 with data, 401 without the header. The schema
/// is private and introspection is off, so the queries below are the web client's own, copied out
/// of its bundle, and every input shape was probed against the live gateway.
extension SoundCloudAPI {
    static let graphQLEndpoint = URL(string: "https://graph.soundcloud.com/graphql")!

    struct GraphQLFailure: Error {
        let messages: [String]
    }

    func graphQL<T: Decodable & Sendable>(
        _ query: String,
        operation: String,
        variables: [String: SCJSON] = [:]
    ) async throws -> T {
        guard let token = Keychain.get(Self.tokenAccount) else { throw SCError.notAuthenticated }
        let body = try JSONEncoder().encode(
            GraphQLBody(operationName: operation, query: query, variables: variables))

        let (data, code) = try await sendAuthorized(token: token) { token in
            var request = URLRequest(url: Self.graphQLEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard (200..<300).contains(code) else { throw SCError.http(code) }

        let envelope = try JSONDecoder().decode(GraphQLEnvelope<T>.self, from: data)
        if let payload = envelope.data { return payload }
        throw GraphQLFailure(messages: envelope.errors?.map(\.message) ?? ["empty response"])
    }
}

nonisolated private struct GraphQLBody: Encodable {
    let operationName: String
    let query: String
    let variables: [String: SCJSON]
}

nonisolated private struct GraphQLEnvelope<Payload: Decodable>: Decodable {
    struct Message: Decodable { let message: String }
    let data: Payload?
    let errors: [Message]?
}

/// A JSON value for GraphQL variables. The gateway takes ids as strings, times as numbers and
/// enums unquoted inside the query text, so only these cases are ever needed.
nonisolated enum SCJSON: Encodable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case object([String: SCJSON])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .object(let value): try container.encode(value)
        }
    }
}

extension SCTrack {
    var urn: String { "soundcloud:tracks:\(id)" }
}
