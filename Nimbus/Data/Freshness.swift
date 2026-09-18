import Foundation
import os

let refreshLog = Logger(subsystem: "io.github.dearonski.Nimbus", category: "refresh")

struct Freshness {
    let name: String
    let ttl: Duration
    private(set) var fetchedAt: ContinuousClock.Instant?
    private(set) var isLoading = false
    // `refreshStale` leaves alone a list no page has opened yet.
    private(set) var isWanted = false

    init(_ name: String, ttl: Duration) {
        self.name = name
        self.ttl = ttl
    }

    var hasLoaded: Bool { fetchedAt != nil }

    mutating func begin(force: Bool) -> Bool {
        isWanted = true
        guard !isLoading, Self.isDue(name, fetchedAt: fetchedAt, ttl: ttl, force: force) else { return false }
        isLoading = true
        return true
    }

    mutating func finish(loaded: Bool) {
        isLoading = false
        if loaded { fetchedAt = .now }
    }

    mutating func reset() {
        self = Freshness(name, ttl: ttl)
    }

    static func isDue(_ name: String, fetchedAt: ContinuousClock.Instant?, ttl: Duration, force: Bool) -> Bool {
        guard let fetchedAt else {
            refreshLog.info("\(name, privacy: .public): first load")
            return true
        }
        let age = ContinuousClock.now - fetchedAt
        let seconds = age.components.seconds
        if force {
            refreshLog.info("\(name, privacy: .public): forced, \(seconds)s old")
            return true
        }
        guard age >= ttl else {
            refreshLog.debug("\(name, privacy: .public): fresh, \(seconds)s old")
            return false
        }
        refreshLog.info("\(name, privacy: .public): stale, \(seconds)s old")
        return true
    }
}

// A refresh answered before the server applied these would put the old state back on screen.
struct PendingWrites {
    private(set) var inFlight = 0
    private(set) var version = 0

    var isSettled: Bool { inFlight == 0 }

    mutating func begin() {
        inFlight += 1
        version += 1
    }

    mutating func end() {
        inFlight = max(0, inFlight - 1)
        version += 1
    }
}
