import AppKit
import SwiftUI

struct ShellOverlay: View {
    let model: AppModel
    let shell: ShellState
    let hits: OverlayHits

    @State private var showsCrashNotice = Diagnostics.previousRunEndedBadly

    var body: some View {
        ZStack {
            PlayerPill(
                player: model.player,
                onOpenTrack: { shell.open($0) },
                onOpenArtist: { shell.open($0) },
                onExpand: { shell.toggleFullPlayer(fullScreen: false) },
                onArtworkView: { shell.fullPlayer.pillArtwork = $0 },
                hidesArtwork: shell.fullPlayer.isOpen,
                isQueueVisible: Binding(get: { shell.isQueueVisible }, set: { shell.setQueueVisible($0) }),
                onHitArea: { hits.pill = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            banner
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(.snappy, value: showsCrashNotice)
        .animation(.snappy, value: model.player.lastError)
        .environment(\.navigator, Navigator { [weak shell] in shell?.open(AnyHashable($0)) })
        .environment(shell.viewer)
        .environment(model.library)
        .tint(.scOrange)
    }

    @ViewBuilder
    private var banner: some View {
        if let error = model.player.lastError {
            reporting(PlaybackErrorBanner(message: error) { model.player.dismissError() })
        } else if showsCrashNotice {
            reporting(CrashNoticeBanner {
                Diagnostics.reportIssue()
                showsCrashNotice = false
            } onDismiss: {
                showsCrashNotice = false
            })
        }
    }

    private func reporting(_ banner: some View) -> some View {
        banner
            // `.global`, not a space named on the root: that one starts below the toolbar.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                hits.banner = $0
            }
            .onDisappear { hits.banner = .zero }
    }
}

// Read on every hit test, so a plain reference: as state it would redraw the overlay each time the pill moved.
final class OverlayHits {
    var pill: CGRect = .zero
    var banner: CGRect = .zero
}

// Spans the column but takes the pointer only over the pill or a banner, so the page under it keeps the rest.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var hits: OverlayHits?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hits, let content = window?.contentView else { return super.hitTest(point) }
        // The hits come in SwiftUI's `.global`, which is the window's space from its top-left corner.
        let inWindow = convert(convert(point, from: superview), to: nil)
        let topDown = CGPoint(x: inWindow.x, y: content.frame.height - inWindow.y)
        guard hits.pill.contains(topDown) || hits.banner.contains(topDown) else { return nil }
        return super.hitTest(point)
    }
}
