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

        Task { [weak self] in
            await api.setRefreshToken { await WebSessionCookies.freshToken() }
            await api.setOnSessionExpired { [weak self] in
                await self?.sessionExpired()
            }
        }
    }

    /// Both the harvested token and the web session are gone — back to the login screen, with the
    /// account's traces cleared so nothing of it survives into the next sign-in.
    private func sessionExpired() async {
        guard isAuthenticated else { return }
        Keychain.remove(SoundCloudAPI.tokenAccount)
        player.clearSession()
        library.reset()
        isAuthenticated = false
    }

    /// Puts back the queue from the previous launch, paused. Ids are resolved through the same
    /// batch call the lazy queues use, so a restored session costs one request.
    func restoreSession() async {
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
        player.clearSession()
        library.reset()
        isAuthenticated = false
        // Async because the web data store is: without dropping it the login page would sign the
        // same account straight back in from its surviving cookies.
        Task { await WebSessionCookies.clear() }
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
