import AppKit
import Foundation
import os

/// Tells SoundCloud what was heard as its web player does; play history is built from these events.
@MainActor
final class PlayReporter {
    enum Trigger: String {
        case manual, auto, `repeat`
    }

    struct Playing {
        let track: SCTrack
        let transcoding: SCTranscoding?
        let context: PlayContext?
    }

    var nextTrigger = Trigger.manual

    private let api: SoundCloudAPI
    private var playing: Playing?
    private var item: ObjectIdentifier?
    private var isSounding = false
    private var position: Double = 0
    private var queued: [SCAudioEvent] = []
    private var flushTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var userURN: String?

    private static let log = Logger(subsystem: "io.github.dearonski.Nimbus", category: "events")
    private static let checkpointInterval = Duration.seconds(30)
    private static let flushDelay = Duration.seconds(5)
    // The web player's application id: the pipeline only knows events as that client's.
    private static let webClientID = 46941

    private static let anonymousID: String = {
        let key = "eventsAnonymousID"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let made = (0..<4).map { _ in String(Int.random(in: 0..<1_000_000)) }.joined(separator: "-")
        UserDefaults.standard.set(made, forKey: key)
        return made
    }()

    init(api: SoundCloudAPI) {
        self.api = api
    }

    func tick(_ seconds: Double, track id: Int?) {
        if id == playing?.track.id { position = seconds }
    }

    /// Sound came on for `item`. True when that is a fresh start rather than a resume.
    @discardableResult
    func started(_ now: Playing, item: ObjectIdentifier, at seconds: Double) -> Bool {
        let isFresh = item != self.item
        if isFresh {
            if isSounding, let previous = playing {
                enqueue("pause", previous, at: position, reason: nil, trigger: .auto)
            }
            playing = now
            self.item = item
            position = seconds
            isSounding = false
        }
        guard !isSounding else { return false }
        isSounding = true
        enqueue("play", now, at: position, reason: nil, trigger: nextTrigger)
        nextTrigger = .manual
        startCheckpoints()
        return isFresh
    }

    func paused(ended: Bool) {
        guard isSounding, let playing else { return }
        isSounding = false
        checkpointTask?.cancel()
        checkpointTask = nil
        enqueue("pause", playing, at: position, reason: ended ? nil : "pause", trigger: ended ? .auto : .manual)
    }

    func stopped() {
        paused(ended: false)
        playing = nil
        item = nil
        flushTask?.cancel()
        flushTask = nil
        Task { await flush() }
        userURN = nil
    }

    private func startCheckpoints() {
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkpointInterval)
                guard !Task.isCancelled, let self, self.isSounding, let playing = self.playing else { return }
                self.enqueue("checkpoint", playing, at: self.position, reason: nil, trigger: .auto)
            }
        }
    }

    private func enqueue(_ action: String, _ playing: Playing, at seconds: Double, reason: String?, trigger: Trigger) {
        let track = playing.track
        let inPlaylist: String? = if case .set(let urn) = playing.context, urn.hasPrefix("soundcloud:playlists:") { urn } else { nil }
        queued.append(SCAudioEvent(
            action: action,
            track: "soundcloud:tracks:\(track.id)",
            trackOwner: "soundcloud:users:\(track.user.id)",
            trackLength: track.duration,
            playheadPosition: Int((seconds * 1000).rounded()),
            trackAuthorization: action == "play" ? track.trackAuthorization : nil,
            pauseReason: reason,
            trigger: trigger.rawValue,
            policy: track.policy,
            monetizationModel: track.monetizationModel,
            playerType: "MaestroHLSMSE",
            preset: playing.transcoding?.preset,
            quality: playing.transcoding?.quality,
            audioQualityMode: "standard",
            appState: NSApp.isActive ? "foreground" : "background",
            source: playing.context == .history ? "history" : nil,
            inPlaylist: inPlaylist,
            anonymousID: Self.anonymousID,
            clientID: Self.webClientID,
            user: nil,
            url: track.permalinkURL,
            ts: Int64(Date.now.timeIntervalSince1970 * 1000)))
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard !queued.isEmpty else { return }
        var batch = queued
        queued = []
        if userURN == nil, let me = try? await api.me() { userURN = "soundcloud:users:\(me.id)" }
        for index in batch.indices { batch[index].user = userURN }
        let actions = batch.map { "\($0.action) \($0.track.split(separator: ":").last ?? "")" }.joined(separator: ", ")
        do {
            try await api.report(batch)
            Self.log.info("sent \(actions, privacy: .public)")
        } catch {
            Self.log.error("couldn't send \(actions, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
