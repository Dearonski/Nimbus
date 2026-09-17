import Foundation
import Testing
@testable import Nimbus

/// Runs the whole read catalogue against the live api-v2 and prints what broke.
///
/// Reads only: nothing here likes, follows, blocks or uploads, so a run leaves the account exactly
/// as it found it. Writes are covered by `SCWrite` and stay a manual check on purpose.
///
/// Needs a signed-in session — the token comes from the app's Keychain, which is why the target
/// runs inside the app (`TEST_HOST`): the sandboxed keychain item is unreachable from a bare
/// test bundle.
@Suite(.serialized)
struct EndpointSmokeTests {
    private static let signedIn = Keychain.get(SoundCloudAPI.tokenAccount) != nil

    struct Probe: Sendable {
        let name: String
        let run: @Sendable (SoundCloudAPI) async throws -> Void

        init(_ name: String, _ run: @escaping @Sendable (SoundCloudAPI) async throws -> Void) {
            self.name = name
            self.run = run
        }
    }

    enum Outcome: Sendable {
        case ok
        case http(Int)
        case schema(field: String, detail: String)
        case failed(String)

        var isFailure: Bool { if case .ok = self { false } else { true } }

        var line: String {
            switch self {
            case .ok: "ok"
            case .http(let code): "HTTP \(code)"
            case .schema(let field, let detail): "schema: \(field) — \(detail)"
            case .failed(let text): text
            }
        }
    }

    @Test(.enabled(if: signedIn, "no saved session — sign in inside the app first"))
    func catalogueAnswers() async throws {
        let api = SoundCloudAPI()

        let me = try await api.meUser()
        let likes = try await api.likedTracks(userID: me.id, limit: 5)
        let track = try #require(likes.collection.first?.track, "the account has no liked tracks to probe with")
        let artistID = track.user.id
        let (playlistID, systemURN) = try await playlistFixtures(api)
        let transcoding = try #require(track.bestHLSAAC ?? track.bestProgressive)

        var probes: [Probe] = [
            .init("me") { _ = try await $0.me() },
            .init("meUser") { _ = try await $0.meUser() },
            .init("editableProfile") { _ = try await $0.editableProfile() },
            .init("stream") { _ = try await $0.stream(limit: 5) },
            .init("library") { _ = try await $0.library() },
            .init("history") { _ = try await $0.history(limit: 5) },
            .init("likedTracks") { _ = try await $0.likedTracks(userID: me.id, limit: 5) },
            .init("likedTrackIDs") { _ = try await $0.likedTrackIDs(cap: 200) },
            .init("likedPlaylistIDs") { _ = try await $0.likedPlaylistIDs() },
            .init("repostedPlaylistIDs") { _ = try await $0.repostedPlaylistIDs() },
            .init("blockedUserIDs") { _ = try await $0.blockedUserIDs(cap: 200) },

            .init("user") { _ = try await $0.user(id: artistID) },
            .init("userTracks") { _ = try await $0.userTracks(id: artistID, limit: 5) },
            .init("userTopTracks") { _ = try await $0.userTopTracks(id: artistID, limit: 5) },
            .init("userAlbums") { _ = try await $0.userAlbums(id: artistID, limit: 5) },
            .init("userPlaylists") { _ = try await $0.userPlaylists(id: artistID, limit: 5) },
            .init("userStream") { _ = try await $0.userStream(id: artistID, limit: 5) },
            .init("userSpotlight") { _ = try await $0.userSpotlight(id: artistID, limit: 5) },
            .init("userReposts") { _ = try await $0.userReposts(id: artistID, limit: 5) },
            .init("userFollowings") { _ = try await $0.userFollowings(id: me.id, limit: 5) },
            .init("userFollowers") { _ = try await $0.userFollowers(id: artistID, limit: 5) },
            .init("userLikes") { _ = try await $0.userLikes(id: artistID, limit: 5) },
            .init("userComments") { _ = try await $0.userComments(id: artistID, limit: 5) },
            .init("userWebProfiles") { _ = try await $0.userWebProfiles(id: artistID) },
            .init("relatedArtists") { _ = try await $0.relatedArtists(id: artistID, limit: 5) },

            .init("tracks(ids:)") { _ = try await $0.tracks(ids: [track.id]) },
            .init("relatedTracks") { _ = try await $0.relatedTracks(id: track.id, limit: 5) },
            .init("trackAlbums") { _ = try await $0.trackAlbums(id: track.id, limit: 5) },
            .init("trackPlaylists") { _ = try await $0.trackPlaylists(id: track.id, limit: 5) },
            .init("resolve") {
                _ = try await $0.resolve(for: transcoding, trackAuthorization: track.trackAuthorization)
            },

            .init("charts") { _ = try await $0.charts(limit: 5) },
            .init("genrePopular") { _ = try await $0.genrePopular(slug: "house", limit: 5) },
            .init("search") { _ = try await $0.search("boards of canada", limit: 5) },
            .init("mixedSelections") { _ = try await $0.mixedSelections(limit: 5) },
            .init("artistStation") { _ = try await $0.artistStation(userID: artistID) },
            .init("artistStationTracks") { _ = try await $0.artistStationTracks(userID: artistID, limit: 5) },

            .init("trackComments (GraphQL)") { _ = try await $0.trackComments(trackURN: track.urn, first: 5) },
            .init("topFans (GraphQL)") { _ = try await $0.topFans(trackURN: track.urn) },
        ]
        if let playlistID {
            probes += [
                .init("playlist") { _ = try await $0.playlist(id: playlistID) },
                .init("playlistLikers") { _ = try await $0.playlistLikers(id: playlistID, limit: 5) },
                .init("playlistReposters") { _ = try await $0.playlistReposters(id: playlistID, limit: 5) },
            ]
        }
        if let systemURN {
            probes.append(.init("systemPlaylist") { _ = try await $0.systemPlaylist(urn: systemURN) })
        }

        var results: [(String, Outcome)] = []
        for probe in probes {
            results.append((probe.name, await outcome(of: probe, against: api)))
        }

        let width = results.map(\.0.count).max() ?? 0
        print("\n── endpoint smoke, \(Date.now.formatted(date: .numeric, time: .shortened)) ──")
        for (name, outcome) in results {
            print("\(outcome.isFailure ? "✗" : "·") \(name.padding(toLength: width, withPad: " ", startingAt: 0))  \(outcome.line)")
        }

        let broken = results.filter { $0.1.isFailure }
        print("\(results.count - broken.count)/\(results.count) alive\n")
        #expect(broken.isEmpty, "\(broken.map(\.0).joined(separator: ", ")) stopped answering")
    }

    private func outcome(of probe: Probe, against api: SoundCloudAPI) async -> Outcome {
        do {
            try await probe.run(api)
            return .ok
        } catch let error as SCError {
            switch error {
            case .http(let code): return .http(code)
            case .decoding(_, let field, let detail): return .schema(field: field, detail: detail)
            default: return .failed(String(describing: error))
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Sets to probe with, taken from the library: a normal one (numeric id) for `/playlists/{id}`
    /// and a system mix (urn id) for `/system-playlists/{urn}`. Either can be absent on a fresh
    /// account, and then those probes are simply skipped.
    private func playlistFixtures(_ api: SoundCloudAPI) async throws -> (Int?, String?) {
        var numeric: Int?
        var urn: String?
        for playlist in try await api.library().collection.compactMap(\.asPlaylist) {
            if let id = Int(playlist.id) {
                numeric = numeric ?? id
            } else {
                urn = urn ?? playlist.id
            }
        }
        return (numeric, urn)
    }
}
