import Foundation

enum PlayContext: Equatable {
    // Playing through history must not reshuffle the list on screen as each track starts.
    case history
    case set(urn: String)
}

/// What a queue is made of. `PlayerEngine` installs nothing else, so a screen cannot start playback
/// without saying whether it means the whole collection or only the rows it happens to have loaded.
struct PlayQueue {
    /// A paged collection: how to walk its ids, how to turn a slice of them into tracks, and what
    /// to call it when the walk fails.
    struct Source {
        let name: String
        let ids: () async -> [Int]
        let resolve: ([Int]) async -> [SCTrack]
    }

    private let rows: [SCTrack]
    private let source: Source?
    private let context: PlayContext?

    /// These tracks and nothing behind them. Spelled out at the call site, so a screen backed by a
    /// paged feed cannot land on it by omission.
    static func exactly(_ rows: [SCTrack], context: PlayContext? = nil) -> PlayQueue {
        PlayQueue(rows: rows, source: nil, context: context)
    }

    static func collection(_ source: Source, loaded rows: [SCTrack]) -> PlayQueue {
        PlayQueue(rows: rows, source: source, context: nil)
    }

    func start(_ track: SCTrack? = nil, shuffled: Bool = false, on player: PlayerEngine) async {
        // A locked row is drawn as one, and pressing it starts nothing.
        guard track?.isPlayable ?? true else { return }
        guard let source else {
            guard rows.contains(where: \.isPlayable) else {
                player.report("None of these tracks can be played on this account")
                return
            }
            let ids = rows.map(\.id)
            await player.install(ids: ids, startingAt: track?.id, shuffled: shuffled,
                                 head: ids.count, lead: ids.count, context: context,
                                 resolve: Self.lookup(rows))
            return
        }

        let ids = await source.ids()
        // A row can be on screen from the cache and gone from the collection; anchoring on an id
        // the walk never returned would start from the collection's top instead of the click.
        guard !ids.isEmpty, track.map({ ids.contains($0.id) }) ?? true else {
            if ids.isEmpty {
                player.report("Couldn't load all of \(source.name) — playing what's loaded")
            }
            await Self.exactly(rows).start(track, shuffled: shuffled, on: player)
            return
        }
        await player.install(ids: ids, startingAt: track?.id, shuffled: shuffled,
                             resolve: source.resolve)
    }

    private static func lookup(_ rows: [SCTrack]) -> ([Int]) async -> [SCTrack] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return { $0.compactMap { byID[$0] } }
    }
}
