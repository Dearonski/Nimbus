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
    private(set) var focusFieldRequest = 0
    /// Pages are kept alive off screen, so only the field of the section asked for takes focus.
    private(set) var focusFieldTarget: LibrarySection = .search

    func requestFieldFocus(in section: LibrarySection) {
        focusFieldTarget = section
        focusFieldRequest += 1
    }

    /// Bumped by ⌘R; the shell refreshes whatever page it is showing.
    var refreshRequest = 0

    // Raise to sign everyone out once on update. 1: builds up to 1.0.1 left dead tokens in the web jar.
    private static let signInResetVersion = 1
    private static let signInResetKey = "signInResetVersion"

    @ObservationIgnored private var webSessionClearing: Task<Void, Never>?

    init() {
        let api = SoundCloudAPI()
        self.api = api
        self.player = PlayerEngine(api: api)
        self.library = LibraryStore(api: api)
        let resetDue = UserDefaults.standard.integer(forKey: Self.signInResetKey) < Self.signInResetVersion
        if resetDue {
            api.auth.clear()
            UserDefaults.standard.set(Self.signInResetVersion, forKey: Self.signInResetKey)
        }
        self.isAuthenticated = api.auth.token != nil
        player.onTrackPlayed = { [library] track, context in library.recordPlay(track, context: context) }
        if resetDue { clearWebSession() }

        Task { [weak self] in
            await api.auth.configure(renew: { await WebSessionCookies.refresh() },
                                     onExpired: { [weak self] in await self?.sessionExpired() })
        }
    }

    /// SoundCloud refused to renew the session; nothing of the account survives into the next sign-in.
    private func sessionExpired() {
        guard isAuthenticated else { return }
        endSession()
    }

    private func endSession() {
        api.auth.clear()
        player.clearSession()
        library.reset()
        isAuthenticated = false
        // Otherwise the login page harvests the dead token still sitting in its jar and bounces straight back here.
        clearWebSession()
    }

    /// The login sheet waits on this, or it could harvest a cookie the clearing is about to drop.
    func readyForLogin() async {
        await webSessionClearing?.value
    }

    private func clearWebSession() {
        webSessionClearing = Task { await WebSessionCookies.clear() }
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

    func didAuthenticate(token: String) {
        api.auth.store(token)
        isAuthenticated = true
    }

    func signOut() {
        endSession()
    }

    /// Playlists arrive as track stubs (and mixed-selections carry none at all), so the ids come
    /// first and the metadata follows in slices — a 500-track set starts on the first batch instead
    /// of after ten round trips, and shuffle covers the whole set rather than what's resolved.
    func play(_ playlist: SCPlaylist, shuffled: Bool = false) async {
        let ticket = player.claimInstall()
        var ids = playlist.trackIDs
        if ids.isEmpty, let numericID = Int(playlist.id) {
            ids = (try? await api.playlist(id: numericID).trackIDs) ?? []
            guard player.isCurrentInstall(ticket) else { return }
        }
        guard !ids.isEmpty else {
            // Otherwise a set that fails to resolve is just a dead click.
            player.report("Couldn't load \(playlist.title)")
            return
        }
        await player.install(ids: ids, shuffled: shuffled, context: .set(urn: playlist.urn), ticket: ticket) { [library] chunk in
            await library.tracks(ids: chunk)
        }
    }
}
