import Foundation
import Observation

/// A list fetched whole and fetched again once it is older than its TTL.
@MainActor
@Observable
final class FreshList<Item> {
    private(set) var items: [Item] = []
    /// Only for a list that never came: a failed refresh keeps what is already on screen.
    private(set) var error: String?
    var isLoading: Bool { freshness.isLoading }
    var hasLoaded: Bool { freshness.hasLoaded }
    /// `refreshStale` leaves alone a list no page has opened yet.
    var isWanted: Bool { freshness.isWanted }

    /// Set after the owner exists, since it usually reads the owner's own state.
    @ObservationIgnored var fetch: () async throws -> [Item] = { [] }
    /// Asked before a refresh: one that started under a write still in flight would put the old state back.
    @ObservationIgnored var isSettled: () -> Bool = { true }

    private var freshness: Freshness
    /// Bumped by `reset()`, so an answer for the account that signed out lands nowhere.
    @ObservationIgnored private var generation = 0

    init(_ name: String, ttl: Duration) {
        freshness = Freshness(name, ttl: ttl)
    }

    /// Unstructured, so a view's `.task` cancelled while the window settles on launch can't -999 it.
    func loadIfNeeded(force: Bool = false) {
        Task { await update(force: force) }
    }

    /// False only when the server didn't answer.
    func update(force: Bool = false) async -> Bool {
        guard !hasLoaded || isSettled(), freshness.begin(force: force) else { return true }
        let generation = self.generation
        do {
            let loaded = try await fetch()
            guard generation == self.generation else { return true }
            items = loaded
            error = nil
            freshness.finish(loaded: true)
            return true
        } catch {
            guard generation == self.generation else { return true }
            if !hasLoaded { self.error = error.surfaced() }
            freshness.finish(loaded: false)
            return false
        }
    }

    func edit(_ change: (inout [Item]) -> Void) {
        change(&items)
    }

    func reset() {
        generation += 1
        items = []
        error = nil
        freshness.reset()
    }
}
