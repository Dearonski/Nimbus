import AppKit
import Nuke
import SwiftUI

// The cover averaged over a 3×3 grid: a mesh drawn from these nine keeps the picture's own layout of colour.
nonisolated struct ArtworkPalette: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        var chroma: Double { max(red, green, blue) - min(red, green, blue) }
    }

    let cells: [RGB]

    // The most colourful cell, not the mean: averaging a warm corner with a cool one comes out brown.
    var accent: RGB {
        cells.max { $0.chroma < $1.chroma } ?? RGB(red: 0.5, green: 0.5, blue: 0.5)
    }

    @MainActor
    static func of(_ track: SCTrack?) async -> ArtworkPalette? {
        // The size the full player warms ahead of a switch: the 100 px one came from the network after the swap.
        guard let url = track?.coverURL.liveArtwork.scArtwork(.mid) else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached.palette }
        guard let image = try? await ImagePipeline.shared.image(for: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let palette = sample(cgImage)
        else { return nil }
        cache.setObject(Box(palette), forKey: url as NSURL)
        return palette
    }

    private static func sample(_ image: CGImage) -> ArtworkPalette? {
        let side = 12, block = side / 3
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var cells: [RGB] = []
        for row in 0..<3 {
            for column in 0..<3 {
                var sum = RGB(red: 0, green: 0, blue: 0)
                for y in row * block..<(row + 1) * block {
                    for x in column * block..<(column + 1) * block {
                        let index = (y * side + x) * 4
                        sum.red += Double(pixels[index])
                        sum.green += Double(pixels[index + 1])
                        sum.blue += Double(pixels[index + 2])
                    }
                }
                let scale = Double(block * block) * 255
                cells.append(RGB(red: sum.red / scale, green: sum.green / scale, blue: sum.blue / scale))
            }
        }
        return ArtworkPalette(cells: cells)
    }

    private final class Box {
        let palette: ArtworkPalette
        init(_ palette: ArtworkPalette) { self.palette = palette }
    }

    nonisolated(unsafe) private static let cache = NSCache<NSURL, Box>()
}

extension ArtworkPalette.RGB {
    // Covers are often muted; a little more colour reads as the cover rather than as grey.
    func color(saturation boost: Double = 1.25, brightness ceiling: Double = 1) -> Color {
        let base = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(saturation * boost, 1), brightness: min(brightness, ceiling))
    }
}

// The full player's room: the cover's colours, drifting slowly, as the lyrics screen in Music does.
struct LivingBackdrop: View {
    let palette: ArtworkPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifted = false

    var body: some View {
        // Drawn small and scaled up as a picture: full size, a track change hitched 137–159 ms/s, this 5–62.
        GeometryReader { proxy in
            mesh
                .frame(width: 64, height: 40)
                .drawingGroup()
                .scaleEffect(x: proxy.size.width / 64, y: proxy.size.height / 40)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) { drifted = true }
            }
    }

    private var mesh: some View {
        MeshGradient(width: 3, height: 3, points: drifted ? Self.drift : Self.grid,
                     colors: palette.cells.map { $0.color() })
            .animation(.easeInOut(duration: 1.2), value: palette)
    }

    private static let grid: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.5, 0.5], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]

    private static let drift: [SIMD2<Float>] = [
        [0, 0], [0.68, 0], [1, 0],
        [0, 0.34], [0.36, 0.64], [1, 0.6],
        [0, 1], [0.4, 1], [1, 1],
    ]
}

#if DEBUG
#Preview("Cover colours") {
    let warm = ArtworkPalette(cells: [
        .init(red: 0.85, green: 0.45, blue: 0.2), .init(red: 0.6, green: 0.2, blue: 0.25),
        .init(red: 0.2, green: 0.1, blue: 0.2), .init(red: 0.9, green: 0.6, blue: 0.3),
        .init(red: 0.5, green: 0.3, blue: 0.4), .init(red: 0.15, green: 0.2, blue: 0.4),
        .init(red: 0.95, green: 0.8, blue: 0.5), .init(red: 0.3, green: 0.35, blue: 0.6),
        .init(red: 0.1, green: 0.15, blue: 0.3),
    ])
    let json = """
    {"id":1,"title":"prop hunt [prod. ptrckparker]","duration":243000,"permalink_url":"x","artwork_url":null,\
    "user":{"id":100,"username":"ONDA ANDAR"},"media":{"transcodings":[]},"track_authorization":""}
    """
    let track = try! JSONDecoder().decode(SCTrack.self, from: Data(json.utf8))
    return VStack(spacing: 20) {
        LivingBackdrop(palette: warm)
            .opacity(0.75)
            .background(.black)
            .overlay { Color.black.opacity(0.35) }
            .frame(width: 760, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        ForEach([nil, warm.accent.color()], id: \.self) { tint in
            PlayerPillContent(track: track, isPlaying: true, currentTime: 78, duration: 243,
                              canPrevious: true, canNext: true, volume: .constant(0.7), isLiked: true,
                              onToggle: {}, onSeek: { _ in }, isQueueVisible: .constant(false), tint: tint)
        }
    }
    .frame(width: 780)
    .padding(24)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}
#endif
