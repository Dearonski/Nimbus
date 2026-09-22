import SwiftUI

/// The window's toolbar, built in AppKit: Back and Forward as one navigational pair, the way
/// Finder and System Settings carry them — both always there, the one with nowhere to go dimmed.
/// A two-segment control, as Finder's pair is — two loose items share a capsule with no divider
/// between them. Segment widths are set by hand: left to size themselves they came out wider than
/// Finder's, which is 36 points a button.
///
/// Owning the toolbar also means owning what SwiftUI put there: a window with no item at all loses
/// its titlebar area, taking the sidebar's top with it, so the bar always keeps at least a spacer.
private nonisolated let navigationItem = NSToolbarItem.Identifier("nimbus.navigation")

struct WindowToolbar: NSViewRepresentable {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        context.coordinator.update(self)
        // The window is not there yet on the first pass, which is why this waits a turn.
        DispatchQueue.main.async {
            context.coordinator.attach(to: probe.window)
        }
        return probe
    }

    func updateNSView(_ probe: NSView, context: Context) {
        context.coordinator.update(self)
        context.coordinator.attach(to: probe.window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSToolbarDelegate {
        private var goBack: (() -> Void)?
        private var goForward: (() -> Void)?
        private var canGoBack = false
        private var canGoForward = false
        private weak var window: NSWindow?
        private var titleObservation: NSKeyValueObservation?
        /// Remembered once found: while the title is empty there is nothing to recognise it by.
        private weak var titleField: NSTextField?
        private weak var control: NSSegmentedControl?
        private weak var group: NSToolbarItemGroup?

        func update(_ toolbar: WindowToolbar) {
            goBack = toolbar.goBack
            goForward = toolbar.goForward
            canGoBack = toolbar.canGoBack
            canGoForward = toolbar.canGoForward
            applyEnabled()
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            let toolbar = NSToolbar(identifier: "nimbus.window")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            applyEnabled()
            // `.prior`: told before the text changes, so the change lands inside the transition.
            titleObservation = window.observe(\.title, options: [.prior]) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.fadeTitle(of: window) }
            }
        }

        /// The window's title has no animated setter, but it is drawn by a plain text field in the
        /// titlebar: a fade on that field's layer turns the swap into a cross-fade. Found by shape,
        /// not by a private class name — if it is ever not there, the title just changes at once.
        private func fadeTitle(of window: NSWindow) {
            if titleField?.window !== window, !window.title.isEmpty, let frame = window.contentView?.superview {
                titleField = Self.titleField(in: frame)
            }
            guard let field = titleField else { return }
            field.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            field.layer?.add(fade, forKey: "title")
        }

        private static func titleField(in view: NSView) -> NSTextField? {
            for subview in view.subviews {
                if let field = subview as? NSTextField, !field.isEditable,
                   field.stringValue == field.window?.title {
                    return field
                }
                // The page's own content is not the titlebar; only the frame's chrome is searched.
                if subview === view.window?.contentView { continue }
                if let found = titleField(in: subview) { return found }
            }
            return nil
        }

        private func applyEnabled() {
            // Both: the toolbar draws the pair from the subitems, the overflow menu from the control.
            control?.setEnabled(canGoBack, forSegment: 0)
            control?.setEnabled(canGoForward, forSegment: 1)
            if let items = group?.subitems, items.count == 2 {
                items[0].isEnabled = canGoBack
                items[1].isEnabled = canGoForward
            }
        }

        nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [navigationItem, .flexibleSpace]
        }

        nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            // The spacer as well: a bar that is allowed to be empty takes the titlebar down with it.
            [navigationItem, .flexibleSpace]
        }

        nonisolated func toolbar(_ toolbar: NSToolbar,
                                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard identifier == navigationItem else { return nil }
            return MainActor.assumeIsolated {
                let images = [
                    NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")!,
                    NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward")!,
                ]
                let group = NSToolbarItemGroup(itemIdentifier: identifier, images: images,
                                               selectionMode: .momentary, labels: nil,
                                               target: self, action: #selector(navigate(_:)))
                group.label = "Back/Forward"
                group.isNavigational = true
                // Enabled by hand from the history; validation would switch both back on.
                group.autovalidates = false
                group.subitems.forEach { $0.autovalidates = false }
                if let control = group.view as? NSSegmentedControl {
                    for segment in 0..<control.segmentCount {
                        control.setWidth(Self.segmentWidth, forSegment: segment)
                        control.setToolTip(segment == 0 ? "Back" : "Forward", forSegment: segment)
                    }
                    self.control = control
                }
                self.group = group
                applyEnabled()
                return group
            }
        }

        private static let segmentWidth: CGFloat = 26

        @objc private func navigate(_ sender: NSToolbarItemGroup) {
            if sender.selectedIndex == 0 { goBack?() } else { goForward?() }
        }
    }
}
