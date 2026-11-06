import Foundation

extension SCEndpoint where Response == SCPage<SCFailable<SCActivity>> {
    // VERIFIED 06.11.2026: the site's notifications; `/activities/all` and `/me/activities/all/own` from its code 404.
    static func activities(limit: Int) -> Self {
        .get("/activities", ["limit": "\(limit)", "linked_partitioning": "1"], verified: "2026-11-06")
    }
}

extension SoundCloudAPI {
    func activities(limit: Int = 50) async throws -> [SCActivity] {
        try await get(.activities(limit: limit)).collection.compactMap(\.value)
    }
}
