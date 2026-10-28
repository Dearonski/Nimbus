import Foundation
import os

/// Thin async wrapper over SoundCloud's internal api-v2.
/// Auth is a harvested `oauth_token` owned by `AuthSession`; the client_id is scraped and rotated here.
/// Requests themselves live in `Endpoints/`; this file is the transport they go through.

actor SoundCloudAPI {
    let auth = AuthSession()

    private static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let base = URL(string: "https://api-v2.soundcloud.com")!

    private let clientIDs = ClientIDResolver()

    private let decoder = JSONDecoder()
    private static let log = Logger(subsystem: "io.github.dearonski.Nimbus", category: "api")

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
        let url = switch endpoint.target {
        case .path(let path): base.appendingPathComponent(path)
        case .absolute(let absolute): URL(string: absolute) ?? base
        }
        let (data, code) = try await authorized(clientID: .rotatedOn([401, 403])) { token, clientID in
            try await read(url, query: endpoint.query, clientID: clientID ?? "", token: token)
        }
        guard (200..<300).contains(code) else { throw SCError.http(code) }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch let error as DecodingError {
            throw Self.schemaChanged(error, at: endpoint.label, verified: endpoint.verified)
        }
    }

    /// The page a `next_href` points at, shaped like the first one it followed.
    func page<Page: Decodable & Sendable>(after nextHref: String, as _: Page.Type = Page.self) async throws -> Page {
        try await get(.following(nextHref))
    }

    func send(_ write: SCWrite) async throws {
        try await send { _ in write }
    }

    /// For a write whose body carries the token itself, rebuilt if a 401 renews it.
    func send(_ makeWrite: (_ token: String) throws -> SCWrite) async throws {
        var sent: SCWrite?
        // A 403 on a write is DataDome, not a stale client_id, and a scrape would not help it.
        let (data, code) = try await authorized(clientID: .rotatedOn([401])) { token, clientID in
            let write = try makeWrite(token)
            sent = write
            return try await mutate(write, clientID: clientID ?? "", token: token)
        }
        guard (200..<300).contains(code) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            Self.log.error("\(sent?.method ?? "", privacy: .public) \(sent?.path ?? "", privacy: .public) -> \(code): \(body, privacy: .public)")
            throw SCError.http(code)
        }
    }

    enum ClientIDUse {
        case none
        case rotatedOn(Set<Int>)
    }

    /// Renews an expired token before suspecting the client_id: the JWT runs out daily, a scrape costs a dozen requests.
    func authorized(clientID use: ClientIDUse,
                    _ send: (_ token: String, _ clientID: String?) async throws -> (Data, Int)) async throws -> (Data, Int) {
        guard var token = await auth.current() else { throw SCError.notAuthenticated }
        var clientID: String?
        var rotateOn: Set<Int> = []
        if case .rotatedOn(let codes) = use {
            clientID = try await clientIDs.clientID()
            rotateOn = codes
        }
        var reply = try await send(token, clientID)
        var renewedToken = false

        if reply.1 == 401, AuthSession.mayHaveExpired(token) {
            token = try await renewed(token)
            renewedToken = true
            reply = try await send(token, clientID)
        }
        if let stale = clientID, rotateOn.contains(reply.1) {
            clientID = try await clientIDs.clientID(replacing: stale)
            reply = try await send(token, clientID)
        }
        // A token that looked alive was refused anyway, and a fresh client_id didn't help either.
        if reply.1 == 401, !renewedToken {
            token = try await renewed(token)
            reply = try await send(token, clientID)
        }
        return reply
    }

    private func renewed(_ stale: String) async throws -> String {
        switch await auth.renewed(replacing: stale) {
        case .token(let fresh): fresh
        case .rejected: throw SCError.notAuthenticated
        case .unavailable: throw SCError.sessionUnverified
        }
    }

    /// Turns a `DecodingError` into which endpoint and which field to go look at: a schema change
    /// on SoundCloud's side otherwise surfaces as an unreadable error somewhere up in the UI.
    static func schemaChanged(_ error: DecodingError, at endpoint: String, verified: String? = nil) -> SCError {
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
        // How long since the endpoint was last checked live says whether to suspect SoundCloud or this change.
        let checked = verified.map { " (verified \($0))" } ?? ""
        log.error("\(endpoint, privacy: .public)\(checked, privacy: .public) — \(field, privacy: .public): \(detail, privacy: .public)")
        return .decoding(endpoint: endpoint, field: field, detail: detail)
    }

    private func read(_ url: URL, query: [String: String], clientID: String, token: String) async throws -> (Data, Int) {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // A parameter we pass wins over the one a `next_href` already carries.
        var items = (comps.queryItems ?? []).filter { query[$0.name] == nil }
            + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "client_id", value: clientID))
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        return try await Self.load(req)
    }

    /// A mutating request. Uses the web client's auth — `Authorization` header + `client_id` — and
    /// goes through the web page first: api-v2 writes are behind DataDome bot protection, which
    /// rejects them from URLSession even with the right cookie. Reads aren't gated.
    private func mutate(_ write: SCWrite, clientID: String, token: String) async throws -> (Data, Int) {
        var comps = URLComponents(url: base.appendingPathComponent(write.path), resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "client_id", value: clientID)]

        // -1 means fetch threw rather than the server answering: api-v2's error responses carry no
        // CORS headers, so a rejected write reads as "Load failed" from the page. The same request
        // from URLSession isn't bound by CORS and shows what the server actually said.
        if let reply = await WebWriteBridge.shared.send(method: write.method, url: comps.url!.absoluteString,
                                                        token: token, json: write.json),
           reply.status != -1 {
            if !(200..<300).contains(reply.status) {
                Self.log.error("\(write.method, privacy: .public) \(write.path, privacy: .public) -> \(reply.status) via page, cookies: \(reply.cookies, privacy: .public)")
            }
            return (Data(reply.body.utf8), reply.status)
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = write.method
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        // A bodyless PUT/POST goes out without Content-Length, which SoundCloud rejects — that is
        // why removing a like or a follow worked while adding one silently failed.
        if write.method != "DELETE" {
            let body = Data((write.json ?? "").utf8)
            req.httpBody = body
            req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // DataDome profiles the caller, not just the cookie: a request without the web player's
        // origin and agent is treated as a bot even when the cookie rides along.
        req.setValue("https://soundcloud.com", forHTTPHeaderField: "Origin")
        req.setValue("https://soundcloud.com/", forHTTPHeaderField: "Referer")
        req.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        let reply = try await Self.load(req)
        if !(200..<300).contains(reply.1) {
            let cookie = await WebSessionCookies.hasBotProtectionCookie ? "present" : "MISSING"
            Self.log.error("\(write.method, privacy: .public) \(write.path, privacy: .public) -> \(reply.1) via URLSession, datadome \(cookie, privacy: .public)")
        }
        return reply
    }

    static func load(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }
}
