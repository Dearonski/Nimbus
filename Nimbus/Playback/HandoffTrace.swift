import Foundation
import os

/// Times one track handoff — from the moment a track ends to the first audible sample of the next.
/// Marks print an offset from the start and a delta from the previous mark, so a single run says
/// where the gap actually goes instead of leaving the whole half second unattributed.
///
/// Read it back with:
/// `/usr/bin/log show --last 15m --info --debug \
///   --predicate 'process == "Nimbus" AND category == "handoff"' --style compact`
nonisolated final class HandoffTrace: @unchecked Sendable {
    static let shared = HandoffTrace()

#if DEBUG
    private let log = Logger(subsystem: "io.github.dearonski.Nimbus", category: "handoff")
    private let lock = NSLock()
    private var start: DispatchTime?
    private var previous: DispatchTime?
    private var sequence = 0

    /// Opens a window. Marks outside one are dropped: the same stream store also refreshes its
    /// signatures mid-track, and those refreshes would otherwise land in the middle of a handoff.
    func begin(_ label: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now()
        start = now
        previous = now
        sequence += 1
        log.info("\("#\(self.sequence) ── \(label)", privacy: .public)")
    }

    func mark(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let start, let last = previous else { return }
        let now = DispatchTime.now()
        previous = now
        let total = Self.ms(from: start, to: now)
        let delta = Self.ms(from: last, to: now)
        log.info("\(Self.line(self.sequence, total, delta, name), privacy: .public)")
    }

    /// Closes the window, so nothing after the first audible sample is attributed to the handoff.
    func end(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let start, let last = previous else { return }
        let now = DispatchTime.now()
        let total = Self.ms(from: start, to: now)
        let delta = Self.ms(from: last, to: now)
        log.info("\(Self.line(self.sequence, total, delta, name), privacy: .public)")
        self.start = nil
        previous = nil
    }

    private static func ms(from: DispatchTime, to: DispatchTime) -> Double {
        Double(to.uptimeNanoseconds &- from.uptimeNanoseconds) / 1_000_000
    }

    private static func line(_ sequence: Int, _ total: Double, _ delta: Double, _ name: String) -> String {
        let totalText = String(format: "%7.1fms", total)
        let deltaText = String(format: "(+%.1f)", delta)
        return "#\(sequence) \(totalText) \(deltaText.padding(toLength: 10, withPad: " ", startingAt: 0)) \(name)"
    }
#else
    func begin(_ label: String) {}
    func mark(_ name: String) {}
    func end(_ name: String) {}
#endif
}
