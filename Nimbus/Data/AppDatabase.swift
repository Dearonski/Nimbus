import Foundation
import GRDB

/// GRDB store for track metadata: fast local browse and instant FTS5 search.
/// The full track is kept as a JSON payload so a cached row can be played back directly.
nonisolated struct TrackRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "track"

    var id: Int64
    var title: String
    var username: String
    var artworkURL: String?
    var duration: Int
    var permalinkURL: String
    var payload: Data

    init(track: SCTrack) throws {
        id = Int64(track.id)
        title = track.title
        username = track.user.username
        artworkURL = track.artworkURL
        duration = track.duration
        permalinkURL = track.permalinkURL
        payload = try JSONEncoder().encode(track)
    }

    func decoded() throws -> SCTrack {
        try JSONDecoder().decode(SCTrack.self, from: payload)
    }
}

/// Membership of a collection, kept apart from the tracks themselves: `track` is a cache keyed by
/// id, while this preserves what belongs to Likes or History and in which order — enough for a cold
/// start to show the library before the network answers.
nonisolated struct CollectionItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "collectionItem"

    var collection: String
    var position: Int
    var trackID: Int64
}

nonisolated final class AppDatabase: Sendable {
    private let dbQueue: DatabaseQueue

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        dbQueue = try DatabaseQueue(path: support.appendingPathComponent("nimbus.sqlite").path)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "track") { t in
                t.primaryKey("id", .integer)
                t.column("title", .text).notNull()
                t.column("username", .text).notNull()
                t.column("artworkURL", .text)
                t.column("duration", .integer).notNull()
                t.column("permalinkURL", .text).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(virtualTable: "track_ft", using: FTS5()) { t in
                t.synchronize(withTable: "track")
                t.column("title")
                t.column("username")
            }
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: CollectionItemRecord.databaseTableName) { t in
                t.column("collection", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("trackID", .integer).notNull()
                t.primaryKey(["collection", "trackID"])
            }
            try db.create(index: "collectionItem_order",
                          on: CollectionItemRecord.databaseTableName,
                          columns: ["collection", "position"])
        }
        return migrator
    }

    /// Replaces a collection's membership wholesale — writing only the new rows would leave stale
    /// ones behind when something is unliked elsewhere.
    func saveCollection(_ name: String, ids: [Int]) {
        try? dbQueue.write { db in
            try CollectionItemRecord.filter(Column("collection") == name).deleteAll(db)
            for (index, id) in ids.enumerated() {
                try CollectionItemRecord(collection: name, position: index, trackID: Int64(id))
                    .save(db)
            }
        }
    }

    func collectionIDs(_ name: String) -> [Int] {
        let records = (try? dbQueue.read { db in
            try CollectionItemRecord
                .filter(Column("collection") == name)
                .order(Column("position"))
                .fetchAll(db)
        }) ?? []
        return records.map { Int($0.trackID) }
    }

    /// Cached tracks for the given ids, in the order asked for. Ids without a cached row are
    /// dropped rather than faulted in — the caller refreshes from the network anyway.
    func tracks(ids: [Int]) -> [SCTrack] {
        guard !ids.isEmpty else { return [] }
        let records = (try? dbQueue.read { db in
            try TrackRecord.filter(keys: ids.map(Int64.init)).fetchAll(db)
        }) ?? []
        let byID = Dictionary(
            records.compactMap { record -> (Int, SCTrack)? in
                guard let track = try? record.decoded() else { return nil }
                return (track.id, track)
            },
            uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Wipes everything cached for the signed-in account.
    func clear() {
        try? dbQueue.write { db in
            try CollectionItemRecord.deleteAll(db)
            try TrackRecord.deleteAll(db)
        }
    }

    func save(_ tracks: [SCTrack]) {
        try? dbQueue.write { db in
            for track in tracks {
                try? TrackRecord(track: track).save(db)
            }
        }
    }

    func search(_ query: String, limit: Int = 100) -> [SCTrack] {
        (try? dbQueue.read { db -> [SCTrack] in
            guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }
            let records = try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM track
                JOIN track_ft ON track_ft.rowid = track.id
                WHERE track_ft MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [pattern, limit])
            return records.compactMap { try? $0.decoded() }
        }) ?? []
    }
}
