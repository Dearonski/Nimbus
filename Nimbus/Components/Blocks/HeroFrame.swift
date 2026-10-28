import SwiftUI

/// The block a track's and a set's page open with, laid out like soundcloud.com's own: play, title
/// and byline top left, a strip across the middle, actions along the bottom, the artwork on the right
/// and again, blurred, behind it all — the treatment the artist banner uses too.
struct HeroFrame<Play: View, Byline: View, Middle: View, Bottom: View, Badge: View>: View {
    let artwork: Artwork
    let coverURL: String?
    let title: String
    @ViewBuilder let play: () -> Play
    @ViewBuilder let byline: () -> Byline
    @ViewBuilder let middle: () -> Middle
    @ViewBuilder let bottom: () -> Bottom
    @ViewBuilder var badge: () -> Badge

    @Environment(\.metrics) private var metrics
    @Environment(PageRoom.self) private var room: PageRoom?

    /// Shared with the column under the hero, whose right edge the artwork lines up with.
    private var artworkSize: CGFloat {
        TrackDetailView.showsRail(in: room, usable: metrics.usable) ? TrackDetailView.railWidth : 240
    }

    /// Measured off the live page: a 130pt strip beside 336pt artwork. Tied to the artwork, the ratio
    /// holds at every window size — left to fill the block, the waveform came out twice the site's height.
    private var middleHeight: CGFloat { artworkSize * 0.39 }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 0) {
                headline
                Spacer(minLength: 12)
                middle()
                    .frame(height: middleHeight)
                    // A comment card hangs below the strip; the action row, later in the stack, would paint over it.
                    .zIndex(1)
                Spacer(minLength: 12)
                bottom()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            artwork
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) { badge() }
                .opensArtwork(coverURL, preview: .hero, title: title)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
        .padding(ContentMetrics.heroInset)
        .frame(minHeight: artworkSize + ContentMetrics.heroInset * 2)
        .background {
            // Cropped before the blur: a filled square cover would otherwise be blurred whole.
            artwork
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 60, opaque: true)
                .overlay(Color.black.opacity(0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.snappy, value: artworkSize)
    }

    private var headline: some View {
        HStack(spacing: 14) {
            play()

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(2)

                HStack(spacing: 6) { byline() }
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}

extension HeroFrame where Badge == EmptyView {
    init(artwork: Artwork, coverURL: String?, title: String,
         @ViewBuilder play: @escaping () -> Play,
         @ViewBuilder byline: @escaping () -> Byline,
         @ViewBuilder middle: @escaping () -> Middle,
         @ViewBuilder bottom: @escaping () -> Bottom) {
        self.init(artwork: artwork, coverURL: coverURL, title: title, play: play, byline: byline,
                  middle: middle, bottom: bottom, badge: { EmptyView() })
    }
}
