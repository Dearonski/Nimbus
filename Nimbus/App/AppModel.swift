import Observation

@MainActor
@Observable
final class AppModel {
    let api: SoundCloudAPI
    let player: PlayerEngine
    let library: LibraryStore

    var isAuthenticated: Bool

    init() {
        let api = SoundCloudAPI()
        self.api = api
        self.player = PlayerEngine(api: api)
        self.library = LibraryStore(api: api)
        self.isAuthenticated = Keychain.get(SoundCloudAPI.tokenAccount) != nil
    }

    /// Puts back the queue from the previous launch, paused. Ids are resolved through the same
    /// batch call the lazy queues use, so a restored session costs one request.
    func restoreSession() async {
        await WebSessionCookies.sync()
        let session = PlayerEngine.storedSession
        guard !session.ids.isEmpty else { return }
        let tracks = await library.tracks(ids: session.ids)
        guard !tracks.isEmpty else { return }
        player.restore(tracks, at: session.index)
    }

    func didAuthenticate() {
        isAuthenticated = true
    }

    func signOut() {
        Keychain.remove(SoundCloudAPI.tokenAccount)
        isAuthenticated = false
    }

    /// Playlists arrive as track stubs (and mixed-selections carry none at all), so the ids come
    /// first and the metadata follows in slices — a 500-track set starts on the first batch instead
    /// of after ten round trips, and shuffle covers the whole set rather than what's resolved.
    func play(_ playlist: SCPlaylist, shuffled: Bool = false) async {
        var ids = playlist.trackIDs
        if ids.isEmpty, let numericID = Int(playlist.id) {
            ids = (try? await api.playlist(id: numericID).trackIDs) ?? []
        }
        guard !ids.isEmpty else {
            // Otherwise a set that fails to resolve is just a dead click.
            player.report("Couldn't load \(playlist.title)")
            return
        }
        await player.play(ids: ids, shuffled: shuffled) { [library] chunk in
            await library.tracks(ids: chunk)
        }
    }
}
