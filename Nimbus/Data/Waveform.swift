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

    private init(peaks: [Float]) {
        self.peaks = peaks
    }

    /// Drawn where SoundCloud has no peaks for a track yet, as the site does, so the playhead still shows.
    static let flat = Waveform(peaks: Array(repeating: 0.12, count: 1800))

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
    private var waveform: Waveform?
    /// The last URL that answered with nothing usable — a fresh upload has no peaks for a while.
    private var unavailableURL: String?
    @ObservationIgnored private var loadedURL: String?
    @ObservationIgnored private var owner: String?

    /// Asked per track rather than read as state: a recycled cell keeps this loader, and its last
    /// track's peaks must not be drawn under the next one — nor a warm cache wait for `load`.
    func peaks(for urlString: String?) -> Waveform? {
        // Read before anything can return: a body that never touched it is not redrawn when the fetch lands.
        let loaded = waveform
        guard let urlString else { return nil }
        if owner == urlString, let loaded { return loaded }
        return Self.cache.object(forKey: urlString as NSString)?.waveform
    }

    func isUnavailable(_ urlString: String?) -> Bool {
        urlString == nil || unavailableURL == urlString
    }

    private final class Box {
        let waveform: Waveform
        init(_ waveform: Waveform) { self.waveform = waveform }
    }

    // Parsed peaks, not the JSON: a row coming back on screen used to decode 1800 samples on the main thread.
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()

    /// Call from `.task`, so that a card flung past cancels its download instead of finishing it.
    func load(_ urlString: String?) async {
        guard loadedURL != urlString else { return }
        loadedURL = urlString
        // Cached peaks are already on screen through `peaks(for:)`; writing state would only redraw the card.
        guard let urlString, let url = URL(string: urlString),
              Self.cache.object(forKey: urlString as NSString) == nil else { return }
        guard let parsed = await Self.fetch(url) else {
            if loadedURL == urlString {
                loadedURL = nil
                unavailableURL = urlString
            }
            return
        }
        Self.cache.setObject(Box(parsed), forKey: urlString as NSString)
        guard loadedURL == urlString else { return }
        owner = urlString
        waveform = parsed
        if unavailableURL == urlString { unavailableURL = nil }
    }

    private static var warming: Set<String> = []

    /// Peaks for rows about to scroll in, so a strip arrives drawn instead of filling in afterwards.
    static func warm(_ urlStrings: [String?]) {
        for case let urlString? in urlStrings {
            guard cache.object(forKey: urlString as NSString) == nil, !warming.contains(urlString),
                  let url = URL(string: urlString) else { continue }
            warming.insert(urlString)
            Task {
                if let parsed = await fetch(url) { cache.setObject(Box(parsed), forKey: urlString as NSString) }
                warming.remove(urlString)
            }
        }
    }

    @concurrent
    nonisolated private static func fetch(_ url: URL) async -> Waveform? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return Waveform(data: data)
    }

#if DEBUG
    /// Lets a preview put peaks behind a fake `waveform_url`, so views that load their own
    /// waveform draw one without a network.
    static func seedCache(_ urlString: String, json: String) {
        guard let waveform = Waveform(data: Data(json.utf8)) else { return }
        cache.setObject(Box(waveform), forKey: urlString as NSString)
    }
#endif
}

/// SoundCloud's signature object, drawn for real: peaks resampled to the available width,
/// the played span filled with the accent and the rest left as a ghost.
///
/// Each colour is its own layer of bars, drawn once and windowed by a mask. The playhead moves
/// every frame while a track plays, and moving a mask costs nothing where redrawing a few hundred
/// rounded bars would; it also lets the fill stop part-way across a bar instead of a bar at a time.
struct WaveformView: View {
    let waveform: Waveform?
    var progress: Double = 0
    /// Where the pointer sits, if it is over the strip. Bars up to it fill with a dimmer accent —
    /// SoundCloud previews the seek by extending the fill rather than by drawing a marker.
    var hoverProgress: Double = 0
    var remainingColor: Color = .primary
    /// How lit the whole strip is, 0 to 1. Set while this is not the track playing: there is no
    /// playhead to preview a seek against, so hovering lights everything instead.
    var highlight: Double = 0

    /// Anything drawn over the strip — comment faces, time badges, the loading skeleton — has to
    /// find where the bars stand, so the geometry lives here rather than as numbers copied around.
    nonisolated static let barWidth: CGFloat = 3
    nonisolated static let barSpacing: CGFloat = 1
    /// Share of the height given to the upright bars; the rest is the dimmer reflection below the
    /// centre line, as on SoundCloud.
    nonisolated static let topRatio: CGFloat = 0.68
    nonisolated static let centreGap: CGFloat = 2
    private static let playedColor: Color = .scOrange

    nonisolated static func barsBottom(in height: CGFloat) -> CGFloat {
        (height - centreGap) * topRatio
    }

    /// The run the bars actually cover: a whole number of slots, short of the width by under one.
    nonisolated static func barsSpan(in width: CGFloat) -> CGFloat {
        CGFloat(max(Int(width / (barWidth + barSpacing)), 1)) * (barWidth + barSpacing)
    }

    var body: some View {
        let played = min(max(progress, 0), 1)
        let hovered = min(max(hoverProgress, 0), 1)
        // With the pointer down the strip the fill runs to it in both directions: bars the
        // click would keep stay solid, bars it would give up (or gain) go dim, so hovering
        // behind the playhead reads as "this would rewind" instead of looking inert.
        let solid = hovered > 0 ? min(hovered, played) : played
        let dim = hovered > 0 ? max(hovered, played) : played

        ZStack {
            if let waveform {
                // The reflection tracks real playback only: letting the hover preview reach it made
                // the whole strip flicker as the pointer swept across.
                WaveformBars(waveform: waveform, top: remainingColor.opacity(0.22), bottom: remainingColor.opacity(0.1))
                    .equatable()
                    .mask { WaveformRunMask(top: dim...1, bottom: played...1) }
                WaveformBars(waveform: waveform, top: Self.playedColor.opacity(0.45), bottom: nil)
                    .equatable()
                    .mask { WaveformRunMask(top: solid...dim, bottom: nil) }
                WaveformBars(waveform: waveform, top: Self.playedColor, bottom: Self.playedColor.opacity(0.35))
                    .equatable()
                    .mask { WaveformRunMask(top: 0...solid, bottom: 0...played) }
                WaveformBars(waveform: waveform, top: remainingColor.opacity(0.42), bottom: remainingColor.opacity(0.16))
                    .equatable()
                    .opacity(highlight)
            }
        }
        .animation(.default, value: waveform == nil)
    }
}

/// One colour's worth of bars. Equatable so a moving playhead, which only reaches the masks,
/// never has SwiftUI run the Canvas again.
private struct WaveformBars: View, Equatable {
    let waveform: Waveform
    let top: Color
    let bottom: Color?

    /// macOS 26 shifts parts of a Canvas path holding many rounded rects (issue #1); eight per path draw right.
    private static let barsPerFill = 8

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.top == rhs.top && lhs.bottom == rhs.bottom && lhs.waveform.peaks == rhs.waveform.peaks
    }

    var body: some View {
        Canvas { context, size in
            let slot = WaveformView.barWidth + WaveformView.barSpacing
            let bars = waveform.resampled(to: max(Int(size.width / slot), 1))
            let topHeight = WaveformView.barsBottom(in: size.height)
            let bottomHeight = size.height - WaveformView.centreGap - topHeight
            let corner = CGSize(width: WaveformView.barWidth / 2, height: WaveformView.barWidth / 2)

            for first in stride(from: 0, to: bars.count, by: Self.barsPerFill) {
                var upper = Path()
                var lower = Path()
                for index in first..<min(first + Self.barsPerFill, bars.count) {
                    let x = CGFloat(index) * slot
                    let rise = max(CGFloat(bars[index]) * topHeight, 2)
                    upper.addRoundedRect(in: CGRect(x: x, y: topHeight - rise, width: WaveformView.barWidth, height: rise),
                                         cornerSize: corner)
                    if bottom != nil {
                        let drop = max(CGFloat(bars[index]) * bottomHeight, 1)
                        lower.addRoundedRect(in: CGRect(x: x, y: topHeight + WaveformView.centreGap,
                                                        width: WaveformView.barWidth, height: drop),
                                             cornerSize: corner)
                    }
                }
                context.fill(upper, with: .color(top))
                if let bottom { context.fill(lower, with: .color(bottom)) }
            }
        }
    }
}

/// The window one layer shows through: a span of the upright bars and, separately, of the reflection.
private nonisolated struct WaveformRunMask: Shape {
    let top: ClosedRange<Double>
    let bottom: ClosedRange<Double>?

    func path(in rect: CGRect) -> Path {
        let span = WaveformView.barsSpan(in: rect.width)
        let split = WaveformView.barsBottom(in: rect.height) + WaveformView.centreGap / 2
        func run(_ range: ClosedRange<Double>, _ y: CGFloat, _ height: CGFloat) -> CGRect {
            let start = span * range.lowerBound
            // The far end of the strip runs to the edge, so no sliver past the last slot is left out.
            let end = range.upperBound >= 1 ? rect.width : span * range.upperBound
            return CGRect(x: start, y: y, width: max(end - start, 0), height: height)
        }
        var path = Path()
        path.addRect(run(top, 0, split))
        if let bottom { path.addRect(run(bottom, split, rect.height - split)) }
        return path
    }
}
