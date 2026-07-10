import Foundation
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

    /// Fired with each freshly loaded page. The likes feed uses it to seed liked-track ids.
    var onLoad: ([SCTrack]) -> Void = { _ in }

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

    /// The first load runs in an unstructured Task so it survives the view's `.task` being
    /// cancelled while SwiftUI settles the window on launch (which would otherwise -999 the
    /// cold client_id scrape and leave the list empty until you switch tabs).
    func loadInitialIfNeeded() {
        guard !started else { return }
        started = true
        Task { await loadMore() }
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
            onLoad(newTracks)
            nextHref = page.nextHref
            reachedEnd = page.nextHref == nil
            error = nil
        } catch is CancellationError {
            started = false
        } catch let urlError as URLError where urlError.code == .cancelled {
            started = false
        } catch {
            self.error = "\(error)"
        }
    }
}
