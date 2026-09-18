import Foundation
import Testing
@testable import Nimbus

@MainActor
@Suite struct PagerRefreshTests {
    struct Row: Identifiable {
        let id: Int
    }

    @MainActor
    final class Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        var isHolding: Bool { waiting != nil }

        func hold() async {
            await withCheckedContinuation { waiting = $0 }
        }

        func release() {
            waiting?.resume()
            waiting = nil
        }
    }

    // Keyset paging, like api-v2's `next_href`: a cursor names the last row a page ended on.
    @MainActor
    final class Server {
        var rows: [Int]
        let pageSize: Int
        var failNext = false
        var holdNext: Gate?

        init(_ rows: [Int], pageSize: Int = 4) {
            self.rows = rows
            self.pageSize = pageSize
        }

        func page(after cursor: String?) async throws -> Page<Row> {
            if let gate = holdNext {
                holdNext = nil
                await gate.hold()
            }
            if failNext {
                failNext = false
                throw URLError(.notConnectedToInternet)
            }
            var start = 0
            if let cursor, let id = Int(cursor), let index = rows.firstIndex(of: id) { start = index + 1 }
            let slice = Array(rows[start...].prefix(pageSize))
            let hasMore = start + slice.count < rows.count
            return Page(items: slice.map(Row.init), next: hasMore ? slice.last.map(String.init) : nil)
        }
    }

    private func pager(_ server: Server) -> Pager<Row> {
        Pager(first: { try await server.page(after: nil) },
              next: { try await server.page(after: $0) })
    }

    private func ids(_ pager: Pager<Row>) -> [Int] { pager.items.map(\.id) }

    private func dropped(_ outcome: Pager<Row>.Refresh) -> [Int]? {
        if case .applied(let dropped) = outcome { dropped } else { nil }
    }

    private func isSkipped(_ outcome: Pager<Row>.Refresh) -> Bool {
        if case .skipped = outcome { true } else { false }
    }

    @Test func newRowsLandOnTopAndPagingCarriesOn() async {
        let server = Server(Array(1...10))
        let pager = pager(server)
        await pager.loadMore()
        await pager.loadMore()
        server.rows = [11, 12] + Array(1...10)

        let outcome = await pager.refresh()

        #expect(dropped(outcome) == [])
        #expect(ids(pager) == [11, 12] + Array(1...8))
        await pager.loadMore()
        #expect(ids(pager) == [11, 12] + Array(1...10))
    }

    @Test func rowsGoneFromTheHeadAreDropped() async {
        let server = Server(Array(1...8))
        let pager = pager(server)
        await pager.loadMore()
        await pager.loadMore()
        server.rows.removeAll { $0 == 2 }

        let outcome = await pager.refresh()

        #expect(dropped(outcome) == [2])
        #expect(ids(pager) == [1, 3, 4, 5, 6, 7, 8])
    }

    @Test func aReplayedRowMovesUpWithoutADuplicate() async {
        let server = Server(Array(1...8))
        let pager = pager(server)
        await pager.loadMore()
        await pager.loadMore()
        server.rows = [7, 1, 2, 3, 4, 5, 6, 8]

        let outcome = await pager.refresh()

        #expect(dropped(outcome) == [])
        #expect(ids(pager) == [7, 1, 2, 3, 4, 5, 6, 8])
    }

    @Test func moreNewThanAPageStartsOver() async {
        let server = Server(Array(1...8))
        let pager = pager(server)
        await pager.loadMore()
        await pager.loadMore()
        server.rows = Array(101...105) + Array(1...8)

        let outcome = await pager.refresh()

        #expect(dropped(outcome) == [])
        #expect(ids(pager) == Array(101...104))
        #expect(pager.pagesLoaded == 1)
        await pager.loadMore()
        #expect(ids(pager) == Array(101...105) + [1, 2, 3])
    }

    @Test func anEmptyHeadEmptiesTheList() async {
        let server = Server(Array(1...4))
        let pager = pager(server)
        await pager.loadMore()
        server.rows = []

        _ = await pager.refresh()

        #expect(pager.items.isEmpty)
        await pager.loadMore()
        #expect(pager.items.isEmpty)
    }

    @Test func aFailedRefreshKeepsTheRowsAndShowsNoError() async {
        let server = Server(Array(1...4))
        let pager = pager(server)
        await pager.loadMore()
        let loadedAt = pager.fetchedAt
        server.rows = [9] + Array(1...4)
        server.failNext = true

        let outcome = await pager.refresh()

        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        #expect(ids(pager) == [1, 2, 3, 4])
        #expect(pager.error == nil)
        #expect(pager.nextPageError == nil)
        #expect(pager.fetchedAt == loadedAt)
    }

    @Test func aVetoedAnswerChangesNothing() async {
        let server = Server(Array(1...4))
        let pager = pager(server)
        await pager.loadMore()
        server.rows = [9] + Array(1...4)

        let outcome = await pager.refresh(applyIf: { false })

        #expect(isSkipped(outcome))
        #expect(ids(pager) == [1, 2, 3, 4])
    }

    @Test func aResetWhileRefreshingDiscardsTheAnswer() async {
        let server = Server(Array(1...4))
        let pager = pager(server)
        await pager.loadMore()
        let gate = Gate()
        server.holdNext = gate
        server.rows = [9] + Array(1...4)

        let refreshing = Task { await pager.refresh() }
        while !gate.isHolding { await Task.yield() }
        pager.reset()
        gate.release()
        let outcome = await refreshing.value

        #expect(isSkipped(outcome))
        #expect(pager.items.isEmpty)
        #expect(pager.fetchedAt == nil)
    }

    @Test func startingOverStrandsAPageFromTheOldCursor() async {
        let server = Server(Array(1...8))
        let pager = pager(server)
        await pager.loadMore()
        let gate = Gate()
        server.holdNext = gate

        let paging = Task { await pager.loadMore() }
        while !gate.isHolding { await Task.yield() }
        server.rows = Array(101...105) + Array(1...8)
        _ = await pager.refresh()
        gate.release()
        await paging.value

        #expect(ids(pager) == Array(101...104))
        #expect(!pager.isLoading)
        await pager.loadMore()
        #expect(ids(pager) == Array(101...105) + [1, 2, 3])
    }

    @Test func aRefreshBeforeTheFirstPageDoesNothing() async {
        let pager = pager(Server(Array(1...4)))

        #expect(isSkipped(await pager.refresh()))
        #expect(pager.items.isEmpty)
    }
}
