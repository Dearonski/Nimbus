import Foundation
import Observation
import OSLog

// SoundCloud's own receiver: it resolves, decrypts (Widevine) and reports plays itself, given a urn and our token.
@MainActor
@Observable
final class CastSession {
    enum PlayerState: String {
        case idle = "IDLE", playing = "PLAYING", paused = "PAUSED", buffering = "BUFFERING"
    }

    enum Event {
        case progress
        case finished
        case failed(String)
        // Another sender put its own track on the receiver.
        case takenOver
    }

    struct ConnectFailure: Error { let reason: String }

    let device: CastDevice
    private(set) var state: PlayerState = .idle
    private(set) var volume: Float = 1
    private(set) var isMuted = false
    private(set) var duration: Double?

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    @ObservationIgnored var onEnd: ((String) -> Void)?

    private static let appID = "B143C57E"
    private static let senderID = "sender-nimbus"
    private static let platform = "receiver-0"
    private enum Namespace {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }
    private static let log = Logger(subsystem: "io.github.dearonski.Nimbus", category: "cast")

    @ObservationIgnored private let channel: CastChannel
    @ObservationIgnored private var requestID = 0
    @ObservationIgnored private var transportID: String?
    @ObservationIgnored private var appSessionID: String?
    @ObservationIgnored private var mediaSessionID: Int?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = Date.now
    @ObservationIgnored private var launching: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var hasEnded = false

    @ObservationIgnored private var position: Double = 0
    @ObservationIgnored private var positionStamp = Date.now
    @ObservationIgnored private var contentID: String?
    // Statuses about the track before ours keep arriving until the receiver confirms the new load.
    @ObservationIgnored private var expectedContentID: String?
    @ObservationIgnored private var loadConfirmed = false
    @ObservationIgnored private var foreignItemIDs: Set<Int> = []
    @ObservationIgnored private var volumeSend: Task<Void, Never>?
    @ObservationIgnored private var loggedStream: String?
    // Asked of every load too: the receiver starts each track back at 1×.
    @ObservationIgnored private(set) var rate: Double = 1
    @ObservationIgnored private var volumeSetAt = Date.distantPast

    init(device: CastDevice) {
        self.device = device
        channel = CastChannel(endpoint: device.endpoint)
    }

    var isPlaying: Bool { state == .playing || state == .buffering }

    func position(at date: Date) -> Double {
        guard state == .playing else { return position }
        let running = position + date.timeIntervalSince(positionStamp) * rate
        return duration.map { min(running, $0) } ?? running
    }

    func connect() async throws {
        try await channel.open()
        listening = Task { [weak self, channel] in
            for await message in channel.messages {
                self?.handle(message)
            }
            self?.end("connection closed")
        }
        send(Namespace.connection, to: Self.platform, ["type": "CONNECT"])
        startHeartbeat()
        do {
            try await withCheckedThrowingContinuation { (launch: CheckedContinuation<Void, any Error>) in
                launching = launch
                send(Namespace.receiver, to: Self.platform, ["type": "LAUNCH", "appId": Self.appID], numbered: true)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    self?.failLaunch("the receiver didn't start")
                }
            }
        } catch {
            hasEnded = true
            tearDown()
            throw error
        }
    }

    func load(contentID: String, authorization: String?, at seconds: Double, autoplay: Bool) {
        guard let transportID else { return }
        expectedContentID = contentID
        loadConfirmed = false
        mediaSessionID = nil
        duration = nil
        state = autoplay ? .buffering : .paused
        setPosition(seconds)
        var custom: [String: Any] = ["queue": [["urn": contentID]], "current_index": 0]
        if let authorization { custom["credentials"] = ["authorization": authorization] }
        send(Namespace.media, to: transportID, [
            "type": "LOAD", "autoplay": autoplay, "currentTime": seconds, "playbackRate": rate,
            "media": ["contentId": contentID, "streamType": "BUFFERED", "contentType": "audio/mp3", "customData": [:]],
            "customData": custom,
        ], numbered: true)
    }

    // The receiver lists SET_PLAYBACK_RATE (supportedMediaCommands 274639, 06.11.2026); Chrome keeps the pitch.
    func setRate(_ value: Double) {
        guard value != rate else { return }
        setPosition(position(at: .now))
        rate = value
        media("SET_PLAYBACK_RATE", ["playbackRate": value])
    }

    func play() {
        media("PLAY")
        if state == .paused { state = .playing }
        setPosition(position)
    }

    func pause() {
        setPosition(position(at: .now))
        media("PAUSE")
        if isPlaying { state = .paused }
    }

    func seek(to seconds: Double) {
        setPosition(seconds)
        media("SEEK", ["currentTime": seconds])
    }

    func stopMedia() {
        media("STOP")
        state = .idle
        expectedContentID = nil
    }

    // A drag sends a level per pixel; the device answers each one late and dragged the slider back.
    func setVolume(_ level: Float) {
        volume = min(max(level, 0), 1)
        volumeSetAt = .now
        if isMuted, volume > 0 {
            isMuted = false
            send(Namespace.receiver, to: Self.platform, ["type": "SET_VOLUME", "volume": ["muted": false]],
                 numbered: true)
        }
        guard volumeSend == nil else { return }
        volumeSend = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !hasEnded else { return }
            volumeSend = nil
            send(Namespace.receiver, to: Self.platform, ["type": "SET_VOLUME", "volume": ["level": Double(volume)]],
                 numbered: true)
        }
    }

    func disconnect(stopReceiver: Bool) {
        guard !hasEnded else { return }
        hasEnded = true
        if stopReceiver, let appSessionID {
            send(Namespace.receiver, to: Self.platform, ["type": "STOP", "sessionId": appSessionID], numbered: true)
        }
        if let transportID { send(Namespace.connection, to: transportID, ["type": "CLOSE"]) }
        tearDown()
    }

    private func end(_ reason: String) {
        guard !hasEnded else { return }
        hasEnded = true
        Self.log.notice("cast ended: \(reason, privacy: .public)")
        failLaunch(reason)
        tearDown()
        onEnd?(reason)
    }

    private func tearDown() {
        heartbeat?.cancel()
        listening?.cancel()
        channel.close()
    }

    private func failLaunch(_ reason: String) {
        launching?.resume(throwing: ConnectFailure(reason: reason))
        launching = nil
    }

    private func setPosition(_ seconds: Double) {
        position = seconds
        positionStamp = .now
    }

    private func startHeartbeat() {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if Date.now.timeIntervalSince(lastHeard) > 20 {
                    end("the device stopped answering")
                    return
                }
                send(Namespace.heartbeat, to: Self.platform, ["type": "PING"])
            }
        }
    }

    private func media(_ type: String, _ extra: [String: Any] = [:]) {
        guard let transportID, let mediaSessionID else { return }
        var payload = extra
        payload["type"] = type
        payload["mediaSessionId"] = mediaSessionID
        send(Namespace.media, to: transportID, payload, numbered: true)
    }

    private func send(_ namespace: String, to destination: String, _ payload: [String: Any], numbered: Bool = false) {
        var payload = payload
        if numbered {
            requestID += 1
            payload["requestId"] = requestID
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        channel.send(CastMessage(source: Self.senderID, destination: destination, namespace: namespace,
                                 payload: String(decoding: data, as: UTF8.self)))
    }

    private func handle(_ message: CastMessage) {
        lastHeard = .now
        guard let json = try? JSONSerialization.jsonObject(with: Data(message.payload.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch (message.namespace, type) {
        case (Namespace.heartbeat, "PING"):
            send(Namespace.heartbeat, to: message.source, ["type": "PONG"])
        case (Namespace.connection, "CLOSE") where message.source == transportID:
            end("the receiver closed")
        case (Namespace.receiver, "RECEIVER_STATUS"):
            receiverStatus(json["status"] as? [String: Any] ?? [:])
        case (Namespace.receiver, "LAUNCH_ERROR"):
            failLaunch(json["reason"] as? String ?? "launch error")
        case (Namespace.media, "MEDIA_STATUS"):
            mediaStatus(json["status"] as? [[String: Any]] ?? [])
        case (Namespace.media, "QUEUE_CHANGE"):
            queueChanged(json)
        case (Namespace.media, "LOAD_FAILED"), (Namespace.media, "LOAD_CANCELLED"), (Namespace.media, "INVALID_REQUEST"):
            Self.log.error("cast \(type, privacy: .public): \(message.payload, privacy: .public)")
            if type != "LOAD_CANCELLED" { onEvent?(.failed("Chromecast couldn't play this track")) }
        default:
            break
        }
    }

    private func receiverStatus(_ status: [String: Any]) {
        if let reported = status["volume"] as? [String: Any], Date.now.timeIntervalSince(volumeSetAt) > 1.5 {
            if let level = reported["level"] as? Double { volume = Float(level) }
            if let muted = reported["muted"] as? Bool { isMuted = muted }
        }
        let apps = status["applications"] as? [[String: Any]] ?? []
        guard let app = apps.first(where: { $0["appId"] as? String == Self.appID }),
              let transport = app["transportId"] as? String else {
            if transportID != nil { end("another app took the device") }
            return
        }
        appSessionID = app["sessionId"] as? String
        guard transportID != transport else { return }
        transportID = transport
        send(Namespace.connection, to: transport, ["type": "CONNECT"])
        send(Namespace.media, to: transport, ["type": "GET_STATUS"], numbered: true)
        launching?.resume()
        launching = nil
    }

    private func mediaStatus(_ statuses: [[String: Any]]) {
        guard let status = statuses.first else { return }
        if let media = status["media"] as? [String: Any] {
            contentID = media["contentId"] as? String
            if let length = media["duration"] as? Double, length > 0 { duration = length }
            if let url = (media["contentUrl"] as? String).flatMap(URL.init(string:)), loggedStream != url.path() {
                loggedStream = url.path()
                Self.log.notice("cast stream: \(url.host() ?? "", privacy: .public)\(url.path(), privacy: .public)")
            }
        }
        guard let expectedContentID else { return }
        if contentID == expectedContentID {
            loadConfirmed = true
        } else if loadConfirmed, let item = status["currentItemId"] as? Int, foreignItemIDs.contains(item) {
            // Our track ended into a station pick that slipped past the removal.
            self.expectedContentID = nil
            stopMedia()
            onEvent?(.finished)
            return
        } else if loadConfirmed, contentID != nil {
            onEvent?(.takenOver)
            return
        }
        guard loadConfirmed else { return }
        mediaSessionID = status["mediaSessionId"] as? Int ?? mediaSessionID
        if let reported = status["currentTime"] as? Double { setPosition(reported) }
        let reported = PlayerState(rawValue: status["playerState"] as? String ?? "") ?? .idle
        if reported != state {
            let reason = status["idleReason"] as? String ?? ""
            Self.log.info("cast state: \(reported.rawValue, privacy: .public) \(reason, privacy: .public)")
        }
        state = reported
        if reported == .idle {
            switch status["idleReason"] as? String {
            case "FINISHED":
                self.expectedContentID = nil
                onEvent?(.finished)
            case "ERROR":
                self.expectedContentID = nil
                onEvent?(.failed("Chromecast couldn't play this track"))
            default:
                onEvent?(.progress)
            }
        } else {
            onEvent?(.progress)
        }
    }

    // The receiver tops up a short queue with its own station picks; the queue is ours, so they go.
    private func queueChanged(_ json: [String: Any]) {
        guard json["changeType"] as? String == "INSERT",
              let items = json["itemIds"] as? [Int], !items.isEmpty else { return }
        foreignItemIDs.formUnion(items)
        media("QUEUE_REMOVE", ["itemIds": items])
    }
}
