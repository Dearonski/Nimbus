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
}
