import AppKit
import MediaPlayer
import Nuke

/// The system's Now Playing entry and the media keys, for whatever the engine has on air.
@MainActor
final class NowPlayingBridge {
    nonisolated struct Info: Sendable {
        let title: String
        let artist: String
        let elapsed: Double
        let duration: Double
        let isPlaying: Bool
        let rate: Double
    }

    private var targets: [(command: MPRemoteCommand, target: Any)] = []
    private var info: Info?
    private var artwork: MPMediaItemArtwork?
    private var artworkTrackID: Int?
    private var artworkLoad: Task<Void, Never>?

    init(engine: PlayerEngine) {
        // A preview's engine would otherwise answer the media keys alongside the app's.
        guard !ProcessInfo.isRunningForPreviews else { return }
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { [weak engine] _ in engine?.togglePlayPause(forcePlay: true) }
        add(center.pauseCommand) { [weak engine] _ in engine?.togglePlayPause(forcePause: true) }
        add(center.togglePlayPauseCommand) { [weak engine] _ in engine?.togglePlayPause() }
        add(center.nextTrackCommand) { [weak engine] _ in Task { await engine?.next() } }
        add(center.previousTrackCommand) { [weak engine] _ in Task { await engine?.previous() } }
        add(center.changePlaybackPositionCommand) { [weak engine] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            engine?.seek(to: event.positionTime)
        }
    }

    isolated deinit {
        artworkLoad?.cancel()
        for entry in targets { entry.command.removeTarget(entry.target) }
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
        let target = command.addTarget { event in
            nonisolated(unsafe) let event = event
            Task { @MainActor in action(event) }
            return .success
        }
        targets.append((command, target))
    }

    /// Nil clears the entry, as when the queue is emptied or the session ends.
    func update(_ info: Info?) {
        self.info = info
        if info == nil {
            artworkLoad?.cancel()
            artwork = nil
            artworkTrackID = nil
        }
        publish()
    }

    func loadArtwork(for trackID: Int, from url: URL?) {
        guard artworkTrackID != trackID else { return }
        artworkTrackID = trackID
        artwork = nil
        artworkLoad?.cancel()
        guard let url else { return }
        // Through Nuke, whose cache the pill and the full player have most likely filled already.
        artworkLoad = Task { [weak self] in
            guard let (data, _) = try? await ImagePipeline.shared.data(for: ImageRequest(url: url)),
                  let size = NSImage(data: data)?.size, !Task.isCancelled else { return }
            // MediaPlayer calls this on any thread; a main-actor closure would trip Swift 6's executor check.
            let art = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in NSImage(data: data) ?? NSImage() }
            // A quick skip can land the previous track's cover after this one's.
            guard let self, self.artworkTrackID == trackID else { return }
            self.artwork = art
            self.publish()
        }
    }

    /// MPNowPlayingInfoCenter asserts it runs on the main dispatch queue; Swift-concurrency
    /// executor hops don't reliably land there, so marshal explicitly with DispatchQueue.main.
    private func publish() {
        guard let info else {
            DispatchQueue.main.async {
                let center = MPNowPlayingInfoCenter.default()
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
            }
            return
        }
        nonisolated(unsafe) let art = artwork
        DispatchQueue.main.async {
            var entry: [String: Any] = [
                MPMediaItemPropertyTitle: info.title,
                MPMediaItemPropertyArtist: info.artist,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
                MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? info.rate : 0.0,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: info.rate,
            ]
            if info.duration > 0 { entry[MPMediaItemPropertyPlaybackDuration] = info.duration }
            if let art { entry[MPMediaItemPropertyArtwork] = art }
            let center = MPNowPlayingInfoCenter.default()
            center.nowPlayingInfo = entry
            center.playbackState = info.isPlaying ? .playing : .paused
        }
    }
}
