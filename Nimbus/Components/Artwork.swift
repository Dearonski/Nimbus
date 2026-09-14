import Nuke
import NukeUI
import SwiftUI

enum ArtworkSize: String {
    /// SoundCloud already serves `-large` at 100px, so this variant substitutes onto itself.
    case thumb = "large"
    case mid = "t300x300"
    case hero = "t500x500"
    /// The upload itself, at whatever size it was made. `t1080x1080` and `t3000x3000` also answer,
    /// but they are the same picture scaled up — measured: a 500px cover comes back 3000px wide.
    case original = "original"
}

/// What to draw when there is no image: a neutral tint where the surface has no identity to key a
/// gradient on, and SoundCloud's own gradient everywhere it does.
enum ArtworkFallback: Equatable {
    case tint(Double)
    case gradient(Int)
}

struct Artwork: View {
    let url: URL?
    var placeholderOpacity: Double = 0.15
    var fallback: ArtworkFallback = .tint(0.15)

    init(url: URL?, placeholderOpacity: Double = 0.15) {
        self.url = url
        self.placeholderOpacity = placeholderOpacity
        self.fallback = .tint(placeholderOpacity)
    }

    init(_ track: SCTrack?, size: ArtworkSize) {
        self.url = track?.coverURL.liveArtwork.scArtwork(size)
        self.fallback = track.map { .gradient(SCGradient.index(for: $0.id)) } ?? .tint(0.15)
    }

    init(_ user: SCUser?, size: ArtworkSize, placeholderOpacity: Double = 0.15) {
        self.url = user?.avatarURL.liveArtwork.scArtwork(size)
        self.placeholderOpacity = placeholderOpacity
        self.fallback = user.map { .gradient(SCGradient.index(for: $0.id)) }
            ?? .tint(placeholderOpacity)
    }

    /// An artist's header visual. Falls back to the user's gradient rather than a flat tint —
    /// the site paints a plain grey there, which reads as a hole in a dark interface.
    init(banner user: SCUser) {
        self.url = user.bannerURL.flatMap(URL.init)
        // Deliberately offset from the avatar's own gradient — 5 is coprime with the twelve, so
        // the two never land on the same pair and the avatar cannot vanish into the banner.
        self.fallback = .gradient(SCGradient.index(for: user.id &+ 5))
    }

    init(_ playlist: SCPlaylist, size: ArtworkSize) {
        self.url = playlist.coverURL.liveArtwork.scArtwork(size)
        self.fallback = .gradient(SCGradient.index(for: playlist.id))
    }

    var body: some View {
        if let url, !DeadArtwork.contains(url) {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else if state.error != nil {
                    placeholder
                } else {
                    // Gated on `error`, never a bare `else`: the closure runs once before the load
                    // starts, and a looser test flashes the fallback on every cover in the app.
                    Color.secondary.opacity(placeholderOpacity)
                }
            }
            .onCompletion { DeadArtwork.record($0, for: url) }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch fallback {
        case .tint(let opacity): Color.secondary.opacity(opacity)
        case .gradient(let index): SCGradient(index: index)
        }
    }
}

/// Assets SoundCloud has deleted, remembered for the session so a list scrolled up and down does
/// not re-request each dead cover on every row that comes back on screen.
@MainActor
enum DeadArtwork {
    private static var stems: Set<String> = []

    static func contains(_ url: URL) -> Bool { stems.contains(stem(url)) }

    /// Only a real deletion counts. Admitting a transient failure would let one dropped connection
    /// blank every cover on screen for the rest of the session.
    static func record(_ result: Result<ImageResponse, Error>, for url: URL) {
        guard case .failure(let error) = result,
              let pipelineError = error as? ImagePipeline.Error,
              case .dataLoadingFailed(let underlying) = pipelineError,
              let loaderError = underlying as? DataLoader.Error,
              case .statusCodeUnacceptable(let code) = loaderError,
              code == 404 || code == 410
        else { return }
        stems.insert(stem(url))
    }

    /// Keyed on the filename without its size suffix: Nuke keys its cache per URL, so a dead
    /// `t500x500` would otherwise let `t300x300` fire a fresh request for the same missing asset.
    private static func stem(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard let cut = name.lastIndex(of: "-") else { return name }
        return String(name[name.startIndex..<cut])
    }
}
