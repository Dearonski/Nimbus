import SwiftUI

let gutter: CGFloat = 24

/// Section headers step down the page and carry an optional editorial eyebrow and rationale —
/// the cheapest variety there is, and the thing SoundCloud's own discover leans on.
struct SectionHeader: View {
    let title: String
    var eyebrow: String? = nil
    var subtitle: String? = nil
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.tint)
            }
            Text(title).font(.system(size: size, weight: .bold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, gutter)
    }
}

/// A horizontal shelf. Left unclipped on purpose: on macOS 26 the sidebar floats above the detail
/// column, so scrolled-off cards pass under its glass — the platform's intended look.
struct Shelf<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: spacing) {
                content
            }
            .scrollTargetLayout()
            .padding(.horizontal, gutter)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

/// A titled horizontal shelf of cards with an optional "See all" action.
struct HomeCarousel<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    var seeAll: (() -> Void)? = nil
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2).bold()
                Spacer()
                if let seeAll {
                    Button("See all", action: seeAll)
                        .buttonStyle(.plain).foregroundStyle(.tint).font(.subheadline)
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}
