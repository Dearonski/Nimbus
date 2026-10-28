import SwiftUI

/// A titled block: a quiet uppercase label with an optional control opposite it, the way the site
/// heads every panel in this column.
struct RailBlock<Content: View>: View {
    let title: String
    var action: String?
    var run: (() -> Void)?
    var destination: (any Hashable)?
    @ViewBuilder let content: Content

    init(title: String, action: String? = nil, destination: (any Hashable)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.destination = destination
        self.content = content()
    }

    init(title: String, action: String?, run: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.run = run
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if let action {
                    if let destination {
                        NavButton(value: destination) { actionLabel(action) }
                    } else if let run {
                        Button(action: run) { actionLabel(action) }.buttonStyle(.plain)
                    }
                }
            }
            content
        }
    }

    private func actionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
    }
}

/// Who made it, with the follow control right there — the card that opens the column beside a
/// track or a set.
struct RailArtistCard: View {
    let artist: SCUser
    let model: AppModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                NavButton(value: artist) {
                    Artwork(artist, size: .mid)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    NavButton(value: artist) {
                        VerifiedName(artist, seal: .system(size: 12))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    if let city = artist.city, !city.isEmpty {
                        Text(city).font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    Text("\(countString(artist.followersCount ?? 0)) followers · "
                         + "\(countString(artist.trackCount ?? 0)) tracks")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                let isFollowing = model.library.isFollowing(artist)
                Button { model.library.toggleFollow(artist) } label: {
                    Label(isFollowing ? "Following" : "Follow",
                          systemImage: isFollowing ? "checkmark" : "plus")
                        .frame(maxWidth: .infinity)
                }
                .glassButton(.prominent)

                if let messages = messagesURL {
                    Button { openURL(messages) } label: {
                        Label("Message", systemImage: "envelope").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
            }
            .glassButtonRow()
        }
        .padding(16)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
    }

    private var messagesURL: URL? {
        guard let permalink = artist.permalinkURL?.split(separator: "/").last, !permalink.isEmpty
        else { return nil }
        return URL(string: "https://soundcloud.com/messages/\(permalink)")
    }
}

/// "Fans also like" — an artist per row with the follow control right there, so the whole point of
/// the block (finding someone new to follow) takes one click.
struct ArtistFanList: View {
    let artists: [SCUser]
    let library: LibraryStore
    var wide = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: 24, alignment: .leading)]
    }

    var body: some View {
        if wide {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(artists) { FanRow(artist: $0, library: library) }
            }
        } else {
            VStack(spacing: 4) {
                ForEach(artists) { FanRow(artist: $0, library: library) }
            }
        }
    }
}

private struct FanRow: View {
    let artist: SCUser
    let library: LibraryStore

    private var isFollowing: Bool { library.isFollowing(artist) }

    var body: some View {
        HStack(spacing: 12) {
            NavButton(value: artist) {
                HStack(spacing: 12) {
                    Artwork(artist, size: .mid)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        VerifiedName(artist, seal: .system(size: 11))
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 12) {
                            Label(countString(artist.followersCount ?? 0), systemImage: "person.fill")
                            Label(countString(artist.trackCount ?? 0), systemImage: "waveform")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // Neutral, not tinted: three orange buttons stacked down the rail read as the page's
            // main action, and the page's main action is the Follow up in the header.
            Button(isFollowing ? "Following" : "Follow") { library.toggleFollow(artist) }
                .glassButton()
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

/// The overlapping strip of faces the site puts under the follower count. Purely a sample — the
/// count above it is the real number.
struct FollowerFaces: View {
    let followers: [SCUser]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(followers) { follower in
                NavButton(value: follower) {
                    Artwork(follower, size: .thumb)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        .overlay { Circle().strokeBorder(Color(nsColor: .windowBackgroundColor),
                                                          lineWidth: 2) }
                        .help(follower.username)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
