import Foundation

/// Where playback stands, as of the engine's last word on it. The player reports twice a second,
/// so anything drawn from the bare number moves in half-second hops; this carries the rate along,
/// and a view asks for the position at its own frame time instead.
nonisolated struct Playhead: Equatable, Sendable {
    var position: Double = 0
    var anchor: Date = .distantPast
    /// Zero while the sound isn't actually moving — paused, buffering or seeking.
    var rate: Double = 0
    var duration: Double = 0

    var isRunning: Bool { rate > 0 && duration > 0 }

    /// A report lands every half second; past this the player has stalled without saying so, and
    /// running on would only snap back when it speaks.
    private static let reach: TimeInterval = 0.75

    func time(at date: Date) -> Double {
        position + min(max(date.timeIntervalSince(anchor), 0), Self.reach) * rate
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(time(at: date) / duration, 0), 1)
    }

    static func still(_ progress: Double) -> Playhead {
        Playhead(position: progress, duration: 1)
    }
}
