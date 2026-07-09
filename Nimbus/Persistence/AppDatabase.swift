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
        return migrator
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
