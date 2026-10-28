import AppKit
import SwiftUI

extension View {
    /// Space toggles playback from anywhere in the window, so it is watched at the event level
    /// rather than with `onKeyPress`: SwiftUI routes key events into the view tree only while
    /// something inside it holds focus, and once a text field handed focus back, nothing did —
    /// Space stopped arriving at all on any page that has a field.
    func shellKeys(model: AppModel, viewer: ArtworkViewer, fullPlayer: FullPlayerPresenter,
                   window: @escaping () -> NSWindow?) -> some View {
        modifier(ShellKeyMonitor(model: model, viewer: viewer, fullPlayer: fullPlayer, window: window))
    }
}

private struct ShellKeyMonitor: ViewModifier {
    let model: AppModel
    let viewer: ArtworkViewer
    let fullPlayer: FullPlayerPresenter
    let window: () -> NSWindow?

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: start)
            .onDisappear(perform: stop)
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [model, viewer, fullPlayer, window] event in
            // This window and its panels only — the picture viewer is a child panel. Sparkle's
            // window becomes main too, and Space there paused the music.
            let inShell = MainActor.assumeIsolated { () -> Bool in
                guard let shell = window(), let target = event.window else { return false }
                return target === shell || target.parent === shell
            }
            guard inShell else { return event }
            // Bare Space only: ⌘Space and friends belong to the system.
            let bare = event.modifierFlags
                .intersection([.command, .option, .control, .shift]).isEmpty
            // With a picture open, Esc and Space close it — Space the way it closes Quick Look —
            // instead of reaching the page or the player behind it.
            if bare, event.keyCode == 53 || event.keyCode == 49 {
                let closed = MainActor.assumeIsolated { () -> Bool in
                    guard viewer.viewing != nil else { return false }
                    viewer.dismiss()
                    return true
                }
                if closed { return nil }
            }
            if bare, event.keyCode == 53 {
                let closed = MainActor.assumeIsolated { () -> Bool in
                    guard fullPlayer.isOpen else { return false }
                    fullPlayer.close()
                    return true
                }
                if closed { return nil }
            }
            guard event.keyCode == 49 && bare else { return event }
            // Only a Bool crosses back out of the actor: NSEvent is not Sendable.
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                // Both: the fields' own report, and a text editor actually holding the keyboard — a
                // report left standing by a field that lost focus unseen must not cost Space.
                if model.isTypingInField, event.window?.firstResponder is NSTextView { return false }
                model.player.togglePlayPause()
                return true
            }
            return swallowed ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
