import Foundation
import os

/// Thin async wrapper over SoundCloud's internal api-v2.
/// Auth is a harvested `oauth_token`; on 401/403 we refresh the client_id once and retry.
/// Requests themselves live in `Endpoints/`; this file is the transport they go through.

actor SoundCloudAPI {
    static let tokenAccount = "oauth_token"

    private static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Asked for a fresh token when the current one stops being accepted; returns nil when the web
    /// session is gone too, which is the app's cue to show the login screen.
    private var refreshToken: (@Sendable () async -> String?)?

    private var onSessionExpired: (@Sendable () async -> Void)?

    func setRefreshToken(_ handler: @escaping @Sendable () async -> String?) {
        refreshToken = handler
    }

    func setOnSessionExpired(_ handler: @escaping @Sendable () async -> Void) {
        onSessionExpired = handler
    }

    private let base = URL(string: "https://api-v2.soundcloud.com")!

    private let clientIDs = ClientIDResolver()

    private let decoder = JSONDecoder()
    private static let log = Logger(subsystem: "io.github.dearonski.Nimbus", category: "api")

    private var token: String? { Keychain.get(SoundCloudAPI.tokenAccount) }

    func allIDs(_ endpoint: SCEndpoint<SCIDPage>, cap: Int) async throws -> [Int] {
        var ids: [Int] = []
        var page = try await get(endpoint)
        ids.append(contentsOf: page.collection)

        while let next = page.nextHref, ids.count < cap {
            page = try await get(.idPage(after: next))
            ids.append(contentsOf: page.collection)
        }
        return Array(ids.prefix(cap))
    }

    func get<Response>(_ endpoint: SCEndpoint<Response>) async throws -> Response {
        switch endpoint.target {
        case .path(let path):
            try await getDecoded(path: path, query: endpoint.query)
        case .absolute(let url):
            try await getDecoded(absolute: url, query: endpoint.query)
        }
    }

    func send(_ write: SCWrite) async throws {
        try await mutate(method: write.method, path: write.path, json: write.json)
    }

    /// A body-less mutating request (PUT/DELETE like/repost/follow). Uses the web client's auth —
    /// `Authorization` header + `client_id` — and relies on URLSession.shared carrying the
    /// `datadome` cookie synced from the login WebView: api-v2 writes are behind DataDome bot
    /// protection and 403 without it, even though reads aren't gated.
    func mutate(method: String, path: String, json: String? = nil) async throws {
        guard let token else { throw SCError.notAuthenticated }
        let clientID = try await clientIDs.clientID()
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "client_id", value: clientID)]

        // Writes go through the web page: DataDome rejects them from URLSession even with the right
        // cookie. Reads are ungated and stay on URLSession, which is far cheaper.
        if let reply = await WebWriteBridge.shared.send(method: method, url: comps.url!.absoluteString,
                                                        token: token, json: json) {
            if (200..<300).contains(reply.status) { return }
            print("""
            [api-v2] \(method) \(path) -> \(reply.status) (via web page)
              final url: \(reply.url)
              page cookies: \(reply.cookies)
              body: \(reply.body)
            """)
            // -1 means fetch threw rather than the server answering: api-v2's error responses carry no
            // CORS headers, so a rejected write reads as "Load failed" from the page. The same request
            // from URLSession isn't bound by CORS and shows what the server actually said.
            guard reply.status == -1 else { throw SCError.http(reply.status) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        // A bodyless PUT/POST goes out without Content-Length, which SoundCloud rejects — that is
        // why removing a like or a follow worked while adding one silently failed.
        if method != "DELETE" {
            let body = Data((json ?? "").utf8)
            req.httpBody = body
            req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // DataDome profiles the caller, not just the cookie: a request without the web player's
        // origin and agent is treated as a bot even when the cookie rides along.
        req.setValue("https://soundcloud.com", forHTTPHeaderField: "Origin")
        req.setValue("https://soundcloud.com/", forHTTPHeaderField: "Referer")
        req.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let body = String(decoding: data.prefix(160), as: UTF8.self)
            let cookie = await WebSessionCookies.hasBotProtectionCookie ? "datadome: yes" : "datadome: MISSING"
            print("[api-v2] \(method) \(path) -> \(code) [\(cookie)] \(body)")
            throw SCError.http(code)
        }
    }

    // Shared by api-v2 and GraphQL, so a stale token is refreshed whichever of them notices first.

    /// Turns a `DecodingError` into which endpoint and which field to go look at: a schema change
    /// on SoundCloud's side otherwise surfaces as an unreadable error somewhere up in the UI.
    private static func schemaChanged(_ error: DecodingError, at endpoint: String) -> SCError {
        func name(_ path: [CodingKey], _ key: CodingKey? = nil) -> String {
            (path + (key.map { [$0] } ?? [])).map(\.stringValue).joined(separator: ".")
        }
        let field: String
        let detail: String
        switch error {
        case .keyNotFound(let key, let context):
            field = name(context.codingPath, key)
            detail = "missing"
        case .typeMismatch(let type, let context):
            field = name(context.codingPath)
            detail = "expected \(type)"
        case .valueNotFound(let type, let context):
            field = name(context.codingPath)
            detail = "null, expected \(type)"
        case .dataCorrupted(let context):
            field = name(context.codingPath)
            detail = context.debugDescription
        @unknown default:
            field = ""
            detail = String(describing: error)
        }
        log.error("\(endpoint, privacy: .public) — \(field, privacy: .public): \(detail, privacy: .public)")
        return .decoding(endpoint: endpoint, field: field, detail: detail)
    }

    func sendAuthorized(token: String,
                        _ send: (String) async throws -> (Data, Int)) async throws -> (Data, Int) {
        var (data, code) = try await send(token)
        // A rotated client_id doesn't help a stale token, so try the web session's own before
        // giving up on it.
        if code == 401, let refreshed = await refreshToken?(), refreshed != token {
            Keychain.set(refreshed, for: Self.tokenAccount)
            (data, code) = try await send(refreshed)
        }
        if code == 401 {
            await onSessionExpired?()
        }
        return (data, code)
    }

    func getDecoded<T: Decodable>(
        path: String? = nil,
        absolute: String? = nil,
        query: [String: String]
    ) async throws -> T {
        guard let token else { throw SCError.notAuthenticated }

        func makeURL(clientID: String) -> URL {
            let baseURL = absolute.flatMap { URL(string: $0) } ?? base.appendingPathComponent(path ?? "")
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            var items = (comps.queryItems ?? []) + query.map { URLQueryItem(name: $0.key, value: $0.value) }
            items.append(URLQueryItem(name: "client_id", value: clientID))
            comps.queryItems = items
            return comps.url!
        }

        func request(clientID: String, token: String) async throws -> (Data, Int) {
            var req = URLRequest(url: makeURL(clientID: clientID))
            req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (data, code)
        }

        var clientID = try await clientIDs.clientID()
        var rotated = false
        let (data, code) = try await sendAuthorized(token: token) { token in
            var reply = try await request(clientID: clientID, token: token)
            if !rotated, reply.1 == 401 || reply.1 == 403 {
                rotated = true
                await clientIDs.invalidate()
                clientID = try await clientIDs.clientID(forceRefresh: true)
                reply = try await request(clientID: clientID, token: token)
            }
            return reply
        }
        guard (200..<300).contains(code) else { throw SCError.http(code) }
        do {
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw Self.schemaChanged(error, at: absolute ?? path ?? "")
        }
    }
}
