import Foundation
import Testing
@testable import Nimbus

/// Checks that every write path still exists, without writing anything.
///
/// The trick is the one the paths were established with in the first place (see `SCWrite.blockUser`):
/// api-v2 answers **401** on a real path with no credentials and **404** on a spelling it does not
/// know. So each request goes out from an ephemeral session — no token, no cookies, nothing the
/// app's jar carries — and the status alone says whether the route is alive.
///
/// What this cannot tell: whether the write itself still goes through. Body shape and the DataDome
/// context that gates every mutation are only provable by really liking something, which belongs in
/// a manual pass rather than in a test that runs on its own.
@Suite(.serialized)
struct WritePathTests {
    /// Never probed, even unauthenticated: reporting is not undoable, and the rest can only be
    /// verified for real, by hand.
    private static let manualOnly = ["reportComment"]

    struct Probe: Sendable {
        let name: String
        let write: SCWrite
    }

    enum Verdict: Sendable {
        case alive(Int)
        case gone
        case unclear(Int)

        var line: String {
            switch self {
            case .alive(let code): "alive (\(code))"
            case .gone: "GONE — 404, the path is no longer known"
            case .unclear(let code): "unclear (\(code))"
            }
        }
    }

    @MainActor
    @Test func writePathsStillExist() async throws {
        // Ids only have to be well-formed: the request is refused before anything is looked up.
        let me = 1, track = 1, playlist = 1

        let probes: [Probe] = [
            .init(name: "likeTrack", write: .likeTrack(me, trackID: track)),
            .init(name: "unlikeTrack", write: .unlikeTrack(me, trackID: track)),
            .init(name: "likePlaylist", write: .likePlaylist(me, playlistID: playlist)),
            .init(name: "unlikePlaylist", write: .unlikePlaylist(me, playlistID: playlist)),
            .init(name: "repostTrack", write: .repostTrack(track)),
            .init(name: "unrepostTrack", write: .unrepostTrack(track)),
            .init(name: "repostPlaylist", write: .repostPlaylist(playlist)),
            .init(name: "unrepostPlaylist", write: .unrepostPlaylist(playlist)),
            .init(name: "followUser", write: .followUser(me)),
            .init(name: "unfollowUser", write: .unfollowUser(me)),
            .init(name: "blockUser", write: .blockUser(me)),
            .init(name: "unblockUser", write: .unblockUser(me)),
            .init(name: "updateProfile", write: .updateProfile(json: "{}")),
            .init(name: "uploadAvatar", write: .uploadAvatar(json: "{}")),
            .init(name: "setProfileHeader", write: .setProfileHeader(json: "{}")),
            .init(name: "removeProfileHeader", write: .removeProfileHeader()),
        ].filter { !Self.manualOnly.contains($0.name) }

        let session = URLSession(configuration: .ephemeral)
        var results: [(String, Verdict)] = []
        for probe in probes {
            results.append((probe.name, await verdict(for: probe.write, using: session)))
        }

        let width = results.map(\.0.count).max() ?? 0
        print("\n── write paths, \(Date.now.formatted(date: .numeric, time: .shortened)) ──")
        for (name, verdict) in results {
            let gone = if case .gone = verdict { true } else { false }
            print("\(gone ? "✗" : "·") \(name.padding(toLength: width, withPad: " ", startingAt: 0))  \(verdict.line)")
        }

        let gone = results.filter { if case .gone = $0.1 { true } else { false } }
        print("\(results.count - gone.count)/\(results.count) still routed\n")
        #expect(gone.isEmpty, "\(gone.map(\.0).joined(separator: ", ")) answer 404 — the paths moved")
    }

    private nonisolated func verdict(for write: SCWrite,
                                     using session: URLSession) async -> Verdict {
        var request = URLRequest(url: URL(string: "https://api-v2.soundcloud.com" + write.path)!)
        request.httpMethod = write.method
        guard let (_, response) = try? await session.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode else {
            return .unclear(-1)
        }
        return switch code {
        case 401, 403: .alive(code)
        case 404: .gone
        default: .unclear(code)
        }
    }
}
