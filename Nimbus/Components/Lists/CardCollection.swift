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
    /// Room kept under the last row for whatever floats over the list.
    var bottomReserve: CGFloat = 0
    /// A new value means a different list: the old scroll offset is meaningless.
    var topToken: String = ""
    var footerHeight: CGFloat = 0
    /// A page's hero, the full width above the rows; it sizes itself.
    var header: AnyView? = nil
    /// What opens the rows' own column, under the header and beside the side column; it sizes itself too.
    var lead: AnyView? = nil
    var side: CardCollectionSide? = nil
    /// How far a row reaches past the column's edges, for a highlight that bleeds out of it.
    var rowOutset: CGFloat = 0
    /// For rows that are each their own height and change it themselves — a comment, its replies
    /// arriving. A row stands at `estimatedHeight` until it is on screen and reports its real one;
    /// `heightKey` then only names the row the height is remembered for.
    var selfSizing = false
    var estimatedHeight: CGFloat = 80
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
        let onPrefetch = onPrefetch
        context.coordinator.update(CardCollectionCoordinator.Input(
            ids: items.map { AnyHashable($0.id) },
            content: { id in byID[id].map { AnyView(card($0).environment(\.self, environment)) } },
            heightKey: { id in byID[id].map(heightKey) ?? AnyHashable(0) },
            footer: AnyView(footer().environment(\.self, environment)),
            header: header.map { AnyView($0.environment(\.self, environment)) },
            lead: lead.map { AnyView($0.environment(\.self, environment)) },
            rowOutset: rowOutset,
            selfSizing: selfSizing, estimatedHeight: estimatedHeight,
            side: side.map { side in
                var side = side
                side.content = AnyView(side.content.environment(\.self, environment))
                return side
            },
            layoutToken: layoutToken, insets: insets, spacing: spacing,
            bottomReserve: bottomReserve, topToken: topToken, footerHeight: footerHeight,
            onNearEnd: onNearEnd, onClick: onClick,
            onPrefetch: { ids in onPrefetch(ids.compactMap { byID[$0] }) }))
    }
}

/// A column that stands beside the rows while there is room and under the last of them when there is not.
struct CardCollectionSide {
    var width: CGFloat
    var spacing: CGFloat
    var spacingBelow: CGFloat = 26
    var isBeside: Bool
    /// Held in view while the rows scroll past it, instead of leaving with the header.
    var pins = false
    var topInset: CGFloat = 16
    var bottomInset: CGFloat = 16
    var content: AnyView
}

@MainActor
final class CardCollectionCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    struct Input {
        var ids: [AnyHashable] = []
        var content: (AnyHashable) -> AnyView? = { _ in nil }
        var heightKey: (AnyHashable) -> AnyHashable = { _ in 0 }
        var footer = AnyView(EmptyView())
        var header: AnyView?
        var lead: AnyView?
        var rowOutset: CGFloat = 0
        var selfSizing = false
        var estimatedHeight: CGFloat = 80
        var side: CardCollectionSide?
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
    private let layout = CardFlowLayout()
    private var headerHost: ScrollAwareHostingView<AnyView>?
    private var sideHost: ScrollAwareHostingView<AnyView>?
    private var leadHost: ScrollAwareHostingView<AnyView>?
    private var headerHeight: CGFloat = 0
    private var leadHeight: CGFloat = 0
    private var sideHeight: CGFloat = 0
    /// What the rows are laid out under; it follows `leadHeight` a frame at a time when that grows by itself.
    private var shownLeadHeight: CGFloat = 0
    private var leadWidth: CGFloat = 0
    private var leadMotion: Motion?
    private var displayLink: CADisplayLink?

    private struct Motion {
        let spring: Spring
        let from: CGFloat
        let to: CGFloat
        let start = CACurrentMediaTime()

        /// Nil once it has settled.
        func value(at time: CFTimeInterval) -> CGFloat? {
            let elapsed = time - start
            guard elapsed < spring.settlingDuration else { return nil }
            return from + spring.value(target: to - from, time: elapsed)
        }
    }
    private let prototype = NSHostingController(rootView: AnyView(EmptyView()))
    private var heights: [AnyHashable: CGFloat] = [:]
    // One per row, so a layout pass over thousands of rows is an array read, not a key and a lookup each.
    private var rowHeights: [CGFloat] = []
    private var measuredWidth: CGFloat = 0
    private var rowIndex: [AnyHashable: Int] = [:]
    private var reportedAreStale = false
    /// How much rows above the window have grown since the last layout; the scroll offset follows, or the page jumps.
    private var pendingShift: CGFloat = 0
    private var clipWidth: CGFloat = 0
    private var hasContent = false
    private var isLiveScrolling = false
    private var visibleAreStale = false
    private var lastDisplayed = 0
    private let probe = ScrollProbe.isEnabled ? ScrollProbe() : nil
    private static let prefetchWindow = 12

    private static let cellID = NSUserInterfaceItemIdentifier("card")
    private static let footerID = NSUserInterfaceItemIdentifier("footer")

    func makeScrollView() -> NSScrollView {
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(CardCell.self, forItemWithIdentifier: Self.cellID)
        collectionView.register(CardFooterView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter,
                                withIdentifier: Self.footerID)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        // The cards underneath keep their own clicks; this only tells the page one happened.
        click.delaysPrimaryMouseButtonEvents = false
        collectionView.addGestureRecognizer(click)

        layout.onPrepared = { [weak self] in self?.positionAccessories() }
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged),
                                               name: NSView.frameDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollBegan),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded),
                                               name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        probe?.attach(to: scrollView)
        return scrollView
    }

    func update(_ new: Input) {
        let old = input
        input = new

        // Scrollers already follow `contentInsets`; an inset of their own on top stopped the bar twice as high.
        scrollView.contentInsets.bottom = new.bottomReserve
        layout.minimumLineSpacing = new.spacing
        let sideMoves = old.side != nil && new.side != nil && old.side?.isBeside != new.side?.isBeside
        showAccessories()
        if sideMoves { fadeSideIn() }

        if new.selfSizing, old.ids != new.ids {
            rowIndex = Dictionary(new.ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }

        let remeasure = old.layoutToken != new.layoutToken
        if remeasure {
            heights.removeAll()
            rowHeights.removeAll()
        }

        if !hasContent {
            hasContent = true
            collectionView.reloadData()
        } else if old.ids != new.ids {
            // A page landing at the end is the common case by far, and the one that arrives mid-scroll:
            // reloading for it rebuilt every visible card and re-measured every row, 100 ms and more.
            if new.ids.count > old.ids.count, new.ids.starts(with: old.ids) {
                let added = (old.ids.count..<new.ids.count).map { IndexPath(item: $0, section: 0) }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    collectionView.insertItems(at: Set(added))
                }
                visibleAreStale = true
            } else {
                rowHeights.removeAll()
                collectionView.reloadData()
            }
        } else if remeasure || old.footerHeight != new.footerHeight || old.spacing != new.spacing {
            layout.invalidateLayout()
            visibleAreStale = visibleAreStale || remeasure
        } else {
            // Nothing about the rows changed, but what a card captures may have — a filter's queue, the theme.
            visibleAreStale = true
        }
        refreshVisibleIfIdle()

        let footerPath = IndexPath(item: 0, section: 0)
        (collectionView.supplementaryView(forElementKind: NSCollectionView.elementKindSectionFooter,
                                          at: footerPath) as? CardFooterView)?.show(new.footer)

        if old.topToken != new.topToken, !old.ids.isEmpty {
            scrollView.scrollToTop()
        }
    }

    /// Cards on screen take their new inputs once the list is at rest: eight root views swapped in
    /// the middle of a fling is two frames gone for something nobody can see change.
    private func refreshVisibleIfIdle() {
        guard visibleAreStale, !isLiveScrolling else { return }
        visibleAreStale = false
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard indexPath.item < input.ids.count,
                  let cell = collectionView.item(at: indexPath) as? CardCell,
                  let content = content(at: indexPath.item) else { continue }
            cell.show(content)
        }
    }

    @objc private func liveScrollBegan() { isLiveScrolling = true }

    @objc private func liveScrollEnded() {
        isLiveScrolling = false
        refreshVisibleIfIdle()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        input.ids.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.cellID, for: indexPath)
        guard indexPath.item < input.ids.count, let cell = item as? CardCell,
              let content = content(at: indexPath.item) else { return item }
        let start = CACurrentMediaTime()
        cell.show(content)
        if let probe {
            // Only while measuring: brings the card's update forward so it can be timed.
            cell.view.layoutSubtreeIfNeeded()
            probe.swapped(ms: (CACurrentMediaTime() - start) * 1000)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView,
                        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.footerID, for: indexPath)
        (view as? CardFooterView)?.show(input.footer)
        return view
    }

    private func content(at index: Int) -> AnyView? {
        let id = input.ids[index]
        guard let content = input.content(id) else { return nil }
        guard input.selfSizing else { return content }
        return AnyView(SelfMeasured(content: content, width: nil) { [weak self] in self?.rowMeasured(id, $0) })
    }

    private func rowMeasured(_ id: AnyHashable, _ height: CGFloat) {
        let key = input.heightKey(id)
        guard height > 0, abs((heights[key] ?? -1) - height) > 0.5 else { return }
        heights[key] = height
        guard let index = rowIndex[id], index < rowHeights.count else { return }
        let first = collectionView.indexPathsForVisibleItems().map(\.item).min() ?? 0
        if index < first { pendingShift += height - rowHeights[index] }
        rowHeights[index] = height
        // Several rows report in one pass; the layout answers once.
        guard !reportedAreStale else { return }
        reportedAreStale = true
        DispatchQueue.main.async { [weak self] in self?.applyReported() }
    }

    private func applyReported() {
        reportedAreStale = false
        layout.invalidateLayout()
        guard pendingShift != 0 else { return }
        collectionView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + pendingShift))
        scrollView.reflectScrolledClipView(clip)
        pendingShift = 0
    }

    @objc private func clicked() { input.onClick() }

    @objc private func clipScrolled() {
        probe?.scrolled()
        if input.side?.pins == true { positionAccessories() }
    }

    @objc private func clipFrameChanged() {
        let width = scrollView.contentView.bounds.width
        guard abs(width - clipWidth) > 0.5 else { return }
        clipWidth = width
        showAccessories()
        layout.invalidateLayout()
    }

    // MARK: - Header and side column

    private func host(_ existing: ScrollAwareHostingView<AnyView>?,
                      for content: AnyView?) -> ScrollAwareHostingView<AnyView>? {
        guard content != nil else {
            existing?.removeFromSuperview()
            return nil
        }
        if let existing { return existing }
        let host = ScrollAwareHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        host.safeAreaRegions = []
        collectionView.addSubview(host)
        return host
    }

    /// Hands the accessories their content at the width they are about to have, then makes room.
    private func showAccessories() {
        let width = scrollView.contentView.bounds.width
        headerHost = host(headerHost, for: input.header)
        sideHost = host(sideHost, for: input.side?.content)
        leadHost = host(leadHost, for: input.lead)
        // Unfolding is the container opening over content already in place, not the text racing the rows.
        leadHost?.clipsToBounds = true
        if input.header == nil { headerHeight = 0 }
        if input.lead == nil {
            leadHeight = 0
            shownLeadHeight = 0
        }
        if input.side == nil { sideHeight = 0 }
        // Asked once before the view has a frame; content laid out at no width is all line breaks.
        if width > 100 {
            if let header = input.header {
                headerHost?.rootView = AnyView(SelfMeasured(content: header, width: width) { [weak self] in
                    self?.measured(\.headerHeight, $0)
                })
            }
            if let side = input.side {
                sideHost?.rootView = AnyView(SelfMeasured(content: side.content, width: sideWidth(side, in: width)) { [weak self] in
                    self?.measured(\.sideHeight, $0)
                })
            }
            if let lead = input.lead {
                let column = columnWidth(in: width)
                leadHost?.rootView = AnyView(SelfMeasured(content: lead, width: column) { [weak self] in
                    self?.leadMeasured($0, at: column)
                })
            }
        }
        makeRoomForAccessories()
    }

    /// A lead that grows at a width it already had was opened by hand — a description unfolding —
    /// and the rows slide out from under it as they did in a SwiftUI stack. Anything else is a resize.
    private func leadMeasured(_ height: CGFloat, at width: CGFloat) {
        guard abs(leadHeight - height) > 0.5 else { return }
        let sameWidth = abs(leadWidth - width) < 0.5
        leadWidth = width
        leadHeight = height
        if sameWidth, shownLeadHeight > 0 {
            leadMotion = Motion(spring: Spring(duration: 0.25, bounce: 0), from: shownLeadHeight, to: height)
            startDisplayLink()
        } else {
            leadMotion = nil
            shownLeadHeight = height
            DispatchQueue.main.async { [weak self] in self?.makeRoomForAccessories() }
        }
    }

    // Reported from inside the host's own layout pass; resizing the host there is laying it out reentrantly.
    private func measured(_ height: ReferenceWritableKeyPath<CardCollectionCoordinator, CGFloat>, _ value: CGFloat) {
        guard abs(self[keyPath: height] - value) > 0.5 else { return }
        self[keyPath: height] = value
        DispatchQueue.main.async { [weak self] in self?.makeRoomForAccessories() }
    }

    private func sideWidth(_ side: CardCollectionSide, in width: CGFloat) -> CGFloat {
        side.isBeside ? side.width : max(width - input.insets.left - input.insets.right, 1)
    }

    /// A resize is the hand on the window's edge, so the layout keeps up with it and snaps; only the
    /// column turning up in its new place is eased in, as a secondary pane is.
    private func fadeSideIn() {
        guard let layer = sideHost?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "appear")
    }

    /// Every frame lays the rows out for real, as a window resize does.
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = scrollView.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let motion = leadMotion {
            shownLeadHeight = motion.value(at: now) ?? motion.to
            if shownLeadHeight == motion.to { leadMotion = nil }
        }
        if leadMotion == nil {
            link.invalidate()
            displayLink = nil
        }
        // Rooms only: a growing lead moves the rows, and a new root view for the hero every frame made it stutter.
        makeRoomForAccessories()
    }

    private func columnWidth(in width: CGFloat) -> CGFloat {
        var column = width - input.insets.left - input.insets.right
        if let side = input.side, side.isBeside { column -= side.width + side.spacing }
        return max(column, 1)
    }

    private func makeRoomForAccessories() {
        let header = headerHeight
        let lead = shownLeadHeight
        let side = sideHeight

        var inset = input.insets
        inset.top += header + lead
        inset.left -= input.rowOutset
        inset.right -= input.rowOutset
        var minimumHeight: CGFloat = 0
        var extraBottom: CGFloat = 0
        if let column = input.side {
            if column.isBeside {
                inset.right += column.width + column.spacing
                minimumHeight = input.insets.top + header + side + input.insets.bottom
            } else {
                extraBottom = column.spacingBelow + side
            }
        }

        let insetChanged = !NSEdgeInsetsEqual(layout.sectionInset, inset)
        if insetChanged || layout.minimumHeight != minimumHeight || layout.extraBottom != extraBottom {
            layout.sectionInset = inset
            layout.minimumHeight = minimumHeight
            layout.extraBottom = extraBottom
            layout.invalidateLayout()
        }
        positionAccessories()
    }

    private func positionAccessories() {
        let clip = scrollView.contentView.bounds
        headerHost?.frame = NSRect(x: 0, y: 0, width: clip.width, height: headerHeight)
        leadHost?.frame = NSRect(x: input.insets.left, y: headerHeight + input.insets.top,
                                 width: columnWidth(in: clip.width), height: shownLeadHeight)
        guard let side = input.side, let sideHost else { return }

        let width = sideWidth(side, in: clip.width)
        guard side.isBeside else {
            settle(sideHost, at: NSRect(x: input.insets.left, y: layout.rowsBottom + side.spacingBelow,
                                        width: width, height: sideHeight))
            return
        }
        let rest = headerHeight + input.insets.top
        let x = clip.width - input.insets.right - width
        // Shorter than the window, it holds under the top edge; taller, it rides until its own end shows.
        let underTop = clip.minY + scrollView.contentInsets.top + side.topInset - rest
        let aboveBottom = clip.maxY - side.bottomInset - sideHeight - rest
        let shift = side.pins ? min(underTop, aboveBottom) : 0
        guard shift > 0 else {
            settle(sideHost, at: NSRect(x: x, y: rest, width: width, height: sideHeight))
            return
        }
        // Held by the scroll view itself: a frame set from here every scroll frame trails the
        // scrolling, which runs ahead of the main thread, and the column shivered.
        if sideHost.superview === collectionView {
            scrollView.addFloatingSubview(sideHost, for: .vertical)
        }
        let top = rest + shift - clip.minY
        let flipped = sideHost.superview?.isFlipped ?? true
        let height = sideHost.superview?.bounds.height ?? clip.height
        sideHost.frame = NSRect(x: x, y: flipped ? top : height - top - sideHeight, width: width, height: sideHeight)
    }

    private func settle(_ host: NSView, at frame: NSRect) {
        if host.superview !== collectionView { collectionView.addSubview(host) }
        host.frame = frame
    }

    private func height(of id: AnyHashable, width: CGFloat) -> CGFloat {
        // Asked once before the view has a frame; a card measured at no width is all line breaks.
        guard width > 100 else { return 1 }
        if abs(width - measuredWidth) > 0.5 {
            measuredWidth = width
            heights.removeAll()
            rowHeights.removeAll()
        }
        let key = input.heightKey(id)
        if let known = heights[key] { return known }
        if input.selfSizing { return input.estimatedHeight }
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
        max(scrollView.contentView.bounds.width - layout.sectionInset.left - layout.sectionInset.right, 1)
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        let width = rowWidth
        guard indexPath.item < input.ids.count, width > 100 else { return NSSize(width: width, height: 1) }
        if abs(width - measuredWidth) > 0.5 { rowHeights.removeAll() }
        // Filled from where it stops: a page added at the end measures its own rows and no others.
        while rowHeights.count <= indexPath.item {
            rowHeights.append(height(of: input.ids[rowHeights.count], width: width))
        }
        return NSSize(width: width, height: rowHeights[indexPath.item])
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        referenceSizeForFooterInSection section: Int) -> NSSize {
        NSSize(width: rowWidth, height: input.footerHeight)
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        if let probe {
            let start = CACurrentMediaTime()
            item.view.layoutSubtreeIfNeeded()
            probe.displayed(ms: (CACurrentMediaTime() - start) * 1000)
        }
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

/// A flow layout whose document also holds what is not a row: the column beside them can be the
/// taller of the two, and under them it needs room past the last one.
private final class CardFlowLayout: NSCollectionViewFlowLayout {
    var minimumHeight: CGFloat = 0
    var extraBottom: CGFloat = 0
    var onPrepared: () -> Void = {}

    var rowsBottom: CGFloat { super.collectionViewContentSize.height - sectionInset.bottom }

    override var collectionViewContentSize: NSSize {
        var size = super.collectionViewContentSize
        size.height = max(size.height + extraBottom, minimumHeight)
        return size
    }

    override func prepare() {
        super.prepare()
        onPrepared()
    }
}

/// A hero or a column reports its own height: it grows from state of its own — a description
/// opening — that the list never hears about, and it grows a frame at a time.
private struct SelfMeasured: View {
    let content: AnyView
    /// Nil for a row: its cell is already the width it is given.
    let width: CGFloat?
    let report: (CGFloat) -> Void

    var body: some View {
        content
            .frame(width: width, alignment: .topLeading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { report($0) }
            // The host is a step behind while the height changes; held to the top, not centred in it.
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

private final class CardCell: NSCollectionViewItem {
    private var host: ScrollAwareHostingView<AnyView>?

    override func loadView() { view = NSView() }

    func show(_ content: AnyView) {
        if let host {
            host.rootView = content
            return
        }
        let host = ScrollAwareHostingView(rootView: content)
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
    private var host: ScrollAwareHostingView<AnyView>?

    func show(_ content: AnyView) {
        if let host {
            host.rootView = content
            return
        }
        let host = ScrollAwareHostingView(rootView: content)
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
