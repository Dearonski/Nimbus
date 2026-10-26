import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftUI

nonisolated enum RepeatMode: String, Codable {
    case off, all, one
}

/// Holds an ordered queue and plays it through two `AVPlayer` decks: one on air, the other warming
/// the next track, so the end of a track is a deck swap. Each track picks the best source:
/// - unencrypted AAC-HLS → HLSResourceLoader (seamless signature refresh);
/// - FairPlay AAC-HLS (cbcs) → same loader + AVContentKeySession against SoundCloud's server;
/// - progressive MP3 → straight through AVPlayer; unencrypted MP3-HLS → loader (last resort).
@MainActor
@Observable
final class PlayerEngine {
    private(set) var currentTrack: SCTrack?
    private(set) var isPlaying = false
    private(set) var lastError: String?
    private(set) var currentTime: Double = 0 { didSet { anchorClock(at: currentTime) } }
    private(set) var duration: Double = 0
    private var clock = Playhead()

    /// For anything drawn moving: the position between reports, not only at them.
    var playhead: Playhead {
        var playhead = clock
        playhead.duration = duration
        return playhead
    }

    /// The queue's own rules live in `QueueState`; the engine plays it and resolves what it asks for.
    private var state = QueueState() { didSet { scheduleSessionSave() } }
    var queue: [SCTrack] { state.tracks }
    var currentIndex: Int { state.currentIndex }
    var isShuffled: Bool { state.isShuffled }
    /// Tracks resolved lazily behind the loaded queue, so the panel can count and page them.
    var pendingCount: Int { state.pendingIDs.count }
    var repeatMode: RepeatMode { state.repeatMode }
    /// Keep playing past the end of the queue with tracks related to the last one.
    var autoplayRelated: Bool {
        didSet { UserDefaults.standard.set(autoplayRelated, forKey: Self.autoplayKey) }
    }

    /// Lives here rather than on either deck: both follow it, and it is remembered across launches.
    var volume: Float {
        didSet {
            decks.volume = volume
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        }
    }

    /// Back to 1× on every launch: left at 1.5× it would be easy to forget why the music sounds off.
    var speed: Float = 1 {
        didSet {
            guard speed != oldValue else { return }
            decks.rate = speed
            decks.whileHushed(playing: isPlaying) { [self] in
                if player.timeControlStatus != .paused { player.rate = speed }
                reanchorClock()
            }
            updateNowPlayingInfo()
        }
    }

    /// Off is varispeed: the pitch rides with the tempo, the way sped up and slowed edits sound.
    var keepsPitch: Bool {
        didSet {
            UserDefaults.standard.set(keepsPitch, forKey: Self.keepsPitchKey)
            decks.upcoming?.item.audioTimePitchAlgorithm = pitchAlgorithm
            decks.whileHushed(playing: isPlaying) { [self] in decks.current?.item.audioTimePitchAlgorithm = pitchAlgorithm }
        }
    }

    private var pitchAlgorithm: AVAudioTimePitchAlgorithm { keepsPitch ? .spectral : .varispeed }

    static let speedSteps: [Float] = [0.5, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    func stepSpeed(faster: Bool) {
        let next = faster ? Self.speedSteps.first { $0 > speed + 0.001 } : Self.speedSteps.last { $0 < speed - 0.001 }
        if let next { speed = next }
    }

    private let decks: DeckPair
    private var player: AVPlayer { decks.onAir }

    private let api: SoundCloudAPI
    /// Bumped by every request to start a new queue: a slow one resolving after a later click installs nothing.
    @ObservationIgnored private var installTicket = 0
    /// Bumped whenever another track is put on air, so a prepare that finishes late is thrown away.
    @ObservationIgnored private var playTicket = 0
    private var refill: Task<Void, Never>?
    /// The queue panel pages like every other list, and shows a footer while a slice is in flight.
    private(set) var isRefilling = false
    /// Where a restored track left off, kept until its item exists and then until that item can seek:
    /// playback starts once the seek lands, so the first second of the track is never heard.
    @ObservationIgnored private var resumePosition: (trackID: Int, seconds: Double)?
    @ObservationIgnored private var resumingItem: ObjectIdentifier?
    @ObservationIgnored private var persistedPosition: Double = 0
    /// A track started sounding — the moment its `play` event goes to SoundCloud.
    @ObservationIgnored var onTrackPlayed: ((SCTrack, PlayContext?) -> Void)?
    // Only the installed collection plays in its context; Play Next and related autoplay do not.
    @ObservationIgnored private var playContext: (context: PlayContext, trackIDs: Set<Int>)?
    private let reporter: PlayReporter
    /// Unfiltered, so an empty answer means the request failed rather than every track being locked.
    private var resolveIDs: (([Int]) async -> [SCTrack])?
    private static let refillThreshold = 10
    private static let autoplayKey = "autoplayRelated"
    private static let volumeKey = "playerVolume"
    private static let keepsPitchKey = "keepsPitch"
    nonisolated static let headSize = 60
    nonisolated static let leadSize = 40
    private var sessionSave: Task<Void, Never>?
    private var terminationObserver: (any NSObjectProtocol)?
    private var warmTask: Task<Void, Never>?
    private let sessions: SessionStore
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?

    /// Consecutive failed tracks since the last one that actually played. Bounds auto-skip so a
    /// wholly unplayable queue stops instead of spinning forever (esp. under repeat all).
    private var consecutiveFailures = 0
    /// One failure per item: `.status == .failed` and `failedToPlayToEndTime` can both fire.
    private var itemFailed = false
    private var isSeeking = false
    private var seekToken = 0

    init(api: SoundCloudAPI, sessions: SessionStore = .standard) {
        self.api = api
        self.sessions = sessions
        reporter = PlayReporter(api: api)
        autoplayRelated = UserDefaults.standard.object(forKey: Self.autoplayKey) as? Bool ?? true
        let volume = UserDefaults.standard.object(forKey: Self.volumeKey) as? Float ?? 1
        self.volume = volume
        keepsPitch = UserDefaults.standard.object(forKey: Self.keepsPitchKey) as? Bool ?? true
        decks = DeckPair(volume: volume)
        // The debounced save can still be waiting when the app quits, so the last word is written here.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistSession(waiting: true) }
        }
        decks.onTick = { [weak self] seconds, length in self?.tick(seconds, itemDuration: length) }
        decks.onStatus = { [weak self] status in self?.deckDidChange(to: status) }
        decks.onItem = { [weak self] event in self?.item(event) }
        nowPlaying = NowPlayingBridge(engine: self)
    }

    private func tick(_ seconds: Double, itemDuration: Double?) {
        // While a seek is in flight the player still reports the old position; taking it would
        // bounce the clock back before it lands on the target.
        if !isSeeking {
            currentTime = seconds
            reporter.tick(seconds, track: currentTrack?.id)
        }
        // A quit the termination hook never sees — a crash, a stop from Xcode — loses at most this much.
        if abs(currentTime - persistedPosition) >= 5 { persistSession() }
        if let itemDuration, itemDuration != duration {
            duration = itemDuration
            // Now Playing was last told at start, before the item knew its length or had started.
            updateNowPlayingInfo()
        }
        considerWarmingNext()
    }

    /// Sound actually starting and stopping on the deck on air — the moments the web player reports.
    private func deckDidChange(to status: AVPlayer.TimeControlStatus) {
        reanchorClock()
        guard let track = currentTrack, let current = decks.current else { return }
        switch status {
        case .playing:
            let context = playContext.flatMap { $0.trackIDs.contains(track.id) ? $0.context : nil }
            let now = PlayReporter.Playing(track: track, transcoding: current.transcoding, context: context)
            if reporter.started(now, item: ObjectIdentifier(current.item), at: currentTime) {
                onTrackPlayed?(track, context)
            }
        case .paused:
            reporter.paused(ended: duration > 0 && currentTime >= duration - 1)
        default:
            break
        }
    }

    private func reanchorClock() {
        let reported = player.currentTime().seconds
        // Mid-seek the player still answers with where it was, so the target stands until it lands.
        anchorClock(at: isSeeking || !reported.isFinite ? currentTime : reported)
    }

    private func anchorClock(at position: Double) {
        let rate = player.timeControlStatus == .playing ? Double(player.rate) : 0
        clock = Playhead(position: position, anchor: .now, rate: rate)
    }

    var canGoNext: Bool { !queue.isEmpty && (state.hasTrackAhead || autoplayRelated) }
    var canGoPrevious: Bool { state.canGoBack }

    // MARK: - Queue control

    /// Plays `track` within the context of `tracks` (the surrounding list becomes the queue).
    /// The one way a queue is installed. Everything that starts playback goes through `PlayQueue`,
    /// which is what stops a screen from silently queueing only the rows it has loaded.
    func install(ids: [Int],
                 startingAt trackID: Int? = nil,
                 shuffled: Bool,
                 head: Int = PlayerEngine.headSize,
                 lead: Int = PlayerEngine.leadSize,
                 context: PlayContext? = nil,
                 ticket: Int? = nil,
                 resolve collection: @escaping ([Int]) async -> [SCTrack]) async {
        let ticket = ticket ?? claimInstall()
        guard let plan = QueueState.install(ids: ids, startingAt: trackID, shuffled: shuffled,
                                            head: head, lead: lead) else { return }
        // Go+ and region-locked tracks never enter the queue: resolved, then dropped.
        let tracks = await collection(plan.headIDs).filter(\.isPlayable)
        guard isCurrentInstall(ticket) else { return }
        // Committed only once the head is in hand: installing first left the previous queue playing
        // underneath the new collection's tail.
        guard !tracks.isEmpty else {
            report("Couldn't start playback — check your connection")
            return
        }

        consecutiveFailures = 0
        resolveIDs = collection
        playContext = context.map { ($0, Set(plan.ids)) }
        resumePosition = nil
        state.install(plan, tracks: tracks)
        await playCurrent()
    }

    func claimInstall() -> Int {
        installTicket += 1
        return installTicket
    }

    func isCurrentInstall(_ ticket: Int) -> Bool { ticket == installTicket }

    func playNext(_ track: SCTrack) {
        enqueue(track, next: true)
    }

    func playLater(_ track: SCTrack) {
        enqueue(track, next: false)
    }

    private func enqueue(_ track: SCTrack, next: Bool) {
        guard track.isPlayable else { return }
        // With an empty queue this just plays it.
        guard !queue.isEmpty, let current = currentTrack else {
            Task { await PlayQueue.exactly([track]).start(track, on: self) }
            return
        }
        state.insert(track, next: next, currentID: current.id)
    }

    func next() async {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 >= queue.count {
            await pullRefill()
        } else if queue.count - currentIndex <= Self.refillThreshold {
            Task { await pullRefill() }
        }
        // A press of Next lands on the same warmed deck an ended track would have.
        if swapToUpcoming() { return }
        if currentIndex + 1 < queue.count {
            state.currentIndex += 1
        } else if repeatMode == .all, let lap = state.lapStep {
            guard await resolve(lap) == .applied else { return }
        } else if repeatMode == .all {
            state.startLapInPlace()
        } else {
            // Next on the last track does what its end would have done.
            if autoplayRelated, let track = currentTrack { await extendWithRelated(to: track) }
            return
        }
        HandoffTrace.shared.mark("queue ready")
        await playCurrent()
    }

    func previous() async {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if currentIndex > 0 {
            state.currentIndex -= 1
        } else if !state.leadingIDs.isEmpty || (repeatMode == .all && !state.pendingIDs.isEmpty),
                  let front = state.frontStep {
            guard await resolve(front) == .applied else {
                seek(to: 0)
                return
            }
        } else if repeatMode == .all {
            state.currentIndex = queue.count - 1
        } else {
            return
        }
        await playCurrent()
    }

    /// Resolves what a step of the queue asks for and applies it, unless another queue came in meanwhile.
    private func resolve(_ step: QueueState.Step) async -> QueueState.Outcome {
        guard let resolveIDs else { return .stale }
        let epoch = state.epoch
        let missing = state.missing(for: step)
        var resolved: [SCTrack] = []
        if !missing.isEmpty {
            resolved = await resolveIDs(missing)
            // A failed batch would otherwise commit only the few ids that happened to be known already.
            guard !resolved.isEmpty else { return .stale }
        }
        guard epoch == state.epoch else { return .stale }
        return state.apply(step, resolved: resolved)
    }

    /// Reinstates last session's queue without starting playback — the transport shows where you
    /// left off and the first press picks it up. Only `window` arrives resolved; the rest of the queue
    /// waits as ids on either side of it.
    func restore(_ session: Session, window: Range<Int>, tracks resolved: [SCTrack],
                 resolve collection: @escaping ([Int]) async -> [SCTrack]) {
        guard currentTrack == nil, state.restore(session, window: window, tracks: resolved),
              let track = state.current else { return }
        resolveIDs = collection
        playContext = nil
        currentTrack = track
        duration = Double(track.duration) / 1000
        // Within a few seconds of either end the start is as good, and resuming at the very end would only skip.
        if let position = session.position, position > 1, position < duration - 3 {
            resumePosition = (track.id, position)
            currentTime = position
        }
    }

    /// Stops playback and empties the queue, including what was stored for the next launch.
    func clearSession() {
        reporter.stopped()
        discardUpcoming()
        decks.stop()
        isPlaying = false
        installTicket += 1
        playTicket += 1
        state.clear()
        resumePosition = nil
        resumingItem = nil
        resolveIDs = nil
        playContext = nil
        currentTrack = nil
        currentTime = 0
        duration = 0
        sessionSave?.cancel()
        sessions.remove()
        updateNowPlayingInfo()
    }

    func togglePlayPause(forcePlay: Bool = false, forcePause: Bool = false) {
        guard currentTrack != nil else { return }
        // Restored sessions have a track but no loaded item yet.
        guard player.currentItem != nil else {
            if !forcePause { Task { await playCurrent() } }
            return
        }
        let shouldPlay = forcePlay || (!forcePause && !isPlaying)
        if shouldPlay {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
            persistSession()
        }
        updateNowPlayingInfo()
    }

    func toggleShuffle() {
        if state.toggleShuffle(currentID: currentTrack?.id), let mix = state.mixStep {
            Task { _ = await resolve(mix) }
        }
    }

    /// Resolves the next slice of pending ids and appends it to both orders.
    /// Coalesced rather than gated: `next()` relies on the queue having actually grown by the time
    /// this returns, so a second caller has to wait for the first instead of giving up.
    private func pullRefill() async {
        if let refill { return await refill.value }
        guard resolveIDs != nil, state.refillStep != nil else { return }
        let task = Task { await performRefill() }
        refill = task
        await task.value
        refill = nil
    }

    private func performRefill() async {
        isRefilling = true
        defer { isRefilling = false }
        // A slice of locked or deleted tracks is spent and the next one tried, so it can't stall the tail.
        while let step = state.refillStep {
            guard await resolve(step) == .nothingNew else { return }
        }
    }

    /// The panel's paging trigger; playback refills through `next()` on its own.
    func loadMoreQueue() async {
        await pullRefill()
    }

    func cycleRepeat() {
        state.repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    func setRepeat(_ mode: RepeatMode) {
        state.repeatMode = mode
    }

    func nudgeVolume(by step: Float) {
        volume = min(max(volume + step, 0), 1)
    }

    func jump(to index: Int) async {
        guard queue.indices.contains(index) else { return }
        state.currentIndex = index
        await playCurrent()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        state.move(from: source, to: destination, currentID: currentTrack?.id)
    }

#if DEBUG
    /// Fills the queue without touching playback so previews can render a populated panel; `queue`
    /// is otherwise only ever set by playback itself.
    func seedForPreview(_ tracks: [SCTrack], at index: Int = 0, pending: Int = 0) {
        state.seedForPreview(tracks, at: index, pending: pending)
        currentTrack = state.current
    }
#endif

    /// Drops everything queued after the current track. Playback is untouched.
    func clearUpcoming() {
        state.clearUpcoming()
    }

    func removeFromQueue(atOffsets offsets: IndexSet) {
        guard state.remove(atOffsets: offsets, currentID: currentTrack?.id) else { return }
        if queue.isEmpty {
            reporter.stopped()
            player.pause()
            isPlaying = false
            currentTrack = nil
            updateNowPlayingInfo()
        } else {
            Task { await playCurrent() }
        }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        updateNowPlayingInfo()
        scheduleSessionSave()
        // A restored track has no item to seek yet; the position waits for the first press.
        if player.currentItem == nil, let id = currentTrack?.id {
            resumePosition = (id, seconds)
            return
        }
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

    func storedSession() -> Session? {
        sessions.load()
    }

    // Edits land in bursts — a drag moves the queue on every step — so they settle before a write.
    private func scheduleSessionSave() {
        sessionSave?.cancel()
        sessionSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistSession()
        }
    }

    private func persistSession(waiting: Bool = false) {
        sessionSave?.cancel()
        guard !queue.isEmpty else { return }
        // Between a track change and the new track going on air the clock still holds the old one's time.
        let onAir = currentTrack.map { queue.indices.contains(currentIndex) && queue[currentIndex].id == $0.id } ?? false
        let position = onAir ? currentTime : 0
        persistedPosition = position
        sessions.save(state.session(position: position), waiting: waiting)
    }

    private func playCurrent() async {
        persistSession()
        guard queue.indices.contains(currentIndex) else { return }
        let track = queue[currentIndex]
        playTicket += 1
        let ticket = playTicket
        currentTrack = track
        state.markPlayed(track.id)
        HandoffTrace.shared.mark("playCurrent")
        loadArtwork(for: track)

        do {
            let prepared = try await prepare(track)
            guard ticket == playTicket else {
                prepared.retire()
                return
            }
            start(prepared)
        } catch {
            // A skipped track's failure must not advance past the one picked after it.
            guard ticket == playTicket else { return }
            failCurrentTrack((error as? PrepareFailure)?.message ?? error.surfaced())
        }
    }

    private struct PrepareFailure: Error { let message: String }

    /// Builds a track without putting it on air, so one path serves both the track playing now and
    /// the one being warmed for later. Touches no playback state — the caller owns that.
    private func prepare(_ track: SCTrack) async throws -> PreparedTrack {
        let prepared = try await source(for: track)
        prepared.item.audioTimePitchAlgorithm = pitchAlgorithm
        return prepared
    }

    private func source(for track: SCTrack) async throws -> PreparedTrack {
        HandoffTrace.shared.mark("offered: " + track.media.transcodings
            .map { "\($0.format.protocol)/\($0.preset)" }.joined(separator: ", "))

        if let hlsAAC = track.bestHLSAAC {
            HandoffTrace.shared.mark("source: HLS AAC")
            return buildHLS(hlsAAC, trackAuthorization: track.trackAuthorization, fairPlayToken: nil)
        }
        if let fairPlay = track.bestFairPlayAAC {
            HandoffTrace.shared.mark("source: FairPlay AAC")
            let stream = try await api.resolve(
                for: fairPlay, trackAuthorization: track.trackAuthorization)
            HandoffTrace.shared.mark("license token")
            guard let token = stream.licenseAuthToken else {
                throw PrepareFailure(message: "no license token")
            }
            return buildHLS(fairPlay, trackAuthorization: track.trackAuthorization,
                            fairPlayToken: token, playlistURL: URL(string: stream.url))
        }
        if let progressive = track.bestProgressive {
            HandoffTrace.shared.mark("source: progressive")
            let url = try await api.streamURL(
                for: progressive, trackAuthorization: track.trackAuthorization)
            return PreparedTrack(item: AVPlayerItem(url: url), transcoding: progressive)
        }
        if let hlsMP3 = track.bestHLSMP3 {
            HandoffTrace.shared.mark("source: HLS MP3")
            return buildHLS(hlsMP3, trackAuthorization: track.trackAuthorization, fairPlayToken: nil)
        }
        throw PrepareFailure(message: "no playable source")
    }

    /// Builds an HLS item behind the resource loader. With `fairPlayToken` set, a content-key
    /// session is attached to the asset before the item is made from it.
    private func buildHLS(_ transcoding: SCTranscoding, trackAuthorization: String,
                          fairPlayToken: String?, playlistURL: URL? = nil) -> PreparedTrack {
        let loader = HLSResourceLoader(
            api: api, transcoding: transcoding, trackAuthorization: trackAuthorization,
            playlistURL: playlistURL)

        let asset = AVURLAsset(url: loader.assetURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)

        var keySession: AVContentKeySession?
        var keyDelegate: FairPlayKeyDelegate?
        if let fairPlayToken {
            let session = AVContentKeySession(keySystem: .fairPlayStreaming)
            let delegate = FairPlayKeyDelegate(licenseAuthToken: fairPlayToken)
            session.setDelegate(delegate, queue: delegate.queue)
            session.addContentKeyRecipient(asset)
            keySession = session
            keyDelegate = delegate
        }

        return PreparedTrack(item: AVPlayerItem(asset: asset), transcoding: transcoding, loader: loader,
                             keySession: keySession, keyDelegate: keyDelegate)
    }

    private func start(_ prepared: PreparedTrack) {
        discardUpcoming()
        let resume = resumePosition.flatMap { $0.trackID == currentTrack?.id ? $0.seconds : nil }
        resumePosition = nil
        currentTime = resume ?? 0
        duration = 0
        itemFailed = false
        HandoffTrace.shared.mark("replaceCurrentItem")
        if resume != nil {
            resumingItem = ObjectIdentifier(prepared.item)
            seekToken += 1
            isSeeking = true
        } else {
            resumingItem = nil
        }
        decks.put(prepared, playing: resume == nil)
        isPlaying = true
        updateNowPlayingInfo()
    }

    /// Seeks a restored track to where it left off once its item can take a seek, then starts it.
    private func resumeIfWaiting(_ item: AVPlayerItem) {
        guard resumingItem == ObjectIdentifier(item) else { return }
        resumingItem = nil
        let token = seekToken
        let itemID = ObjectIdentifier(item)
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.seekToken == token { self.isSeeking = false }
                // Paused while the seek was landing, or already moved on to another track: stay put.
                guard self.isPlaying, self.player.currentItem.map(ObjectIdentifier.init) == itemID else { return }
                self.player.play()
            }
        }
    }

    private func item(_ event: DeckPair.ItemEvent) {
        switch event {
        case .ended:
            playbackFinished()
        case .failed(let message):
            reportItemFailure(message)
        case .ready(let item):
            consecutiveFailures = 0
            lastError = nil
            resumeIfWaiting(item)
#if DEBUG
            let reported = item.duration.seconds
            if reported.isFinite {
                let claimed = Double(currentTrack?.duration ?? 0) / 1000
                PrimingProbe.note("item duration " + String(format: "%.6f", reported)
                    + "s · api-v2 says " + String(format: "%.3f", claimed) + "s · " + (currentTrack?.title ?? "?"))
            }
#endif
        }
    }

    // MARK: - Warming the next track

    /// How long before the end the next track starts loading. Long enough to cover a licence, a
    /// playlist and a first segment on a slow connection; short enough that skipping around does
    /// not fetch a track per press.
    private static let preloadLead: TimeInterval = 20

    /// Called from the clock. Warms at most one track, and only the one the queue already holds:
    /// an end-of-queue handoff needs a refill first and goes the ordinary way.
    private func considerWarmingNext() {
        guard warmTask == nil, repeatMode != .one else { return }
        guard duration > 0, (duration - currentTime) / Double(speed) <= Self.preloadLead else { return }
        guard queue.indices.contains(currentIndex + 1) else { return }
        let track = queue[currentIndex + 1]
        if let upcomingTrackID = decks.upcomingTrackID {
            guard upcomingTrackID != track.id else { return }
            // Play Next or a drag put another track next after this one was warmed.
            discardUpcoming()
        }
        warmTask = Task { await warm(track) }
    }

    private func warm(_ track: SCTrack) async {
        let epoch = state.epoch
        let prepared = try? await prepare(track)
        // Cancelled means discarded: `warmTask` may already hold the next warm, so leave it alone.
        guard !Task.isCancelled else {
            prepared?.retire()
            return
        }
        warmTask = nil
        guard let prepared else { return }
        // The queue can move while a licence and a playlist are being fetched.
        guard epoch == state.epoch,
              queue.indices.contains(currentIndex + 1),
              queue[currentIndex + 1].id == track.id else {
            prepared.retire()
            return
        }
        decks.park(prepared, as: track.id)
    }

    /// Puts the warmed deck on air. Returns false when nothing is warmed or the queue moved under
    /// it, in which case the caller falls back to the ordinary path.
    private func swapToUpcoming() -> Bool {
        guard let warmedID = decks.upcomingTrackID,
              queue.indices.contains(currentIndex + 1),
              queue[currentIndex + 1].id == warmedID else { return false }

        HandoffTrace.shared.mark("swap to warmed deck")
        playTicket += 1
        decks.swap()
        state.currentIndex += 1
        let track = queue[currentIndex]
        currentTrack = track
        state.markPlayed(track.id)
        currentTime = 0
        duration = 0
        itemFailed = false
        isPlaying = true

        loadArtwork(for: track)
        updateNowPlayingInfo()
        persistSession()
        return true
    }

    /// Throws away a warmed track that is no longer next — a skip, a reorder, a new queue.
    private func discardUpcoming() {
        warmTask?.cancel()
        warmTask = nil
        decks.discardUpcoming()
    }

    private func playbackFinished() {
        HandoffTrace.shared.begin(currentTrack.map { "\($0.id) \($0.title)" } ?? "end of queue")
        reporter.nextTrigger = repeatMode == .one ? .repeat : .auto
        if repeatMode == .one {
            Task { await playCurrent() }
        } else if swapToUpcoming() {
            if queue.count - currentIndex <= Self.refillThreshold {
                Task { await pullRefill() }
            }
        } else if state.hasTrackAhead {
            Task { await next() }
        } else if autoplayRelated, let track = currentTrack {
            let epoch = state.epoch
            Task {
                if !(await extendWithRelated(to: track)), epoch == state.epoch, currentTrack?.id == track.id {
                    isPlaying = false
                }
            }
        } else {
            isPlaying = false
        }
    }

    /// Grows the queue with tracks related to the last one. Only reached at a genuine end-of-queue —
    /// the last track ending, or Next pressed on it. A track auto-skipped for being unplayable only
    /// moves within the queue, so a blocked track never drags it off into recommendations.
    @discardableResult
    private func extendWithRelated(to track: SCTrack) async -> Bool {
        let epoch = state.epoch
        let related = ((try? await api.relatedTracks(id: track.id).collection) ?? []).filter(\.isPlayable)
        // Another queue started, or another track picked, while recommendations were on their way.
        guard epoch == state.epoch, currentTrack?.id == track.id else { return false }
        let known = Set(queue.map(\.id))
        let fresh = related.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return false }
        state.appendRelated(fresh)
        await next()
        return true
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
        advanceAfterFailure()
    }

    /// Skips to the next track on failure, but gives up once the whole queue has failed in a row so
    /// an unplayable queue (or repeat all) doesn't loop forever.
    private func advanceAfterFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures < queue.count else {
            isPlaying = false
            return
        }
        if state.hasTrackAhead {
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

    // MARK: - Now Playing

    private func loadArtwork(for track: SCTrack) {
        nowPlaying?.loadArtwork(for: track.id, from: track.coverURL.liveArtwork.scArtwork(.hero))
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            nowPlaying?.update(nil)
            return
        }
        // Without a duration the system draws no timeline at all, so the catalog length stands in.
        let total = duration > 0 ? duration : Double(track.duration) / 1000
        nowPlaying?.update(.init(title: track.title, artist: track.artistLine, elapsed: currentTime,
                                 duration: total, isPlaying: isPlaying, rate: Double(speed)))
    }
}
