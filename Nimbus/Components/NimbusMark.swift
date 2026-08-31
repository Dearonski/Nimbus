import SwiftUI

/// Cloud silhouette used as the app's mark: Nimbus is a rain cloud, and SoundCloud's own identity
/// is a cloud too, so the shape says "SoundCloud client" before any word does.
/// Cloud silhouette: three domes sunk into a rounded base.
///
/// Proportions are what make or break it. The domes have to differ in size and sit at different
/// heights — equal circles in a row read as bubbles — and they must overlap deeply enough that
/// their tangents nearly align where they meet, or the union shows every seam.
struct CloudShape: InsettableShape {
    struct Proportions: Hashable {
        /// centre x, centre y, radius — all as fractions of the mark's width.
        var crown: (x: CGFloat, y: CGFloat, r: CGFloat)
        var left: (x: CGFloat, y: CGFloat, r: CGFloat)
        var right: (x: CGFloat, y: CGFloat, r: CGFloat)
        var baseHeight: CGFloat
        /// How far small domes bulge past the bottom edge, as a fraction of width. Zero leaves the
        /// flat base a rounded rectangle gives, which reads as if the cloud were cut off.
        var bellyDepth: CGFloat = 0

        static func == (a: Proportions, b: Proportions) -> Bool {
            a.crown == b.crown && a.left == b.left && a.right == b.right
                && a.baseHeight == b.baseHeight
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(crown.x); hasher.combine(crown.y); hasher.combine(crown.r)
            hasher.combine(baseHeight)
        }

        /// Wide and low, the domes barely cresting the base.
        static let low = Proportions(crown: (0.50, 0.40, 0.25), left: (0.24, 0.58, 0.23),
                                     right: (0.78, 0.60, 0.20), baseHeight: 0.34)

        func belly(_ depth: CGFloat) -> Proportions {
            var copy = self
            copy.bellyDepth = depth
            return copy
        }
        /// Taller crown offset from centre — the shape most cloud glyphs settle on.
        static let classic = Proportions(crown: (0.46, 0.36, 0.28), left: (0.22, 0.56, 0.22),
                                         right: (0.76, 0.58, 0.24), baseHeight: 0.38)
        /// Rounder and puffier, closer to a cartoon cloud.
        static let puffy = Proportions(crown: (0.50, 0.34, 0.30), left: (0.24, 0.54, 0.26),
                                       right: (0.76, 0.54, 0.26), baseHeight: 0.42)
    }

    var proportions: Proportions = .classic
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> CloudShape {
        CloudShape(proportions: proportions, inset: inset + amount)
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let w = r.width
        let h = r.height

        func dome(_ spec: (x: CGFloat, y: CGFloat, r: CGFloat)) -> CGPath {
            let radius = w * spec.r
            return CGPath(ellipseIn: CGRect(x: r.minX + w * spec.x - radius,
                                            y: r.minY + h * spec.y - radius,
                                            width: radius * 2, height: radius * 2),
                          transform: nil)
        }

        let baseHeight = h * proportions.baseHeight
        let base = CGPath(roundedRect: CGRect(x: r.minX, y: r.maxY - baseHeight,
                                              width: w, height: baseHeight),
                          cornerWidth: baseHeight / 2, cornerHeight: baseHeight / 2,
                          transform: nil)

        var cloud = dome(proportions.left)
            .union(dome(proportions.crown))
            .union(dome(proportions.right))
            .union(base)

        // Two shallow domes hanging under the base give the underside a wave instead of a ruler
        // edge, without touching the silhouette above.
        if proportions.bellyDepth > 0 {
            let radius = w * proportions.bellyDepth
            for x in [0.34, 0.66] as [CGFloat] {
                let bulge = CGPath(ellipseIn: CGRect(x: r.minX + w * x - radius,
                                                     y: r.maxY - radius * 1.15,
                                                     width: radius * 2, height: radius * 2),
                                   transform: nil)
                cloud = cloud.union(bulge)
            }
        }

        return Path(cloud)
    }
}

/// Sound held by a cloud, drawn as one continuous weight: the outline and the bars share a stroke
/// width, which is what keeps a line mark from looking assembled out of parts.
struct CloudSoundMark: View {
    enum Accent {
        /// Nothing — plain white bars.
        case none
        /// The left of the wave is solid and the rest is dimmed: the played/remaining split the app
        /// draws on every track, carried into the mark.
        case progress
        /// One bar filled to full height, like the playhead sitting inside the sound.
        case playhead
    }

    /// Fraction of the mark's width used as the stroke, applied to the cloud and the bars alike.
    var weight: CGFloat = 0.05
    var accent: Accent = .progress
    var proportions: CloudShape.Proportions = .classic
    private let bars: [CGFloat] = [0.42, 0.72, 1.0, 0.86, 0.58, 0.34]
    private let playedCount = 3

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let stroke = size.width * weight
            let cloudHeight = size.height * 0.58
            let span = size.height * 0.40

            ZStack(alignment: .top) {
                CloudShape(proportions: proportions)
                    .strokeBorder(style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
                    .frame(height: cloudHeight)

                HStack(alignment: .center, spacing: stroke * 1.15) {
                    ForEach(bars.indices, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(opacity(at: index)))
                            .frame(width: stroke, height: height(at: index, span: span))
                    }
                }
                .frame(height: span)
                .offset(y: cloudHeight + stroke * 0.7)
            }
            .foregroundStyle(.white)
        }
    }

    private func height(at index: Int, span: CGFloat) -> CGFloat {
        guard accent == .playhead, index == playedCount - 1 else { return span * bars[index] }
        return span
    }

    private func opacity(at index: Int) -> Double {
        switch accent {
        case .none: 1
        case .progress: index < playedCount ? 1 : 0.5
        case .playhead: 1
        }
    }
}

/// The mark on its app-icon tile, so a variant can be judged the way it will be seen.
struct MarkTile<Mark: View>: View {
    var size: CGFloat = 104
    /// How much of the tile the mark fills. macOS icons sit closer to their edges than the 0.62 a
    /// glyph would take.
    var fill: CGFloat = 0.78
    @ViewBuilder let mark: Mark

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color.scOrange, Color.scOrange.opacity(0.72)],
                                     startPoint: .top, endPoint: .bottom))
            mark
                .frame(width: size * fill, height: size * fill)
        }
        .frame(width: size, height: size)
    }
}
