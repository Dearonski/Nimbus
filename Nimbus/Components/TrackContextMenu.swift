import AppKit
import SwiftUI

extension View {
    func trackContextMenu(_ track: SCTrack, player: PlayerEngine) -> some View {
        contextMenu {
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
        }
    }
}
