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

final class HistoryPageController: NSPageController, NSPageControllerDelegate {
    var page: ((AnyHashable) -> AnyView)?
    var onShow: ((AnyHashable, Bool) -> Void)?

    /// Every page gets an identifier of its own, so the controller never hands one page's view
    /// controller to another and no page inherits a neighbour's scroll position.
    private var identifiers: [AnyHashable: String] = [:]
    private var objects: [String: AnyHashable] = [:]
    private var root: AnyHashable?
    private var monitor: Any?

    var canGoBack: Bool { selectedIndex > 0 }

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

    /// Switching sections starts a new history rather than pushing onto the old one.
    func show(root newRoot: AnyHashable) {
        guard root != newRoot else { return }
        root = newRoot
        arrangedObjects = [newRoot]
        selectedIndex = 0
        report(newRoot)
    }

    func open(_ object: AnyHashable) {
        var list = arrangedObjects.compactMap { $0 as? AnyHashable }
        // Opening something new drops whatever was ahead of it, the way a browser does.
        if selectedIndex < list.count - 1 {
            list.removeSubrange((selectedIndex + 1)...)
        }
        list.append(object)
        arrangedObjects = list
        // Straight to the page, no transition: opening something is a tap, and only coming back —
        // by gesture — is worth animating.
        selectedIndex = list.count - 1
    }

    private func report(_ object: AnyHashable) {
        // Reported on the next turn of the loop: this can run inside SwiftUI's own update, and
        // writing the shell's state from there is "modifying state during view update".
        let back = canGoBack
        DispatchQueue.main.async { [onShow] in onShow?(object, back) }
    }

    private func identifier(for object: AnyHashable) -> String {
        if let known = identifiers[object] { return known }
        let made = UUID().uuidString
        identifiers[object] = made
        objects[made] = object
        return made
    }

    // MARK: - NSPageControllerDelegate

    func pageController(_ pageController: NSPageController,
                        identifierFor object: Any) -> NSPageController.ObjectIdentifier {
        guard let object = object as? AnyHashable else { return UUID().uuidString }
        return identifier(for: object)
    }

    func pageController(_ pageController: NSPageController,
                        viewControllerForIdentifier identifier: NSPageController.ObjectIdentifier)
        -> NSViewController {
        let content = objects[identifier].flatMap { page?($0) } ?? AnyView(Color.clear)
        let host = NSHostingController(rootView: content)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.width, .height]

        // The pages draw no background of their own — the window's was showing through them. That
        // holds until a transition lifts a page off the window, and then there is nothing behind
        // it, so each page carries the window's own material.
        let backing = NSVisualEffectView(frame: view.bounds)
        backing.material = .windowBackground
        backing.blendingMode = .behindWindow
        backing.state = .followsWindowActiveState
        backing.autoresizingMask = [.width, .height]
        backing.addSubview(host.view)

        let wrapper = NSViewController()
        wrapper.view = backing
        wrapper.addChild(host)
        return wrapper
    }

    func pageController(_ pageController: NSPageController,
                        prepare viewController: NSViewController, with object: Any?) {
        guard let host = viewController.children.first as? NSHostingController<AnyView>,
              let object = object as? AnyHashable, let page else { return }
        host.rootView = page(object)
    }

    func pageController(_ pageController: NSPageController, didTransitionTo object: Any) {
        guard let object = object as? AnyHashable else { return }
        report(object)
    }

    /// Without `completeTransition` the content stays hidden behind the transition once it
    /// settles. The report goes out from here too: coming back by gesture, the shell was left
    /// showing the title of the page just left behind.
    func pageControllerDidEndLiveTransition(_ pageController: NSPageController) {
        pageController.completeTransition()
        if let object = arrangedObjects[safe: selectedIndex] as? AnyHashable {
            report(object)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
