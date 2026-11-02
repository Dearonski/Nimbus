import Foundation
import Observation

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

    /// Averages the peaks down to `count` buckets so the strip draws one bar per bucket
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
