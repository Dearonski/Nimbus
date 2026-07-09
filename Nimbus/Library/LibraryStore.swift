import Foundation
import Observation

/// The signed-in user's library. v1 covers liked tracks and play history; both are
/// paginated track feeds cached to GRDB for instant local FTS5 search.
@MainActor
@Observable
final class LibraryStore {
    let likes: TrackFeed
    let history: TrackFeed

    private(set) var searchResults: [SCTrack] = []

    private let database: AppDatabase?

    init(api: SoundCloudAPI) {
        let database = try? AppDatabase()
        self.database = database

        let persist: ([SCTrack]) -> Void = { tracks in
            guard let database else { return }
            Task.detached { database.save(tracks) }
        }

        likes = TrackFeed(api: api, persist: persist) {
            try await api.likedTracks(userID: try await api.me().id)
        }
        history = TrackFeed(api: api, persist: persist) {
            try await api.history()
        }
    }

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let database, !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchResults = database.search(trimmed)
    }
}
