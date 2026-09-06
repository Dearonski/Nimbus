import SwiftUI

/// The square card every shelf and grid is built from: artwork that plays, a caption that
/// navigates. Split that way because wrapping the whole card in a link swallowed the play button's
/// click, so the button was a lie.
struct MediaCard<Cover: View, Caption: View>: View {
    /// Resolving a set takes a request; the button says so rather than looking dead for a second.
    var isBusy = false
    var isPlaying = false
    let play: () -> Void
    @ViewBuilder let cover: Cover
    @ViewBuilder let caption: Caption

    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    private var isRevealed: Bool { hovering || isBusy || isPlaying }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: play) {
                ZStack {
                    cover
                    // Held in the tree at zero opacity rather than inserted on hover: an `if` pops
                    // the scrim and the button in, and there is nothing there to fade.
                    ZStack {
                        Color.black.opacity(0.3)
                        PlayFAB(size: 40, isStarting: isBusy, isPlaying: isPlaying)
                            .scaleEffect(isRevealed ? 1 : 0.88)
                    }
                    .opacity(isRevealed ? 1 : 0)
                }
                .frame(width: metrics.card, height: metrics.card)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: isRevealed)
            }
            .buttonStyle(.plain)

            caption
        }
        .frame(width: metrics.card, alignment: .leading)
        .onHover { hovering = $0 }
    }
}

struct PlayFAB: View {
    let size: CGFloat
    var isStarting = false
    var isPlaying = false

    var body: some View {
        Circle()
            .fill(.tint)
            .frame(width: size, height: size)
            .overlay {
                if isStarting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.38))
                        .foregroundStyle(.white)
                }
            }
    }
}

/// Title over subtitle, sized and clipped the same on every card so a shelf and a grid of them
/// line up. The whole block is the navigation target.
struct CardCaption: View {
    let title: String
    let subtitle: String
    var isCurrent = false

    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: metrics.card, alignment: .leading)
        .contentShape(Rectangle())
    }
}
