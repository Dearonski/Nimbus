import AppKit
import SwiftUI

/// What every menu offers for a page's own link: copy it, open it on the site, and share it.
struct LinkMenuItems: View {
    let url: URL
    /// Off where a Share button already stands beside the menu.
    var share = true

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        Button("Open in SoundCloud", systemImage: "safari") { openURL(url) }
        if share {
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
    }
}
