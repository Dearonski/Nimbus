import Foundation
import os

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
    private static var log: Logger { Logger(subsystem: "io.github.dearonski.Nimbus", category: "api") }

    let value: T?
    init(from decoder: Decoder) throws {
        do {
            value = try T(from: decoder)
        } catch {
            // Silently dropped, a schema change emptied whole feeds instead of naming the field.
            let path = decoder.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            Self.log.error("dropped \(String(describing: T.self), privacy: .public) at \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            value = nil
        }
    }
}
