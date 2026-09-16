import SwiftUI

/// Holds a side column in view while the page scrolls past it.
///
/// A column shorter than the window pins under the top edge. A column taller than it rides along
/// until its own end comes into view and only then holds — pinning the top of a long rail would put
/// its last block permanently out of reach.
struct StickyColumn<Content: View>: View {
    /// Off when the column sits under the content rather than beside it, where holding it would pull it over what it follows.
    var pins = true
    var topInset: CGFloat = 16
    var bottomInset: CGFloat = 16
    @ViewBuilder var content: Content

    @State private var shift: CGFloat = 0

    /// Two offsets on purpose. The plain one carries hit testing, which a visual effect leaves
    /// behind at the layout position — a pinned rail's Follow buttons would answer clicks in the
    /// wrong place. The effect then draws the difference, so the column never lags the scroll by
    /// the frame it takes state to arrive.
    var body: some View {
        let top = topInset
        let bottom = bottomInset
        let pins = pins
        let applied = shift
        return ZStack(alignment: .top) {
            content.offset(y: shift)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            pins ? Self.pin(proxy, top: top, bottom: bottom) : 0
        } action: { shift = $0 }
        .visualEffect { effect, proxy in
            effect.offset(y: (pins ? Self.pin(proxy, top: top, bottom: bottom) : 0) - applied)
        }
    }

    nonisolated private static func pin(_ proxy: GeometryProxy,
                                        top: CGFloat, bottom: CGFloat) -> CGFloat {
        let viewport = proxy.bounds(of: .scrollView)?.height ?? 0
        let origin = proxy.frame(in: .scrollView).minY
        let height = proxy.size.height
        guard viewport > 0, height > 0 else { return 0 }
        let underTop = top + proxy.safeAreaInsets.top - origin
        let aboveBottom = viewport - bottom - height - origin
        return max(0, min(underTop, aboveBottom))
    }
}

#if DEBUG
#Preview("Sticky column") {
    // Opens mid-scroll, which is the only state worth looking at: pinned, not at rest.
    ScrollView {
        HStack(alignment: .top, spacing: 32) {
            VStack(spacing: 12) {
                ForEach(0..<24, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.primary.opacity(0.08))
                        .frame(height: 90)
                        .overlay(Text("post \(index)").foregroundStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity)

            StickyColumn {
                VStack(alignment: .leading, spacing: 14) {
                    Text("PINNED RAIL").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.tint.opacity(0.25))
                        .frame(height: 220)
                    Text("Stays put while the posts scroll")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 300, alignment: .leading)
        }
        .padding(24)
    }
    .defaultScrollAnchor(.center)
    .frame(width: 900, height: 600)
    .tint(.scOrange)
}
#endif
