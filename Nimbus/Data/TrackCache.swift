import Foundation

/// Only Likes and History go to disk: a cold start shows them before the network answers, and search finds them offline.
@MainActor
final class TrackCache {
    let database: AppDatabase?
    private var orderSaves: [String: Task<Void, Never>] = [:]

    init() {
        database = try? AppDatabase()
        // Chart, queue and set tracks were once cached too, though nothing ever read them back.
        if let database { Task.detached(priority: .background) { database.pruneOrphans() } }
    }

    func save(_ tracks: [SCTrack]) {
        guard let database, !tracks.isEmpty else { return }
        Task.detached { database.save(tracks) }
    }

    /// Read off the main thread: a long Likes list decodes its whole JSON payload here.
    func rows(of collection: String) async -> [SCTrack] {
        guard let database else { return [] }
        return await Task.detached { database.tracks(ids: database.collectionIDs(collection)) }.value
    }

    /// Settles before writing: each page rewrote the whole collection, quadratic over a long Likes list.
    func saveOrder(_ collection: String, ids: [Int]) {
        guard let database else { return }
        orderSaves[collection]?.cancel()
        orderSaves[collection] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await Task.detached { database.saveCollection(collection, ids: ids) }.value
        }
    }

    func clear() {
        for save in orderSaves.values { save.cancel() }
        orderSaves = [:]
        database?.clear()
    }
}
