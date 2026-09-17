import Foundation
import Observation

/// A paginated list of tracks backed by a `linked_partitioning` api-v2 collection.
/// The first page is produced by `firstPage`; subsequent pages follow `next_href`.
/// Each loaded page is handed to `persist` so it can be cached for offline browse/search.
@MainActor
@Observable
final class TrackFeed {
    var tracks: [SCTrack] { pages.items }
    var isLoading: Bool { pages.isLoading }
    var error: String? { pages.error }
    var nextPageError: String? { pages.nextPageError }
    var pagesLoaded: Int { pages.pagesLoaded }

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

    private let pages: Pager<SCTrack>
    /// Rows cached from a previous run, shown until the network answers.
    private let cached: () -> [SCTrack]

    init(
        api: SoundCloudAPI,
        persist: @escaping ([SCTrack]) -> Void = { _ in },
        cached: @escaping () -> [SCTrack] = { [] },
        persistOrder: @escaping ([SCTrack]) -> Void = { _ in },
        firstPage: @escaping () async throws -> SCTrackLikesPage
    ) {
        self.cached = cached
        pages = Pager(
            first: { try await Self.page(firstPage()) },
            next: { try await Self.page(api.nextPage($0)) })
        pages.onPage = { [weak self] rows in
            guard let self else { return }
            persist(rows)
            persistOrder(tracks)
            onLoad(rows)
        }
    }

    /// The first load runs in an unstructured Task so it survives the view's `.task` being
    /// cancelled while SwiftUI settles the window on launch (which would otherwise -999 the
    /// cold client_id scrape and leave the list empty until you switch tabs).
    func loadInitialIfNeeded() {
        guard !pages.hasLoaded, !pages.isLoading else { return }
        // Cold start shows the cached list first: the network call below replaces it, but the
        // library is browsable and playable in the meantime instead of an empty screen.
        if tracks.isEmpty {
            pages.items = cached()
            onLoad(tracks)
        }
        Task { await loadMore() }
    }

    /// Drops the rows and every paging key, so the feed loads again from scratch for whoever
    /// signs in next.
    func reset() {
        pages.reset()
    }

#if DEBUG
    /// Fills the feed without a request so previews can render a populated page.
    func seedForPreview(_ tracks: [SCTrack]) {
        pages.seedForPreview(tracks)
    }
#endif

    func loadMore() async {
        await pages.loadMore()
    }

    /// Reflects a like made elsewhere: puts the track at the top of this feed (e.g. Likes).
    func prepend(_ track: SCTrack) {
        guard !tracks.contains(where: { $0.id == track.id }) else { return }
        pages.items.insert(track, at: 0)
    }

    func remove(id: Int) {
        pages.items.removeAll { $0.id == id }
    }

    private static func page(_ page: SCTrackLikesPage) -> Page<SCTrack> {
        Page(items: page.collection.map(\.track), next: page.nextHref)
    }
}
