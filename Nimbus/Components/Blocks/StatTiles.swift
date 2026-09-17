import SwiftUI

/// A row of count tiles, one big number over a quiet label each, sharing the width equally. Every
/// page's counts go through here — a track's plays, a set's tracks, a profile's followers — so they
/// can't drift apart again the way the profile's label-over-number block did.
struct StatTiles: View {
    struct Stat: Identifiable {
        let label: String
        let value: Int?
        /// Where the tile leads when its number has a list behind it, as a profile's followers do
        /// on the site.
        var destination: (any Hashable)?

        var id: String { label }
    }

    let stats: [Stat]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(stats) { stat in
                if let destination = stat.destination {
                    NavButton(value: destination) { StatTile(stat: stat, isLink: true) }
                        .buttonStyle(.plain)
                } else {
                    StatTile(stat: stat, isLink: false)
                }
            }
        }
    }
}

/// One tile. A tile with a list behind it lights up under the pointer, and only that one — flat,
/// not glass: glass in this app marks controls, and next to a tile that leads nowhere it would make
/// all of them look pressable.
private struct StatTile: View {
    let stat: StatTiles.Stat
    let isLink: Bool
    /// Lets a #Preview show the hover state, which has no pointer to produce it.
    var forceHover = false

    @State private var hovering = false

    private var lit: Bool { isLink && (hovering || forceHover) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        VStack(spacing: 2) {
            Text(countString(stat.value ?? 0))
                .font(.system(size: 19, weight: .bold))
                .monospacedDigit()
            Text(stat.label)
                .font(.system(size: 11))
                .foregroundStyle(lit ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.primary.opacity(lit ? 0.1 : 0.05), in: shape)
        .overlay { shape.strokeBorder(.primary.opacity(lit ? 0.18 : 0.07)) }
        .contentShape(shape)
        .onHover { hovering = $0 }
        .pointerStyle(isLink ? .link : nil)
        .animation(.easeOut(duration: 0.12), value: lit)
    }
}

extension StatTiles {
    static func track(_ track: SCTrack) -> StatTiles {
        StatTiles(stats: [
            Stat(label: "Plays", value: track.playbackCount),
            Stat(label: "Likes", value: track.likesCount),
            Stat(label: "Reposts", value: track.repostsCount),
        ])
    }

    static func playlist(_ playlist: SCPlaylist, trackCount: Int) -> StatTiles {
        StatTiles(stats: [
            Stat(label: "Tracks", value: trackCount),
            Stat(label: "Likes", value: playlist.likesCount),
            Stat(label: "Reposts", value: playlist.repostsCount),
        ])
    }

    static func profile(_ user: SCUser) -> StatTiles {
        StatTiles(stats: [
            Stat(label: "Followers", value: user.followersCount, destination: ProfileList.followers(user)),
            Stat(label: "Following", value: user.followingsCount, destination: ProfileList.following(user)),
            Stat(label: "Tracks", value: user.trackCount),
        ])
    }
}


#if DEBUG
#Preview("Stat tiles") {
    // Followers under the pointer; Following is a link at rest; Tracks leads nowhere.
    HStack(spacing: 8) {
        StatTile(stat: .init(label: "Followers", value: 72_855), isLink: true, forceHover: true)
        StatTile(stat: .init(label: "Following", value: 12), isLink: true)
        StatTile(stat: .init(label: "Tracks", value: 108), isLink: false)
    }
    .frame(width: 320)
    .padding(20)
    .background(Color(nsColor: .windowBackgroundColor))
}
#endif
