import Foundation
import Observation
import SwiftUI

/// SoundCloud's per-track peak data, served from `wave.sndcdn.com` as `{width, height, samples}`.
/// Samples are absolute peaks in `0...height`; we normalise once at decode time.
nonisolated struct Waveform: Sendable {
    let peaks: [Float]

    init?(data: Data) {
        struct Payload: Decodable {
            let height: Int
            let samples: [Int]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.height > 0, !payload.samples.isEmpty else { return nil }
        let height = Float(payload.height)
        peaks = payload.samples.map { min(max(Float($0) / height, 0), 1) }
    }

    /// Averages the peaks down to `count` buckets so a Canvas draws one bar per bucket
    /// regardless of how wide it is on screen.
    func resampled(to count: Int) -> [Float] {
        guard count > 0, peaks.count > count else { return peaks }
        let stride = Float(peaks.count) / Float(count)
        return (0..<count).map { index in
            let start = Int(Float(index) * stride)
            let end = min(Int(Float(index + 1) * stride), peaks.count)
            guard start < end else { return peaks[min(start, peaks.count - 1)] }
            return peaks[start..<end].reduce(0, +) / Float(end - start)
        }
    }
}

@MainActor
@Observable
final class WaveformLoader {
    private(set) var waveform: Waveform?
    private var loadedURL: String?

    private static let cache = NSCache<NSString, NSData>()

    func load(_ urlString: String?) {
        guard loadedURL != urlString else { return }
        loadedURL = urlString
        waveform = nil
        guard let urlString, let url = URL(string: urlString) else { return }

        if let cached = Self.cache.object(forKey: urlString as NSString) {
            waveform = Waveform(data: cached as Data)
            return
        }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            guard loadedURL == urlString else { return }
            Self.cache.setObject(data as NSData, forKey: urlString as NSString)
            waveform = Waveform(data: data)
        }
    }

#if DEBUG
    /// Lets a preview put peaks behind a fake `waveform_url`, so views that load their own
    /// waveform draw one without a network.
    static func seedCache(_ urlString: String, json: String) {
        cache.setObject(Data(json.utf8) as NSData, forKey: urlString as NSString)
    }
#endif
}

/// SoundCloud's signature object, drawn for real: peaks resampled to the available width,
/// the played span filled with the accent and the rest left as a ghost.
struct WaveformView: View, Animatable {
    let waveform: Waveform?
    var progress: Double = 0
    /// Where the pointer sits, if it is over the strip. Bars up to it fill with a dimmer accent —
    /// SoundCloud previews the seek by extending the fill rather than by drawing a marker.
    var hoverProgress: Double = 0
    var remainingColor: Color = .primary
    /// How lit the whole strip is, 0 to 1. Set while this is not the track playing: there is no
    /// playhead to preview a seek against, so hovering lights everything instead. Animatable, so
    /// the Canvas is redrawn frame by frame as it fades in — a plain parameter would snap.
    var highlight: Double = 0

    var animatableData: Double {
        get { highlight }
        set { highlight = newValue }
    }

    /// Anything drawn over the strip — comment faces, time badges, the loading skeleton — has to
    /// find where the bars stand, so the geometry lives here rather than as numbers copied around.
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 1
    /// Share of the height given to the upright bars; the rest is the dimmer reflection below the
    /// centre line, as on SoundCloud.
    static let topRatio: CGFloat = 0.68
    static let centreGap: CGFloat = 2
    private static let playedColor: Color = .scOrange

    static func barsBottom(in height: CGFloat) -> CGFloat {
        (height - centreGap) * topRatio
    }

    var body: some View {
        Canvas { context, size in
            let slot = Self.barWidth + Self.barSpacing
            let count = max(Int(size.width / slot), 1)
            guard let bars = waveform?.resampled(to: count) else { return }
            let playedBars = Int(Double(count) * min(max(progress, 0), 1))
            let hoveredBars = Int(Double(count) * min(max(hoverProgress, 0), 1))
            // With the pointer down the strip the fill runs to it in both directions: bars the
            // click would keep stay solid, bars it would give up (or gain) go dim, so hovering
            // behind the playhead reads as "this would rewind" instead of looking inert.
            let solid = hoveredBars > 0 ? min(hoveredBars, playedBars) : playedBars
            let dim = hoveredBars > 0 ? max(hoveredBars, playedBars) : playedBars

            let topHeight = (size.height - Self.centreGap) * Self.topRatio
            let bottomHeight = size.height - Self.centreGap - topHeight

            for (index, peak) in bars.enumerated() {
                let x = CGFloat(index) * slot
                let upper = max(CGFloat(peak) * topHeight, 2)
                let lower = max(CGFloat(peak) * bottomHeight, 1)

                let topColor: Color = if index < solid {
                    Self.playedColor
                } else if index < dim {
                    Self.playedColor.opacity(0.45)
                } else {
                    remainingColor.opacity(0.22)
                }
                // The reflection tracks real playback only: letting the hover preview reach it made
                // the whole strip flicker as the pointer swept across.
                let bottomColor: Color = index < playedBars
                    ? Self.playedColor.opacity(0.35)
                    : remainingColor.opacity(0.1)

                let top = CGRect(x: x, y: topHeight - upper, width: Self.barWidth, height: upper)
                context.fill(Path(roundedRect: top, cornerRadius: Self.barWidth / 2), with: .color(topColor))

                let bottom = CGRect(x: x, y: topHeight + Self.centreGap, width: Self.barWidth, height: lower)
                context.fill(Path(roundedRect: bottom, cornerRadius: Self.barWidth / 2),
                             with: .color(bottomColor))

                if highlight > 0 {
                    context.fill(Path(roundedRect: top, cornerRadius: Self.barWidth / 2),
                                 with: .color(remainingColor.opacity(0.42 * highlight)))
                    context.fill(Path(roundedRect: bottom, cornerRadius: Self.barWidth / 2),
                                 with: .color(remainingColor.opacity(0.16 * highlight)))
                }
            }
        }
        .animation(.default, value: waveform == nil)
    }
}
