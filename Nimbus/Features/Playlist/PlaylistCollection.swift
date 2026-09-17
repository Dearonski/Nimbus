import SwiftUI

/// One page for each of the three things `/me/library/all` already distinguishes.
struct PlaylistCollection: View {
    let section: LibrarySection
    let library: LibraryStore

    private var playlists: [SCPlaylist] {
        switch section {
        case .albums: library.albums
        case .stations: library.stations
        default: library.userPlaylists
        }
    }

    private var emptyMessage: String {
        switch section {
        case .albums: "Albums you like or repost appear here."
        case .stations: "SoundCloud's mixes and stations you save appear here."
        default: "Playlists you create, like or repost appear here."
        }
    }

    private var isFirstLoad: Bool { library.isLoadingPlaylists && library.playlists.isEmpty }

    var body: some View {
        Group {
            if isFirstLoad {
                ScrollView { PlaylistRowsSkeleton().padding(.vertical, 8) }
            } else {
                list
            }
        }
        .task { library.loadPlaylistsIfNeeded() }
    }

    private var list: some View {
        List(playlists) { playlist in
            // Stays a link: inside a List that is what gives the row its selection and keyboard
            // navigation, and a handful of rows is not what floods the navigation observer.
            NavigationLink(value: playlist) {
                PlaylistRow(playlist: playlist)
            }
        }
        .listStyle(.inset)
        .overlay {
            if playlists.isEmpty, let error = library.playlistsError {
                LoadFailure(title: "Couldn't load your library", message: error) {
                    library.loadPlaylistsIfNeeded()
                }
            } else if playlists.isEmpty {
                ContentUnavailableView("No \(section.rawValue.lowercased())",
                    systemImage: section.systemImage,
                    description: Text(emptyMessage))
            }
        }
    }
}
