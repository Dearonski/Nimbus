import SwiftUI

/// The description, folded to three lines until asked. Long bios are the norm on SoundCloud and
/// would otherwise push the tracks off the first screen.
struct ArtistBio: View {
    let text: String

    private static let foldedLines = 3

    @State private var expanded = false
    @State private var foldedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    /// SwiftUI will not say whether a Text was clipped, so both shapes are laid out unseen behind
    /// the visible one and their heights compared. Measuring the visible copy instead would break
    /// the moment it expands — it would then match, and the control to fold it back would vanish.
    private var isTruncated: Bool { fullHeight > foldedHeight + 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : Self.foldedLines)
                .fixedSize(horizontal: false, vertical: true)
                .background(alignment: .top) { rulers }

            if isTruncated {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tint)
            }
        }
    }

    private var rulers: some View {
        ZStack(alignment: .top) {
            measured(lines: Self.foldedLines) { foldedHeight = $0 }
            measured(lines: nil) { fullHeight = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func measured(lines: Int?, _ report: @escaping (CGFloat) -> Void) -> some View {
        Text(text)
            .font(.system(size: 13))
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
    }
}
