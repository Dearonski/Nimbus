import AVFoundation
import Foundation

/// Plays SoundCloud's FairPlay-encrypted (cbcs / SAMPLE-AES) AAC by driving Apple's own
/// FairPlay client. This is the intended DRM flow — the same one the SoundCloud web player
/// uses — not a circumvention: we fetch the public app certificate, let AVFoundation build
/// the SPC, POST it to SoundCloud's license server (authorized by the per-stream
/// `licenseAuthToken`), and hand the returned CKC back to AVFoundation for secure decode.
nonisolated final class FairPlayKeyDelegate: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    static let endpoint = URL(string: "https://license.media-streaming.soundcloud.cloud/playback/fairplay")!

    let queue = DispatchQueue(label: "io.github.dearonski.Nimbus.fairplay")
    private let licenseAuthToken: String
    private let lock = NSLock()
    private var invalidated = false

    init(licenseAuthToken: String) {
        self.licenseAuthToken = licenseAuthToken
    }

    /// Answering a key request whose session has been torn down (the user skipped tracks while the
    /// license was in flight) makes AVFoundation raise an ObjC exception, which Swift cannot catch.
    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    private var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        Task { await handle(keyRequest) }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest
    ) {
        Task { await handle(keyRequest) }
    }

    private func handle(_ keyRequest: AVContentKeyRequest) async {
        guard !isInvalidated else { return }
        guard let identifier = keyRequest.identifier as? String,
              let assetID = assetID(from: identifier) else {
            keyRequest.processContentKeyResponseError(SCError.badResponse)
            return
        }
        do {
            let certificate = try await fetchCertificate()
            let spc = try await keyRequest.makeStreamingContentKeyRequestData(
                forApp: certificate, contentIdentifier: Data(assetID.utf8), options: nil)
            let ckc = try await fetchCKC(spc: spc, assetID: assetID)
            guard !isInvalidated else { return }
            guard Self.isPlausibleCKC(ckc) else { throw SCError.badResponse }
            keyRequest.processContentKeyResponse(
                AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
        } catch {
            guard !isInvalidated else { return }
            keyRequest.processContentKeyResponseError(error)
        }
    }

    /// A CKC is opaque binary. Server errors arrive as JSON or HTML, and feeding those to
    /// `processContentKeyResponse` aborts the process instead of failing the request.
    private static func isPlausibleCKC(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first != UInt8(ascii: "{") && first != UInt8(ascii: "<")
    }

    private func assetID(from skd: String) -> String? {
        guard let range = skd.range(of: "skd://") else { return skd.isEmpty ? nil : skd }
        return String(skd[range.upperBound...])
    }

    private func fetchCertificate() async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("https://soundcloud.com", forHTTPHeaderField: "Origin")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        return data
    }

    private func fetchCKC(spc: Data, assetID: String) async throws -> Data {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "license_token", value: licenseAuthToken),
            URLQueryItem(name: "assetId", value: assetID),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://soundcloud.com", forHTTPHeaderField: "Origin")
        request.httpBody = Data("spc=\(spc.base64EncodedString())&assetId=\(assetID)".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        return Self.parseCKC(data)
    }

    /// The endpoint may return the CKC raw or base64-encoded text.
    private static func parseCKC(_ data: Data) -> Data {
        if let text = String(data: data, encoding: .utf8),
           let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return decoded
        }
        return data
    }

    private static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw SCError.http(code) }
    }
}
