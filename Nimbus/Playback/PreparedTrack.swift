import AVFoundation
import Foundation

/// One track built and ready to hand to a player: the item, plus everything that has to stay
/// alive exactly as long as it does. Owned per item rather than per engine — with a single global
/// key session, warming the next track would retire the keys of the one still playing.
nonisolated final class PreparedTrack {
    let item: AVPlayerItem
    let transcoding: SCTranscoding

    private let loader: HLSResourceLoader?
    private let keySession: AVContentKeySession?
    private let keyDelegate: FairPlayKeyDelegate?
    private let lock = NSLock()
    private var isRetired = false

    init(item: AVPlayerItem,
         transcoding: SCTranscoding,
         loader: HLSResourceLoader? = nil,
         keySession: AVContentKeySession? = nil,
         keyDelegate: FairPlayKeyDelegate? = nil) {
        self.item = item
        self.transcoding = transcoding
        self.loader = loader
        self.keySession = keySession
        self.keyDelegate = keyDelegate
    }

    /// Silences the delegate before expiring the session: answering a key request whose session
    /// AVFoundation has already forgotten raises an ObjC exception, which Swift cannot catch.
    /// Idempotent, because `deinit` calls it too.
    func retire() {
        lock.lock()
        let already = isRetired
        isRetired = true
        lock.unlock()
        guard !already else { return }
        keyDelegate?.invalidate()
        keySession?.expire()
    }

    deinit { retire() }
}
