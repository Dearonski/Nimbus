import AppKit
import SwiftUI

extension View {
    func trackContextMenu(_ track: SCTrack, player: PlayerEngine) -> some View {
        modifier(TrackContextMenu(track: track, player: player))
    }
}

/// Everything a track can do that isn't worth a button of its own — the row itself keeps only play,
/// like and repost, the way SoundCloud does.
private struct TrackContextMenu: ViewModifier {
    let track: SCTrack
    let player: PlayerEngine

    @Environment(LibraryStore.self) private var library: LibraryStore?
    @Environment(\.openURL) private var openURL

    private var isLiked: Bool { library?.isLiked(track) ?? false }
    private var isReposted: Bool { library?.isReposted(track) ?? false }
    private var url: URL? { URL(string: track.permalinkURL) }

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(isLiked ? "Unlike" : "Like",
                   systemImage: isLiked ? "heart.slash" : "heart") {
                library?.toggleLike(track)
            }
            Button(isReposted ? "Remove Repost" : "Repost",
                   systemImage: "arrow.2.squarepath") {
                library?.toggleRepost(track)
            }

            Divider()

            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.playNext(track)
            }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                player.playLater(track)
            }

            Divider()

            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(track.permalinkURL, forType: .string)
            }
            if let url {
                Button("Open in SoundCloud", systemImage: "safari") { openURL(url) }
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
        }
    }
}
