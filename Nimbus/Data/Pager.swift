import Foundation
import Observation

struct Page<Item> {
    let items: [Item]
    let next: String?
}

protocol CursorPage {
    associatedtype Row
    var collection: [Row] { get }
    var nextHref: String? { get }
}

extension CursorPage {
    var page: Page<Row> { Page(items: collection, next: nextHref) }
}

extension SCPage: CursorPage {}
extension SCStreamPage: CursorPage {}
extension SCLikesPage: CursorPage {}
extension SCTrackSearchPage: CursorPage {}

extension SCCommentsPage {
    var page: Page<SCComment> { Page(items: comments, next: hasNextPage ? endCursor : nil) }
}

/// Cursor paging for one list: a failed page keeps its cursor, a reset strands what is in flight.
@MainActor
@Observable
final class Pager<Item: Identifiable> {
    enum Refresh {
        case applied(dropped: [Item.ID])
        case skipped
        case failed
    }

    var items: [Item] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// Success-only, so a page that dedupes away entirely still advances a paging key.
    private(set) var pagesLoaded = 0
    @ObservationIgnored var onPage: ([Item]) -> Void = { _ in }
    @ObservationIgnored private(set) var fetchedAt: ContinuousClock.Instant?

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var reachedEnd = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private let first: () async throws -> Page<Item>
    @ObservationIgnored private let next: (String) async throws -> Page<Item>

    init(first: @escaping () async throws -> Page<Item>,
         next: @escaping (String) async throws -> Page<Item>) {
        self.first = first
        self.next = next
    }

    var hasLoaded: Bool { pagesLoaded > 0 }

    /// A later page that failed. The first page failing is the list's own empty state, not a footer.
    var nextPageError: String? { hasLoaded ? error : nil }
    var firstPageError: String? { hasLoaded ? nil : error }

    func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        let generation = self.generation
        let cursor = self.cursor
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        do {
            let page: Page<Item>
            if let cursor {
                page = try await next(cursor)
            } else {
                page = try await first()
            }
            guard generation == self.generation else { return }
            if cursor == nil {
                items = page.items
                fetchedAt = .now
            } else {
                items.appendNew(page.items)
            }
            self.cursor = page.next
            reachedEnd = page.next == nil
            pagesLoaded += 1
            error = nil
            onPage(page.items)
        } catch is CancellationError {
            // Not a failure: nothing to report, and the same page is asked for next time.
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            guard generation == self.generation else { return }
            self.error = "\(error)"
        }
    }

    /// Folds a fresh first page over the head, so rows read further down and the cursor survive.
    func refresh(applyIf isValid: () -> Bool = { true }) async -> Refresh {
        guard hasLoaded, !isRefreshing else { return .skipped }
        isRefreshing = true
        let generation = self.generation
        let page: Page<Item>
        do {
            page = try await first()
        } catch {
            if generation == self.generation { isRefreshing = false }
            return .failed
        }
        guard generation == self.generation else { return .skipped }
        isRefreshing = false
        guard isValid() else { return .skipped }

        let dropped: [Item.ID]
        if let seam = page.items.last?.id, let end = items.firstIndex(where: { $0.id == seam }) {
            let fresh = Set(page.items.map(\.id))
            dropped = items[...end].map(\.id).filter { !fresh.contains($0) }
            items = page.items + items[(end + 1)...].filter { !fresh.contains($0.id) }
        } else {
            // No seam — more is new than a page holds: start over, stranding a page from the old cursor.
            self.generation += 1
            dropped = []
            items = page.items
            cursor = page.next
            reachedEnd = page.next == nil
            pagesLoaded = 1
            isLoading = false
            error = nil
        }
        fetchedAt = .now
        onPage(page.items)
        return .applied(dropped: dropped)
    }

    func reset() {
        generation += 1
        items = []
        isLoading = false
        isRefreshing = false
        error = nil
        pagesLoaded = 0
        fetchedAt = nil
        cursor = nil
        reachedEnd = false
    }
}

#if DEBUG
extension Pager {
    func seedForPreview(_ items: [Item]) {
        self.items = items
        pagesLoaded = 1
        fetchedAt = .now
        reachedEnd = true
    }
}
#endif
