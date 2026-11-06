import Foundation
import Observation

// Each genre's trending playlist, and the covers of its first few tracks for the Browse tiles.
@MainActor
@Observable
final class GenreCharts {
    private(set) var playlists: [String: SCPlaylist] = [:]
    // The playlist's own cover is its first track's; the next few stand in when a genre above has taken it.
    private var covers: [String: [String]] = [:]
    @ObservationIgnored private var loading: [String: Task<SCPlaylist?, Never>] = [:]
    @ObservationIgnored private var coverLoads: Set<String> = []

    private let api: SoundCloudAPI

    init(api: SoundCloudAPI) {
        self.api = api
    }

    func playlist(for genre: SCGenre) async -> SCPlaylist? {
        if let playlist = playlists[genre.slug] { return playlist }
        if let running = loading[genre.slug] { return await running.value }
        let load = Task { [api] in try? await api.systemPlaylist(urn: genre.chartURN) }
        loading[genre.slug] = load
        let playlist = await load.value
        loading[genre.slug] = nil
        if let playlist { playlists[genre.slug] = playlist }
        return playlist
    }

    func loadCover(for genre: SCGenre) async {
        guard !coverLoads.contains(genre.slug) else { return }
        coverLoads.insert(genre.slug)
        guard let playlist = await playlist(for: genre) else {
            coverLoads.remove(genre.slug)
            return
        }
        let next = Array(playlist.trackIDs.dropFirst().prefix(3))
        let more = (try? await api.tracks(ids: next))?.compactMap(\.coverURL.liveArtwork) ?? []
        covers[genre.slug] = [playlist.coverURL.liveArtwork].compactMap(\.self) + more
    }

    // Two genres often share a number one; going down the order, each takes the first cover not already shown.
    func cover(for genre: SCGenre, in order: [SCGenre]) -> String? {
        var shown = Set<String>()
        for other in order {
            guard let candidates = covers[other.slug] else { continue }
            let pick = candidates.first { !shown.contains($0) } ?? candidates.first
            if other == genre { return pick }
            if let pick { shown.insert(pick) }
        }
        return nil
    }
}
