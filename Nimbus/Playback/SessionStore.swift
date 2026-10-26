import Foundation

extension PlayerEngine {
    /// Everything a relaunch needs to put the queue back as it stood, the unresolved tail included.
    nonisolated struct Session: Codable, Sendable {
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
}

/// Where the queue waits between launches. A preview gets one that keeps nothing, or its fake rows
/// would overwrite the real queue.
nonisolated struct SessionStore: Sendable {
    private let url: URL?
    private static let writer = DispatchQueue(label: "io.github.dearonski.Nimbus.session", qos: .utility)

    static let standard = SessionStore(
        url: ProcessInfo.isRunningForPreviews ? nil : URL.applicationSupportDirectory.appending(path: "session.json"))

    func load() -> PlayerEngine.Session? {
        guard let url, let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(PlayerEngine.Session.self, from: data),
              !session.queue.isEmpty else { return nil }
        return session
    }

    /// Encoded on the writer's queue: a long autoplay queue is real work, and it is saved every five seconds.
    func save(_ session: PlayerEngine.Session, waiting: Bool = false) {
        guard let url else { return }
        let write: @Sendable () -> Void = {
            guard let data = try? JSONEncoder().encode(session) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if waiting {
            Self.writer.sync(execute: write)
        } else {
            Self.writer.async(execute: write)
        }
    }

    func remove() {
        guard let url else { return }
        Self.writer.async { try? FileManager.default.removeItem(at: url) }
    }
}
