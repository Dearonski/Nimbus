import Foundation
import Testing
@testable import Nimbus

/// Likes, reposts, follows and blocks without a network: a fake server answers when the test says so.
@MainActor
@Suite(.serialized)
struct OptimisticSetTests {
    @MainActor
    final class Server {
        var calls: [(id: Int, on: Bool)] = []
        private var waiting: [CheckedContinuation<Void, Error>] = []

        func write(_ id: Int, _ on: Bool) async throws {
            calls.append((id, on))
            try await withCheckedThrowingContinuation { waiting.append($0) }
        }

        func answer(failing: Bool = false) async {
            for _ in 0..<1000 where waiting.isEmpty { await Task.yield() }
            guard !waiting.isEmpty else {
                Issue.record("no write is waiting for an answer")
                return
            }
            let next = waiting.removeFirst()
            if failing { next.resume(throwing: SCError.http(403)) } else { next.resume() }
            await OptimisticSetTests.settle()
        }
    }

    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func set(_ server: Server) -> OptimisticSet<Int> {
        OptimisticSet { id, on in try await server.write(id, on) }
    }

    @Test func tapsDuringAWriteGoOutInOrderAndTheLastWins() async {
        let server = Server()
        let likes = set(server)
        likes.set(1, true)
        await Self.settle()
        likes.set(1, false)
        likes.set(1, true)
        likes.set(1, false)
        #expect(server.calls.count == 1)
        await server.answer()
        #expect(server.calls.map(\.on) == [true, false])
        await server.answer()
        #expect(!likes.contains(1))
        #expect(likes.pending.isSettled)
    }

    @Test func aFailedWriteShowsWhatTheServerHolds() async {
        let server = Server()
        let likes = set(server)
        var shown: [Bool] = []
        likes.set(7, true) { shown.append($0) }
        await server.answer(failing: true)
        #expect(!likes.contains(7))
        #expect(shown == [true, false])
    }

    @Test func aWalkReplacesTheSetButNotTapsMadeWhileItRan() async {
        let server = Server()
        let likes = set(server)
        likes.adopt([1, 2, 3], since: likes.mark)
        let mark = likes.mark
        likes.set(9, true)
        likes.set(3, false)
        await server.answer()
        await server.answer()
        likes.adopt([1, 3, 4], since: mark)
        #expect(likes.ids == [1, 4, 9])
    }

    @Test func anUnlikeMadeElsewhereGoesOutOnTheNextWalk() {
        let likes = set(Server())
        likes.seed([1, 2])
        likes.adopt([2], since: likes.mark)
        #expect(likes.ids == [2])
    }

    @Test func aPageDoesNotUndoATapInFlight() async {
        let server = Server()
        let likes = set(server)
        likes.seed([5])
        likes.set(5, false)
        likes.seed([5])
        #expect(!likes.contains(5))
        await server.answer()
    }

    @Test func aCountMovesWithYourOwnTapButNotTwice() async {
        let server = Server()
        let likes = set(server)
        likes.seed([2])
        #expect(likes.count(1, sent: 4) == 4)
        likes.toggle(1, counted: 4)
        likes.toggle(2, counted: 7)
        #expect(likes.count(1, sent: 4) == 5)
        #expect(likes.count(2, sent: 7) == 6)
        // Fetched again after the tap, the server's own count already holds it.
        #expect(likes.count(1, sent: 5) == 5)
        await server.answer()
        await server.answer()
        likes.toggle(1, counted: 5)
        #expect(likes.count(1, sent: 4) == 4)
        await server.answer()
    }

    @Test func signingOutDropsTheAnswerForTheOldAccount() async {
        let server = Server()
        let likes = set(server)
        var shown: [Bool] = []
        likes.set(3, true) { shown.append($0) }
        await Self.settle()
        likes.reset()
        await server.answer(failing: true)
        #expect(likes.ids.isEmpty)
        #expect(shown == [true])
        #expect(likes.pending.isSettled)
    }
}
