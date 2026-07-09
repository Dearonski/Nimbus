import AVFoundation
import Foundation
import Observation

enum RepeatMode {
    case off, all, one
}

/// v1 engine. Holds an ordered queue over a single AVPlayer: end-of-track auto-advances,
/// prev/next/shuffle/repeat drive the queue. Each track picks the best source:
/// - unencrypted AAC-HLS → HLSResourceLoader (seamless signature refresh);
/// - FairPlay AAC-HLS (cbcs) → same loader + AVContentKeySession against SoundCloud's server;
/// - progressive MP3 → straight through AVPlayer; unencrypted MP3-HLS → loader (last resort).
/// Track changes rebuffer briefly (not gapless — true gapless is a later milestone).
@MainActor
@Observable
final class PlayerEngine {
    private(set) var currentTrack: SCTrack?
    private(set) var isPlaying = false
    private(set) var status = "idle"
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    private(set) var queue: [SCTrack] = []
    private(set) var currentIndex = 0
    private(set) var isShuffled = false
    private(set) var repeatMode: RepeatMode = .off

    let player = AVPlayer()

    private let api: SoundCloudAPI
    private var originalOrder: [SCTrack] = []
    private var loader: HLSResourceLoader?
    private var keySession: AVContentKeySession?
    private var keyDelegate: FairPlayKeyDelegate?
    private var endObserver: (any NSObjectProtocol)?

    init(api: SoundCloudAPI) {
        self.api = api
        player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                if let itemDuration = self.player.currentItem?.duration.seconds, itemDuration.isFinite {
                    self.duration = itemDuration
                }
            }
        }
    }

    var canGoNext: Bool {
        !queue.isEmpty && (currentIndex + 1 < queue.count || repeatMode == .all)
    }
    var canGoPrevious: Bool { !queue.isEmpty }

    // MARK: - Queue control

    /// Plays `track` within the context of `tracks` (the surrounding list becomes the queue).
    func play(_ track: SCTrack, in tracks: [SCTrack]) async {
        originalOrder = tracks
        if isShuffled {
            queue = [track] + tracks.filter { $0.id != track.id }.shuffled()
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = tracks.firstIndex { $0.id == track.id } ?? 0
        }
        await playCurrent()
    }

    func play(_ track: SCTrack) async {
        await play(track, in: [track])
    }

    func next() async {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 < queue.count {
            currentIndex += 1
        } else if repeatMode == .all {
            currentIndex = 0
        } else {
            return
        }
        await playCurrent()
    }

    func previous() async {
        guard !queue.isEmpty else { return }
        if currentTime > 3 || currentIndex == 0 {
            seek(to: 0)
            return
        }
        currentIndex -= 1
        await playCurrent()
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func toggleShuffle() {
        isShuffled.toggle()
        guard let current = currentTrack else { return }
        if isShuffled {
            queue = [current] + originalOrder.filter { $0.id != current.id }.shuffled()
            currentIndex = 0
        } else {
            queue = originalOrder
            currentIndex = queue.firstIndex { $0.id == current.id } ?? 0
        }
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    // MARK: - Playback of the current queue item

    private func playCurrent() async {
        guard queue.indices.contains(currentIndex) else { return }
        let track = queue[currentIndex]
        currentTrack = track
        status = "loading…"

        if let hlsAAC = track.bestHLSAAC {
            playHLS(hlsAAC, trackAuthorization: track.trackAuthorization, fairPlayToken: nil)
        } else if let fairPlay = track.bestFairPlayAAC {
            await playFairPlay(fairPlay, trackAuthorization: track.trackAuthorization)
        } else if let progressive = track.bestProgressive {
            await playDirect(progressive, trackAuthorization: track.trackAuthorization)
        } else if let hlsMP3 = track.bestHLSMP3 {
            playHLS(hlsMP3, trackAuthorization: track.trackAuthorization, fairPlayToken: nil)
        } else {
            status = "no playable source"
        }
    }

    private func playFairPlay(_ transcoding: SCTranscoding, trackAuthorization: String) async {
        do {
            let stream = try await api.resolve(for: transcoding, trackAuthorization: trackAuthorization)
            guard let token = stream.licenseAuthToken else {
                status = "unavailable — no license token"
                return
            }
            playHLS(transcoding, trackAuthorization: trackAuthorization, fairPlayToken: token)
        } catch {
            status = "error: \(error)"
        }
    }

    /// Plays an HLS transcoding through the resource loader. When `fairPlayToken` is set, a
    /// FairPlay content-key session is attached to the same asset before playback begins.
    private func playHLS(_ transcoding: SCTranscoding, trackAuthorization: String, fairPlayToken: String?) {
        let loader = HLSResourceLoader(
            api: api, transcoding: transcoding, trackAuthorization: trackAuthorization)
        self.loader = loader

        let asset = AVURLAsset(url: HLSResourceLoader.assetURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)

        if let fairPlayToken {
            let session = AVContentKeySession(keySystem: .fairPlayStreaming)
            let delegate = FairPlayKeyDelegate(licenseAuthToken: fairPlayToken)
            keySession = session
            keyDelegate = delegate
            session.setDelegate(delegate, queue: delegate.queue)
            session.addContentKeyRecipient(asset)
            status = "playing (FairPlay)"
        } else {
            keySession = nil
            keyDelegate = nil
            status = "playing"
        }

        start(AVPlayerItem(asset: asset))
    }

    private func playDirect(_ transcoding: SCTranscoding, trackAuthorization: String) async {
        loader = nil
        keySession = nil
        keyDelegate = nil
        do {
            let url = try await api.streamURL(for: transcoding, trackAuthorization: trackAuthorization)
            status = "playing"
            start(AVPlayerItem(url: url))
        } catch {
            status = "unavailable"
        }
    }

    private func start(_ item: AVPlayerItem) {
        currentTime = 0
        duration = 0
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.playbackFinished() }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
    }

    private func playbackFinished() {
        if repeatMode == .one {
            Task { await playCurrent() }
        } else if canGoNext {
            Task { await next() }
        } else {
            isPlaying = false
            status = "finished"
        }
    }
}
