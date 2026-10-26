import AVFoundation
import Foundation

/// Two `AVPlayer` decks: one on air, the other holding the next track warm, so a track's end is a swap.
@MainActor
final class DeckPair {
    enum ItemEvent {
        case ready(AVPlayerItem)
        case ended
        case failed(String)
    }

    /// The on-air deck's position every half second, with its item's length once that is known.
    var onTick: ((_ seconds: Double, _ itemDuration: Double?) -> Void)?
    /// Sound actually starting and stopping on the deck on air.
    var onStatus: ((AVPlayer.TimeControlStatus) -> Void)?
    var onItem: ((ItemEvent) -> Void)?

    private let deckA = AVPlayer()
    private let deckB = AVPlayer()
    private var isDeckAActive = true

    /// Every transport control — play, pause, seek, the clock, Now Playing — reads through here,
    /// so putting the other deck on air moves all of them at once.
    var onAir: AVPlayer { isDeckAActive ? deckA : deckB }
    private var standby: AVPlayer { isDeckAActive ? deckB : deckA }
    private var decks: [AVPlayer] { [deckA, deckB] }

    /// The track on air, with its loader and key session. Retired only once its successor is in the
    /// player, so nothing tears down keys still in use.
    private(set) var current: PreparedTrack?
    /// The next track, built and buffering in the standby deck.
    private(set) var upcoming: PreparedTrack?
    private(set) var upcomingTrackID: Int?

    /// Both decks: the standby one is warming the next track and would otherwise come on air at
    /// whatever level it was built with.
    var volume: Float {
        didSet { for deck in decks { deck.volume = volume } }
    }

    var rate: Float = 1 {
        didSet { for deck in decks { deck.defaultRate = rate } }
    }

    /// Dips in flight per deck — a shared count left a deck swapped out mid-dip silent for good.
    private var hushes: [ObjectIdentifier: Int] = [:]

    private var timeObservers: [(deck: AVPlayer, token: Any)] = []
    private var statusObservers: [NSKeyValueObservation] = []
    private var endObserver: (any NSObjectProtocol)?
    private var failObserver: (any NSObjectProtocol)?
    private var itemObserver: NSKeyValueObservation?

    init(volume: Float) {
        self.volume = volume
        // Observed on both decks rather than moved on every swap. A periodic observer only fires
        // while its deck is playing, and the guard keeps the standby deck out of the clock.
        for deck in decks {
            deck.volume = volume
            let token = deck.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, self.onAir === deck else { return }
                    let length = deck.currentItem?.duration.seconds
                    self.onTick?(time.seconds, length?.isFinite == true ? length : nil)
                }
            }
            timeObservers.append((deck, token))

            let deckID = ObjectIdentifier(deck)
            statusObservers.append(deck.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
                let status = observed.timeControlStatus
#if DEBUG
                switch status {
                case .playing:
                    HandoffTrace.shared.end("playing")
                case .waitingToPlayAtSpecifiedRate:
                    let reason = observed.reasonForWaitingToPlay?.rawValue ?? "unknown"
                    HandoffTrace.shared.mark("waiting — \(reason)")
                default:
                    break
                }
#endif
                Task { @MainActor [weak self] in
                    guard let self, ObjectIdentifier(self.onAir) == deckID else { return }
                    self.onStatus?(status)
                }
            })
        }
    }

    // AVPlayer.h: releasing the observer without this call is undefined behaviour.
    isolated deinit {
        for entry in timeObservers { entry.deck.removeTimeObserver(entry.token) }
    }

    /// The outgoing track is retired only after the swap: the next one is built while it still plays.
    func put(_ prepared: PreparedTrack, playing: Bool) {
        observe(prepared.item)
        let outgoing = current
        current = prepared
        onAir.replaceCurrentItem(with: prepared.item)
        outgoing?.retire()
        if playing { onAir.play() }
    }

    /// An item buffers only once it is inside a player. The deck stays paused and silent, but
    /// AVFoundation now pulls the playlist and the first segments through our loader.
    func park(_ prepared: PreparedTrack, as trackID: Int) {
        upcoming = prepared
        upcomingTrackID = trackID
        standby.replaceCurrentItem(with: prepared.item)
    }

    /// Puts the warmed deck on air and empties the other.
    func swap() {
        guard let prepared = upcoming else { return }
        let outgoing = current
        let outgoingDeck = onAir
        upcoming = nil
        upcomingTrackID = nil
        current = prepared
        isDeckAActive.toggle()
        observe(prepared.item)
        onAir.play()
        outgoingDeck.pause()
        outgoingDeck.replaceCurrentItem(with: nil)
        outgoing?.retire()
    }

    func discardUpcoming() {
        guard let prepared = upcoming else { return }
        standby.replaceCurrentItem(with: nil)
        prepared.retire()
        upcoming = nil
        upcomingTrackID = nil
    }

    func stop() {
        discardUpcoming()
        for deck in decks {
            deck.pause()
            deck.replaceCurrentItem(with: nil)
        }
        current?.retire()
        current = nil
    }

    /// AVPlayer rebuilds its audio chain on a rate or pitch-mode change and clicks; a quick dip hides it.
    func whileHushed(playing: Bool, _ change: @escaping () -> Void) {
        guard playing else {
            change()
            return
        }
        let deck = onAir
        let deckID = ObjectIdentifier(deck)
        hushes[deckID, default: 0] += 1
        Task {
            await Self.ramp(deck, to: 0, over: .milliseconds(60))
            change()
            try? await Task.sleep(for: .milliseconds(40))
            hushes[deckID, default: 1] -= 1
            guard hushes[deckID] == 0 else { return }
            await Self.ramp(deck, to: volume, over: .milliseconds(150))
        }
    }

    private static func ramp(_ deck: AVPlayer, to target: Float, over duration: Duration) async {
        let start = deck.volume
        let steps = 6
        for step in 1...steps {
            deck.volume = start + (target - start) * Float(step) / Float(steps)
            try? await Task.sleep(for: duration / steps)
        }
    }

    /// Re-pointed on every handoff, warmed or not: these three are what tell a track ended or died.
    private func observe(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onItem?(.ended) }
        }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "playback stopped unexpectedly"
            MainActor.assumeIsolated { self?.onItem?(.failed(message)) }
        }
        // A stalled buffer is a normal, recoverable underrun (expected while a >5-min HLS signature
        // is re-resolved mid-track), so it is deliberately NOT routed to auto-skip. Only a hard
        // .failed status or failedToPlayToEndTime advances the queue.
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let ready = observed.status == .readyToPlay
            let failed = observed.status == .failed
            if ready { HandoffTrace.shared.mark("readyToPlay") }
            let message = observed.error?.localizedDescription ?? "couldn't load this track"
            Task { @MainActor [weak self] in
                guard let self, self.onAir.currentItem === observed else { return }
                if ready {
                    self.onItem?(.ready(observed))
                } else if failed {
                    self.onItem?(.failed(message))
                }
            }
        }
    }
}
