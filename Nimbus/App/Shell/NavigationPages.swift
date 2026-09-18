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
    /// Fires when the displayed page changes, gesture or button alike, with whether anything is
    /// left behind it.
    let onShow: (AnyHashable, Bool) -> Void
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
private final class PageVisit: NSObject {
    let object: AnyHashable

    init(_ object: AnyHashable) {
        self.object = object
    }
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
    var onShow: ((AnyHashable, Bool) -> Void)?

    // Held here: the controller's reuse queue keeps every view controller it was ever handed.
    private var pages: [PageVisit: NSHostingController<AnyView>] = [:]
    private var recentRoots: [PageVisit] = []
    private var root: AnyHashable?
    private var monitor: Any?
    private var isSwiping = false
    private var isTrimScheduled = false

    private static let keptBehind = 4
    private static let keptSections = 3

    var canGoBack: Bool { selectedIndex > 0 }

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
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, MainActor.assumeIsolated({ self.allows(event) }) else { return nil }
            return event
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Only one gesture is on offer: a swipe back, over this column, with a page behind this one.
    /// Forward is not — a walkable history is a browser idea, and nothing here asks for it.
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
        return event.scrollingDeltaX > 0 && canGoBack
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

    /// Switching sections starts a new history; a section left recently comes back as it was left.
    func show(root newRoot: AnyHashable) {
        guard root != newRoot else { return }
        root = newRoot
        let visit = recentRoots.first { $0.object == newRoot } ?? PageVisit(newRoot)
        recentRoots.removeAll { $0 === visit }
        recentRoots = Array((recentRoots + [visit]).suffix(Self.keptSections))
        arrangedObjects = [visit]
        selectedIndex = 0
        report(newRoot)
        scheduleTrim()
    }

    func open(_ object: AnyHashable) {
        var list = visits
        // Opening something new drops whatever was ahead of it, the way a browser does.
        if selectedIndex < list.count - 1 {
            list.removeSubrange((selectedIndex + 1)...)
        }
        list.append(PageVisit(object))
        arrangedObjects = list
        // Straight to the page, no transition: opening something is a tap, and only coming back —
        // by gesture — is worth animating.
        selectedIndex = list.count - 1
        scheduleTrim()
    }

    private func report(_ object: AnyHashable) {
        // Reported on the next turn of the loop: this can run inside SwiftUI's own update, and
        // writing the shell's state from there is "modifying state during view update".
        let back = canGoBack
        DispatchQueue.main.async { [onShow] in onShow?(object, back) }
    }

    private func host(for visit: PageVisit) -> NSHostingController<AnyView> {
        if let made = pages[visit] { return made }
        let made = NSHostingController(rootView: page?(visit.object) ?? AnyView(Color.clear))
        pages[visit] = made
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

    private func trimPages() {
        guard !isSwiping else { return }
        let list = visits
        var kept = Set(recentRoots)
        if let first = list.first { kept.insert(first) }
        let low = max(0, selectedIndex - Self.keptBehind)
        // The page just left stays too: Back may still be animating it away.
        let high = min(list.count - 1, selectedIndex + 1)
        if low <= high { kept.formUnion(list[low...high]) }
        for (visit, host) in pages where !kept.contains(visit) {
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
