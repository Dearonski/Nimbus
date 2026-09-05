import NukeUI
import SwiftUI

enum ArtworkSize: String {
    /// SoundCloud already serves `-large` at 100px, so this variant substitutes onto itself.
    case thumb = "large"
    case mid = "t300x300"
    case hero = "t500x500"
}

struct Artwork: View {
    let url: URL?
    var placeholderOpacity: Double = 0.15

    init(url: URL?, placeholderOpacity: Double = 0.15) {
        self.url = url
        self.placeholderOpacity = placeholderOpacity
    }

    init(_ artworkURL: String?, size: ArtworkSize, placeholderOpacity: Double = 0.15) {
        self.url = artworkURL.scArtwork(size)
        self.placeholderOpacity = placeholderOpacity
    }

    var body: some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(placeholderOpacity)
            }
        }
    }
}
