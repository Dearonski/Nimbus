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
    /// Rows cached from a previous run, shown until the network answers.
    private let cached: () -> [SCTrack]
    /// Called with the full list once a first page lands, so the cache mirrors the live order.
    private let persistOrder: ([SCTrack]) -> Void
    private var nextHref: String?
    private var reachedEnd = false
    private var started = false

    init(
        api: SoundCloudAPI,
        persist: @escaping ([SCTrack]) -> Void = { _ in },
        cached: @escaping () -> [SCTrack] = { [] },
        persistOrder: @escaping ([SCTrack]) -> Void = { _ in },
        firstPage: @escaping () async throws -> SCTrackLikesPage
    ) {
        self.api = api
        self.persist = persist
        self.cached = cached
        self.persistOrder = persistOrder
        self.firstPage = firstPage
    }

    /// The first load runs in an unstructured Task so it survives the view's `.task` being
    /// cancelled while SwiftUI settles the window on launch (which would otherwise -999 the
    /// cold client_id scrape and leave the list empty until you switch tabs).
    func loadInitialIfNeeded() {
        guard !started else { return }
        started = true
        // Cold start shows the cached list first: the network call below replaces it, but the
        // library is browsable and playable in the meantime instead of an empty screen.
        if tracks.isEmpty {
            tracks = cached()
        }
        Task { await loadMore() }
    }

#if DEBUG
    /// Fills the feed without a request so previews can render a populated page.
    func seedForPreview(_ tracks: [SCTrack]) {
        self.tracks = tracks
        started = true
        reachedEnd = true
    }
#endif

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
            let fresh = page.collection.map(\.track)
            // A first page replaces the cache rather than merging into it, otherwise tracks unliked
            // on another device would linger forever.
            if nextHref == nil {
                tracks = fresh
            } else {
                let known = Set(tracks.map(\.id))
                tracks.append(contentsOf: fresh.filter { !known.contains($0.id) })
            }
            let newTracks = fresh
            persist(newTracks)
            persistOrder(tracks)
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

    /// Reflects a like made elsewhere: puts the track at the top of this feed (e.g. Likes).
    func prepend(_ track: SCTrack) {
        guard !tracks.contains(where: { $0.id == track.id }) else { return }
        tracks.insert(track, at: 0)
    }

    func remove(id: Int) {
        tracks.removeAll { $0.id == id }
    }
}
