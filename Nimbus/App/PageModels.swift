import Foundation

enum PageModelKey: Hashable {
    case track(Int)
    case playlist(String)
    /// Your own page carries other rail blocks than the same profile opened as anyone else's.
    case artist(Int, isMe: Bool)
    case followers(Int)
    case following(Int)
    case likes(Int)
    case genre(String)

    /// The page an object in the navigation history opens, if it keeps a model.
    init?(page object: AnyHashable) {
        switch object {
        case let track as SCTrack: self = .track(track.id)
        case let playlist as SCPlaylist: self = .playlist(playlist.id)
        case let user as SCUser: self = .artist(user.id, isMe: false)
        case let genre as SCGenre: self = .genre(genre.slug)
        case let list as ProfileList:
            switch list {
            case .followers(let user): self = .followers(user.id)
            case .following(let user): self = .following(user.id)
            case .likes(let user): self = .likes(user.id)
            }
        default: return nil
        }
    }

    var isMe: Bool {
        if case .artist(_, let isMe) = self { isMe } else { false }
    }
}

/// The models of pages opened lately: each opening is a new visit with fresh view state, and without
/// these a page opened again loaded everything over.
final class PageModels {
    private struct Entry {
        let model: AnyObject
        let made: ContinuousClock.Instant
        var used: Int
    }

    private static let capacity = 30
    private static let lifetime: Duration = .seconds(10 * 60)

    private var entries: [PageModelKey: Entry] = [:]
    private var uses = 0
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    init() {
        // A page opened again only loads over; the memory is worth more to whatever is on screen.
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.removeAll() }
        }
        pressure.activate()
    }

    deinit {
        pressure.cancel()
    }

    func model<Model: AnyObject>(for key: PageModelKey, make: () -> Model) -> Model {
        uses += 1
        if let entry = entries[key], let model = entry.model as? Model, .now - entry.made < Self.lifetime {
            entries[key]?.used = uses
            return model
        }
        let model = make()
        entries[key] = Entry(model: model, made: .now, used: uses)
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries[oldest] = nil
        }
        return model
    }

    func drop(where matches: (PageModelKey) -> Bool) {
        entries = entries.filter { !matches($0.key) }
    }

    func removeAll() {
        entries = [:]
    }
}
