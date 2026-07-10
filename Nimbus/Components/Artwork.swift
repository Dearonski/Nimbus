import NukeUI
import SwiftUI

struct Artwork: View {
    let url: URL?
    var body: some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.15)
            }
        }
    }
}
