import Foundation
import Observation

// One paged list per kind, as the site's own tabs fetch them: a single mixed page held 30 of everything.
@MainActor
@Observable
final class SearchModel {
    private(set) var tracks: Pager<SCTrack>?
    private(set) var users: Pager<SCUser>?
    private(set) var albums: Pager<SCPlaylist>?
    private(set) var playlists: Pager<SCPlaylist>?
    private(set) var localResults: [SCTrack] = []
    private(set) var isSearching = false

    private let api: SoundCloudAPI
    private let database: AppDatabase?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var query = ""

    init(api: SoundCloudAPI, database: AppDatabase?) {
        self.api = api
        self.database = database
    }

    var isEmpty: Bool {
        [tracks?.items.isEmpty, users?.items.isEmpty, albums?.items.isEmpty, playlists?.items.isEmpty]
            .allSatisfy { $0 ?? true }
    }

    // Only when every kind failed: one empty tab is a result, not an error.
    var error: String? {
        let errors = [tracks?.firstPageError, users?.firstPageError, albums?.firstPageError, playlists?.firstPageError]
        return errors.allSatisfy { $0 != nil } ? errors.first ?? nil : nil
    }

    func run(_ text: String) {
        task?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed
        clearRemote()
        guard !trimmed.isEmpty else {
            localResults = []
            isSearching = false
            return
        }
        isSearching = true
        if let database {
            Task.detached {
                let local = database.search(trimmed, limit: 50)
                await MainActor.run {
                    guard self.query == trimmed else { return }
                    self.localResults = local
                }
            }
        }
        let api = api
        task = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let tracks = Self.pager(api, .tracks, trimmed, as: SCTrack.self)
            let users = Self.pager(api, .users, trimmed, as: SCUser.self)
            let albums = Self.pager(api, .albums, trimmed, as: SCPlaylist.self)
            let playlists = Self.pager(api, .playlists, trimmed, as: SCPlaylist.self)
            self.tracks = tracks
            self.users = users
            self.albums = albums
            self.playlists = playlists
            async let first: Void = tracks.loadMore()
            async let second: Void = users.loadMore()
            async let third: Void = albums.loadMore()
            async let fourth: Void = playlists.loadMore()
            _ = await (first, second, third, fourth)
            guard !Task.isCancelled else { return }
            isSearching = false
        }
    }

    private static func pager<Item: Identifiable>(_ api: SoundCloudAPI, _ kind: SCSearchKind, _ query: String,
                                                  as _: Item.Type) -> Pager<Item> where Item: Decodable & Sendable {
        Pager(first: { try await (api.search(kind, query) as SCSearchResults<Item>).page },
              next: { try await api.page(after: $0, as: SCSearchResults<Item>.self).page })
    }

    func retry() {
        run(query)
    }

    func reset() {
        task?.cancel()
        task = nil
        query = ""
        isSearching = false
        clearRemote()
        localResults = []
    }

    private func clearRemote() {
        tracks = nil
        users = nil
        albums = nil
        playlists = nil
    }
}
