import AppKit
import SwiftUI

// MARK: - Shimmer clock

private struct SkeletonPhaseKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

extension EnvironmentValues {
    var skeletonPhase: Double {
        get { self[SkeletonPhaseKey.self] }
        set { self[SkeletonPhaseKey.self] = newValue }
    }
}

/// One shimmer clock for a whole screenful of placeholders. A timeline per bar would run dozens of
/// them out of step, and the sweep would read as noise rather than one pass over the page.
struct SkeletonGroup<Content: View>: View {
    @ViewBuilder let content: Content

    private static var period: Double { 1.6 }

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate / Self.period
            content
                .environment(\.skeletonPhase, elapsed.truncatingRemainder(dividingBy: 1))
        }
        .accessibilityHidden(true)
        // Hit-testable, every shimmer frame AppKit re-unioned each shape into the window's drag region, seconds of main thread.
        .allowsHitTesting(false)
    }
}

// MARK: - Primitives

struct SkeletonFill<S: Shape>: View {
    let shape: S

    @Environment(\.skeletonPhase) private var phase

    var body: some View {
        shape
            .fill(Color.primary.opacity(0.08))
            .overlay { sheen.mask(shape) }
    }

    private var sheen: some View {
        GeometryReader { proxy in
            let band = proxy.size.width * 0.55
            LinearGradient(colors: [.clear, Color.primary.opacity(0.09), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + phase * (proxy.size.width + band))
        }
    }
}

struct SkeletonBox: View {
    var cornerRadius: CGFloat = 6

    var body: some View {
        SkeletonFill(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct SkeletonDisc: View {
    var body: some View { SkeletonFill(shape: Circle()) }
}

/// Stands in for one line of type. The bar is drawn at cap height but reserves the full line box
/// the real text will need — measured off the system font, so the row keeps its height when the
/// placeholder is swapped for words.
struct SkeletonLine: View {
    var width: CGFloat
    var textSize: CGFloat

    var body: some View {
        SkeletonFill(shape: Capsule())
            .frame(width: width, height: (textSize * 0.72).rounded())
            .frame(height: Self.lineHeight(textSize))
    }

    static func lineHeight(_ textSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: textSize)
        return (font.ascender - font.descender + font.leading).rounded()
    }
}
