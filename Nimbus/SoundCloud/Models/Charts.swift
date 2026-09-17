import Foundation

/// A `/charts` entry — the trending/top list wraps each track alongside a ranking score.
nonisolated struct SCChartPage: Decodable, Sendable {
    struct Item: Decodable, Sendable { let track: SCTrack }

    let collection: [SCTrack]

    enum CodingKeys: String, CodingKey {
        case collection
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode([SCFailable<Item>].self, forKey: .collection).compactMap { $0.value?.track }
    }
}
