import AppKit
import OSLog

/// How late the main thread runs while a `CardCollection` scrolls, and what each new row costs it,
/// summed up in the log once the scrolling stops. Not what reaches the screen: AppKit scrolls on a
/// thread of its own, and a run this calls 60% late can look smooth. For that, Animation Hitches:
///
///     xcrun xctrace record --template 'Animation Hitches' --attach <pid> --time-limit 6s
///
/// Switched on by the launch argument `-perf.scrollProbe YES`:
///
///     /usr/bin/log show --last 30m --predicate 'process == "Nimbus" AND category == "scroll"'
@MainActor
final class ScrollProbe: NSObject {
    /// A default rather than `#if DEBUG`: a debug build under Xcode is the one place the numbers lie.
    static let isEnabled = UserDefaults.standard.bool(forKey: "perf.scrollProbe")

    private static let log = Logger(subsystem: "io.github.dearonski.Nimbus", category: "scroll")

    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var budget: Double = 0
    private var frames: [Double] = []
    private var swaps: [Double] = []
    private var displays: [Double] = []
    private var quietTicks = 0

    func attach(to view: NSView) {
        guard link == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(tick))
        // Common modes: scrolling runs the loop in event-tracking mode, where a default-mode link sleeps.
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.link = link
    }

    func scrolled() {
        quietTicks = 0
        link?.isPaused = false
    }

    func swapped(ms: Double) { swaps.append(ms) }
    func displayed(ms: Double) { displays.append(ms) }

    @objc private func tick(_ link: CADisplayLink) {
        budget = (link.targetTimestamp - link.timestamp) * 1000
        if lastFrame > 0 { frames.append((link.timestamp - lastFrame) * 1000) }
        lastFrame = link.timestamp
        quietTicks += 1
        guard quietTicks > 45 else { return }
        link.isPaused = true
        lastFrame = 0
        report()
    }

    private func report() {
        // The quiet tail that ended the run is not scrolling.
        let run = frames.dropLast(min(45, frames.count))
        defer { frames = []; swaps = []; displays = [] }
        guard run.count > 30 else { return }
        let late = run.filter { $0 > budget * 1.5 }
        let lost = late.reduce(0) { $0 + ($1 / budget).rounded() - 1 }
        let perRow = swaps.isEmpty ? 0 : lost * budget / Double(swaps.count)
        // `notice`, not `info`: info lives in memory only and is gone within minutes — a run of five was lost to that.
        Self.log.notice("""
            \(perRow, format: .fixed(precision: 1), privacy: .public) ms lost per new row | \
            frames \(run.count, privacy: .public) at \(self.budget, format: .fixed(precision: 1), privacy: .public) ms, \
            late \(late.count, privacy: .public), lost \(Int(lost), privacy: .public), \
            worst \(run.max() ?? 0, format: .fixed(precision: 1), privacy: .public) ms | \
            swap \(Self.summary(self.swaps), privacy: .public) | display \(Self.summary(self.displays), privacy: .public)
            """)
    }

    private static func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "none" }
        let sorted = values.sorted()
        func at(_ share: Double) -> Double { sorted[min(Int(Double(sorted.count) * share), sorted.count - 1)] }
        return String(format: "n=%d median %.1f p95 %.1f max %.1f ms", sorted.count, at(0.5), at(0.95), sorted[sorted.count - 1])
    }
}
