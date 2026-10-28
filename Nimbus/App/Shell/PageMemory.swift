import SwiftUI

/// The page the window was left on, remembered by what it points at rather than by the object.
///
/// A track or a set is a whole API response — storing one would mean serving a stale copy on the
/// next launch, with counts and artwork from whenever it was saved. An id costs a request and comes
/// back current. Only the section was remembered before, so a restart always landed on a root page.
struct PageMemory: Codable {
    enum Kind: String, Codable {
        case user, track, playlist, systemPlaylist, genre
    }

    let kind: Kind
    let id: String

    private static let key = "lastPage"

    init?(_ object: AnyHashable) {
        switch object {
        case let user as SCUser:
            kind = .user
            id = String(user.id)
        case let track as SCTrack:
            kind = .track
            id = String(track.id)
        case let playlist as SCPlaylist:
            // A station or a system mix is identified by its urn; an ordinary set by a number.
            kind = Int(playlist.id) == nil ? .systemPlaylist : .playlist
            id = playlist.id
        case let genre as SCGenre:
            kind = .genre
            id = genre.slug
        default:
            // A profile list is made of a user and a kind of list; not worth restoring.
            return nil
        }
    }

    static func remember(_ object: AnyHashable) {
        guard let memory = PageMemory(object), let data = try? JSONEncoder().encode(memory) else {
            forget()
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func stored() -> PageMemory? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PageMemory.self, from: data)
    }

    /// Fetches the page afresh. A deleted track or a set gone private simply leaves the window on
    /// its section, which is what it did before any of this.
    func resolve(api: SoundCloudAPI) async -> AnyHashable? {
        switch kind {
        case .user:
            guard let id = Int(id) else { return nil }
            return try? await api.user(id: id)
        case .track:
            guard let id = Int(id) else { return nil }
            return try? await api.tracks(ids: [id]).first
        case .playlist:
            guard let id = Int(id) else { return nil }
            return try? await api.playlist(id: id)
        case .systemPlaylist:
            return try? await api.systemPlaylist(urn: id)
        case .genre:
            return SCGenre.browse.first { $0.slug == id } ?? SCGenre.all
        }
    }
}

extension View {
    /// Opens the page the window was left on, unless the user has gone somewhere else meanwhile.
    func restoresLastPage(api: SoundCloudAPI, shown: @escaping () -> AnyHashable,
                          controller: @escaping () -> HistoryPageController?) -> some View {
        task {
            guard let memory = PageMemory.stored() else { return }
            // The controller arrives a cycle after the view does, and a page served from cache can
            // beat it there.
            for _ in 0..<20 where controller() == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let before = shown()
            guard let page = await memory.resolve(api: api) else { return }
            // On a slow network the user may have gone somewhere else already; that wins.
            guard shown() == before else { return }
            controller()?.open(page)
        }
    }
}
