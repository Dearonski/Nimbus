import Foundation
import Testing
@testable import Nimbus

/// The queue's rules without playback or network: every case here once broke in the live app.
struct QueueStateTests {
    private static func track(_ id: Int, locked: Bool = false) -> SCTrack {
        let policy = locked ? #","policy":"SNIP""# : ""
        let json = """
        {"id":\(id),"title":"T\(id)","duration":180000,"permalink_url":"x","user":{"id":1,"username":"u"},\
        "media":{"transcodings":[]},"track_authorization":""\(policy)}
        """
        return try! JSONDecoder().decode(SCTrack.self, from: Data(json.utf8))
    }

    private static func tracks(_ ids: some Sequence<Int>, locked: Bool = false) -> [SCTrack] {
        ids.map { track($0, locked: locked) }
    }

    /// Installs `ids` with the head resolved as a real install would.
    private static func installed(_ ids: [Int], startingAt start: Int? = nil, shuffled: Bool = false,
                                  head: Int = 60, lead: Int = 40) -> QueueState {
        var state = QueueState()
        let plan = QueueState.install(ids: ids, startingAt: start, shuffled: shuffled, head: head, lead: lead)!
        state.install(plan, tracks: tracks(plan.headIDs))
        return state
    }

    @Test func installKeepsRowsAboveTheClickedOne() {
        let state = Self.installed(Array(1...100), startingAt: 50)
        #expect(state.current?.id == 50)
        #expect(state.currentIndex == 40)
        #expect(state.leadingIDs == Array(1...9))
        #expect(state.tracks.first?.id == 10)
        #expect(state.pendingIDs.isEmpty)
    }

    @Test func installDropsRepeatedIDs() {
        let state = Self.installed([1, 2, 2, 3, 1])
        #expect(state.tracks.map(\.id) == [1, 2, 3])
        #expect(state.canonicalIDs == [1, 2, 3])
    }

    @Test func unshuffleKeepsRemovedTracksOut() {
        var state = Self.installed(Array(1...10))
        let mixesTail = state.toggleShuffle(currentID: 1)
        #expect(!mixesTail)
        let removed = state.tracks.firstIndex { $0.id == 5 }!
        let removedCurrent = state.remove(atOffsets: IndexSet(integer: removed), currentID: 1)
        #expect(!removedCurrent)
        _ = state.toggleShuffle(currentID: 1)
        #expect(state.tracks.map(\.id) == [1, 2, 3, 4, 6, 7, 8, 9, 10])
        #expect(!state.pendingIDs.contains(5) && !state.leadingIDs.contains(5))
    }

    @Test func clearedTailStaysClearedAfterUnshuffle() {
        var state = Self.installed(Array(1...100), head: 20)
        state.clearUpcoming()
        _ = state.toggleShuffle(currentID: 1)
        _ = state.toggleShuffle(currentID: 1)
        #expect(state.tracks.map(\.id) == [1])
        #expect(state.pendingIDs.isEmpty && state.leadingIDs.isEmpty)
    }

    @Test func refillSpendsASliceOfLockedTracksAndMovesOn() throws {
        var state = Self.installed(Array(1...120), head: 10)
        let first = try #require(state.refillStep)
        #expect(state.missing(for: first) == Array(11...60))
        let spent = state.apply(first, resolved: Self.tracks(11...60, locked: true))
        #expect(spent == .nothingNew)
        #expect(state.pendingIDs == Array(61...120))
        let second = try #require(state.refillStep)
        let filled = state.apply(second, resolved: Self.tracks(61...110))
        #expect(filled == .applied)
        #expect(state.tracks.map(\.id) == Array(1...10) + Array(61...110))
    }

    @Test func refillTakenFromAMovedTailChangesNothing() throws {
        var state = Self.installed(Array(1...120), head: 10)
        let step = try #require(state.refillStep)
        state.clearUpcoming()
        let outcome = state.apply(step, resolved: Self.tracks(11...60))
        #expect(outcome == .stale)
        #expect(state.tracks.map(\.id) == [1])
    }

    @Test func previousOnTheFirstRowPullsTheRowsAbove() throws {
        var state = Self.installed(Array(1...100), startingAt: 60, lead: 10)
        state.currentIndex = 0
        let step = try #require(state.frontStep)
        let outcome = state.apply(step, resolved: Self.tracks(1...49))
        #expect(outcome == .applied)
        #expect(state.current?.id == 49)
        #expect(state.leadingIDs.isEmpty)
    }

    @Test func restoreKeepsTheFirstOfRepeatedIDs() {
        var state = QueueState()
        let session = PlayerEngine.Session(queue: [1, 2, 2, 3], index: 3, leading: [5, 1], pending: [3, 4, 4],
                                           canonical: [5, 1, 2, 2, 3, 4], isShuffled: false, repeatMode: .all,
                                           position: nil)
        let restored = state.restore(session, window: 0..<4, tracks: Self.tracks([1, 2, 2, 3]))
        #expect(restored)
        #expect(state.tracks.map(\.id) == [1, 2, 3])
        #expect(state.current?.id == 3)
        #expect(state.pendingIDs == [4])
        #expect(state.leadingIDs == [5])
        #expect(state.canonicalIDs == [5, 1, 2, 3, 4])
    }

    @Test func autoplayKeepsABoundedHistory() {
        var state = Self.installed(Array(1...300), head: 300)
        state.currentIndex = 299
        state.appendRelated(Self.tracks(301...305))
        #expect(state.current?.id == 300)
        #expect(state.currentIndex == QueueState.historyLimit)
        #expect(state.tracks.count == QueueState.historyLimit + 6)
        #expect(state.originalOrder.count == state.tracks.count)
    }

    @Test func playNextGoesRightAfterTheCurrentTrack() {
        var state = Self.installed(Array(1...5))
        state.currentIndex = 1
        let inserted = state.insert(Self.track(4), next: true, currentID: 2)
        #expect(inserted)
        #expect(state.tracks.map(\.id) == [1, 2, 4, 3, 5])
        #expect(state.originalOrder.map(\.id) == [1, 2, 4, 3, 5])
        let onAir = state.insert(Self.track(2), next: true, currentID: 2)
        #expect(!onAir)
    }

    @Test func dragKeepsTheCurrentTrackCurrent() {
        var state = Self.installed(Array(1...5))
        state.currentIndex = 2
        state.move(from: IndexSet(integer: 4), to: 0, currentID: 3)
        #expect(state.tracks.map(\.id) == [5, 1, 2, 3, 4])
        #expect(state.current?.id == 3)
    }
}
