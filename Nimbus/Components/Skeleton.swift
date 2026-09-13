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
    }
}

// MARK: - Primitives

private struct SkeletonFill<S: Shape>: View {
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

/// Deterministic jitter: a column of identical bars reads as a table, not as text.
private func jitter(_ index: Int, _ widths: [CGFloat]) -> CGFloat {
    widths[index % widths.count]
}

// MARK: - Shapes that mirror real content

/// Mirrors `TrackRow`.
struct TrackRowsSkeleton: View {
    var count = 8

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(spacing: 12) {
                        SkeletonBox(cornerRadius: 6).frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            SkeletonLine(width: jitter(index, [232, 168, 288, 196]), textSize: 15)
                            SkeletonLine(width: jitter(index, [104, 138, 92, 120]), textSize: 13)
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 16) {
                            ForEach(0..<4, id: \.self) { _ in
                                SkeletonLine(width: 34, textSize: 12)
                            }
                        }
                        SkeletonLine(width: 38, textSize: 13)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

/// Mirrors `ChartRow`, rank column included — that block is the page's strongest vertical, and
/// leaving it out makes the real list jump sideways when it lands.
struct ChartRowsSkeleton: View {
    var count = 5

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(spacing: 12) {
                        SkeletonBox(cornerRadius: 3).frame(width: jitter(index, [12, 14, 13, 15, 14]), height: 21)
                            .frame(width: ChartRow.rankWidth(for: count), alignment: .trailing)
                        SkeletonBox(cornerRadius: 6).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            SkeletonLine(width: jitter(index, [214, 156, 262, 188, 172]), textSize: 14)
                            SkeletonLine(width: jitter(index, [96, 124, 88, 110, 132]), textSize: 12)
                        }
                        Spacer(minLength: 12)
                        SkeletonLine(width: 40, textSize: 11)
                        SkeletonLine(width: 34, textSize: 12).frame(width: 44, alignment: .trailing)
                    }
                    .padding(.horizontal, ChartRow.inset)
                    .frame(height: 52)
                }
            }
        }
    }
}

/// Mirrors `PlaylistRow` inside an inset list.
struct PlaylistRowsSkeleton: View {
    var count = 8

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(spacing: 10) {
                        SkeletonBox(cornerRadius: 4).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            SkeletonLine(width: jitter(index, [186, 132, 224, 158]), textSize: 13)
                            SkeletonLine(width: 62, textSize: 11)
                        }
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
            }
        }
    }
}

/// Mirrors a grid of `MediaCard`s.
struct CardGridSkeleton: View {
    var count = 12

    @Environment(\.metrics) private var metrics

    var body: some View {
        SkeletonGroup {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.card), spacing: 18)], spacing: 22) {
                ForEach(0..<count, id: \.self) { index in
                    CardSkeleton(index: index)
                }
            }
        }
    }
}

/// Mirrors a shelf of `MediaCard`s — one row, clipped by the page like the real carousel.
struct CardRowSkeleton: View {
    var count = 5

    @Environment(\.metrics) private var metrics

    var body: some View {
        SkeletonGroup {
            HStack(alignment: .top, spacing: 18) {
                ForEach(0..<count, id: \.self) { index in
                    CardSkeleton(index: index)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct CardSkeleton: View {
    let index: Int

    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBox(cornerRadius: 10).frame(width: metrics.card, height: metrics.card)
            VStack(alignment: .leading, spacing: 2) {
                SkeletonLine(width: metrics.card * jitter(index, [0.94, 0.88, 0.97, 0.91]), textSize: 13)
                SkeletonLine(width: metrics.card * jitter(index, [0.44, 0.62, 0.38, 0.55]), textSize: 13)
                SkeletonLine(width: metrics.card * jitter(index, [0.5, 0.66, 0.42, 0.58]), textSize: 11)
            }
        }
        .frame(width: metrics.card, alignment: .leading)
    }
}

/// Mirrors a grid of `ArtistCircle`s.
struct ArtistCirclesSkeleton: View {
    var count = 12

    @Environment(\.metrics) private var metrics

    var body: some View {
        SkeletonGroup {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.shelfAvatar + 24), spacing: 20)],
                      spacing: 24) {
                ForEach(0..<count, id: \.self) { index in
                    VStack(spacing: 8) {
                        SkeletonDisc().frame(width: metrics.shelfAvatar, height: metrics.shelfAvatar)
                        VStack(spacing: 2) {
                            SkeletonLine(width: metrics.shelfAvatar * jitter(index, [0.82, 0.6, 0.94, 0.7]),
                                         textSize: 12)
                            SkeletonLine(width: metrics.shelfAvatar * 0.45, textSize: 11)
                        }
                    }
                }
            }
        }
    }
}

/// Mirrors `LikeCard`: cover, byline over title, the waveform strip, and the action row under it.
struct LikeCardsSkeleton: View {
    var count = 5

    @Environment(\.metrics) private var metrics

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 20) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(alignment: .top, spacing: 16) {
                        SkeletonBox(cornerRadius: 6)
                            .frame(width: metrics.listArtwork, height: metrics.listArtwork)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                SkeletonDisc().frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    SkeletonLine(width: jitter(index, [118, 92, 146, 104]), textSize: 12)
                                    SkeletonLine(width: jitter(index, [244, 178, 296, 210]), textSize: 15)
                                }
                                Spacer(minLength: 12)
                                SkeletonLine(width: 68, textSize: 11)
                            }
                            WaveformSkeleton()
                            HStack(spacing: 8) {
                                ForEach(0..<3, id: \.self) { _ in
                                    SkeletonBox(cornerRadius: 11).frame(width: 58, height: 22)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

/// The waveform strip, on `WaveformView`'s own geometry — bar, gap, centre gap and the 0.68 split
/// are its defaults, so the real strip lands exactly where this one stood.
private struct WaveformSkeleton: View {
    private static let height: CGFloat = 48
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 1
    private static let centreGap: CGFloat = 2
    private static let topRatio: CGFloat = 0.68

    var body: some View {
        GeometryReader { proxy in
            let slot = Self.barWidth + Self.barSpacing
            let count = max(Int(proxy.size.width / slot), 1)
            let top = (Self.height - Self.centreGap) * Self.topRatio
            let bottom = Self.height - Self.centreGap - top
            HStack(alignment: .top, spacing: Self.barSpacing) {
                ForEach(0..<count, id: \.self) { index in
                    let peak = amplitude(index)
                    VStack(spacing: Self.centreGap) {
                        SkeletonBox(cornerRadius: 1)
                            .frame(width: Self.barWidth, height: max(peak * top, 2))
                            .frame(height: top, alignment: .bottom)
                        SkeletonBox(cornerRadius: 1)
                            .frame(width: Self.barWidth, height: max(peak * bottom, 1))
                            .frame(height: bottom, alignment: .top)
                            .opacity(0.5)
                    }
                }
            }
        }
        .frame(height: Self.height)
    }

    /// Three detuned sines: one alone reads as a machine part, three read as a track.
    private func amplitude(_ index: Int) -> CGFloat {
        let x = Double(index)
        let mixed = abs(sin(x * 0.34) * 0.45 + sin(x * 0.11) * 0.32 + sin(x * 0.83) * 0.23)
        return CGFloat(0.16 + 0.84 * pow(mixed, 0.75))
    }
}

/// Mirrors `ProfileHeader` plus the first shelf under it.
struct ProfileSkeleton: View {
    @Environment(\.metrics) private var metrics

    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 24) {
                    SkeletonDisc().frame(width: metrics.avatar, height: metrics.avatar)
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonLine(width: 226, textSize: 26)
                        HStack(spacing: 28) {
                            ForEach(0..<3, id: \.self) { _ in
                                VStack(spacing: 2) {
                                    SkeletonLine(width: 46, textSize: 13)
                                    SkeletonLine(width: 62, textSize: 10)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, gutter)

                VStack(alignment: .leading, spacing: 12) {
                    SkeletonLine(width: 96, textSize: 20).padding(.horizontal, gutter)
                    CardRowSkeleton().padding(.horizontal, gutter)
                }
            }
            .padding(.vertical, 16)
        }
    }
}

/// Mirrors `FeaturedMix`: square cover beside eyebrow, title and the two buttons.
struct FeaturedMixSkeleton: View {
    @Environment(\.metrics) private var metrics

    var body: some View {
        SkeletonGroup {
            HStack(alignment: .top, spacing: 22) {
                SkeletonBox(cornerRadius: 12)
                    .frame(width: metrics.hero - 40, height: metrics.hero - 40)

                VStack(alignment: .leading, spacing: 8) {
                    SkeletonLine(width: 78, textSize: 11)
                    SkeletonLine(width: 306, textSize: 28)
                    SkeletonLine(width: 218, textSize: 13)
                    Spacer(minLength: 6)
                    HStack(spacing: 12) {
                        SkeletonBox(cornerRadius: 7).frame(width: 104, height: 28)
                        SkeletonBox(cornerRadius: 7).frame(width: 112, height: 28)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(height: metrics.hero)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07))
            }
        }
    }
}

#Preview("Skeletons") {
    ScrollView {
        VStack(alignment: .leading, spacing: 32) {
            ChartRowsSkeleton(count: 3)
            TrackRowsSkeleton(count: 3)
            LikeCardsSkeleton(count: 1)
            CardRowSkeleton(count: 4)
            ArtistCirclesSkeleton(count: 4)
        }
        .padding(24)
    }
    .frame(width: 900, height: 900)
}
