import AVFoundation
import Foundation
import Observation

/// v1 engine. Picks the best source for a track and plays it, in priority order:
/// - unencrypted AAC-HLS → HLSResourceLoader (seamless signature refresh, no glitch);
/// - FairPlay AAC-HLS (cbcs) → same loader + AVContentKeySession against SoundCloud's
///   license server, so encrypted tracks are seamless too;
/// - progressive MP3 → straight through AVPlayer;
/// - unencrypted MP3-HLS → HLSResourceLoader (last resort).
@MainActor
@Observable
final class PlayerEngine {
    private(set) var currentTrack: SCTrack?
    private(set) var isPlaying = false
    private(set) var status = "idle"

    let player = AVPlayer()

    private let api: SoundCloudAPI
    private var loader: HLSResourceLoader?
    private var keySession: AVContentKeySession?
    private var keyDelegate: FairPlayKeyDelegate?
    private var endObserver: (any NSObjectProtocol)?

    init(api: SoundCloudAPI) {
        self.api = api
    }

    func play(_ track: SCTrack) async {
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
        isPlaying = false
        status = "finished"
    }
}
