import AVFoundation
import Foundation

/// Feeds a SoundCloud AAC-HLS (fMP4/CMAF) stream to AVPlayer through a custom URL scheme.
///
/// CloudFront signs the playlist/segment URLs for only a few minutes. Instead of swapping
/// the AVPlayerItem (which rebuffers and glitches), we keep ONE continuous item: the media
/// playlist is served with stable custom-scheme refs, and every segment / init-map request
/// is REDIRECTED to a freshly signed CDN URL. AVFoundation fetches and decodes those
/// natively (the resource loader only supports redirects for HLS media, not raw data),
/// while we transparently refresh the signatures underneath — so a long track never 403s
/// and playback never breaks.
nonisolated final class HLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let playlistScheme = "nimbushls"
    static let segmentScheme = "nimbusseg"
    static let mapScheme = "nimbusmap"
    static var assetURL: URL { URL(string: "\(playlistScheme)://stream/media.m3u8")! }

    let queue = DispatchQueue(label: "io.github.dearonski.Nimbus.hls")
    private let store: HLSStreamStore

    init(api: SoundCloudAPI, transcoding: SCTranscoding, trackAuthorization: String) {
        store = HLSStreamStore(api: api, transcoding: transcoding, trackAuthorization: trackAuthorization)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let box = RequestBox(loadingRequest)
        Task { await handle(box) }
        return true
    }

    private func handle(_ box: RequestBox) async {
        let request = box.request
        guard let url = request.request.url, let scheme = url.scheme else {
            request.finishLoading(with: URLError(.badURL)); return
        }
        do {
            switch scheme {
            case Self.playlistScheme:
                serveData(request, try await store.servedPlaylistData(), contentType: "public.m3u8-playlist")
            case Self.segmentScheme:
                let index = Int(url.lastPathComponent) ?? -1
                redirect(request, to: try await store.segmentURL(index: index))
            case Self.mapScheme:
                redirect(request, to: try await store.mapURL())
            default:
                request.finishLoading(with: URLError(.unsupportedURL))
            }
        } catch {
            request.finishLoading(with: error)
        }
    }

    private func redirect(_ request: AVAssetResourceLoadingRequest, to url: URL) {
        request.redirect = URLRequest(url: url)
        request.response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)
        request.finishLoading()
    }

    private func serveData(_ request: AVAssetResourceLoadingRequest, _ data: Data, contentType: String) {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let dataRequest = request.dataRequest {
            let offset = Int(dataRequest.currentOffset)
            if offset < data.count {
                let length = dataRequest.requestsAllDataToEndOfResource
                    ? data.count - offset
                    : min(dataRequest.requestedLength, data.count - offset)
                dataRequest.respond(with: data.subdata(in: offset..<(offset + length)))
            }
        }
        request.finishLoading()
    }
}

private nonisolated struct RequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
}

/// Holds the live segment/map map and refreshes the signed URLs before they expire.
private actor HLSStreamStore {
    private let api: SoundCloudAPI
    private let transcoding: SCTranscoding
    private let trackAuthorization: String

    /// Playlist lines with segment + map URLs replaced by stable custom-scheme refs.
    private var template: [String] = []
    /// index → freshly signed CDN segment URL.
    private var segmentURLs: [URL] = []
    /// Freshly signed fMP4 init-segment URL (`#EXT-X-MAP`).
    private var initMapURL: URL?
    private var lastRefresh = Date.distantPast
    private var refreshTask: Task<Void, Error>?

    private let refreshInterval: TimeInterval = 180

    init(api: SoundCloudAPI, transcoding: SCTranscoding, trackAuthorization: String) {
        self.api = api
        self.transcoding = transcoding
        self.trackAuthorization = trackAuthorization
    }

    func servedPlaylistData() async throws -> Data {
        try await refreshIfNeeded()
        return Data(template.joined(separator: "\n").utf8)
    }

    func segmentURL(index: Int) async throws -> URL {
        try await refreshIfNeeded()
        guard segmentURLs.indices.contains(index) else { throw SCError.badResponse }
        return segmentURLs[index]
    }

    func mapURL() async throws -> URL {
        try await refreshIfNeeded()
        guard let initMapURL else { throw SCError.badResponse }
        return initMapURL
    }

    private func refreshIfNeeded() async throws {
        if !segmentURLs.isEmpty, Date().timeIntervalSince(lastRefresh) < refreshInterval { return }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await doRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func doRefresh() async throws {
        let playlistURL = try await api.streamURL(
            for: transcoding, trackAuthorization: trackAuthorization)
        var (text, base) = try await fetchText(playlistURL)

        if text.contains("#EXT-X-STREAM-INF"), let variant = Self.firstURI(in: text, base: base) {
            (text, base) = try await fetchText(variant)
        }

        var newTemplate: [String] = []
        var urls: [URL] = []
        var mapURL: URL?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let uri = Self.mapURI(in: trimmed), let resolved = URL(string: uri, relativeTo: base)?.absoluteURL {
                mapURL = resolved
                newTemplate.append("#EXT-X-MAP:URI=\"\(HLSResourceLoader.mapScheme)://init.mp4\"")
            } else if trimmed.hasPrefix("#") || trimmed.isEmpty {
                newTemplate.append(line)
            } else if let segmentURL = URL(string: trimmed, relativeTo: base)?.absoluteURL {
                newTemplate.append("\(HLSResourceLoader.segmentScheme)://seg/\(urls.count)")
                urls.append(segmentURL)
            }
        }

        if template.isEmpty { template = newTemplate }
        segmentURLs = urls
        initMapURL = mapURL
        lastRefresh = Date()
    }

    private func fetchText(_ url: URL) async throws -> (String, URL) {
        let (data, _) = try await URLSession.shared.data(from: url)
        return (String(decoding: data, as: UTF8.self), url)
    }

    private static func mapURI(in line: String) -> String? {
        guard line.hasPrefix("#EXT-X-MAP:"), let range = line.range(of: "URI=\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func firstURI(in playlist: String, base: URL) -> URL? {
        for raw in playlist.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix("#"), !line.isEmpty {
                return URL(string: line, relativeTo: base)?.absoluteURL
            }
        }
        return nil
    }
}
