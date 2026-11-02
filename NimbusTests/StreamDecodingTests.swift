import Foundation
import Testing
@testable import Nimbus

struct StreamDecodingTests {
    private static let track = """
    {"kind":"track","id":7,"title":"T","duration":180000,"permalink_url":"x","created_at":"2026-01-01T00:00:00Z",\
    "user":{"id":1,"username":"u"},"media":{"transcodings":[]},"track_authorization":""}
    """
    private static let playlist = """
    {"kind":"playlist","id":9,"title":"P","permalink_url":"y","user":{"id":1,"username":"u"}}
    """

    private func page(_ items: String...) throws -> SCStreamPage {
        try JSONDecoder().decode(SCStreamPage.self, from: Data(#"{"collection":[\#(items.joined(separator: ","))]}"#.utf8))
    }

    @Test func spotlightKeepsBarePinnedItems() throws {
        let items = try page(Self.track, Self.playlist).collection
        #expect(items.count == 2)
        guard case .track(let t) = items.first?.content else { Issue.record("not a track"); return }
        #expect(t.id == 7)
        #expect(items.first?.reposter == nil)
        guard case .playlist(let p) = items.last?.content else { Issue.record("not a playlist"); return }
        #expect(p.id == "9")
    }

    @Test func streamWrapperStillCarriesTheReposter() throws {
        let repost = #"{"type":"track-repost","created_at":"2026-01-02T00:00:00Z","user":{"id":5,"username":"r"},"track":\#(Self.track)}"#
        let items = try page(repost).collection
        #expect(items.count == 1)
        #expect(items.first?.reposter?.id == 5)
    }
}
