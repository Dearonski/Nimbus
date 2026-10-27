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

    private var phase: ListPhase { ListPhase(library.playlistList, isEmpty: playlists.isEmpty) }

    var body: some View {
        Group {
            if phase == .loading {
                ScrollView { PlaylistRowsSkeleton().padding(.vertical, 8) }
            } else {
                list
            }
        }
        .task { library.loadPlaylistsIfNeeded() }
    }

    private var list: some View {
        List(playlists) { playlist in
            // A button, not a `NavigationLink`: there is no navigation stack behind the detail
            // column any more, and a link inside a page controller simply does nothing when
            // pressed — these three sections stopped opening at all.
            NavButton(value: playlist) {
                PlaylistRow(playlist: playlist)
                    .contentShape(Rectangle())
            }
        }
        .listStyle(.inset)
        .listStatus(phase, failure: "Couldn't load your library", retry: { library.loadPlaylistsIfNeeded() }) {
            ContentUnavailableView("No \(section.rawValue.lowercased())",
                systemImage: section.systemImage,
                description: Text(emptyMessage))
        }
    }
}
