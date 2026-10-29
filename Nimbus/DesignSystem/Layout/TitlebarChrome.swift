import AppKit

/// Everything in a window's titlebar but the window buttons, faded out under a layer laid over the
/// whole window and back. Turning the toolbar off instead would re-lay the whole window.
@MainActor
final class TitlebarChrome {
    private var hidden: [NSView] = []

    func hide(in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard hidden.isEmpty, var titlebar = buttons.first?.superview else { return }
        while let parent = titlebar.superview, parent !== window.contentView?.superview { titlebar = parent }

        func collect(in view: NSView) {
            for subview in view.subviews where !buttons.contains(where: { $0 === subview }) {
                if buttons.contains(where: { $0.isDescendant(of: subview) }) {
                    collect(in: subview)
                } else if !subview.isHidden {
                    hidden.append(subview)
                }
            }
        }
        collect(in: titlebar)
        fade(to: 0)
    }

    func show() {
        guard !hidden.isEmpty else { return }
        fade(to: 1)
        hidden = []
    }

    /// In step with the layer: switched off outright, the bar blinked out over a layer still fading in.
    private func fade(to alpha: CGFloat) {
        let views = hidden
        if alpha > 0 { for view in views { view.isHidden = false } }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            for view in views { view.animator().alphaValue = alpha }
        } completionHandler: {
            // Hidden as well as clear, so the bar's buttons can't be clicked through the layer.
            MainActor.assumeIsolated { if alpha == 0 { for view in views { view.isHidden = true } } }
        }
    }
}
