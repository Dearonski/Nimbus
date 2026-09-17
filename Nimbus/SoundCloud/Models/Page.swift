import Foundation

/// A page of bare ids: what the `/ids` endpoints answer with, walked in full by `allIDs`.
nonisolated struct SCIDPage: Decodable, Sendable {
    let collection: [Int]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }
}

/// A flat `linked_partitioning` page (e.g. a user's tracks, search/tracks).
nonisolated struct SCPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let collection: [Item]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }
}

/// Wraps a decode so one malformed element doesn't fail the whole collection.
nonisolated struct SCFailable<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
