import Foundation
import Observation

/// Ids the user switches on and off — liked, reposted, followed, blocked — shown at once and written behind.
@MainActor
@Observable
final class OptimisticSet<ID: Hashable & Sendable> {
    private(set) var ids: Set<ID> = []

    private struct Write {
        /// What the server holds, as far as anyone here knows.
        var confirmed: Bool
        var wanted: Bool
        /// Everything a state means beyond the set — a Likes row, a Following row — applied again on rollback.
        var effect: (Bool) -> Void
    }

    @ObservationIgnored private var writes: [ID: Write] = [:]
    /// When each id was last tapped, by tap count: a walk that began earlier knows nothing of it.
    @ObservationIgnored private var touched: [ID: Int] = [:]
    @ObservationIgnored private var taps = 0
    /// Bumped by `reset()`, so an answer meant for the account that signed out lands nowhere.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var walking: Task<Void, Never>?
    @ObservationIgnored private(set) var pending = PendingWrites()

    private let write: (_ id: ID, _ on: Bool) async throws -> Void
    private let walk: (() async throws -> [ID])?

    init(walk: (() async throws -> [ID])? = nil, write: @escaping (_ id: ID, _ on: Bool) async throws -> Void) {
        self.walk = walk
        self.write = write
    }

    func contains(_ id: ID) -> Bool { ids.contains(id) }

    /// Taken before a walk starts and handed to `adopt`, so taps made meanwhile survive its answer.
    var mark: Int { taps }

    func toggle(_ id: ID, effect: @escaping (Bool) -> Void = { _ in }) {
        set(id, !ids.contains(id), effect: effect)
    }

    /// One write per id at a time, last tap wins: two in parallel could land liked under an empty heart.
    func set(_ id: ID, _ on: Bool, effect: @escaping (Bool) -> Void = { _ in }) {
        guard ids.contains(id) != on else { return }
        note(id, on)
        effect(on)
        if writes[id] != nil {
            writes[id]?.wanted = on
            writes[id]?.effect = effect
            return
        }
        writes[id] = Write(confirmed: !on, wanted: on, effect: effect)
        Task { await send(id) }
    }

    /// A change the server makes on its own, like a block dropping the follow: shown, never written.
    func assume(_ id: ID, _ on: Bool) {
        note(id, on)
    }

    /// Ids a loaded page shows as on; one with a write in flight keeps what was tapped.
    func seed(_ seen: some Sequence<ID>) {
        for id in seen where writes[id] == nil { ids.insert(id) }
    }

    /// Ids the server no longer lists; one with a write in flight keeps what was tapped.
    func drop(_ gone: some Sequence<ID>) {
        for id in gone where writes[id] == nil { ids.remove(id) }
    }

    /// Replacing rather than adding lets an unlike made on the site go out here; taps since `mark` still win.
    func adopt(_ walked: some Sequence<ID>, since mark: Int) {
        var next = Set(walked)
        for (id, at) in touched where at > mark || writes[id] != nil {
            if ids.contains(id) { next.insert(id) } else { next.remove(id) }
        }
        ids = next
        touched = touched.filter { $0.value > mark }
    }

    /// One full walk per session, retried on the next ask if it failed.
    func loadIfNeeded() {
        guard let walk, !loaded, walking == nil else { return }
        let generation = self.generation
        let mark = self.mark
        walking = Task {
            defer { if generation == self.generation { walking = nil } }
            guard let walked = try? await walk(), generation == self.generation else { return }
            adopt(walked, since: mark)
            loaded = true
        }
    }

    func reset() {
        generation += 1
        ids = []
        writes = [:]
        touched = [:]
        loaded = false
        walking?.cancel()
        walking = nil
        pending = PendingWrites()
    }

    private func note(_ id: ID, _ on: Bool) {
        taps += 1
        touched[id] = taps
        if on { ids.insert(id) } else { ids.remove(id) }
    }

    private func send(_ id: ID) async {
        let generation = self.generation
        pending.begin()
        defer { if generation == self.generation { pending.end() } }
        while generation == self.generation, let next = writes[id], next.wanted != next.confirmed {
            do {
                try await write(id, next.wanted)
                guard generation == self.generation else { return }
                writes[id]?.confirmed = next.wanted
            } catch {
                guard generation == self.generation, let failed = writes[id] else { return }
                // The server still holds `confirmed`, whatever was tapped after the failed write.
                if failed.confirmed { ids.insert(id) } else { ids.remove(id) }
                failed.effect(failed.confirmed)
                writes[id] = nil
                return
            }
        }
        if generation == self.generation { writes[id] = nil }
    }
}
