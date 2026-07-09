import Foundation
import Observation

/// The signed-in user's library: liked tracks and play history (paginated track feeds
/// cached to GRDB for instant FTS5 search) plus playlists from `/me/library/all`.
@MainActor
@Observable
final class LibraryStore {
    let likes: TrackFeed
    let history: TrackFeed

    private(set) var searchResults: [SCTrack] = []
    private(set) var playlists: [SCPlaylist] = []
    private(set) var playlistsError: String?

    private let api: SoundCloudAPI
    private let database: AppDatabase?
    private var playlistsLoaded = false

    init(api: SoundCloudAPI) {
        self.api = api
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

    func loadPlaylistsIfNeeded() async {
        guard !playlistsLoaded else { return }
        playlistsLoaded = true
        do {
            playlists = try await api.library().collection.compactMap(\.asPlaylist)
            playlistsError = nil
        } catch {
            playlistsLoaded = false
            playlistsError = "\(error)"
        }
    }

    /// Resolves a playlist's stub track IDs into full playable tracks, caching them for search.
    func tracks(for playlist: SCPlaylist) async -> [SCTrack] {
        do {
            let tracks = try await api.tracks(ids: playlist.trackIDs)
            if let database { Task.detached { database.save(tracks) } }
            return tracks
        } catch {
            return []
        }
    }
}
