import Foundation
import SwiftUI

extension Color {
    /// SoundCloud's signature orange, used as the app-wide accent.
    static let scOrange = Color(red: 1.0, green: 0.333, blue: 0.0)
    /// The mark's plate — a warm near-black, not a neutral one, so it sits with the orange.
    static let nimbusInk = Color(red: 0.118, green: 0.075, blue: 0.067)
    /// The mark's letterform: bone rather than pure white, which reads cold against the orange.
    static let nimbusBone = Color(red: 0.961, green: 0.894, blue: 0.863)
}

extension Optional where Wrapped == String {
    /// SoundCloud's own image view treats a default avatar as no image at all and paints a gradient
    /// instead. Matched on the substring because three variants are live — large, tiny and badge.
    var liveArtwork: String? {
        guard let raw = self, !raw.contains("default_avatar") else { return nil }
        return raw
    }

    /// SoundCloud serves 100px `-large` artwork by default. Swap in a higher-res variant so large
    /// cards and headers aren't upscaled and blurry. Only `ArtworkSize` spells the variant: the
    /// substitution is unvalidated, so an invented name yields a silently dead URL.
    func scArtwork(_ size: ArtworkSize) -> URL? {
        guard let raw = self else { return nil }
        return URL(string: raw.replacingOccurrences(of: "-large.", with: "-\(size.rawValue)."))
    }
}
