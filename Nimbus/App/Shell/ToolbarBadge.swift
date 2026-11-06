// Alone in its file: AppKit's overlay declares `NSItemBadge.indicator` a mutable static, which Swift 6 refuses to read.
@preconcurrency import AppKit

extension NSToolbarItem {
    func showsDot(_ shown: Bool) {
        badge = shown ? .indicator : nil
    }
}
