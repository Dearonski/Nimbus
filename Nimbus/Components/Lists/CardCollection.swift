import AppKit
import SwiftUI

/// A one-column list of SwiftUI cards scrolled by AppKit. A `LazyVStack` re-runs layout and
/// redraws on every scroll frame; here a frame only moves layers, and a recycled cell swaps its
/// root view instead of building a card from nothing.
struct CardCollection<Item: Identifiable, Card: View, Footer: View>: NSViewRepresentable {
    let items: [Item]
    /// Cards sharing a key are the same height, so each key is measured once per width.
    let heightKey: (Item) -> AnyHashable
    /// Anything besides the width that changes a card's height.
    var layoutToken: AnyHashable = 0
    var insets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
    var spacing: CGFloat = 20
    /// For cards whose `@State` must not follow a recycled cell onto the next item (a hover flag, a
    /// spinner). Costs the cheap root-view swap: the card is rebuilt on reuse.
    var resetsStateOnReuse = false
    /// Room kept under the last row for whatever floats over the list.
    var bottomReserve: CGFloat = 0
    /// A new value means a different list: the old scroll offset is meaningless.
    var topToken: String = ""
    var footerHeight: CGFloat = 0
    var onNearEnd: () -> Void = {}
    var onClick: () -> Void = {}
    /// The rows next in the direction of travel, handed over before they are on screen.
    var onPrefetch: ([Item]) -> Void = { _ in }
    @ViewBuilder let card: (Item) -> Card
    @ViewBuilder let footer: () -> Footer

    func makeCoordinator() -> CardCollectionCoordinator { CardCollectionCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let environment = context.environment
        let byID = Dictionary(items.map { (AnyHashable($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let card = card
        let heightKey = heightKey
        let footer = footer
        let resets = resetsStateOnReuse
        let onPrefetch = onPrefetch
        context.coordinator.update(CardCollectionCoordinator.Input(
            ids: items.map { AnyHashable($0.id) },
            content: { id in
                byID[id].map { item in
                    resets ? AnyView(card(item).id(id).environment(\.self, environment))
                           : AnyView(card(item).environment(\.self, environment))
                }
            },
            heightKey: { id in byID[id].map(heightKey) ?? AnyHashable(0) },
            footer: AnyView(footer().environment(\.self, environment)),
            layoutToken: layoutToken, insets: insets, spacing: spacing,
            bottomReserve: bottomReserve, topToken: topToken, footerHeight: footerHeight,
            onNearEnd: onNearEnd, onClick: onClick,
            onPrefetch: { ids in onPrefetch(ids.compactMap { byID[$0] }) }))
    }
}

@MainActor
final class CardCollectionCoordinator: NSObject, NSCollectionViewDelegateFlowLayout {
    struct Input {
        var ids: [AnyHashable] = []
        var content: (AnyHashable) -> AnyView? = { _ in nil }
        var heightKey: (AnyHashable) -> AnyHashable = { _ in 0 }
        var footer = AnyView(EmptyView())
        var layoutToken: AnyHashable = 0
        var insets = NSEdgeInsets()
        var spacing: CGFloat = 0
        var bottomReserve: CGFloat = 0
        var topToken = ""
        var footerHeight: CGFloat = 0
        var onNearEnd: () -> Void = {}
        var onClick: () -> Void = {}
        var onPrefetch: ([AnyHashable]) -> Void = { _ in }
    }

    private var input = Input()
    private let scrollView = TitlebarAwareScrollView()
    private let collectionView = NSCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, AnyHashable>?
    private let prototype = NSHostingController(rootView: AnyView(EmptyView()))
    private var heights: [AnyHashable: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private var clipWidth: CGFloat = 0
    private var hasContent = false
    private var lastDisplayed = 0
    private static let prefetchWindow = 12

    private static let cellID = NSUserInterfaceItemIdentifier("card")
    private static let footerID = NSUserInterfaceItemIdentifier("footer")

    func makeScrollView() -> NSScrollView {
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.delegate = self
        collectionView.register(CardCell.self, forItemWithIdentifier: Self.cellID)
        collectionView.register(CardFooterView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter,
                                withIdentifier: Self.footerID)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        // The cards underneath keep their own clicks; this only tells the page one happened.
        click.delaysPrimaryMouseButtonEvents = false
        collectionView.addGestureRecognizer(click)

        let source = NSCollectionViewDiffableDataSource<Int, AnyHashable>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            let item = collectionView.makeItem(withIdentifier: Self.cellID, for: indexPath)
            if let self, let cell = item as? CardCell, let content = input.content(id) {
                cell.show(content)
            }
            return item
        }
        source.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.footerID,
                                                            for: indexPath)
            if let self { (view as? CardFooterView)?.show(input.footer) }
            return view as? (NSView & NSCollectionViewElement)
        }
        dataSource = source

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged),
                                               name: NSView.frameDidChangeNotification,
                                               object: scrollView.contentView)
        return scrollView
    }

    func update(_ new: Input) {
        let old = input
        input = new

        // Scrollers already follow `contentInsets`; an inset of their own on top stopped the bar twice as high.
        scrollView.contentInsets.bottom = new.bottomReserve
        layout.minimumLineSpacing = new.spacing
        layout.sectionInset = new.insets

        if old.layoutToken != new.layoutToken { heights.removeAll() }
        let relayout = old.layoutToken != new.layoutToken || old.footerHeight != new.footerHeight
            || old.spacing != new.spacing

        if old.ids != new.ids || !hasContent {
            hasContent = true
            var snapshot = NSDiffableDataSourceSnapshot<Int, AnyHashable>()
            snapshot.appendSections([0])
            snapshot.appendItems(new.ids)
            dataSource?.apply(snapshot, animatingDifferences: false)
        } else if relayout {
            layout.invalidateLayout()
        }

        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard indexPath.item < new.ids.count,
                  let cell = collectionView.item(at: indexPath) as? CardCell,
                  let content = new.content(new.ids[indexPath.item]) else { continue }
            cell.show(content)
        }
        let footerPath = IndexPath(item: 0, section: 0)
        (collectionView.supplementaryView(forElementKind: NSCollectionView.elementKindSectionFooter,
                                          at: footerPath) as? CardFooterView)?.show(new.footer)

        if old.topToken != new.topToken, !old.ids.isEmpty {
            scrollView.scrollToTop()
        }
    }

    @objc private func clicked() { input.onClick() }

    @objc private func clipFrameChanged() {
        let width = scrollView.contentView.bounds.width
        guard abs(width - clipWidth) > 0.5 else { return }
        clipWidth = width
        layout.invalidateLayout()
    }

    private func height(of id: AnyHashable, width: CGFloat) -> CGFloat {
        // Asked once before the view has a frame; a card measured at no width is all line breaks.
        guard width > 100 else { return 1 }
        if abs(width - measuredWidth) > 0.5 {
            measuredWidth = width
            heights.removeAll()
        }
        let key = input.heightKey(id)
        if let known = heights[key] { return known }
        guard let content = input.content(id) else { return 1 }
        prototype.rootView = AnyView(content.frame(width: width))
        let measured = prototype.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        // Dropped at once: left in place, the measuring copy would start the card's own loading.
        prototype.rootView = AnyView(EmptyView())
        let height = max(measured.rounded(.up), 1)
        heights[key] = height
        return height
    }

    private var rowWidth: CGFloat {
        max(scrollView.contentView.bounds.width - input.insets.left - input.insets.right, 1)
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        guard indexPath.item < input.ids.count else { return NSSize(width: rowWidth, height: 1) }
        let width = rowWidth
        return NSSize(width: width, height: height(of: input.ids[indexPath.item], width: width))
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        referenceSizeForFooterInSection section: Int) -> NSSize {
        NSSize(width: rowWidth, height: input.footerHeight)
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        prefetch(around: indexPath.item)
        guard indexPath.item >= input.ids.count - pagingRunway else { return }
        input.onNearEnd()
    }

    private func prefetch(around index: Int) {
        let forward = index >= lastDisplayed
        lastDisplayed = index
        let window = forward ? (index + 1)...(index + Self.prefetchWindow)
                             : (index - Self.prefetchWindow)...(index - 1)
        let ahead = window.clamped(to: 0...max(input.ids.count - 1, 0))
        guard !input.ids.isEmpty, ahead.lowerBound != index else { return }
        input.onPrefetch(Array(input.ids[ahead]))
    }
}

private final class CardCell: NSCollectionViewItem {
    private var host: NSHostingView<AnyView>?

    override func loadView() { view = NSView() }

    func show(_ content: AnyView) {
        if let host {
            host.rootView = content
            return
        }
        let host = NSHostingView(rootView: content)
        // The layout owns the size; a host negotiating its own re-measures the card on every pass.
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        self.host = host
    }
}

private final class CardFooterView: NSView, NSCollectionViewElement {
    private var host: NSHostingView<AnyView>?

    func show(_ content: AnyView) {
        if let host {
            host.rootView = content
            return
        }
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        self.host = host
    }
}

/// A list that is the whole page runs under the window's toolbar, as SwiftUI's own scroll views
/// do: the frame ignores the safe area and the overlap comes back as a content inset.
private final class TitlebarAwareScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let window else { return }
        let overlap = max(0, convert(bounds, to: nil).maxY - window.contentLayoutRect.maxY)
        guard abs(contentInsets.top - overlap) > 0.5 else { return }
        let wasAtTop = contentView.bounds.minY <= -contentInsets.top + 0.5
        contentInsets.top = overlap
        if wasAtTop { scrollToTop() }
    }

    func scrollToTop() {
        contentView.scroll(to: NSPoint(x: 0, y: -contentInsets.top))
        reflectScrolledClipView(contentView)
    }
}
