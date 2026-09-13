import SwiftUI

/// The column beside a set's tracklist: who made it, how it is doing, and the faces of the people
/// who liked and reposted it — the two blocks the site keeps there. A mix has no author and nobody
/// reposts it, so its column is what the site gives one instead: what it was built from, who it
/// was built for, and the artists on it.
struct PlaylistRail: View {
    let page: PlaylistPageModel
    let model: AppModel

    private var playlist: SCPlaylist { page.playlist }

    var body: some View {
        if playlist.isSystem { mixColumn } else { setColumn }
    }

    private var mixColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let description = playlist.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let madeFor = playlist.madeFor {
                HStack(spacing: 10) {
                    Artwork(madeFor, size: .thumb)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                    Text("Made for \(madeFor.username)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                }
            }

            if !page.featuredArtists.isEmpty {
                RailBlock(title: "Artists featured") {
                    ArtistFanList(artists: page.featuredArtists, library: model.library)
                }
            }
        }
    }

    private var setColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let artist = page.author ?? playlist.user, !playlist.isSystem {
                RailArtistCard(artist: artist, model: model)
            }

            StatTiles.playlist(playlist, trackCount: page.trackCount)

            if !page.likers.isEmpty {
                RailBlock(title: "\(countString(playlist.likesCount ?? page.likers.count)) likes") {
                    FollowerFaces(followers: Array(page.likers.prefix(8)))
                }
            }

            if !page.reposters.isEmpty {
                RailBlock(title: "\(countString(playlist.repostsCount ?? page.reposters.count)) reposts") {
                    FollowerFaces(followers: Array(page.reposters.prefix(8)))
                }
            }
        }
    }
}
