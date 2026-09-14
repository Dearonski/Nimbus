import SwiftUI

/// SoundCloud's own placeholder, matched to the site: it never draws the grey default image, it
/// paints one of twelve gradients picked by the entity's id. Values quoted from `.sc-artwork-
/// placeholder-*` in a-v2.sndcdn.com/assets/css/app.css; the same table is theme-independent there.
struct SCGradient: View {
    let index: Int

    static func index(for id: Int) -> Int {
        mod(id, count)
    }

    /// Playlist ids arrive as strings and are numeric for user sets and a URN for system mixes —
    /// the site parses the number where it can and falls back to the same hash for the rest.
    static func index(for id: String) -> Int {
        mod(Int(id) ?? quickHash(id), count)
    }

    var body: some View {
        let pair = Self.pair(index)
        LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static let count = 12

    private static let palette = [
        Color(red: 0.518, green: 0.380, blue: 0.439),  // #846170
        Color(red: 0.439, green: 0.573, blue: 0.612),  // #70929c
        Color(red: 0.902, green: 0.518, blue: 0.431),  // #e6846e
        Color(red: 0.557, green: 0.518, blue: 0.522),  // #8e8485
    ]

    /// The twelve are every ordered pair of the four, in the order app.css lists them.
    private static func pair(_ index: Int) -> (Color, Color) {
        let first = index / 3
        let rest = palette.indices.filter { $0 != first }
        return (palette[first], palette[rest[index % 3]])
    }

    /// SoundCloud's own `quickHash`, kept character for character so a set lands on the same
    /// gradient here as on the site.
    private static func quickHash(_ text: String) -> Int {
        text.utf16.enumerated().reduce(7) { $0 + 31 * Int($1.element) * $1.offset }
    }

    private static func mod(_ value: Int, _ modulus: Int) -> Int {
        (value % modulus + modulus) % modulus
    }
}

#if DEBUG
#Preview("SoundCloud gradients") {
    VStack(spacing: 12) {
        ForEach(0..<3, id: \.self) { row in
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { column in
                    let index = row * 4 + column
                    VStack(spacing: 6) {
                        SCGradient(index: index)
                            .frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        SCGradient(index: index)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                        Text("\(index)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    .padding(24)
}
#endif
