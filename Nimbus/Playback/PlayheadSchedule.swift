import SwiftUI

// `.animation(minimumInterval:)` still wakes on every display frame only to skip it.
struct PlayheadSchedule: TimelineSchedule {
    var interval: TimeInterval
    var paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        let step = paused ? nil : max(interval, 1.0 / 120)
        return AnyIterator {
            defer { next = step.flatMap { s in next.map { $0 + s } } }
            return next
        }
    }
}
