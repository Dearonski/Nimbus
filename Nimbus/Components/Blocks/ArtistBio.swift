import AppKit
import SwiftUI

/// The description, folded to three lines until asked. Long bios are the norm on SoundCloud and
/// would otherwise push the tracks off the first screen.
struct ArtistBio: View {
    let text: String
    /// Off where the container does the unfolding: two animations a frame apart read as a stutter.
    var animatesItself = true

    private let linked: AttributedString

    init(text: String, animatesItself: Bool = true) {
        self.text = text
        self.animatesItself = animatesItself
        linked = Self.linkify(text)
    }

    @Environment(\.navigator) private var navigator
    @Environment(LibraryStore.self) private var library: LibraryStore?

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
            Text(linked)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : Self.foldedLines)
                .fixedSize(horizontal: false, vertical: true)
                .background(alignment: .top) { rulers }
                .environment(\.openURL, OpenURLAction(handler: open))

            if isTruncated {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(animatesItself ? .snappy(duration: 0.2) : nil) { expanded.toggle() }
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
        Text(linked)
            .font(.system(size: 13))
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
    }

    /// SoundCloud's own links open here; anything else, or one that won't resolve, goes to the browser.
    private func open(_ url: URL) -> OpenURLAction.Result {
        guard SoundCloudLink.isSoundCloud(url), let api = library?.api else { return .systemAction }
        Task {
            if let item = await SoundCloudLink.resolve(url, api: api) {
                navigator.open(item)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return .handled
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    // Not after a word, a dot or a slash, so an email address or a path doesn't read as a mention.
    private static let mention = try? NSRegularExpression(pattern: #"(?<![\w.@/])@([A-Za-z0-9_-]{2,})"#)

    /// Addresses as links, and `@name` as the profile it names — the site links both.
    static func linkify(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let whole = NSRange(text.startIndex..., in: text)
        let matches = detector?.matches(in: text, range: whole) ?? []
        for match in matches {
            guard let url = match.url, let range = Range(match.range, in: result) else { continue }
            result[range].link = url
        }
        for found in mention?.matches(in: text, range: whole) ?? [] {
            let span = found.range
            guard !matches.contains(where: { NSIntersectionRange($0.range, span).length > 0 }),
                  let name = Range(found.range(at: 1), in: text).map({ text[$0].lowercased() }),
                  let url = URL(string: "https://soundcloud.com/\(name)"),
                  let range = Range(span, in: result) else { continue }
            result[range].link = url
        }
        return result
    }
}

#if DEBUG
#Preview("Links in a bio") {
    ArtistBio(text: """
    New EP out now on soundcloud.com/m83/sets/hurry-up-were-dreaming — mixed by @kavinsky and \
    @daft_punk. Bookings: mgmt@example.com · https://example.com/tour
    """)
    .frame(width: 420)
    .padding(20)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}
#endif
