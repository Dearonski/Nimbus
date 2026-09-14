import AppKit
import AVFoundation
import Foundation
import MediaPlayer
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
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    private(set) var queue: [SCTrack] = [] { didSet { scheduleSessionSave() } }
    private(set) var currentIndex = 0 { didSet { scheduleSessionSave() } }
    private(set) var isShuffled = false { didSet { scheduleSessionSave() } }
    /// Tracks resolved lazily behind the loaded queue, so the panel can count and page them.
    var pendingCount: Int { pendingIDs.count }
    private(set) var repeatMode: RepeatMode = .off { didSet { scheduleSessionSave() } }
    /// Keep playing past the end of the queue with tracks related to the last one.
    var autoplayRelated: Bool {
        didSet { UserDefaults.standard.set(autoplayRelated, forKey: Self.autoplayKey) }
    }

    /// Lives here rather than on either deck: both follow it, and it is remembered across launches.
    var volume: Float {
        didSet {
            // Both decks: the standby one is already warming the next track and would otherwise
            // come on air at whatever level it was built with.
            for deck in decks { deck.volume = volume }
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        }
    }

    private let deckA = AVPlayer()
    private let deckB = AVPlayer()
    private var isDeckAActive = true

    /// The deck on air. Every transport control — play, pause, seek, the clock, Now Playing —
    /// reads through here, so putting the other deck on air moves all of them at once.
    private var player: AVPlayer { isDeckAActive ? deckA : deckB }
    /// The deck that warms the next track while this one plays.
    private var standby: AVPlayer { isDeckAActive ? deckB : deckA }
    private var decks: [AVPlayer] { [deckA, deckB] }

    private let api: SoundCloudAPI
    private var originalOrder: [SCTrack] = []

    /// The collection behind the queue, as ids in their canonical order, plus the ids still to be
    /// resolved. Holding the whole collection here — not just the resolved head — is what lets
    /// shuffle cover everything instead of the slice that happens to be loaded.
    private var canonicalIDs: [Int] = []
    /// Bumped wherever a new collection is installed, so work resumed after an await can tell a
    /// skip inside the same queue from a different queue entirely.
    private var queueEpoch = 0
    private var refill: Task<Void, Never>?
    /// The queue panel pages like every other list, and shows a footer while a slice is in flight.
    private(set) var isRefilling = false
    private var pendingIDs: [Int] = [] { didSet { scheduleSessionSave() } }
    /// Unresolved rows of the collection above the queue: Previous walks up into them and a lap under
    /// repeat starts from them, but the collection ending never wraps round to them.
    private var leadingIDs: [Int] = [] { didSet { scheduleSessionSave() } }
    /// Tracks this queue has actually put on air. Turning shuffle on keeps only these behind the
    /// current track, so Previous walks what was heard rather than rows it never reached.
    @ObservationIgnored private var playedIDs: Set<Int> = []
    /// Where a restored track left off, kept until its item exists and then until that item can seek:
    /// playback starts once the seek lands, so the first second of the track is never heard.
    @ObservationIgnored private var resumePosition: (trackID: Int, seconds: Double)?
    @ObservationIgnored private var resumingItem: ObjectIdentifier?
    @ObservationIgnored private var persistedPosition: Double = 0
    private var resolveIDs: (([Int]) async -> [SCTrack])?
    private static let refillThreshold = 10
    private static let autoplayKey = "autoplayRelated"
    private static let volumeKey = "playerVolume"
    private static let sessionURL = URL.applicationSupportDirectory.appending(path: "session.json")
    private static let sessionWriter = DispatchQueue(label: "io.github.dearonski.Nimbus.session", qos: .utility)
    nonisolated static let headSize = 60
    nonisolated static let leadSize = 40
    private var sessionSave: Task<Void, Never>?
    private var terminationObserver: (any NSObjectProtocol)?
    private static let refillSize = 50
    /// The track the player is playing, with its loader and key session. Retired only once its
    /// successor is in the player, so nothing tears down keys still in use.
    private var current: PreparedTrack?
    /// The next track, built and buffering in the standby deck.
    private var upcoming: PreparedTrack?
    private var upcomingTrackID: Int?
    private var warmTask: Task<Void, Never>?
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
    private var timeObservers: [(deck: AVPlayer, token: Any)] = []
    private var timeControlObservers: [NSKeyValueObservation] = []

    init(api: SoundCloudAPI) {
        self.api = api
        autoplayRelated = UserDefaults.standard.object(forKey: Self.autoplayKey) as? Bool ?? true
        volume = UserDefaults.standard.object(forKey: Self.volumeKey) as? Float ?? 1
        // Observed on both decks rather than moved on every swap. A periodic observer only fires
        // while its deck is playing, and the guard keeps the standby deck out of the clock.
        for deck in decks {
            deck.volume = volume
            let token = deck.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, self.player === deck else { return }
                    // While a seek is in flight the player still reports the old position; taking
                    // it would bounce the clock back before it lands on the target.
                    if !self.isSeeking { self.currentTime = time.seconds }
                    // A quit the termination hook never sees — a crash, a stop from Xcode — loses at most this much.
                    if abs(self.currentTime - self.persistedPosition) >= 5 { self.persistSession() }
                    if let itemDuration = deck.currentItem?.duration.seconds, itemDuration.isFinite,
                       itemDuration != self.duration {
                        self.duration = itemDuration
                        // Now Playing was last told at start, before the item knew its length or had started.
                        self.updateNowPlayingInfo()
                    }
                    self.considerWarmingNext()
                }
            }
            timeObservers.append((deck, token))
        }
        configureRemoteCommands()
        // The debounced save can still be waiting when the app quits, so the last word is written here.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistSession(waiting: true) }
        }
#if DEBUG
        for deck in decks {
            timeControlObservers.append(deck.observe(\.timeControlStatus, options: [.new]) { observed, _ in
                switch observed.timeControlStatus {
                case .playing:
                    HandoffTrace.shared.end("playing")
                case .waitingToPlayAtSpecifiedRate:
                    let reason = observed.reasonForWaitingToPlay?.rawValue ?? "unknown"
                    HandoffTrace.shared.mark("waiting — \(reason)")
                default:
                    break
                }
            })
        }
#endif
    }

    // AVPlayer.h: releasing the observer without this call is undefined behaviour.
    isolated deinit {
        for entry in timeObservers { entry.deck.removeTimeObserver(entry.token) }
    }

    /// A later row, an unresolved tail, or a lap under repeat — somewhere to go without leaving the collection.
    private var hasTrackAhead: Bool {
        currentIndex + 1 < queue.count || !pendingIDs.isEmpty || repeatMode == .all
    }
    var canGoNext: Bool { !queue.isEmpty && (hasTrackAhead || autoplayRelated) }
    var canGoPrevious: Bool { !queue.isEmpty && (currentIndex > 0 || !leadingIDs.isEmpty || repeatMode == .all) }

    // MARK: - Queue control

    /// Plays `track` within the context of `tracks` (the surrounding list becomes the queue).
    /// The one way a queue is installed. Everything that starts playback goes through `PlayQueue`,
    /// which is what stops a screen from silently queueing only the rows it has loaded.
    func install(ids: [Int],
                 startingAt trackID: Int? = nil,
                 shuffled: Bool,
                 head: Int = PlayerEngine.headSize,
                 lead: Int = PlayerEngine.leadSize,
                 resolve: @escaping ([Int]) async -> [SCTrack]) async {
        guard !ids.isEmpty else { return }

        var order = ids
        if shuffled { order.shuffle() }
        var leading = 0
        var above: [Int] = []
        if let trackID, let index = order.firstIndex(of: trackID) {
            if shuffled {
                // A random order has no "above": whatever preceded the pick is still to come.
                order = Array(order[index...]) + Array(order[..<index])
            } else {
                // Rows above the clicked one stay ahead of it, or Previous on it had nowhere to go but its own start.
                leading = min(index, lead)
                above = Array(order[..<(index - leading)])
                order = Array(order[(index - leading)...])
            }
        }

        let headIDs = Array(order.prefix(leading + head))
        let tracks = await resolve(headIDs)
        // Committed only once the head is in hand: installing first left the previous queue playing
        // underneath the new collection's tail.
        guard !tracks.isEmpty else {
            report("Couldn't start playback — check your connection")
            return
        }

        queueEpoch += 1
        consecutiveFailures = 0
        canonicalIDs = ids
        resolveIDs = resolve
        isShuffled = shuffled
        pendingIDs = Array(order.dropFirst(headIDs.count))
        leadingIDs = above
        playedIDs = []
        resumePosition = nil
        queue = tracks
        originalOrder = tracks
        let resolved = Set(tracks.map(\.id))
        let startID = headIDs.dropFirst(leading).first { resolved.contains($0) }
        currentIndex = startID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        await playCurrent()
    }

    /// Queues `track` to play right after the current one. With an empty queue this just plays it.
    func playNext(_ track: SCTrack) {
        guard !queue.isEmpty, currentTrack != nil else {
            Task { await PlayQueue.exactly([track]).start(track, on: self) }
            return
        }
        queue.removeAll { $0.id == track.id && $0.id != currentTrack?.id }
        currentIndex = queue.firstIndex { $0.id == currentTrack?.id } ?? currentIndex
        queue.insert(track, at: min(currentIndex + 1, queue.count))
        syncOriginalOrder(inserting: track, afterCurrent: true)
    }

    func playLater(_ track: SCTrack) {
        guard !queue.isEmpty, currentTrack != nil else {
            Task { await PlayQueue.exactly([track]).start(track, on: self) }
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
        // A press of Next lands on the same warmed deck an ended track would have.
        if swapToUpcoming() { return }
        if currentIndex + 1 < queue.count {
            currentIndex += 1
        } else if repeatMode == .all, !leadingIDs.isEmpty {
            guard await startLapFromTop() else { return }
        } else if repeatMode == .all {
            // A fresh lap gets a fresh order; repeating the same random sequence isn't shuffle.
            if isShuffled { queue = queue.shuffled() }
            currentIndex = 0
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
            currentIndex -= 1
        } else if !leadingIDs.isEmpty || (repeatMode == .all && !pendingIDs.isEmpty) {
            guard await pullToFront(fromLeading: !leadingIDs.isEmpty) else {
                seek(to: 0)
                return
            }
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
        } else {
            return
        }
        await playCurrent()
    }

    /// Previous on the queue's first track: the rows above it, or under repeat the end of the tail. A
    /// slice is resolved and put in front, landing on its last track.
    private func pullToFront(fromLeading: Bool) async -> Bool {
        guard let resolveIDs else { return false }
        let source = fromLeading ? leadingIDs : pendingIDs
        guard !source.isEmpty else { return false }
        let epoch = queueEpoch
        let slice = Array(source.suffix(Self.refillSize))

        var known = Dictionary(originalOrder.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = slice.filter { known[$0] == nil }
        if !missing.isEmpty {
            for track in await resolveIDs(missing) { known[track.id] = track }
        }

        // Next pressed or a refill taken from the same ids while this resolved: the front has moved.
        let now = fromLeading ? leadingIDs : pendingIDs
        guard epoch == queueEpoch, currentIndex == 0,
              now.suffix(slice.count).elementsEqual(slice) else { return false }
        let inQueue = Set(queue.map(\.id))
        let front = slice.compactMap { known[$0] }.filter { !inQueue.contains($0.id) }
        guard !front.isEmpty else { return false }

        if fromLeading { leadingIDs.removeLast(slice.count) } else { pendingIDs.removeLast(slice.count) }
        queue.insert(contentsOf: front, at: 0)
        let seen = Set(originalOrder.map(\.id))
        originalOrder.insert(contentsOf: front.filter { !seen.contains($0.id) }, at: 0)
        currentIndex = front.count - 1
        return true
    }

    /// A lap under repeat starts at the collection's first row, which can still be an unresolved id
    /// above the queue: the next slice of those becomes the queue and what was played waits behind it.
    private func startLapFromTop() async -> Bool {
        guard let resolveIDs, !leadingIDs.isEmpty else { return false }
        let epoch = queueEpoch
        let headIDs = Array(leadingIDs.prefix(Self.refillSize))

        var known = Dictionary(originalOrder.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = headIDs.filter { known[$0] == nil }
        if !missing.isEmpty {
            for track in await resolveIDs(missing) { known[track.id] = track }
        }

        guard epoch == queueEpoch, leadingIDs.starts(with: headIDs) else { return false }
        let head = headIDs.compactMap { known[$0] }
        guard !head.isEmpty else { return false }

        pendingIDs = Array(leadingIDs.dropFirst(headIDs.count)) + queue.map(\.id) + pendingIDs
        leadingIDs = []
        queue = head
        let seen = Set(originalOrder.map(\.id))
        originalOrder.append(contentsOf: head.filter { !seen.contains($0.id) })
        currentIndex = 0
        return true
    }

    /// Reinstates last session's queue without starting playback — the transport shows where you
    /// left off and the first press picks it up. Only `window` arrives resolved; the rest of the queue
    /// waits as ids on either side of it.
    func restore(_ session: Session, window: Range<Int>, tracks: [SCTrack],
                 resolve: @escaping ([Int]) async -> [SCTrack]) {
        guard !tracks.isEmpty, currentTrack == nil else { return }
        let currentID = session.queue.indices.contains(session.index) ? session.queue[session.index] : nil
        queueEpoch += 1
        queue = tracks
        originalOrder = tracks
        pendingIDs = Array(session.queue[window.upperBound...]) + session.pending
        leadingIDs = session.leading + Array(session.queue[..<window.lowerBound])
        playedIDs = []
        canonicalIDs = session.canonical
        resolveIDs = resolve
        isShuffled = session.isShuffled
        repeatMode = session.repeatMode
        // By id: a track that no longer resolves drops out and shifts every position after it.
        currentIndex = currentID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        currentTrack = queue[currentIndex]
        duration = Double(queue[currentIndex].duration) / 1000
        // Within a few seconds of either end the start is as good, and resuming at the very end would only skip.
        if let position = session.position, position > 1, position < duration - 3 {
            resumePosition = (queue[currentIndex].id, position)
            currentTime = position
        }
    }

    /// Stops playback and empties the queue, including what was stored for the next launch.
    func clearSession() {
        discardUpcoming()
        for deck in decks {
            deck.pause()
            deck.replaceCurrentItem(with: nil)
        }
        current?.retire()
        current = nil
        isPlaying = false
        queueEpoch += 1
        queue = []
        originalOrder = []
        canonicalIDs = []
        pendingIDs = []
        leadingIDs = []
        playedIDs = []
        resumePosition = nil
        resumingItem = nil
        resolveIDs = nil
        currentIndex = 0
        currentTrack = nil
        currentTime = 0
        duration = 0
        sessionSave?.cancel()
        let url = Self.sessionURL
        Self.sessionWriter.async { try? FileManager.default.removeItem(at: url) }
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
            persistSession()
        }
        updateNowPlayingInfo()
    }

    func toggleShuffle() {
        isShuffled.toggle()
        guard let current = currentTrack else { return }
        if isShuffled {
            guard queue.indices.contains(currentIndex) else { return }
            let above = queue[..<currentIndex]
            let history = above.filter { playedIDs.contains($0.id) }
            let unheard = above.filter { !playedIDs.contains($0.id) }
            queue = history + [queue[currentIndex]] + (unheard + queue[(currentIndex + 1)...]).shuffled()
            currentIndex = history.count
            pendingIDs = (leadingIDs + pendingIDs).shuffled()
            leadingIDs = []
            // Shuffling the two apart leaves the loaded slice ahead of the tail, so a shuffled
            // 2000-track collection still opens with the first 60 of it. Mix them into one order.
            if !pendingIDs.isEmpty { Task { await mixTailIntoUpcoming() } }
        } else {
            let rank = Dictionary(uniqueKeysWithValues: canonicalIDs.enumerated().map { ($1, $0) })
            queue = originalOrder.sorted { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
            originalOrder = queue
            currentIndex = queue.firstIndex { $0.id == current.id } ?? 0
            let resolved = Set(queue.map(\.id))
            let unresolved = canonicalIDs.filter { !resolved.contains($0) }
            // Split around the current track, or the collection's top would play again after its end.
            let here = rank[current.id, default: .max]
            leadingIDs = unresolved.filter { rank[$0, default: .max] < here }
            pendingIDs = unresolved.filter { rank[$0, default: .max] > here }
        }
    }

    /// Rebuilds the upcoming order out of everything still to come — resolved and not — so a
    /// whole-collection shuffle reaches past the slice that happens to be loaded.
    private func mixTailIntoUpcoming() async {
        guard let resolveIDs, !pendingIDs.isEmpty, queue.indices.contains(currentIndex) else { return }
        let epoch = queueEpoch
        var mixed = Array(queue[(currentIndex + 1)...].map(\.id)) + pendingIDs
        mixed.shuffle()

        let headIDs = Array(mixed.prefix(Self.refillSize))
        let tail = Array(mixed.dropFirst(headIDs.count))
        var known = Dictionary(originalOrder.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = headIDs.filter { known[$0] == nil }
        if !missing.isEmpty {
            let resolved = await resolveIDs(missing)
            // A failed batch would otherwise commit a head of the two or three ids that happened
            // to be cached, dropping the rest of the shuffle on the floor.
            guard !resolved.isEmpty else { return }
            for track in resolved { known[track.id] = track }
        }

        // Anchored on the live position, not the track we started from: pressing Shuffle and then
        // Next is one gesture, and keying on the old track threw the whole new order away.
        guard isShuffled, epoch == queueEpoch, queue.indices.contains(currentIndex) else { return }
        let head = headIDs.compactMap { known[$0] }.filter { $0.id != queue[currentIndex].id }
        guard !head.isEmpty else { return }

        queue = Array(queue[...currentIndex]) + head
        pendingIDs = tail

        // Un-shuffle rebuilds from originalOrder, so it has to keep every track ever resolved.
        let seen = Set(originalOrder.map(\.id))
        originalOrder.append(contentsOf: head.filter { !seen.contains($0.id) })
    }

    /// Resolves the next slice of pending ids and appends it to both orders.
    /// Coalesced rather than gated: `next()` relies on the queue having actually grown by the time
    /// this returns, so a second caller has to wait for the first instead of giving up.
    private func pullRefill() async {
        if let refill { return await refill.value }
        guard resolveIDs != nil, !pendingIDs.isEmpty else { return }
        let task = Task { await performRefill() }
        refill = task
        await task.value
        refill = nil
    }

    private func performRefill() async {
        guard let resolveIDs, !pendingIDs.isEmpty else { return }
        isRefilling = true
        defer { isRefilling = false }

        let slice = Array(pendingIDs.prefix(Self.refillSize))

        // A shuffle demotes already-resolved tracks back into the tail, so refetching the whole
        // slice would both re-request them and append them to originalOrder a second time.
        var known = Dictionary(originalOrder.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = slice.filter { known[$0] == nil }
        if !missing.isEmpty {
            let resolved = await resolveIDs(missing)
            guard !resolved.isEmpty else { return }
            for track in resolved { known[track.id] = track }
        }

        // Spent only once the tracks are in hand, and only if the tail is still the one we took it
        // from: counting it as gone mid-flight made the panel's total dip by fifty and come back.
        guard pendingIDs.starts(with: slice) else { return }
        pendingIDs.removeFirst(slice.count)

        let inQueue = Set(queue.map(\.id))
        let fresh = slice.compactMap { known[$0] }.filter { !inQueue.contains($0.id) }
        guard !fresh.isEmpty else { return }
        queue.append(contentsOf: fresh)
        let seen = Set(originalOrder.map(\.id))
        originalOrder.append(contentsOf: fresh.filter { !seen.contains($0.id) })
    }

    /// The panel's paging trigger; playback refills through `next()` on its own.
    func loadMoreQueue() async {
        await pullRefill()
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

#if DEBUG
    /// Fills the queue without touching playback so previews can render a populated panel; `queue`
    /// is otherwise only ever set by playback itself.
    func seedForPreview(_ tracks: [SCTrack], at index: Int = 0, pending: Int = 0) {
        queue = tracks
        originalOrder = tracks
        currentIndex = min(max(index, 0), max(tracks.count - 1, 0))
        currentTrack = tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil
        pendingIDs = Array(0..<pending).map { -($0 + 1) }
    }
#endif

    /// Drops everything queued after the current track. Playback is untouched — Music's Clear works
    /// the same way — and the pre-shuffle order sheds the same tracks so unshuffling can't resurrect
    /// them.
    func clearUpcoming() {
        // The unresolved tail goes too: leaving it made Clear empty the panel and then refill it
        // from the same collection at the next track change.
        pendingIDs = []
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

    /// Everything a relaunch needs to put the queue back as it stood, the unresolved tail included.
    nonisolated struct Session: Codable {
        var queue: [Int]
        var index: Int
        var leading: [Int]
        var pending: [Int]
        var canonical: [Int]
        var isShuffled: Bool
        var repeatMode: RepeatMode
        // Optional so a session saved before positions were kept still decodes.
        var position: Double?

        /// The part resolved on relaunch — the same lead and head a fresh queue starts with.
        var window: Range<Int> {
            let current = min(max(index, 0), queue.count - 1)
            return max(0, current - PlayerEngine.leadSize)..<min(queue.count, current + PlayerEngine.headSize)
        }
    }

    static func storedSession() -> Session? {
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              !session.queue.isEmpty else { return nil }
        return session
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
        let session = Session(queue: queue.map(\.id), index: currentIndex, leading: leadingIDs, pending: pendingIDs,
                              canonical: canonicalIDs, isShuffled: isShuffled, repeatMode: repeatMode,
                              position: position)
        guard let data = try? JSONEncoder().encode(session) else { return }
        let url = Self.sessionURL
        let write: @Sendable () -> Void = { try? data.write(to: url, options: .atomic) }
        if waiting {
            Self.sessionWriter.sync(execute: write)
        } else {
            Self.sessionWriter.async(execute: write)
        }
    }

    private func playCurrent() async {
        persistSession()
        guard queue.indices.contains(currentIndex) else { return }
        let track = queue[currentIndex]
        currentTrack = track
        playedIDs.insert(track.id)
        HandoffTrace.shared.mark("playCurrent")
        loadArtwork(for: track)

        do {
            let prepared = try await prepare(track)
            start(prepared)
        } catch let failure as PrepareFailure {
            failCurrentTrack(failure.message)
        } catch {
            failCurrentTrack(error.localizedDescription)
        }
    }

    private struct PrepareFailure: Error { let message: String }

    /// Builds a track without putting it on air, so one path serves both the track playing now and
    /// the one being warmed for later. Touches no playback state — the caller owns that.
    private func prepare(_ track: SCTrack) async throws -> PreparedTrack {
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
            return PreparedTrack(item: AVPlayerItem(url: url))
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

        return PreparedTrack(item: AVPlayerItem(asset: asset), loader: loader,
                             keySession: keySession, keyDelegate: keyDelegate)
    }

    private func start(_ prepared: PreparedTrack) {
        discardUpcoming()
        observe(prepared.item)
        let resume = resumePosition.flatMap { $0.trackID == currentTrack?.id ? $0.seconds : nil }
        resumePosition = nil
        currentTime = resume ?? 0
        duration = 0
        itemFailed = false
        HandoffTrace.shared.mark("replaceCurrentItem")
        let outgoing = current
        current = prepared
        player.replaceCurrentItem(with: prepared.item)
        // Retired after the swap rather than before preparing: once the next track is built while
        // this one still plays, preparation can no longer be the moment keys are torn down.
        outgoing?.retire()
        if resume != nil {
            resumingItem = ObjectIdentifier(prepared.item)
            seekToken += 1
            isSeeking = true
        } else {
            resumingItem = nil
            player.play()
        }
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

    /// Watches the item that is about to go on air. Re-pointed on every handoff, warmed or not,
    /// because these three are what tell the engine a track ended or died.
    private func observe(_ item: AVPlayerItem) {
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
            if ready { HandoffTrace.shared.mark("readyToPlay") }
            let message = observed.error?.localizedDescription ?? "couldn't load this track"
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === observed else { return }
                if ready {
                    self.consecutiveFailures = 0
                    self.lastError = nil
                    self.resumeIfWaiting(observed)
#if DEBUG
                    let reported = observed.duration.seconds
                    if reported.isFinite {
                        let claimed = Double(self.currentTrack?.duration ?? 0) / 1000
                        PrimingProbe.note("item duration " + String(format: "%.6f", reported)
                            + "s · api-v2 says " + String(format: "%.3f", claimed) + "s · "
                            + (self.currentTrack?.title ?? "?"))
                    }
#endif
                } else if failed {
                    self.reportItemFailure(message)
                }
            }
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
        guard upcoming == nil, warmTask == nil, repeatMode != .one else { return }
        guard duration > 0, duration - currentTime <= Self.preloadLead else { return }
        guard queue.indices.contains(currentIndex + 1) else { return }
        let track = queue[currentIndex + 1]
        warmTask = Task { await warm(track) }
    }

    private func warm(_ track: SCTrack) async {
        defer { warmTask = nil }
        let epoch = queueEpoch
        guard let prepared = try? await prepare(track) else { return }
        // The queue can move while a licence and a playlist are being fetched.
        guard !Task.isCancelled, epoch == queueEpoch,
              queue.indices.contains(currentIndex + 1),
              queue[currentIndex + 1].id == track.id else {
            prepared.retire()
            return
        }
        upcoming = prepared
        upcomingTrackID = track.id
        // An item buffers only once it is inside a player. The deck stays paused and silent, but
        // AVFoundation now pulls the playlist and the first segments through our loader.
        standby.replaceCurrentItem(with: prepared.item)
    }

    /// Puts the warmed deck on air. Returns false when nothing is warmed or the queue moved under
    /// it, in which case the caller falls back to the ordinary path.
    private func swapToUpcoming() -> Bool {
        guard let prepared = upcoming, let warmedID = upcomingTrackID,
              queue.indices.contains(currentIndex + 1),
              queue[currentIndex + 1].id == warmedID else { return false }

        HandoffTrace.shared.mark("swap to warmed deck")
        let outgoing = current
        let outgoingDeck = player

        upcoming = nil
        upcomingTrackID = nil
        current = prepared
        isDeckAActive.toggle()

        observe(prepared.item)
        currentIndex += 1
        let track = queue[currentIndex]
        currentTrack = track
        playedIDs.insert(track.id)
        currentTime = 0
        duration = 0
        itemFailed = false

        player.play()
        isPlaying = true

        outgoingDeck.pause()
        outgoingDeck.replaceCurrentItem(with: nil)
        outgoing?.retire()

        loadArtwork(for: track)
        updateNowPlayingInfo()
        persistSession()
        return true
    }

    /// Throws away a warmed track that is no longer next — a skip, a reorder, a new queue.
    private func discardUpcoming() {
        warmTask?.cancel()
        warmTask = nil
        guard let prepared = upcoming else { return }
        standby.replaceCurrentItem(with: nil)
        prepared.retire()
        upcoming = nil
        upcomingTrackID = nil
    }

    private func playbackFinished() {
        HandoffTrace.shared.begin(currentTrack.map { "\($0.id) \($0.title)" } ?? "end of queue")
        if repeatMode == .one {
            Task { await playCurrent() }
        } else if swapToUpcoming() {
            if queue.count - currentIndex <= Self.refillThreshold {
                Task { await pullRefill() }
            }
        } else if hasTrackAhead {
            Task { await next() }
        } else if autoplayRelated, let track = currentTrack {
            Task {
                if !(await extendWithRelated(to: track)) { isPlaying = false }
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
        let related = (try? await api.relatedTracks(id: track.id).collection) ?? []
        let known = Set(queue.map(\.id))
        let fresh = related.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return false }
        queue.append(contentsOf: fresh)
        originalOrder.append(contentsOf: fresh)
        canonicalIDs.append(contentsOf: fresh.map(\.id))
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
        if hasTrackAhead {
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
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    /// Loads Now Playing artwork from raw bytes. The MPMediaItemArtwork request handler MUST be
    /// `@Sendable` — MediaPlayer calls it on an arbitrary thread, and a MainActor-isolated closure
    /// would trip a Swift 6 executor assertion (libdispatch abort). Capturing Data (Sendable) and
    /// rebuilding NSImage per call keeps it thread-safe.
    private func loadArtwork(for track: SCTrack) {
        artwork = nil
        guard let url = track.coverURL.liveArtwork.scArtwork(.hero) else { return }
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
        // Without a duration the system draws no timeline at all, so the catalog length stands in.
        let total = duration > 0 ? duration : Double(track.duration) / 1000
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
