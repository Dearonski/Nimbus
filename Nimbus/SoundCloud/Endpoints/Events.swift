import Foundation

/// One `audio` event in the shape the web player's EventGateway sends it.
nonisolated struct SCAudioEvent: Encodable, Sendable {
    let action: String
    let track: String
    let trackOwner: String
    let trackLength: Int
    let playheadPosition: Int
    let trackAuthorization: String?
    let pauseReason: String?
    let trigger: String
    let policy: String?
    let monetizationModel: String?
    let playerType: String
    let preset: String?
    let quality: String?
    let audioQualityMode: String
    let appState: String
    let source: String?
    let inPlaylist: String?
    let anonymousID: String
    let clientID: Int
    var user: String?
    let url: String
    let ts: Int64
}

private nonisolated struct AudioEventBatch: Encodable {
    struct Event: Encodable {
        let event = "audio"
        let version = "v1.27.47"
        let payload: SCAudioEvent
    }

    let events: [Event]
    let sentAt: String
    let authToken: String
}

extension SCWrite {
    /// `eventgateway` in the web route table. History is built from these — `POST /me/play-history` answers 204 and records nothing.
    // Built inside the transport's retry, off the main actor.
    nonisolated static func audioEvents(json: String) -> Self {
        .post("/me", json: json, verified: "2026-09-18")
    }
}

extension SoundCloudAPI {
    func report(_ events: [SCAudioEvent]) async throws {
        let sentAt = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        // The batch carries the token in its body too, so a retry after a renewal rebuilds it.
        try await send { token in
            let batch = AudioEventBatch(events: events.map { .init(payload: $0) }, sentAt: sentAt, authToken: token)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return .audioEvents(json: String(decoding: try encoder.encode(batch), as: UTF8.self))
        }
    }
}
