import AppKit
import SwiftUI

/// Whether anything in the app is being scrolled. A trackpad slides rows under a pointer that is
/// standing still, so each row passing beneath it takes a hover and redraws mid-scroll.
/// A plain flag on purpose: an observed one would redraw every visible row as scrolling starts.
@MainActor
enum ScrollActivity {
    private final class Scrolled {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private static var scrolling: [ObjectIdentifier: Scrolled] = [:]
    private static weak var heldWindow: NSWindow?
    private static var watchdog: Timer?

    static var isLive: Bool {
        guard !scrolling.isEmpty else { return false }
        prune()
        return !scrolling.isEmpty
    }

    /// SwiftUI's scroll views are `NSScrollView`s underneath and post the same notifications, so one
    /// pair of observers covers the AppKit lists and every SwiftUI page alike.
    static func start() {
        let center = NotificationCenter.default
        center.addObserver(watcher, selector: #selector(Watcher.began),
                           name: NSScrollView.willStartLiveScrollNotification, object: nil)
        center.addObserver(watcher, selector: #selector(Watcher.ended),
                           name: NSScrollView.didEndLiveScrollNotification, object: nil)
    }

    private static let watcher = Watcher()

    // Selectors rather than blocks: a block observer is `@Sendable`, and the scroll view is not.
    private final class Watcher: NSObject {
        @objc func began(_ note: Notification) {
            guard let view = note.object as? NSView else { return }
            ScrollActivity.began(view)
        }

        @objc func ended(_ note: Notification) {
            guard let view = note.object as? NSView else { return }
            ScrollActivity.ended(view)
        }
    }

    private static func began(_ view: NSView) {
        scrolling[ObjectIdentifier(view)] = Scrolled(view)
        holdWindow(of: view)
        guard watchdog == nil else { return }
        // A page taken off screen mid-momentum may never post its end, and a flag left up would keep
        // hover dead and the window pinned for good.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { prune() }
        }
    }

    private static func ended(_ view: NSView) {
        scrolling[ObjectIdentifier(view)] = nil
        prune()
    }

    private static func prune() {
        scrolling = scrolling.filter { $0.value.view?.window != nil }
        guard scrolling.isEmpty else { return }
        watchdog?.invalidate()
        watchdog = nil
        heldWindow?.isMovable = true
        heldWindow = nil
    }

    /// With content under the titlebar AppKit rebuilds the window's drag region on every scroll frame,
    /// walking every responder and every nested host's focus items: 19% of the main thread on History,
    /// 0.6% with the window held (measured 20.09.2026). Nobody drags a window mid-scroll.
    private static func holdWindow(of view: NSView) {
        guard heldWindow == nil, let window = view.window, window.isMovable else { return }
        window.isMovable = false
        heldWindow = window
    }
}

/// A hosting view that does not search itself for a focusable item while something scrolls. With the
/// page under the titlebar, AppKit asks on every scroll frame whether what lies there blocks a window
/// drag, and a host answers `acceptsFirstResponder` by walking its whole tree — and every host nested
/// in it — until it finds one. A page with a text field stops at once; one without, History, walked
/// every button of every cell: 20% of the main thread, measured 20.09.2026.
final class ScrollAwareHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool {
        ScrollActivity.isLive ? false : super.acceptsFirstResponder
    }
}

extension View {
    /// `onHover` for anything that scrolls: silent while the list moves, and caught up the moment it
    /// stops — `onHover` only speaks on entering and leaving, so the row the pointer ends up on would
    /// otherwise stay unlit until the pointer left it and came back.
    ///
    /// `resetOn` is for a row that lives in a recycled cell: its state rides on to the next item, and
    /// a cell taken away under the pointer never hears the hover end.
    func onScrollSafeHover(resetOn item: AnyHashable? = nil, perform action: @escaping (Bool) -> Void) -> some View {
        modifier(ScrollSafeHover(item: item, action: action))
    }
}

private struct ScrollSafeHover: ViewModifier {
    let item: AnyHashable?
    let action: (Bool) -> Void

    // A reference, not a value: where the pointer is must not redraw the row by itself.
    @State private var pointer = Pointer()

    private final class Pointer {
        var isInside = false
    }

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pointer.isInside = inside
                action(inside && !ScrollActivity.isLive)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didEndLiveScrollNotification)) { _ in
                if pointer.isInside { action(true) }
            }
            .onChange(of: item) { _, _ in
                pointer.isInside = false
                action(false)
            }
    }
}
