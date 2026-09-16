import SwiftUI

/// Sizes derived from the width the content actually gets. Components ask for a role — a square
/// shelf card, a wide card, a page artwork — instead of carrying their own constants, so the whole
/// page reflows when the sidebar or the queue inspector takes room away, and a new component is
/// adaptive by default rather than by remembering to make it so.
struct ContentMetrics: Equatable {
    /// Width available to the content, gutters already removed.
    let usable: CGFloat

    /// Square card on a shelf or in a grid.
    var card: CGFloat { clamp(usable * 0.15, 128, 230) }
    /// Landscape card, roughly 16:9, used for the wide sets on Home.
    var wideCard: CGSize { CGSize(width: card * 1.62, height: card * 1.62 * 0.56) }
    /// Featured block on Home — the tallest thing above the fold.
    var hero: CGFloat { clamp(usable * 0.2, 150, 260) }
    /// Small round avatar in an artist shelf.
    var shelfAvatar: CGFloat { clamp(card * 0.55, 64, 110) }
    /// Minimum column for a tile grid (genres).
    var tile: CGFloat { clamp(usable * 0.14, 130, 210) }
    /// Minimum column for a grid of rows (recently played).
    var rowGrid: CGFloat { clamp(usable * 0.28, 260, 400) }
    /// Cover on a full-width feed row — SoundCloud's liked-track list.
    var listArtwork: CGFloat { clamp(usable * 0.11, 96, 150) }
    /// Cover thumbnail inside a row-shaped card.
    var rowArtwork: CGFloat { clamp(usable * 0.05, 44, 72) }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }
}

/// A page's room as the window gives it, plus what the queue takes once open. Shape decisions read this,
/// not the live width, which crossed thresholds mid-slide and rearranged the page under the panel.
@MainActor
@Observable
final class PageRoom {
    /// A waveform card still reads at this width; narrower, a side column moves under the content.
    static let contentMinimum: CGFloat = 480

    var shellWidth: CGFloat = 0
    var detailMinX: CGFloat = 0
    var queueWidth: CGFloat = 320
    var isQueueOpen = false

    private var windowUsable: CGFloat { shellWidth - detailMinX - gutter * 2 }

    /// The usable width once the queue has finished opening or closing.
    var settledUsable: CGFloat { windowUsable - (isQueueOpen ? queueWidth : 0) }

    func fitsRail(_ rail: CGFloat, spacing: CGFloat, minimum: CGFloat) -> Bool {
        windowUsable >= minimum && settledUsable - rail - spacing >= Self.contentMinimum
    }
}

private struct ContentMetricsKey: EnvironmentKey {
    static let defaultValue = ContentMetrics(usable: 900)
}

extension EnvironmentValues {
    var metrics: ContentMetrics {
        get { self[ContentMetricsKey.self] }
        set { self[ContentMetricsKey.self] = newValue }
    }
}

extension View {
    /// Publishes metrics derived from this view's own width. Apply once per content column —
    /// measuring here rather than at the shell means the numbers follow whatever actually resizes
    /// the column, inspector included.
    func adaptiveMetrics() -> some View {
        modifier(AdaptiveMetrics())
    }
}

private struct AdaptiveMetrics: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.metrics, ContentMetrics(usable: max(0, width - gutter * 2)))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                width = newWidth
            }
    }
}

#if DEBUG
import os

extension View {
    /// Prints the metrics a screen actually receives. Two screens using the same component can
    /// still draw it differently if the environment reaches them with different widths.
    func logMetrics(_ label: String) -> some View {
        modifier(MetricsLog(label: label))
    }
}

private struct MetricsLog: ViewModifier {
    let label: String
    @Environment(\.metrics) private var metrics

    private static let log = Logger(subsystem: "io.github.dearonski.Nimbus", category: "metrics")

    func body(content: Content) -> some View {
        // On change, not onAppear: the first frame runs before the width has been measured, so
        // onAppear only ever reported the starting value.
        content.onChange(of: metrics.usable, initial: true) { _, usable in
            Self.log.info("""
                \(label, privacy: .public): usable \(Int(usable), privacy: .public), \
                listArtwork \(Int(metrics.listArtwork), privacy: .public), \
                card \(Int(metrics.card), privacy: .public)
                """)
        }
    }
}
#endif
