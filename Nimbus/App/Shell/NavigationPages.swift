import SwiftUI

/// The detail column's navigation, run by `NSPageController` instead of `NavigationStack`.
///
/// What it buys: the back gesture itself. AppKit tracks the two-finger swipe, animates one page out
/// to the right to reveal the one before it — `stackHistory` is the style Safari uses — and deals
/// with a swipe abandoned halfway. Forward comes with it, which `NavigationPath` cannot do at all:
/// it does not even hand back what it pops.
///
/// Custom mode, not history mode. History mode is less code, but it animates *snapshots* of the
/// pages, and a snapshot of a hosting view misses whatever the system draws for us — glass above
/// all — so the page came apart mid-gesture and wanted an opaque colour behind it, which this
/// column never had. Supplying view controllers keeps both pages live through the transition.
struct NavigationPages: NSViewControllerRepresentable {
    /// Where the column sits when nothing is pushed — the section chosen in the sidebar.
    let root: AnyHashable
    /// Builds a page. The environment does not cross into a hosting controller, so everything a
    /// page needs is applied here, at the point it is made.
    let page: (AnyHashable) -> AnyView
    /// Fires when the displayed page changes, gesture or button alike, with whether there is a
    /// page behind it and one ahead of it.
    let onShow: (AnyHashable, Bool, Bool) -> Void
    @Binding var controller: HistoryPageController?

    func makeNSViewController(context: Context) -> HistoryPageController {
        let made = HistoryPageController()
        made.page = page
        made.onShow = onShow
        made.loadViewIfNeeded()
        made.show(root: root)
        DispatchQueue.main.async { controller = made }
        return made
    }

    func updateNSViewController(_ made: HistoryPageController, context: Context) {
        made.page = page
        made.onShow = onShow
        made.show(root: root)
    }
}

/// One visit to a page: the same artist opened twice is two visits, each with a page of its own.
/// A visit is cheap and the history keeps many; the page it shows is kept for only a few.
private final class PageVisit: NSObject {
    let object: AnyHashable
    /// How far down the page was when its view was let go, so coming back lands where it was left.
    var scrollOffset: CGFloat?

    init(_ object: AnyHashable) {
        self.object = object
    }
}

/// A section's own walk: switching sections and back returns to it, both directions intact.
private struct SectionHistory {
    var visits: [PageVisit]
    var index: Int
}

/// What the page controller recycles. The page itself is moved in on `prepare`.
private final class PageSlot: NSViewController {
    override func loadView() {
        // The pages draw no background of their own — the window's was showing through them. That
        // holds until a transition lifts a page off the window, and then there is nothing behind
        // it, so each page carries the window's own material.
        let backing = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        backing.material = .windowBackground
        backing.blendingMode = .behindWindow
        backing.state = .followsWindowActiveState
        view = backing
    }

    func hold(_ page: NSViewController?) {
        for child in children where child !== page {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        guard let page, page.parent !== self else { return }
        page.view.removeFromSuperview()
        page.removeFromParent()
        page.view.frame = view.bounds
        page.view.autoresizingMask = [.width, .height]
        addChild(page)
        view.addSubview(page.view)
    }
}

final class HistoryPageController: NSPageController, NSPageControllerDelegate {
    var page: ((AnyHashable) -> AnyView)?
    var onShow: ((AnyHashable, Bool, Bool) -> Void)?

    // Held here: the controller's reuse queue keeps every view controller it was ever handed.
    private var pages: [PageVisit: NSHostingController<AnyView>] = [:]
    private var histories: [AnyHashable: SectionHistory] = [:]
    /// The sections visited last, the current one at the end.
    private var recentSections: [AnyHashable] = []
    private var root: AnyHashable?
    private var monitor: Any?
    private var memoryPressure: (any DispatchSourceMemoryPressure)?
    private var isSwiping = false
    private var isTrimScheduled = false

    /// Live pages: a neighbour each way so a swipe shows a real page, one more behind because Back
    /// is the common walk. Everything further is a visit that rebuilds its page when reached.
    private static let keptBehind = 2
    private static let keptAhead = 1
    private static let keptSections = 3
    private static let visitLimit = 50

    var canGoBack: Bool { selectedIndex > 0 }
    var canGoForward: Bool { selectedIndex < arrangedObjects.count - 1 }

    private var visits: [PageVisit] { arrangedObjects.compactMap { $0 as? PageVisit } }

    init() {
        super.init(nibName: nil, bundle: nil)
        // Set here, not in viewDidLoad: `arrangedObjects` is filled before the view is ever loaded,
        // and a controller without a delegate at that moment has no way to ask for a page — the
        // column came up empty and never recovered.
        delegate = self
        transitionStyle = .stackHistory
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not from a nib")
    }

    override func loadView() {
        // A zero-sized container leaves every page it hosts zero-sized too, and the column came up
        // blank; the real size arrives from the split view a moment later.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard monitor == nil else { return }
        // Overriding `scrollWheel` on the container did nothing — the controller takes the event
        // before the view ever sees it — so the unwanted ones are stopped before delivery.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            let passes = MainActor.assumeIsolated {
                event.type == .otherMouseDown ? !self.navigates(with: event) : self.allows(event)
            }
            return passes ? event : nil
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.trimPages(underPressure: true) }
        }
        pressure.activate()
        memoryPressure = pressure
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        memoryPressure?.cancel()
        memoryPressure = nil
    }

    // Buttons, keys and mouse buttons step without a transition, as opening a page does: only the
    // gesture, which the fingers drive, is worth animating.
    func goBack() {
        guard canGoBack else { return }
        step(to: selectedIndex - 1)
    }

    func goForward() {
        guard canGoForward else { return }
        step(to: selectedIndex + 1)
    }

    private func step(to index: Int) {
        guard !isSwiping, let visit = arrangedObjects[safe: index] as? PageVisit else { return }
        selectedIndex = index
        settle(on: visit)
    }

    /// The side buttons of a mouse, the way every Mac browser and Finder read them.
    private func navigates(with event: NSEvent) -> Bool {
        guard event.window === view.window else { return false }
        switch event.buttonNumber {
        case 3: goBack()
        case 4: goForward()
        default: return false
        }
        return true
    }

    /// A horizontal swipe over this column pages through its history, either way there is a page.
    private func allows(_ event: NSEvent) -> Bool {
        guard event.window === view.window,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        else { return true }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(point) else { return true }
        // A shelf of cards scrolls sideways under the same two fingers and keeps its own gesture.
        if scrollsSideways(under: event) { return true }
        // Rightwards travel means going back: the sign follows the content, and the content moves
        // with the fingers.
        return event.scrollingDeltaX > 0 ? canGoBack : canGoForward
    }

    private func scrollsSideways(under event: NSEvent) -> Bool {
        guard let hit = view.window?.contentView?.hitTest(event.locationInWindow) else { return false }
        var current: NSView? = hit
        while let view = current {
            if let scroll = view as? NSScrollView ?? view.enclosingScrollView,
               let document = scroll.documentView,
               document.frame.width > scroll.contentView.bounds.width + 1 {
                return true
            }
            current = view.superview
        }
        return false
    }

    /// Each section keeps its own history: coming back to one lands on the page it was left on,
    /// with Back and Forward as they were.
    func show(root newRoot: AnyHashable) {
        guard root != newRoot else { return }
        if let root, !visits.isEmpty {
            histories[root] = SectionHistory(visits: visits, index: selectedIndex)
        }
        root = newRoot
        recentSections.removeAll { $0 == newRoot }
        recentSections = Array((recentSections + [newRoot]).suffix(Self.keptSections))
        let history = histories[newRoot] ?? SectionHistory(visits: [PageVisit(newRoot)], index: 0)
        arrangedObjects = history.visits
        selectedIndex = history.index
        report(history.visits[history.index].object)
        scheduleTrim()
    }

    /// The section already shown, pressed again in the sidebar: back to its first page, with the
    /// way forward kept, so Forward undoes it.
    func showRoot() {
        guard canGoBack else { return }
        step(to: 0)
    }

    func open(_ object: AnyHashable) {
        var list = visits
        // Opening something new drops whatever was ahead of it, the way a browser does.
        if selectedIndex < list.count - 1 {
            list.removeSubrange((selectedIndex + 1)...)
        }
        list.append(PageVisit(object))
        // The oldest go, never the section's own first page.
        while list.count > Self.visitLimit { list.remove(at: 1) }
        arrangedObjects = list
        // Straight to the page, no transition: opening something is a tap, and only coming back —
        // by gesture — is worth animating.
        selectedIndex = list.count - 1
        scheduleTrim()
    }

    private func report(_ object: AnyHashable) {
        // Reported on the next turn of the loop: this can run inside SwiftUI's own update, and
        // writing the shell's state from there is "modifying state during view update".
        let back = canGoBack, forward = canGoForward
        DispatchQueue.main.async { [onShow] in onShow?(object, back, forward) }
    }

    private func host(for visit: PageVisit) -> NSHostingController<AnyView> {
        if let made = pages[visit] { return made }
        let made = NSHostingController(rootView: page?(visit.object) ?? AnyView(Color.clear))
        pages[visit] = made
        if let offset = visit.scrollOffset {
            visit.scrollOffset = nil
            PageScroll.restore(offset, in: made.view)
        }
        return made
    }

    // Next turn of the loop: `show(root:)` runs inside SwiftUI's update, before the slots swap.
    private func scheduleTrim() {
        guard !isTrimScheduled else { return }
        isTrimScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isTrimScheduled = false
            trimPages()
        }
    }

    /// Under memory pressure only the page on screen and its two neighbours stay.
    private func trimPages(underPressure: Bool = false) {
        guard !isSwiping else { return }
        let list = visits
        var kept = Set<PageVisit>()
        let low = max(0, selectedIndex - (underPressure ? 1 : Self.keptBehind))
        let high = min(list.count - 1, selectedIndex + Self.keptAhead)
        if low <= high { kept.formUnion(list[low...high]) }
        if !underPressure {
            // A section's first page is the one a sidebar press returns to, and the costliest to rebuild.
            if let first = list.first { kept.insert(first) }
            for section in recentSections where section != root {
                if let history = histories[section] { kept.insert(history.visits[history.index]) }
            }
        }
        for (visit, host) in pages where !kept.contains(visit) {
            visit.scrollOffset = PageScroll.offset(in: host.view)
            host.view.removeFromSuperview()
            host.removeFromParent()
            pages[visit] = nil
        }
    }

    // Moved only when it is on screen nowhere: pulled out of a running transition, it would blank.
    private func settle(on visit: PageVisit) {
        let host = host(for: visit)
        if host.view.window == nil {
            (selectedViewController as? PageSlot)?.hold(host)
        }
        report(visit.object)
        scheduleTrim()
    }

    // MARK: - NSPageControllerDelegate

    func pageController(_ pageController: NSPageController,
                        identifierFor object: Any) -> NSPageController.ObjectIdentifier {
        "page"
    }

    func pageController(_ pageController: NSPageController,
                        viewControllerForIdentifier identifier: NSPageController.ObjectIdentifier)
        -> NSViewController {
        let slot = PageSlot()
        slot.view.frame = view.bounds
        slot.view.autoresizingMask = [.width, .height]
        return slot
    }

    // Moved in, never rebuilt: a fresh `rootView` scrolled the page back to the top mid-transition.
    func pageController(_ pageController: NSPageController,
                        prepare viewController: NSViewController, with object: Any?) {
        guard let slot = viewController as? PageSlot else { return }
        slot.hold((object as? PageVisit).map { host(for: $0) })
    }

    func pageController(_ pageController: NSPageController, didTransitionTo object: Any) {
        guard let visit = object as? PageVisit, !isSwiping else { return }
        settle(on: visit)
    }

    func pageControllerWillStartLiveTransition(_ pageController: NSPageController) {
        isSwiping = true
    }

    /// Without `completeTransition` the content stays hidden behind the transition once it
    /// settles. The report goes out from here too: coming back by gesture, the shell was left
    /// showing the title of the page just left behind.
    func pageControllerDidEndLiveTransition(_ pageController: NSPageController) {
        pageController.completeTransition()
        isSwiping = false
        if let visit = arrangedObjects[safe: selectedIndex] as? PageVisit {
            settle(on: visit)
        }
    }
}

/// A page's own scroll position, read off whatever view scrolls it — the list's collection or a
/// SwiftUI scroll view, both an `NSScrollView` underneath.
@MainActor
private enum PageScroll {
    static func offset(in view: NSView) -> CGFloat? {
        guard let scroll = main(in: view) else { return nil }
        let offset = scroll.contentView.bounds.minY + scroll.contentInsets.top
        return offset > 1 ? offset : nil
    }

    /// Waits for the rebuilt page to grow tall enough, then puts it back in one move rather than
    /// chasing the content down as it loads. A hand on the page first wins.
    static func restore(_ offset: CGFloat, in view: NSView) {
        Task { @MainActor [weak view] in
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let view, !ScrollActivity.isLive else { return }
                guard let scroll = main(in: view), let document = scroll.documentView else { continue }
                let clip = scroll.contentView
                let top = -scroll.contentInsets.top
                // Moved already: someone is reading.
                guard clip.bounds.minY <= top + 1 else { return }
                let bottom = document.frame.height - clip.bounds.height + scroll.contentInsets.bottom
                guard bottom >= top + offset else { continue }
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top + offset))
                scroll.reflectScrolledClipView(clip)
                return
            }
        }
    }

    /// The largest scroll view in the page is the page's own; shelves and rails scroll inside it.
    private static func main(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var queue = [view]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? NSScrollView,
               scroll.frame.width * scroll.frame.height > (best.map { $0.frame.width * $0.frame.height } ?? 0) {
                best = scroll
            }
            queue.append(contentsOf: next.subviews)
        }
        return best
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
