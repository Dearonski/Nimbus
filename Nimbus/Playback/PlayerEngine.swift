import AppKit
import AVFoundation
import Foundation
import MediaPlayer
import Observation
import SwiftUI

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
    private(set) var lastError: String?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    private(set) var queue: [SCTrack] = []
    private(set) var currentIndex = 0
    private(set) var isShuffled = false
    private(set) var repeatMode: RepeatMode = .off
    /// Keep playing past the end of the queue with tracks related to the last one.
    var autoplayRelated: Bool {
        didSet { UserDefaults.standard.set(autoplayRelated, forKey: Self.autoplayKey) }
    }

    /// Lives here rather than on `AVPlayer` directly: the player is replaced per track, so its own
    /// volume resets to 1.0 and the first track after launch used to blast at full.
    var volume: Float {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        }
    }

    let player = AVPlayer()

    private let api: SoundCloudAPI
    private var originalOrder: [SCTrack] = []

    /// The collection behind the queue, as ids in their canonical order, plus the ids still to be
    /// resolved. Holding the whole collection here — not just the resolved head — is what lets
    /// shuffle cover everything instead of the slice that happens to be loaded.
    private var canonicalIDs: [Int] = []
    private var pendingIDs: [Int] = []
    private var resolveIDs: (([Int]) async -> [SCTrack])?
    private static let refillThreshold = 10
    private static let autoplayKey = "autoplayRelated"
    private static let volumeKey = "playerVolume"
    private static let sessionQueueKey = "sessionQueueIDs"
    private static let sessionIndexKey = "sessionQueueIndex"
    private static let refillSize = 50
    private var loader: HLSResourceLoader?
    private var keySession: AVContentKeySession?
    private var keyDelegate: FairPlayKeyDelegate?
    private var endObserver: (any NSObjectProtocol)?
    private var failObserver: (any NSObjectProtocol)?
    private var statusObserver: NSKeyValueObservation?
    private var artwork: MPMediaItemArtwork?

    /// Consecutive failed tracks since the last one that actually played. Bounds auto-skip so a
    /// wholly unplayable queue stops instead of spinning forever (esp. under repeat all).
    private var consecutiveFailures = 0
    /// One failure per item: `.status == .failed` and `failedToPlayToEndTime` can both fire.
    private var itemFailed = false
    private var isSeeking = false
    private var seekToken = 0

    init(api: SoundCloudAPI) {
        self.api = api
        autoplayRelated = UserDefaults.standard.object(forKey: Self.autoplayKey) as? Bool ?? true
        volume = UserDefaults.standard.object(forKey: Self.volumeKey) as? Float ?? 1
        player.volume = volume
        player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                // While a seek is in flight the player still reports the old position; taking it
                // would bounce the clock back before it lands on the target.
                if !self.isSeeking { self.currentTime = time.seconds }
                if let itemDuration = self.player.currentItem?.duration.seconds, itemDuration.isFinite {
                    self.duration = itemDuration
                }
            }
        }
        configureRemoteCommands()
    }

    var canGoNext: Bool {
        !queue.isEmpty && (currentIndex + 1 < queue.count || repeatMode == .all || !pendingIDs.isEmpty)
    }
    var canGoPrevious: Bool { !queue.isEmpty }

    // MARK: - Queue control

    /// Plays `track` within the context of `tracks` (the surrounding list becomes the queue).
    func play(_ track: SCTrack, in tracks: [SCTrack]) async {
        consecutiveFailures = 0
        canonicalIDs = tracks.map(\.id)
        pendingIDs = []
        resolveIDs = nil
        originalOrder = tracks
        if isShuffled {
            queue = Self.shuffling(after: 0, in: [track] + tracks.filter { $0.id != track.id })
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = tracks.firstIndex { $0.id == track.id } ?? 0
        }
        await playCurrent()
    }

    /// Randomises only what is still ahead. Everything up to and including `index` stays put, so
    /// turning shuffle on mid-track keeps the history that `previous()` and the queue panel show.
    private static func shuffling(after index: Int, in tracks: [SCTrack]) -> [SCTrack] {
        guard tracks.indices.contains(index) else { return tracks.shuffled() }
        return Array(tracks[...index]) + tracks[(index + 1)...].shuffled()
    }

    func play(_ track: SCTrack) async {
        await play(track, in: [track])
    }

    func playShuffled(_ tracks: [SCTrack]) async {
        guard let first = tracks.randomElement() else { return }
        isShuffled = true
        await play(first, in: tracks)
    }

    /// Plays a collection given as ids: only the head is resolved up front, the rest follows as
    /// playback advances. Shuffle then covers the whole collection rather than the resolved slice,
    /// which is the difference between "random within this page" and actual shuffle.
    func play(ids: [Int],
              startingAt trackID: Int? = nil,
              shuffled: Bool,
              head: Int = 60,
              resolve: @escaping ([Int]) async -> [SCTrack]) async {
        guard !ids.isEmpty else { return }
        consecutiveFailures = 0
        canonicalIDs = ids
        resolveIDs = resolve
        isShuffled = shuffled

        var order = ids
        if shuffled { order.shuffle() }
        if let trackID, let index = order.firstIndex(of: trackID) {
            order = Array(order[index...]) + Array(order[..<index])
        }

        let headIDs = Array(order.prefix(head))
        pendingIDs = Array(order.dropFirst(headIDs.count))
        let tracks = await resolve(headIDs)
        guard !tracks.isEmpty else { return }

        queue = tracks
        originalOrder = tracks
        currentIndex = 0
        await playCurrent()
    }

    /// Queues `track` to play right after the current one. With an empty queue this just plays it.
    func playNext(_ track: SCTrack) {
        guard !queue.isEmpty, currentTrack != nil else {
            Task { await play(track) }
            return
        }
        queue.removeAll { $0.id == track.id && $0.id != currentTrack?.id }
        currentIndex = queue.firstIndex { $0.id == currentTrack?.id } ?? currentIndex
        queue.insert(track, at: min(currentIndex + 1, queue.count))
        syncOriginalOrder(inserting: track, afterCurrent: true)
    }

    func playLater(_ track: SCTrack) {
        guard !queue.isEmpty, currentTrack != nil else {
            Task { await play(track) }
            return
        }
        queue.removeAll { $0.id == track.id && $0.id != currentTrack?.id }
        currentIndex = queue.firstIndex { $0.id == currentTrack?.id } ?? currentIndex
        queue.append(track)
        syncOriginalOrder(inserting: track, afterCurrent: false)
    }

    func next() async {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 >= queue.count {
            await pullRefill()
        } else if queue.count - currentIndex <= Self.refillThreshold {
            Task { await pullRefill() }
        }
        if currentIndex + 1 < queue.count {
            currentIndex += 1
        } else if repeatMode == .all {
            // A fresh lap gets a fresh order; repeating the same random sequence isn't shuffle.
            if isShuffled { queue = queue.shuffled() }
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

    /// Reinstates last session's queue without starting playback — the transport shows where you
    /// left off and the first press picks it up.
    func restore(_ tracks: [SCTrack], at index: Int) {
        guard !tracks.isEmpty, currentTrack == nil else { return }
        queue = tracks
        originalOrder = tracks
        canonicalIDs = tracks.map(\.id)
        currentIndex = min(max(index, 0), tracks.count - 1)
        currentTrack = queue[currentIndex]
        duration = Double(queue[currentIndex].duration) / 1000
    }

    /// Stops playback and empties the queue, including what was stored for the next launch.
    func clearSession() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        queue = []
        originalOrder = []
        canonicalIDs = []
        pendingIDs = []
        resolveIDs = nil
        currentIndex = 0
        currentTrack = nil
        currentTime = 0
        duration = 0
        UserDefaults.standard.removeObject(forKey: Self.sessionQueueKey)
        UserDefaults.standard.removeObject(forKey: Self.sessionIndexKey)
    }

    /// Ids of the running queue, so the next launch can put it back.
    var sessionSnapshot: (ids: [Int], index: Int) {
        (Array(queue.prefix(200).map(\.id)), currentIndex)
    }

    func togglePlayPause(forcePlay: Bool = false, forcePause: Bool = false) {
        guard currentTrack != nil else { return }
        // Restored sessions have a track but no loaded item yet.
        guard player.currentItem != nil else {
            Task { await playCurrent() }
            return
        }
        let shouldPlay = forcePlay || (!forcePause && !isPlaying)
        if shouldPlay {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
        updateNowPlayingInfo()
    }

    func toggleShuffle() {
        isShuffled.toggle()
        guard let current = currentTrack else { return }
        if isShuffled {
            queue = Self.shuffling(after: currentIndex, in: queue)
            // The unresolved tail is shuffled too, otherwise everything past the loaded slice would
            // still arrive in collection order.
            pendingIDs.shuffle()
        } else {
            let rank = Dictionary(uniqueKeysWithValues: canonicalIDs.enumerated().map { ($1, $0) })
            queue = originalOrder.sorted { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
            originalOrder = queue
            currentIndex = queue.firstIndex { $0.id == current.id } ?? 0
            let resolved = Set(queue.map(\.id))
            pendingIDs = canonicalIDs.filter { !resolved.contains($0) }
        }
    }

    /// Resolves the next slice of pending ids and appends it to both orders.
    private func pullRefill() async {
        guard let resolveIDs, !pendingIDs.isEmpty else { return }
        let slice = Array(pendingIDs.prefix(Self.refillSize))
        pendingIDs.removeFirst(slice.count)
        let tracks = await resolveIDs(slice)
        guard !tracks.isEmpty else { return }

        let known = Set(queue.map(\.id))
        let fresh = tracks.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        queue.append(contentsOf: fresh)
        originalOrder.append(contentsOf: fresh)
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    func jump(to index: Int) async {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        await playCurrent()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        // While shuffled the two orders legitimately differ, and a reorder inside the random one
        // must not overwrite the order unshuffling goes back to.
        if !isShuffled { originalOrder = queue }
        if let id = currentTrack?.id {
            currentIndex = queue.firstIndex { $0.id == id } ?? currentIndex
        }
    }

    /// Keeps `originalOrder` holding the same tracks as `queue` — only the order may differ.
    private func syncOriginalOrder(inserting track: SCTrack, afterCurrent: Bool) {
        originalOrder.removeAll { $0.id == track.id && $0.id != currentTrack?.id }
        if afterCurrent, let currentID = currentTrack?.id,
           let index = originalOrder.firstIndex(where: { $0.id == currentID }) {
            originalOrder.insert(track, at: min(index + 1, originalOrder.count))
        } else {
            originalOrder.append(track)
        }
    }

    /// Drops everything queued after the current track. Playback is untouched — Music's Clear works
    /// the same way — and the pre-shuffle order sheds the same tracks so unshuffling can't resurrect
    /// them.
#if DEBUG
    /// Fills the queue without touching playback so previews can render a populated panel; `queue`
    /// is otherwise only ever set by playback itself.
    func seedForPreview(_ tracks: [SCTrack]) {
        queue = tracks
        originalOrder = tracks
        currentIndex = 0
        currentTrack = tracks.first
    }
#endif

    func clearUpcoming() {
        guard queue.indices.contains(currentIndex), currentIndex + 1 < queue.count else { return }
        let dropped = Set(queue[(currentIndex + 1)...].map(\.id))
        queue.removeSubrange((currentIndex + 1)...)
        originalOrder.removeAll { dropped.contains($0.id) }
    }

    func removeFromQueue(atOffsets offsets: IndexSet) {
        let removingCurrent = offsets.contains(currentIndex)
        let removed = Set(offsets.compactMap { queue.indices.contains($0) ? queue[$0].id : nil })
        queue.remove(atOffsets: offsets)
        // A removed track is gone from the queue for good, shuffled or not — leaving it in the
        // canonical order would resurrect it the moment shuffle is switched off.
        originalOrder.removeAll { removed.contains($0.id) }
        if let id = currentTrack?.id, let index = queue.firstIndex(where: { $0.id == id }) {
            currentIndex = index
        } else if removingCurrent {
            currentIndex = min(currentIndex, queue.count - 1)
            if queue.isEmpty {
                player.pause()
                isPlaying = false
                currentTrack = nil
            } else {
                Task { await playCurrent() }
            }
        }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        updateNowPlayingInfo()
        seekToken += 1
        let token = seekToken
        isSeeking = true
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                // Only the newest seek clears the flag: a superseded one finishes as cancelled and
                // would otherwise reopen the window its successor is still inside.
                guard let self, self.seekToken == token else { return }
                self.isSeeking = false
            }
        }
    }

    // MARK: - Playback of the current queue item

    private func persistSession() {
        let snapshot = sessionSnapshot
        UserDefaults.standard.set(snapshot.ids, forKey: Self.sessionQueueKey)
        UserDefaults.standard.set(snapshot.index, forKey: Self.sessionIndexKey)
    }

    static var storedSession: (ids: [Int], index: Int) {
        let ids = UserDefaults.standard.array(forKey: sessionQueueKey) as? [Int] ?? []
        return (ids, UserDefaults.standard.integer(forKey: sessionIndexKey))
    }

    private func playCurrent() async {
        persistSession()
        guard queue.indices.contains(currentIndex) else { return }
        let track = queue[currentIndex]
        currentTrack = track
        status = "loading…"
        loadArtwork(for: track)

        if let hlsAAC = track.bestHLSAAC {
            playHLS(hlsAAC, trackAuthorization: track.trackAuthorization, fairPlayToken: nil)
        } else if let fairPlay = track.bestFairPlayAAC {
            await playFairPlay(fairPlay, trackAuthorization: track.trackAuthorization)
        } else if let progressive = track.bestProgressive {
            await playDirect(progressive, trackAuthorization: track.trackAuthorization)
        } else if let hlsMP3 = track.bestHLSMP3 {
            playHLS(hlsMP3, trackAuthorization: track.trackAuthorization, fairPlayToken: nil)
        } else {
            failCurrentTrack("no playable source")
        }
    }

    private func playFairPlay(_ transcoding: SCTranscoding, trackAuthorization: String) async {
        do {
            let stream = try await api.resolve(for: transcoding, trackAuthorization: trackAuthorization)
            guard let token = stream.licenseAuthToken else {
                failCurrentTrack("no license token")
                return
            }
            playHLS(transcoding, trackAuthorization: trackAuthorization, fairPlayToken: token)
        } catch {
            failCurrentTrack(error.localizedDescription)
        }
    }

    /// Plays an HLS transcoding through the resource loader. When `fairPlayToken` is set, a
    /// FairPlay content-key session is attached to the same asset before playback begins.
    private func playHLS(_ transcoding: SCTranscoding, trackAuthorization: String, fairPlayToken: String?) {
        tearDownKeySession()

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
            status = "playing"
        }

        start(AVPlayerItem(asset: asset))
    }

    /// Retires the previous key session before a new track replaces it, so a license still in
    /// flight can't answer a request that AVFoundation has already forgotten about.
    private func tearDownKeySession() {
        keyDelegate?.invalidate()
        keySession?.expire()
        keySession = nil
        keyDelegate = nil
    }

    private func playDirect(_ transcoding: SCTranscoding, trackAuthorization: String) async {
        loader = nil
        tearDownKeySession()
        do {
            let url = try await api.streamURL(for: transcoding, trackAuthorization: trackAuthorization)
            status = "playing"
            start(AVPlayerItem(url: url))
        } catch {
            failCurrentTrack(error.localizedDescription)
        }
    }

    private func start(_ item: AVPlayerItem) {
        currentTime = 0
        duration = 0
        itemFailed = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.playbackFinished() }
        }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "playback stopped unexpectedly"
            MainActor.assumeIsolated { self?.reportItemFailure(message) }
        }
        // A stalled buffer is a normal, recoverable underrun (expected while a >5-min HLS signature
        // is re-resolved mid-track), so it is deliberately NOT routed to auto-skip. Only a hard
        // .failed status or failedToPlayToEndTime advances the queue.
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let ready = observed.status == .readyToPlay
            let failed = observed.status == .failed
            let message = observed.error?.localizedDescription ?? "couldn't load this track"
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === observed else { return }
                if ready {
                    self.consecutiveFailures = 0
                    self.lastError = nil
                } else if failed {
                    self.reportItemFailure(message)
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    private func playbackFinished() {
        if repeatMode == .one {
            Task { await playCurrent() }
        } else if canGoNext {
            Task { await next() }
        } else if autoplayRelated, let track = currentTrack {
            Task { await extendWithRelated(to: track) }
        } else {
            isPlaying = false
            status = "finished"
        }
    }

    /// Grows the queue with tracks related to the one that just ended. Only reached on a genuine
    /// end-of-queue — a track auto-skipped for being unplayable goes through `next()` instead, so a
    /// blocked track never drags the queue off into recommendations.
    private func extendWithRelated(to track: SCTrack) async {
        let related = (try? await api.relatedTracks(id: track.id).collection) ?? []
        let known = Set(queue.map(\.id))
        let fresh = related.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else {
            isPlaying = false
            status = "finished"
            return
        }
        queue.append(contentsOf: fresh)
        originalOrder.append(contentsOf: fresh)
        canonicalIDs.append(contentsOf: fresh.map(\.id))
        await next()
    }

    /// Item-failure entry point, deduped so `.status == .failed` and `failedToPlayToEndTime` can't
    /// both advance the queue for the same track.
    private func reportItemFailure(_ message: String) {
        guard !itemFailed else { return }
        itemFailed = true
        failCurrentTrack(message)
    }

    private func failCurrentTrack(_ message: String) {
        lastError = message
        status = "error: \(message)"
        advanceAfterFailure()
    }

    /// Skips to the next track on failure, but gives up once the whole queue has failed in a row so
    /// an unplayable queue (or repeat all) doesn't loop forever.
    private func advanceAfterFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures < queue.count else {
            isPlaying = false
            status = "nothing in the queue could be played"
            return
        }
        if canGoNext {
            Task { await next() }
        } else {
            isPlaying = false
        }
    }

    /// Surfaces a failure that happened before playback could start (a set that wouldn't resolve),
    /// reusing the banner the engine already shows for unplayable tracks.
    func report(_ message: String) {
        lastError = message
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Now Playing & media keys

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause(forcePlay: true) }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause(forcePause: true) }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.previous() }
            return .success
        }
    }

    /// Loads Now Playing artwork from raw bytes. The MPMediaItemArtwork request handler MUST be
    /// `@Sendable` — MediaPlayer calls it on an arbitrary thread, and a MainActor-isolated closure
    /// would trip a Swift 6 executor assertion (libdispatch abort). Capturing Data (Sendable) and
    /// rebuilding NSImage per call keeps it thread-safe.
    private func loadArtwork(for track: SCTrack) {
        artwork = nil
        guard let url = track.artworkURL.flatMap(URL.init) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let size = NSImage(data: data)?.size else { return }
            let art = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
                NSImage(data: data) ?? NSImage()
            }
            await MainActor.run {
                self.artwork = art
                self.updateNowPlayingInfo()
            }
        }
    }

    /// MPNowPlayingInfoCenter asserts it runs on the main dispatch queue; Swift-concurrency
    /// executor hops don't reliably land there, so marshal explicitly with DispatchQueue.main.
    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            DispatchQueue.main.async {
                let center = MPNowPlayingInfoCenter.default()
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
            }
            return
        }
        let title = track.title
        let artist = track.artistLine
        let elapsed = currentTime
        let total = duration
        let playing = isPlaying
        nonisolated(unsafe) let art = artwork
        DispatchQueue.main.async {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: title,
                MPMediaItemPropertyArtist: artist,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
                MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            ]
            if total > 0 { info[MPMediaItemPropertyPlaybackDuration] = total }
            if let art { info[MPMediaItemPropertyArtwork] = art }
            let center = MPNowPlayingInfoCenter.default()
            center.nowPlayingInfo = info
            center.playbackState = playing ? .playing : .paused
        }
    }
}
