import SwiftUI

/// What the history's pages are made of. Everything a page needs is applied here: a hosting
/// controller starts a fresh environment, so nothing set on the shell reaches inside it.
struct ShellPages {
    let model: AppModel
    let shell: ShellState

    nonisolated static let space = "shell"

    func page(for object: AnyHashable) -> AnyView {
        let page: AnyView = switch object {
        case let user as SCUser: AnyView(ArtistView(user: user, model: model))
        case let track as SCTrack: AnyView(TrackDetailView(track: track, model: model))
        case let playlist as SCPlaylist: AnyView(PlaylistPage(playlist: playlist, model: model))
        case let genre as SCGenre: AnyView(GenreChartView(genre: genre, model: model))
        case let list as ProfileList: AnyView(ProfileListView(list: list, model: model))
        default: AnyView(DetailContent(model: model, section: object as? LibrarySection ?? shell.section ?? .home))
        }
        let shell = shell
        return AnyView(
            page
                .reloads(object, with: shell.reloads)
                // Inside the page, not around the controller: a safe-area inset on an AppKit view
                // takes the strip away from it instead of letting the content scroll under it.
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: PlayerPill.reservedHeight)
                }
                .adaptiveMetrics()
                .environment(\.navigator, Navigator { [weak shell] in shell?.open(AnyHashable($0)) })
                .environment(\.onTitleCollapse, TitleCollapse { [weak shell] in shell?.titleCollapsed($0, on: object) })
                .environment(shell.viewer)
                .environment(shell.room)
                .environment(model.library)
                // Each page is a root of its own: nothing above it in the window hands the accent down.
                .tint(.scOrange)
                .coordinateSpace(.named(Self.space))
        )
    }

    /// The titlebar names the page — but a page that names itself in its hero only once that name
    /// has scrolled under the toolbar: saying it twice was the whole complaint, and saying it
    /// nowhere left a scrolled page without a name.
    static func title(of object: AnyHashable, collapsed: Set<AnyHashable>) -> String {
        let isCollapsed = collapsed.contains(object)
        switch object {
        case let user as SCUser: return isCollapsed ? user.username : ""
        case let track as SCTrack: return isCollapsed ? track.title : ""
        case let playlist as SCPlaylist: return isCollapsed ? playlist.title : ""
        case let genre as SCGenre: return isCollapsed ? genre.name : ""
        case let list as ProfileList: return list.title
        // The profile still names itself — the big line beside the avatar is the user's own
        // name, not a section label.
        case let section as LibrarySection: return section == .profile ? "" : section.rawValue
        default: return ""
        }
    }
}

struct DetailContent: View {
    let model: AppModel
    // A value, not the shell's binding: a kept page must stay the section it was made for.
    let section: LibrarySection

    var body: some View {
        switch section {
        case .search:
            SearchPage(model: model)
        case .home:
            HomeView(model: model)
        case .feed:
            FeedView(model: model)
        case .likes:
            LikesView(model: model)
        case .history:
            TrackList(feed: model.library.history, player: model.player)
        case .playlists:
            PlaylistCollection(section: .playlists, library: model.library)
        case .albums:
            PlaylistCollection(section: .albums, library: model.library)
        case .stations:
            PlaylistCollection(section: .stations, library: model.library)
        case .following:
            FollowingView(model: model)
        case .profile:
            MyProfileView(model: model)
        }
    }
}
