import Observation

/// A paginated list of tracks backed by a `linked_partitioning` api-v2 collection.
/// The first page is produced by `firstPage`; subsequent pages follow `next_href`.
/// Each loaded page is handed to `persist` so it can be cached for offline browse/search.
@MainActor
@Observable
final class TrackFeed {
    private(set) var tracks: [SCTrack] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private let api: SoundCloudAPI
    private let firstPage: () async throws -> SCTrackLikesPage
    private let persist: ([SCTrack]) -> Void
    private var nextHref: String?
    private var reachedEnd = false
    private var started = false

    init(
        api: SoundCloudAPI,
        persist: @escaping ([SCTrack]) -> Void = { _ in },
        firstPage: @escaping () async throws -> SCTrackLikesPage
    ) {
        self.api = api
        self.persist = persist
        self.firstPage = firstPage
    }

    func loadInitialIfNeeded() async {
        guard !started else { return }
        started = true
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page: SCTrackLikesPage
            if let nextHref {
                page = try await api.nextPage(nextHref)
            } else {
                page = try await firstPage()
            }
            let newTracks = page.collection.map(\.track)
            tracks.append(contentsOf: newTracks)
            persist(newTracks)
            nextHref = page.nextHref
            reachedEnd = page.nextHref == nil
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}
