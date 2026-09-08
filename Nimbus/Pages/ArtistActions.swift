import SwiftUI

/// The controls the site keeps opposite an artist's tabs: their station, follow, share, a message
/// and the overflow. Everything but Follow collapses into the overflow when the row runs out of
/// room, so the two controls that matter never move.
struct ArtistActions: View {
    let user: SCUser
    let model: AppModel
    var compact = false

    @Environment(\.openURL) private var openURL
    @Environment(\.navigator) private var navigator

    @State private var isStartingStation = false
    @State private var confirmingBlock = false

    private var isFollowing: Bool { model.library.isFollowing(user) }
    private var isBlocked: Bool { model.library.isBlocked(user) }
    private var permalink: URL? { user.permalinkURL.flatMap(URL.init) }

    /// Everything here is neutral except Follow: the tint marks the one action the page is for,
    /// and a row of five orange buttons marks nothing.
    var body: some View {
        HStack(spacing: 8) {
            stationButton
            followButton
            if !compact {
                shareButton
                messageButton
            }
            overflow
        }
        .controlSize(.large)
        .glassButtonRow()
    }

    private var stationButton: some View {
        Button(action: startStation) {
            HStack(spacing: 6) {
                if isStartingStation {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                Text("Station")
            }
        }
        .glassButton()
        .disabled(isStartingStation)
        .help("Play a station built from \(user.username)")
    }

    /// Orange in both states — it is the page's own action, and a Following button that goes grey
    /// reads as disabled. The state is carried by the word and the glyph instead.
    private var followButton: some View {
        Button { model.library.toggleFollow(user) } label: {
            Label(isFollowing ? "Following" : "Follow",
                  systemImage: isFollowing ? "checkmark" : "plus")
                .frame(minWidth: 84)
        }
        .glassButton(.prominent)
    }

    @ViewBuilder
    private var shareButton: some View {
        if let permalink {
            ShareLink(item: permalink) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .glassButton()
        }
    }

    @ViewBuilder
    private var messageButton: some View {
        if let messages = messagesURL {
            Button { openURL(messages) } label: {
                Image(systemName: "envelope")
            }
            .glassButton(.icon)
            .help("Message \(user.username) on soundcloud.com")
        }
    }

    private var overflow: some View {
        Menu {
            Button("Open station", systemImage: "dot.radiowaves.left.and.right") { openStationPage() }
            if compact {
                Divider()
                if let permalink {
                    ShareLink(item: permalink) { Label("Share…", systemImage: "square.and.arrow.up") }
                }
                if let messages = messagesURL {
                    Button("Message", systemImage: "envelope") { openURL(messages) }
                }
            }
            Divider()
            if isBlocked {
                Button("Unblock \(user.username)", systemImage: "hand.raised.slash") {
                    model.library.toggleBlock(user)
                }
            } else {
                Button("Block \(user.username)", systemImage: "hand.raised", role: .destructive) {
                    confirmingBlock = true
                }
            }
            if let permalink {
                // The report form is a modal inside the web player with no URL of its own, so
                // this lands on the artist's page, where it lives under the same "…" menu.
                Button("Report \(user.username)…", systemImage: "flag") { openURL(permalink) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .glassButton(.icon)
        .fixedSize()
        .task { model.library.loadBlockedIfNeeded() }
        .confirmationDialog("Block \(user.username)?", isPresented: $confirmingBlock) {
            Button("Block", role: .destructive) { model.library.toggleBlock(user) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("They won't be able to interact with you, and you'll stop following them.")
        }
    }

    /// api-v2's messaging is not part of the public surface and the web bundle spells no deep link
    /// to a single conversation, so this hands the artist's permalink to the site and lets it route.
    private var messagesURL: URL? {
        guard let permalink = user.permalinkURL?.split(separator: "/").last, !permalink.isEmpty
        else { return nil }
        return URL(string: "https://soundcloud.com/messages/\(permalink)")
    }

    private func startStation() {
        guard !isStartingStation else { return }
        isStartingStation = true
        Task {
            defer { isStartingStation = false }
            let tracks = (try? await model.api.artistStationTracks(userID: user.id))?.collection ?? []
            guard !tracks.isEmpty else {
                model.player.report("Couldn't load \(user.username)'s station")
                return
            }
            await PlayQueue.exactly(tracks).start(on: model.player)
        }
    }

    private func openStationPage() {
        Task {
            guard let station = try? await model.api.artistStation(userID: user.id) else {
                model.player.report("Couldn't load \(user.username)'s station")
                return
            }
            navigator.open(station)
        }
    }
}
