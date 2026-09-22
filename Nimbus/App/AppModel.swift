import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let api: SoundCloudAPI
    let player: PlayerEngine
    let library: LibraryStore

    var isAuthenticated: Bool

    /// True while a text field owns the keyboard, so the transport can leave Space to it. AppKit's
    /// first responder cannot answer this alone: SwiftUI leaves the window's field editor in place
    /// after the field has given up focus, which left Space dead for the rest of the page.
    var isTypingInField: Bool { !typingFields.isEmpty }

    /// One entry per field, not one flag for all: a page kept alive behind the one on screen
    /// cleared the flag as it left, under the feet of a field still being typed in.
    @ObservationIgnored private var typingFields: Set<UUID> = []

    func setTyping(_ typing: Bool, in field: UUID) {
        if typing { typingFields.insert(field) } else { typingFields.remove(field) }
    }

    /// Bumped by ⌘F. Pages with a text field put focus in it when this changes; a counter rather
    /// than a flag so a second ⌘F on the same page works too.
    var focusFieldRequest = 0

    /// Bumped by ⌘R; the shell refreshes whatever page it is showing.
    var refreshRequest = 0

    init() {
        let api = SoundCloudAPI()
        self.api = api
        self.player = PlayerEngine(api: api)
        self.library = LibraryStore(api: api)
        self.isAuthenticated = Keychain.get(SoundCloudAPI.tokenAccount) != nil
        player.onTrackPlayed = { [library] track, context in library.recordPlay(track, context: context) }

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

    /// Puts back the queue from the previous launch, paused. Only a window around the current track
    /// is resolved up front; the rest follows through the same batch call the lazy queues use.
    func restoreSession() async {
        await WebSessionCookies.sync()
        guard let session = PlayerEngine.storedSession() else { return }
        let window = session.window
        let tracks = await library.tracks(ids: Array(session.queue[window]))
        guard !tracks.isEmpty else { return }
        player.restore(session, window: window, tracks: tracks) { [library] chunk in
            await library.tracks(ids: chunk)
        }
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
        await player.install(ids: ids, shuffled: shuffled, context: .set(urn: playlist.urn)) { [library] chunk in
            await library.tracks(ids: chunk)
        }
    }
}
