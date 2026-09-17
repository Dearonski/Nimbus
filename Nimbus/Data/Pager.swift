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
    var items: [Item] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// Success-only, so a page that dedupes away entirely still advances a paging key.
    private(set) var pagesLoaded = 0
    @ObservationIgnored var onPage: ([Item]) -> Void = { _ in }

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var reachedEnd = false
    @ObservationIgnored private var generation = 0
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

    func reset() {
        generation += 1
        items = []
        isLoading = false
        error = nil
        pagesLoaded = 0
        cursor = nil
        reachedEnd = false
    }
}

#if DEBUG
extension Pager {
    func seedForPreview(_ items: [Item]) {
        self.items = items
        pagesLoaded = 1
        reachedEnd = true
    }
}
#endif
