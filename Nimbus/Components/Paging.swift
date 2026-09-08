import SwiftUI

/// Rows this far from the end arm the next page. Must stay under the smallest API page size (24):
/// a wider runway would land the new trigger on a row that has already appeared, and never re-fire.
let pagingRunway = 8

extension Array where Element: Identifiable {
    /// The whole tail arms rather than one sentinel row: a page that dedupes down to fewer rows
    /// than the runway would otherwise move the trigger onto a row that has already appeared,
    /// whose onAppear never fires again. Concurrent fires collapse on each loader's own guard.
    var pagingTriggerIDs: Set<Element.ID> {
        Set(suffix(pagingRunway).map(\.id))
    }

    /// A live feed shifts under its own cursor — posts landing at the head push entries onto the
    /// next page too — and a repeated id gives ForEach undefined results, not just a wasted row.
    mutating func appendNew(_ items: [Element]) {
        let known = Set(map(\.id))
        append(contentsOf: items.filter { !known.contains($0.id) })
    }
}

extension View {
    func paginates(_ isTrigger: Bool, _ load: (() async -> Void)?) -> some View {
        onAppear {
            guard isTrigger, let load else { return }
            Task { await load() }
        }
    }

    /// A client-side filter can leave too few rows to arm a trigger, or none at all — and with no
    /// row rendered there is no `onAppear` of any kind, so paging has to be driven from outside it.
    func paginatesWhileShort(_ needsMore: Bool, pagesLoaded: Int, resetOn token: String,
                             budget: Int = 10, _ load: @escaping () async -> Void) -> some View {
        modifier(ShortPagePump(needsMore: needsMore, pagesLoaded: pagesLoaded, token: token,
                               budget: budget, load: load))
    }
}

/// Keyed on pages rather than on row count: a page whose rows all dedupe away leaves the count
/// unchanged, which would stall the walk with the empty state still on screen.
private struct ShortPagePump: ViewModifier {
    let needsMore: Bool
    let pagesLoaded: Int
    let token: String
    let budget: Int
    let load: () async -> Void

    @State private var spent = 0
    @State private var lastToken = ""

    private struct Step: Equatable {
        let needsMore: Bool
        let pagesLoaded: Int
        let token: String
    }

    func body(content: Content) -> some View {
        content.onChange(of: Step(needsMore: needsMore, pagesLoaded: pagesLoaded, token: token),
                         initial: true) { _, step in
            if step.token != lastToken {
                lastToken = step.token
                spent = 0
            }
            guard step.needsMore, spent < budget else { return }
            spent += 1
            // Unstructured on purpose: cancelling loadMore rolls the feed back to un-started,
            // so tying this to the view's task would drop a page on every keystroke.
            Task { await load() }
        }
    }
}

struct FeedFooter: View {
    let isLoading: Bool
    var padding: CGFloat = 12
    /// Standing alone under a list rather than tucked inside a control, so it is sized to be seen
    /// across the width of a page instead of matching a button's glyph.
    var size: CGFloat = 30

    var body: some View {
        if isLoading {
            FaderLoader(size: size)
                .frame(maxWidth: .infinity)
                .padding(.vertical, padding)
        }
    }
}
