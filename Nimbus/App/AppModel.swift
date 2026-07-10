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

    func didAuthenticate() {
        isAuthenticated = true
    }

    func signOut() {
        Keychain.remove(SoundCloudAPI.tokenAccount)
        isAuthenticated = false
    }

    /// Playlists arrive as track stubs (and mixed-selections carry none at all), so starting one
    /// always costs a resolve before the first note.
    func play(_ playlist: SCPlaylist, shuffled: Bool = false) async {
        let tracks = await library.tracks(for: playlist)
        guard let first = tracks.first else { return }
        if shuffled {
            await player.playShuffled(tracks)
        } else {
            await player.play(first, in: tracks)
        }
    }
}
