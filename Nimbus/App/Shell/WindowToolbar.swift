import SwiftUI

/// The window's toolbar, built in AppKit so the Back button can animate in and out.
///
/// SwiftUI inserts and removes a `ToolbarItem` whole: the arrow appeared from nowhere, and every way
/// around it inside SwiftUI cost more than it bought — a button kept in place but made invisible
/// still leaves the bar's own backing behind. `NSToolbar` animates `insertItem` and `removeItem`
/// itself, which is what Apple's own apps look like.
///
/// Owning the toolbar also means owning what SwiftUI put there: a window with no item at all loses
/// its titlebar area, taking the sidebar's top with it, so the bar always keeps at least a spacer.
private nonisolated let backItem = NSToolbarItem.Identifier("nimbus.back")

struct WindowToolbar: NSViewRepresentable {
    let canGoBack: Bool
    let goBack: () -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        context.coordinator.goBack = goBack
        // The window is not there yet on the first pass, which is why this waits a turn.
        DispatchQueue.main.async {
            context.coordinator.attach(to: probe.window, canGoBack: canGoBack)
        }
        return probe
    }

    func updateNSView(_ probe: NSView, context: Context) {
        context.coordinator.goBack = goBack
        context.coordinator.attach(to: probe.window, canGoBack: canGoBack)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSToolbarDelegate {
        var goBack: (() -> Void)?
        private weak var window: NSWindow?
        private var showsBack = false



        func attach(to window: NSWindow?, canGoBack: Bool) {
            guard let window else { return }
            if self.window !== window {
                self.window = window
                let toolbar = NSToolbar(identifier: "nimbus.window")
                toolbar.delegate = self
                toolbar.displayMode = .iconOnly
                window.toolbar = toolbar
                showsBack = false
            }
            guard showsBack != canGoBack, let toolbar = window.toolbar else { return }
            showsBack = canGoBack
            // Animated by AppKit, which is the whole point of doing this here.
            if canGoBack {
                toolbar.insertItem(withItemIdentifier: backItem, at: 0)
            } else if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == backItem }) {
                toolbar.removeItem(at: index)
            }
        }

        nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [backItem, .flexibleSpace]
        }

        nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            // A bar that is allowed to be empty takes the titlebar down with it.
            [.flexibleSpace]
        }

        nonisolated func toolbar(_ toolbar: NSToolbar,
                                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard identifier == backItem else { return nil }
            return MainActor.assumeIsolated {
                let item = NSToolbarItem(itemIdentifier: identifier)
                item.label = "Back"
                item.toolTip = "Back"
                item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
                item.target = self
                item.action = #selector(back)
                item.isNavigational = true
                return item
            }
        }

        @objc private func back() {
            goBack?()
        }
    }
}
