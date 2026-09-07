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
    /// Monotonic and success-only, so a page that dedupes away entirely still advances a paging key.
    private(set) var pagesLoaded = 0

    /// Set where the feed is built, so every screen rendering it gets the same answer instead of
    /// deciding for itself. A feed with no ids endpoint leaves it nil and can only play its rows.
    var source: PlayQueue.Source?

    /// `scoped` is the only route to the loaded page, and it has to be asked for by name: a call
    /// site that says nothing gets the whole collection.
    func playQueue(_ rows: [SCTrack], scoped: Bool = false) -> PlayQueue {
        guard let source, !scoped else { return .exactly(rows) }
        return .collection(source, loaded: rows)
    }

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
    /// Bumped by `reset()`: a page already in flight was asked for by the account that just signed
    /// out, so it must not land in the feed the next sign-in is looking at.
    private var epoch = 0

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
            onLoad(tracks)
        }
        Task { await loadMore() }
    }

    /// Drops the rows and every paging key, so the feed loads again from scratch for whoever
    /// signs in next.
    func reset() {
        epoch += 1
        tracks = []
        error = nil
        pagesLoaded = 0
        nextHref = nil
        reachedEnd = false
        started = false
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
        let epoch = self.epoch
        isLoading = true
        defer { if epoch == self.epoch { isLoading = false } }
        do {
            let page: SCTrackLikesPage
            if let nextHref {
                page = try await api.nextPage(nextHref)
            } else {
                page = try await firstPage()
            }
            guard epoch == self.epoch else { return }
            let fresh = page.collection.map(\.track)
            // A first page replaces the cache rather than merging into it, otherwise tracks unliked
            // on another device would linger forever.
            if nextHref == nil {
                tracks = fresh
            } else {
                tracks.appendNew(fresh)
            }
            let newTracks = fresh
            persist(newTracks)
            persistOrder(tracks)
            onLoad(newTracks)
            nextHref = page.nextHref
            reachedEnd = page.nextHref == nil
            pagesLoaded += 1
            error = nil
        } catch is CancellationError {
            if epoch == self.epoch { started = false }
        } catch let urlError as URLError where urlError.code == .cancelled {
            if epoch == self.epoch { started = false }
        } catch {
            if epoch == self.epoch { self.error = "\(error)" }
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
