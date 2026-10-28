import SwiftUI

/// A post in a list the way the site lays one out: its cover on the left, and beside it the byline,
/// the title row and whatever the post carries.
struct PostCard<Cover: View, Content: View>: View {
    @ViewBuilder let cover: () -> Cover
    @ViewBuilder let content: () -> Content

    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            cover()
                .frame(width: metrics.listArtwork, height: metrics.listArtwork)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .padding(.vertical, 4)
    }
}

/// Who posted it, and who reposted it into this feed.
struct PostByline: View {
    let author: SCUser?
    let name: String
    var reposter: SCUser?

    var body: some View {
        HStack(spacing: 5) {
            if let author { link(author, name) }
            if let reposter {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.tint)
                link(reposter, reposter.username)
            }
        }
    }

    private func link(_ user: SCUser, _ text: String) -> some View {
        NavButton(value: user) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}
