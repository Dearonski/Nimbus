import AppKit
import SwiftUI

extension View {
    // A per-frame timeline keeps ticking when hidden, occluded or in a collection view's reuse pool.
    func onScreen(_ isOnScreen: Binding<Bool>) -> some View {
        background(OnScreenReader(isOnScreen: isOnScreen))
    }
}

private struct OnScreenReader: NSViewRepresentable {
    @Binding var isOnScreen: Bool

    func makeNSView(context: Context) -> OnScreenView {
        let view = OnScreenView()
        view.onChange = report
        return view
    }

    func updateNSView(_ nsView: OnScreenView, context: Context) {
        nsView.onChange = report
    }

    private func report(_ visible: Bool) {
        if isOnScreen != visible { isOnScreen = visible }
    }
}

private final class OnScreenView: NSView {
    var onChange: ((Bool) -> Void)?
    private var occlusion: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                   object: $0, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        report()
    }

    override func viewDidHide() {
        super.viewDidHide()
        report()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        report()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Deferred: AppKit calls these from inside SwiftUI's own layout pass, where a state write warns.
    private func report() {
        let visible = window.map { !isHiddenOrHasHiddenAncestor && $0.occlusionState.contains(.visible) } ?? false
        DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
    }

    isolated deinit {
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }
}
