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
    var context: PlayContext?

    /// `scoped` is the only route to the loaded page, and it has to be asked for by name: a call
    /// site that says nothing gets the whole collection.
    func playQueue(_ rows: [SCTrack], scoped: Bool = false) -> PlayQueue {
        guard let source, !scoped else { return .exactly(rows, context: context) }
        return .collection(source, loaded: rows)
    }

    /// Fired with each freshly loaded page. The likes feed uses it to seed liked-track ids.
    var onLoad: ([SCTrack]) -> Void = { _ in }
    // Asked before a refresh starts and again before it lands: its answer would undo a write in flight.
    @ObservationIgnored var isSettled: () -> Bool = { true }
    @ObservationIgnored var onRefresh: (_ dropped: [Int]) -> Void = { _ in }

    var wasAsked: Bool { pages.hasLoaded || pages.error != nil }

    private let name: String
    private let ttl: Duration
    private let pages: Pager<SCTrack>
    /// Rows cached from a previous run, shown until the network answers.
    private let cached: () -> [SCTrack]
    @ObservationIgnored private var edits = 0

    init(
        name: String,
        ttl: Duration,
        api: SoundCloudAPI,
        persist: @escaping ([SCTrack]) -> Void = { _ in },
        cached: @escaping () -> [SCTrack] = { [] },
        persistOrder: @escaping ([SCTrack]) -> Void = { _ in },
        firstPage: @escaping () async throws -> SCTrackLikesPage
    ) {
        self.name = name
        self.ttl = ttl
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

    /// Unstructured, so a view's `.task` cancelled while the window settles on launch can't -999 it.
    func loadIfNeeded(force: Bool = false) {
        Task { await update(force: force) }
    }

    /// The first page if there is none, else a refresh past `ttl`. False only if the server didn't answer.
    func update(force: Bool = false) async -> Bool {
        if pages.hasLoaded {
            guard Freshness.isDue(name, fetchedAt: pages.fetchedAt, ttl: ttl, force: force) else { return true }
            return await refresh()
        }
        guard !pages.isLoading, Freshness.isDue(name, fetchedAt: nil, ttl: ttl, force: force) else { return true }
        // Cold start shows the cached list until the network answers, instead of an empty screen.
        if tracks.isEmpty {
            pages.items = cached()
            onLoad(tracks)
        }
        await pages.loadMore()
        return pages.hasLoaded
    }

    private func refresh() async -> Bool {
        guard isSettled() else { return true }
        let edits = self.edits
        switch await pages.refresh(applyIf: { edits == self.edits && isSettled() }) {
        case .applied(let dropped):
            onRefresh(dropped)
            return true
        case .skipped:
            return true
        case .failed:
            return false
        }
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
        edits += 1
        pages.items.insert(track, at: 0)
    }

    func remove(id: Int) {
        edits += 1
        pages.items.removeAll { $0.id == id }
    }

    func moveToTop(_ track: SCTrack) {
        edits += 1
        pages.items.removeAll { $0.id == track.id }
        pages.items.insert(track, at: 0)
    }

    private static func page(_ page: SCTrackLikesPage) -> Page<SCTrack> {
        Page(items: page.collection.map(\.track), next: page.nextHref)
    }
}
