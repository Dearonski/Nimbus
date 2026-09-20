import AppKit
import SwiftUI

/// Whether anything in the app is being scrolled. A trackpad slides rows under a pointer that is
/// standing still, so each row passing beneath it takes a hover and redraws mid-scroll.
/// A plain flag on purpose: an observed one would redraw every visible row as scrolling starts.
@MainActor
enum ScrollActivity {
    private static var scrolling: Set<ObjectIdentifier> = []

    static var isLive: Bool { !scrolling.isEmpty }

    /// SwiftUI's scroll views are `NSScrollView`s underneath and post the same notifications, so one
    /// pair of observers covers the AppKit lists and every SwiftUI page alike.
    static func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { note in
            guard let view = note.object as AnyObject? else { return }
            let id = ObjectIdentifier(view)
            MainActor.assumeIsolated { _ = scrolling.insert(id) }
        }
        center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { note in
            guard let view = note.object as AnyObject? else { return }
            let id = ObjectIdentifier(view)
            MainActor.assumeIsolated { _ = scrolling.remove(id) }
        }
    }
}

extension View {
    /// `onHover` for anything that scrolls: silent while the list moves, and caught up the moment it
    /// stops — `onHover` only speaks on entering and leaving, so the row the pointer ends up on would
    /// otherwise stay unlit until the pointer left it and came back.
    func onScrollSafeHover(perform action: @escaping (Bool) -> Void) -> some View {
        modifier(ScrollSafeHover(action: action))
    }
}

private struct ScrollSafeHover: ViewModifier {
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
    }
}
